{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE UnboxedSums #-}
{-# LANGUAGE UnboxedTuples #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ViewPatterns #-}
-- | Reading the bytes of a TDS response, when those bytes arrive in pieces.
--
-- = The problem
--
-- A server's response is one long sequence of bytes, but it reaches the client as
-- a series of packets, and a packet can end anywhere: between two columns, in the
-- middle of an integer, or thousands of bytes into a long value.  A reader that
-- reaches the end of a packet has to stop, wait for the next one, and carry on
-- exactly where it was.  Most of the code that understands TDS shouldn't have to
-- know that any of this happens.
--
-- = Recipes
--
-- A /recipe/ describes what to read and in what order, written as ordinary monadic
-- code.  This one reads a length byte and then that many bytes:
--
-- > shortValue :: Parser B.ByteString
-- > shortValue = word8 >>= \n -> boundedBytes (fromIntegral n)
--
-- A recipe is only a value, so defining one reads nothing.  It says nothing about
-- packets either, so it gives the same answer wherever the packets happen to end.
-- 'parseChunks' runs a recipe over payloads already in memory, and returns the
-- result and the input left over:
--
-- > parseChunks shortValue ["\3abcdef"]         -- ("abc", ["def"])
-- > parseChunks shortValue ["\3a", "b", "cdef"] -- ("abc", ["def"])
--
-- = Suspending
--
-- When a recipe runs out of input partway through, it doesn't fail and it doesn't
-- block.  It returns a suspended computation, which holds everything it still has
-- to do, including what it has already read.  Whoever is running the recipe, called
-- its /driver/, fetches the next payload and gives it to that computation:
--
-- > case runParser shortValue "\3a" of
-- >   Right (Got value rest) -> ...            -- complete within this payload
-- >   Left suspended -> inspect suspended >>= \case
-- >     Right (NeedMore continue) -> ...       -- call continue (More nextPayload)
-- >     ...
--
-- This is what keeps the recipes simple.  Where a read has got to is simply where
-- the code is, so a recipe holds no record of its column or its position.  It is
-- also what keeps the module independent of the transport, because TLS, SMP
-- sessions and the packet framing all sit behind the driver.  Most callers should
-- use 'runFrom' or 'parseChunks' rather than write a driver, because a driver has a
-- rule to follow, which 'runFrom' describes.
--
-- = Writing your own
--
-- A recipe for something hmssql doesn't read yet needs only the reads below and
-- @do@ notation.  'fail' stops with a 'ProtocolError'.  For example, a token with a
-- 16-bit length around a list of strings:
--
-- > names :: Parser [Text]
-- > names = do
-- >   size <- word16le
-- >   isolate (fromIntegral size) $ do
-- >     n <- word8
-- >     count (fromIntegral n) bVarChar
--
-- 'chunk' is the most general read, because it gives whatever part of the requested
-- bytes is available, so any format can be built from it.
--
-- A recipe can fail in two ways, which mean different things.  Throwing, as 'fail'
-- does, ends the recipe, so nothing more can be read and the connection is broken.
-- Use it for bytes that make no sense.  A value that was read correctly but can't be
-- used is a 'failValue' instead, once its bytes have been read.  It skips the rest of
-- the recipe up to the nearest 'recover' or 'attempt', which goes on reading from where
-- the failure was.
--
-- This module only reads.  To send something hmssql has no type for, such as a
-- table-valued parameter, build a 'Hmssql.Query.Types.Request' whose body uses
-- "Hmssql.Tds.PacketWriter" and the builders of "Hmssql.Tds.Client".
module Hmssql.Tds.Parser
  ( -- * Recipes and their driver
    Parser, parse, runParser, runParserAt, parseChunks, runFrom
  , Got (..), At (..), Await (..), Feed (..), feedBytes, Runner (..), feedRunner
  , effect, consume, consumeWhole, dynamic, oneShotRecipe
    -- * Failed values
    -- | A value that was read but can't be used fails its recipe with 'failValue',
    -- and 'recover' or 'attempt' catches the failure further out, where the reading
    -- can go on.  A row decoder uses this so that a failed cell stops the row without
    -- every cell's result being an 'Either'.
  , failValue, recover, attempt
    -- * Read-only environments
    -- | A recipe can read a value that isn't in the input.  A row decoder uses this
    -- for the row's null bitmap, so that one recipe, prepared once, serves every row:
    --
    -- > plusBase :: Recipe Word8 Word8
    -- > plusBase = (+) <$> ask <*> liftParser word8
    -- >
    -- > parseChunks (withEnv 10 plusBase) ["\5"]    -- (15, [])
  , Recipe, ask, withEnv, liftParser
    -- * Primitive reads
  , peekToken, peekWord8
  , word8, word16le, word32le, word64le, word32be
  , bytes, ownedBytes, boundedBytes, ownedBoundedBytes
  , chunk, chunkOrDiscard, skip, count
  , bVarChar, usVarChar, isolate, limited
    -- * Value ownership and assembly
  , ValueBytes (..), valueBytes, keepBytes, bytesValue, convertBytes, prefixedValue, prefixedRowValue
  , Accumulator, accumulator, append, finish
    -- * Read failures
  , ReadFailure (..), DecodeError (..), ProtocolError (..), ResultAbandoned (..)
  ) where

import Control.Exception (Exception, throwIO, mask_, finally)
import Control.Monad (unless)
import Data.IORef
import qualified Streaming as S
import qualified Streaming.Prelude as S
import Streaming (Of (..))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Unsafe as BU
import Data.Bits (shiftL, testBit, (.|.))
import Data.Text (Text)
import Hmssql.Internal.Derived
import qualified Hmssql.Tds.Utf16 as Utf16
import Data.Word (Word8, Word16, Word32, Word64)
import Foreign.ForeignPtr (ForeignPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (plusPtr)
import Data.Primitive.SmallArray (SmallArray (..), smallArrayFromListN)
import GHC.Exts (Int (..), Int#, indexSmallArray#, int2Word#, isTrue#, ltWord#, oneShot, (+#), (>=#), (==#))
import Streaming (Stream, inspect)
import Streaming.Internal (Stream (..))
import qualified Hmssql.Tds.Bytes as Read

-- The shape of this module.
--
-- Where a read has got to is where the code is.  The continuation is ordinary
-- Haskell, so a value suspended at a packet boundary needs no phase to resume, an
-- interrupted drain needs no position, and a row cut by a packet is neither rewound
-- nor decoded twice.  A reader that is pushed chunks instead has to store all of
-- that by hand: a column, a phase, and a carry for a delimiter cut by a packet's
-- end.
--
-- Costs and alternatives, measured against the saved binaries in
-- docs/dev/value-streaming-research.md:
--
-- * A bind must be able to reach its continuation from the suspended branch, so
--   wherever GHC inlines a whole row, that continuation is used twice and becomes a
--   heap closure per bind. This is why row decoders are closures compiled per column
--   and not one inlined function: staging them as a selection and a read, so that a
--   row inlined whole, cost about 1.2 times as much in Decode and Mock.query.
-- * Continuation-passing style has the same capture on every read, including reads
--   that never suspend. hpgsql measured about 4.7% from leaving it, and a CPS parser
--   was measured and rejected here too.
-- * Two readings of one recipe, one giving up at the buffer's end with nothing
--   captured, made Recipe a record GHC would not fuse: Decode typed about 2 times as
--   slow, on top of the staging.
-- * Passing the input as the three unboxed fields of a 'B.ByteString', in 'Result'
--   and in 'Recipe''s argument, doubled a typed Mock.query's allocation (3.5 to
--   7.5 MB) and made it 1.7 times as slow.  The RTS has generic-apply entry points
--   only for arguments that are all pointers (stg_ap_p to stg_ap_pppppp, and the
--   pv, ppv and pppv forms) and for one lone unboxed word, so an unknown call whose
--   arguments mix pointers and unboxed words is split into chunks, and each chunk but
--   the last builds a PAP in the RTS, which ticky attributes to no closure.  An index
--   into a 'ByteArray#' with unboxed offsets would meet the same rule.  The payload
--   and a boxed position, below at 'Result', is what works.

-- | How a streaming consumer gets the next piece of its value.  'consume' gives the
-- consumer a stream, and each pull from that stream calls the 'Runner'.
--
-- The reference holds the suspended recipe that reads the value.  'runAwait' runs
-- that recipe until it produces its next result, fetching payloads whenever it needs
-- them, and it saves its progress back in the reference as it goes, so that an
-- interrupted pull doesn't repeat anything.
--
-- The driver supplies the 'Runner' because only the driver knows where the payloads
-- come from and what a pull must hold while it reads them.  The connection's own
-- 'Runner' masks each pull and reads from that response's packets.  'feedRunner' builds
-- one from a function that returns the next payload.
newtype Runner = Runner
  { runAwait :: forall a. IORef (Stream Await IO (Got a)) -> IO (Got a) }

-- | What a driver gives a suspended recipe: the next payload, with the transport and
-- the TDS packet headers already removed, or the end of the message.
data Feed
  = More !B.ByteString
    -- ^ The next payload, to read as usual.
  | Discard !B.ByteString
    -- ^ The next payload of a response being thrown away.  Nobody will use a value
    -- that is still being assembled, so its recipe may release its buffer and skip the
    -- rest of the value.  See 'chunkOrDiscard'.
  | EndOfMessage
    -- ^ There are no more payloads.  This is the normal way to finish at a token
    -- boundary ('peekToken'), and a 'ProtocolError' anywhere else.

-- | The payload, for a read that treats 'More' and 'Discard' alike, or 'Nothing' at
-- the end of the message.
feedBytes :: Feed -> Maybe B.ByteString
feedBytes (More bytes) = Just bytes
feedBytes (Discard bytes) = Just bytes
feedBytes EndOfMessage = Nothing

-- | A recipe's result, and the part of the current payload it didn't read.  The next
-- recipe starts with those bytes.
data Got a = Got !a {-# UNPACK #-} !B.ByteString

-- | Where a recipe that finished within its payload got to ('runParserAt'): its
-- value, or the failed value ('failValue') that nothing recovered, and in either
-- case the position after it in the same payload.
data At a = At !a {-# UNPACK #-} !Int | FailedAt !ReadFailure {-# UNPACK #-} !Int

-- | What a suspended recipe asks its driver for.  A suspended recipe is a 'Stream' of
-- these requests, so a driver sees three things as it runs one.  'Step' is one of these
-- requests, 'Effect' is a short piece of 'IO' that the driver just runs, such as growing
-- a value's buffer, and 'Return' is the final 'Got'.  Using 'inspect' from the
-- @streaming@ package runs the effects and gives the next request or the result.
data Await next
  = NeedMore (Feed -> next)
    -- ^ The recipe needs more input.  The driver fetches a payload and calls this
    -- function, which gives the rest of the recipe.
  | forall x. RunConsumer !Bool (Runner -> IO x) (Maybe x -> next)
    -- ^ The recipe has reached a value that a caller's code wants to read as it
    -- arrives.  The driver runs that code with a 'Runner' for its pulls, outside any
    -- mask the driver holds for reading, and gives its result to the function, which
    -- gives the rest of the recipe.  A driver that is throwing the response away
    -- gives 'Nothing' instead of running the code.  An exception from the code isn't
    -- given to the function: it ends the driver, as an exception of the caller's
    -- does.  The 'Bool' says whether the code pulls the value from the response
    -- ('consume'), so that it may wait for the server, or has the value in hand
    -- ('consumeWhole') and never pulls.

instance Functor Await where
  fmap f (NeedMore k) = NeedMore (f . k)
  fmap f (RunConsumer live io k) = RunConsumer live io (f . k)

-- What running a recipe over a buffer gives: the value and the unread bytes, or a
-- suspended computation. A parse that completes within its buffer builds no Stream.
--
-- An unboxed sum returns completed reads without allocating a control value,
-- even when a dynamically selected recipe prevents inlining. Pattern synonyms
-- keep that representation private and preserve strict values and buffers.
-- Only suspended computations use Stream; its effects and binds handle resumption.
--
-- A failed value is a third alternative, which binds pass on without running their
-- continuations, so a recipe that succeeds builds no 'Either' per value.  A suspended
-- computation can fail too, so its result is an 'Outcome', and 'parse' and
-- 'runParser' turn it into the public 'Got' for drivers.  A failure that reaches them
-- is a bug in the recipe, which should have caught it with 'recover', so it is a
-- 'ProtocolError'.
--
-- 'Result', 'Recipe''s constructor and what is built on them ('run', 'parser', 'await',
-- 'resume', 'stream', 'primitive') stay private on purpose; design.md, "Reading and
-- writing bytes: which layer", gives the reasons.
--
-- A recipe runs on a payload and a position in it, and a completed read returns
-- where it got to, as a position in the same payload.  The payload is one pointer
-- shared by every recipe called within it, and the position is a boxed 'Int', so
-- that a recipe called through an unknown call takes three pointers (stg_ap_ppp)
-- and returns its position unboxed: 16 bytes for the 'Int' box per such call
-- instead of 32 for a 'B.ByteString' of the unread bytes, and nothing at all for a
-- call GHC can see, because the worker it makes takes an 'Int#'.  With the unread
-- bytes as the input, every column of every row returned a fresh 'B.ByteString'.
-- A payload changes only across a suspension, which runs through 'Outcome' and
-- starts the rest of the recipe at position 0 of the next payload; a driver gets
-- the unread bytes back as a 'B.ByteString' built once per 'parse' or 'runParser',
-- or the position itself from 'runParserAt'.
--
-- Measured on 2026-11-04 against the input as the unread bytes, per row by
-- tasty-bench over many iterations: a typed (Int32, Int64) row in Mock.query from
-- 366 to 286 bytes, the nullable NBCROW row from 1,123 to 804, a 'SqlRow' of the
-- same two columns from 544 to 528 (its cells are still unknown calls, and a
-- row's unread bytes cost one 'B.ByteString' where the last cell's used to serve),
-- and a typed row of 50 columns in Decode from 15,560 to 12,220.  The object code
-- of a two-field record's FromSqlRow instance went from 56.5 to 51.0 KB, and of
-- one for each field type by 9 to 12%.  Of the per-row saving, half is the smaller
-- box and half is 'liftA2' below, which turns a column's call into a known one.
type Result a = (# (# a, Int# #) | Stream Await IO (Outcome a) | (# ReadFailure, Int# #) #)

pattern Parsed :: a -> Int -> Result a
pattern Parsed a pos <- (# (# a, (I# -> pos) #) | | #)
  where Parsed !a (I# pos) = (# (# a, pos #) | | #)

pattern Suspended :: Stream Await IO (Outcome a) -> Result a
pattern Suspended suspended = (# | suspended | #)

pattern Failed :: ReadFailure -> Int -> Result a
pattern Failed failure pos <- (# | | (# failure, (I# -> pos) #) #)
  where Failed !failure (I# pos) = (# | | (# failure, pos #) #)
{-# COMPLETE Parsed, Suspended, Failed #-}

-- The bytes of the payload from a position on, which is what a driver gets back.
unread :: B.ByteString -> Int -> B.ByteString
unread bs pos = BU.unsafeDrop pos bs
{-# INLINE unread #-}

-- A slice of the payload at a position, whose bounds the caller has checked.
slice :: B.ByteString -> Int -> Int -> B.ByteString
slice bs pos n = BU.unsafeTake n (BU.unsafeDrop pos bs)
{-# INLINE slice #-}

-- The bytes of the payload still unread from a position.
remaining :: B.ByteString -> Int -> Int
remaining bs pos = B.length bs - pos
{-# INLINE remaining #-}

-- How a suspended computation ends: with its value or a failed value, and the
-- unread part of the last payload.
data Outcome a = Done !a {-# UNPACK #-} !B.ByteString | Stopped !ReadFailure {-# UNPACK #-} !B.ByteString

-- | A recipe that can also read a value of type @env@ with 'ask', which 'withEnv'
-- supplies when the recipe runs.  It reads input and suspends just as a 'Parser' does.
newtype Recipe env a = Recipe { runRecipe :: env -> B.ByteString -> Int -> Result a }

-- | A recipe with no environment, which is the usual kind.
type Parser = Recipe ()

run :: Parser a -> B.ByteString -> Int -> Result a
run p = runRecipe p ()
{-# INLINE run #-}

parser :: (B.ByteString -> Int -> Result a) -> Parser a
parser p = Recipe (\() -> p)
{-# INLINE parser #-}

-- | The value given to 'withEnv'.  This reads no input.
ask :: Recipe env env
ask = Recipe $ \env _ pos -> Parsed env pos
{-# INLINE ask #-}

-- | Use a 'Parser', such as one of the reads below, inside a 'Recipe'.
liftParser :: Parser a -> Recipe env a
liftParser p = Recipe $ \_ -> run p
{-# INLINE liftParser #-}

-- | Supply the environment, which makes the recipe a 'Parser'.  The same recipe can be
-- used again with another value.
withEnv :: env -> Recipe env a -> Parser a
withEnv env p = parser (runRecipe p env)
{-# INLINE withEnv #-}

-- | A recipe chosen at run time, such as a column's prepared recipe, which GHC
-- therefore calls without seeing into it.  Wrapping it here costs nothing in the
-- recipe and saves the 16 bytes that the call would otherwise allocate for its
-- position.  Leave it off a recipe GHC can inline, because there the wrapper only
-- adds a table lookup.
dynamic :: Recipe env a -> Recipe env a
dynamic (Recipe p) = Recipe $ \env bs (I# pos) -> let !box = boxPosition pos in p env bs box
{-# INLINE dynamic #-}

-- | The same recipe, for one that is built to be run once, such as a step of a
-- loop that builds the rest of a row's recipe as it reads.  GHC then takes the
-- recipe's input along with the function's own arguments, rather than build the
-- recipe as closures and thunks and run it after.  On a recipe that runs more than
-- once, such as a prepared one, the work before its input would be repeated for
-- every run.
oneShotRecipe :: Recipe env a -> Recipe env a
oneShotRecipe (Recipe p) = Recipe (oneShot (\env -> oneShot (\bs -> oneShot (\pos -> p env bs pos))))
{-# INLINE oneShotRecipe #-}

-- A position as a boxed 'Int' for a call GHC can't see into, from a table of boxes
-- built once.  The callers force the box before the call: an unknown call's argument
-- is lazy, so left to itself GHC passed a thunk of the lookup, 24 bytes in place of
-- the 16 saved.  A recipe takes its position boxed (see 'Result'), so each column of a
-- row called through an unknown call allocated a fresh box, 16 bytes, which for a
-- typed row of two columns was a tenth of the row's allocation and for a 'SqlRow'
-- cell a quarter of the cell's.  The table covers a payload of the default packet
-- size (8000 bytes); a position beyond it, in a connection with larger packets, is
-- boxed as before.  It is a CAF of about 197 KB on the heap (8,192 boxes and the
-- array) once anything reads a row.  Measured on 2026-11-04 by tasty-bench over
-- many iterations, per row: a typed row of 50 columns in Decode, whose driver is
-- unchanged, from 12,222 to 11,406 bytes, which is 51 boxes; a typed (Int32, Int64)
-- row in Mock.query from 366 to 284 together with 'runParserAt' and the driver
-- keeping its position, of which the two boxes are 32, the unread bytes 32 and the
-- row's 'Right' 16 by ticky.
boxPosition :: Int# -> Int
boxPosition pos
  | isTrue# (int2Word# pos `ltWord#` 8192##) = case positionBoxes of
      SmallArray boxes -> case indexSmallArray# boxes pos of (# box #) -> box
  | otherwise = I# pos
{-# INLINE boxPosition #-}

positionBoxes :: SmallArray Int
positionBoxes = smallArrayFromListN 8192 [0 .. 8191]
{-# NOINLINE positionBoxes #-}

instance Functor (Recipe env) where
  fmap f (Recipe p) = Recipe $ \env bs pos -> case p env bs pos of
    Parsed a end -> Parsed (f a) end
    Suspended suspended -> resume suspended (\a _ -> Parsed (f a) 0)
    Failed failure end -> Failed failure end
  {-# INLINE fmap #-}

instance Applicative (Recipe env) where
  pure a = Recipe $ \_ _ pos -> Parsed a pos
  {-# INLINE pure #-}
  Recipe pf <*> Recipe pa = Recipe $ \env bs pos -> case pf env bs pos of
    Parsed f next -> case pa env bs next of
      Parsed a end -> Parsed (f a) end
      Suspended suspended -> resume suspended (\a _ -> Parsed (f a) 0)
      Failed failure end -> Failed failure end
    Suspended suspended -> resume suspended (\f rest -> runRecipe (fmap f (Recipe pa)) env rest 0)
    Failed failure next -> Failed failure next
  {-# INLINE (<*>) #-}
  -- Written out, rather than the default '<*>' after 'fmap', for two reasons.  The
  -- default was a function of the library's that GHC didn't inline, so each
  -- column's recipe was called from it through an unknown call.  And where the
  -- function is unknown, as in a row's shared generic composition, it is applied
  -- to both values at once instead of building a partial application per value.
  liftA2 f (Recipe pa) (Recipe pb) = Recipe $ \env bs pos -> case pa env bs pos of
    Parsed a next -> case pb env bs next of
      Parsed b end -> Parsed (f a b) end
      Suspended suspended -> resume suspended (\b _ -> Parsed (f a b) 0)
      Failed failure end -> Failed failure end
    Suspended suspended -> resume suspended (\a rest -> runRecipe (fmap (f a) (Recipe pb)) env rest 0)
    Failed failure next -> Failed failure next
  {-# INLINE liftA2 #-}

instance Monad (Recipe env) where
  Recipe p >>= k = Recipe $ \env bs pos -> case p env bs pos of
    Parsed a next -> runRecipe (k a) env bs next
    Suspended suspended -> resume suspended (\a rest -> runRecipe (k a) env rest 0)
    Failed failure next -> Failed failure next
  {-# INLINE (>>=) #-}

-- Keep the recursive Stream traversal off the ordinary, completed path.
-- A suspension traverses the enclosing bind depth, unlike an immediate result:
-- Stream's bind rebuilds each layer through every enclosing bind. That is O(depth)
-- per packet boundary, and the depth is about a row's columns, since long values loop
-- inside 'chunk' and 'skip' rather than through a bind per chunk. NOINLINE because
-- inlining this into each bind would copy the traversal to every read.  The
-- continuation gets the unread part of the last payload, and its result is a
-- position in it.
resume :: Stream Await IO (Outcome a) -> (a -> B.ByteString -> Result b) -> Result b
resume suspended k = Suspended $ suspended >>= \case
  Done a rest -> stream rest (k a rest)
  Stopped failure rest -> Return (Stopped failure rest)
{-# NOINLINE resume #-}

-- | Fail with a value that was read but can't be used.  The bytes after it are left
-- for whatever 'recover' runs next.
failValue :: ReadFailure -> Recipe env a
failValue failure = Recipe $ \_ _ pos -> Failed failure pos
{-# INLINE failValue #-}

-- | Run a recipe, and if a value in it fails ('failValue'), run the handler from
-- where the failure left the input.
recover :: Recipe env a -> (ReadFailure -> Recipe env a) -> Recipe env a
recover (Recipe p) handler = Recipe $ \env bs pos -> case p env bs pos of
  Parsed a end -> Parsed a end
  Suspended suspended -> recoverSuspended suspended (\failure rest -> runRecipe (handler failure) env rest 0)
  Failed failure end -> runRecipe (handler failure) env bs end
{-# INLINE recover #-}

-- Off the completed path, as 'resume' is.
recoverSuspended :: Stream Await IO (Outcome a) -> (ReadFailure -> B.ByteString -> Result a) -> Result a
recoverSuspended suspended handler = Suspended $ suspended >>= \case
  done@(Done _ _) -> Return done
  Stopped failure rest -> stream rest (handler failure rest)
{-# NOINLINE recoverSuspended #-}

-- | Run a recipe, and give its failed value, if it has one, as a 'Left'.
attempt :: Recipe env a -> Recipe env (Either ReadFailure a)
attempt p = recover (Right <$> p) (pure . Left)
{-# INLINE attempt #-}

instance MonadFail (Recipe env) where
  fail msg = liftParser (effect (throwIO (ProtocolError msg)))

-- | Run a short piece of 'IO' as part of a recipe, and evaluate its result.  It runs
-- once, under whatever mask the driver holds, so it must not block.  Code that can
-- block, such as a caller's consumer, belongs in 'consume' instead.
effect :: IO a -> Parser a
effect io = parser $ \bs pos -> Suspended $ Effect $ do
  !a <- io
  pure (Return (Done a (unread bs pos)))

-- Suspend until more bytes arrive, then run the recipe from the new buffer. An
-- empty payload (a packet with only a header) waits again. Reads reached here are
-- inside a token, so a message that ends now is malformed; 'peekToken' is the one read
-- for which the end is a result.
await :: Parser a -> Result a
await p = Suspended $ Step $ NeedMore $ \feed -> case feedBytes feed of
  Just bs | B.null bs -> stream bs (await p)
          | otherwise -> stream bs (run p bs 0)
  Nothing -> stream B.empty (run (fail "message ended inside a token") B.empty 0)

------------------------------------------------------------------------------
-- Primitive reads

-- | The next byte, which is left unread, or 'Nothing' if the message has ended.  This
-- is how to look for the next token, because it is the one read for which the end of
-- the message isn't an error.
peekToken :: Parser (Maybe Word8)
peekToken = parser $ \bs pos ->
  if pos < B.length bs then Parsed (Just (Read.word8At bs pos)) pos
  else Suspended $ Step $ NeedMore $ \feed -> case feedBytes feed of
    Nothing -> pure (Done Nothing B.empty)
    Just next -> stream next (run peekToken next 0)

-- | The next byte, which is left unread.  The end of the message is a 'ProtocolError'.
peekWord8 :: Parser Word8
peekWord8 = parser $ \bs pos -> if pos >= B.length bs then await peekWord8 else Parsed (Read.word8At bs pos) pos

-- A fixed-width read. Only the bounds check and the load are inlined at each use;
-- a word cut by a packet boundary is joined by the out-of-line slow path, which
-- would otherwise be copied into every field of every decoder.
primitive :: Int -> (B.ByteString -> Int -> a) -> Parser a
primitive n read = parser $ \bs pos ->
  if remaining bs pos >= n
    then Parsed (read bs pos) (pos + n)
    else primitiveSlow n read bs pos
{-# INLINE primitive #-}

primitiveSlow :: Int -> (B.ByteString -> Int -> a) -> B.ByteString -> Int -> Result a
primitiveSlow n read = run (fmap (\bytes -> read bytes 0) (boundedBytes n))
{-# NOINLINE primitiveSlow #-}

-- | One byte.
word8 :: Parser Word8
word8 = primitive 1 Read.word8At
{-# INLINE word8 #-}
-- | A little-endian 16-bit integer, as most integers in TDS are.
word16le :: Parser Word16
word16le = primitive 2 Read.word16LeAt
{-# INLINE word16le #-}
-- | A little-endian 32-bit integer.
word32le :: Parser Word32
word32le = primitive 4 Read.word32LeAt
{-# INLINE word32le #-}
-- | A little-endian 64-bit integer.
word64le :: Parser Word64
word64le = primitive 8 Read.word64LeAt
{-# INLINE word64le #-}

-- | A big-endian 32-bit integer.
word32be :: Parser Word32
word32be = B.foldl' (\a b -> (a `shiftL` 8) .|. fromIntegral b) 0 <$> boundedBytes 4

-- | Exactly this many bytes (the second argument), in one 'B.ByteString'.  If they lie
-- within the current payload, the result is a slice of it and nothing is copied.
-- Otherwise they are copied into a buffer of their own as they arrive.
--
-- The first argument is how much may be allocated before the bytes have arrived, as
-- 'append' describes.  It protects against a server that declares a huge length.
--
-- A slice keeps its whole packet alive for as long as it is held, so use 'ownedBytes'
-- for anything kept after the current token.
bytes :: Int -> Int -> Parser B.ByteString
bytes ahead n = contiguous id ahead n
{-# INLINE bytes #-}

-- | Like 'bytes', but the result is always cheap to keep, because a slice is copied.
ownedBytes :: Int -> Int -> Parser B.ByteString
ownedBytes ahead n = contiguous B.copy ahead n
{-# INLINE ownedBytes #-}

-- | 'bytes' that may allocate the whole length ahead.  This is for short metadata whose
-- length field is small enough to bound what a server can ask for, such as the length
-- byte of a B_VARCHAR.
boundedBytes :: Int -> Parser B.ByteString
boundedBytes n = bytes n n

-- | 'ownedBytes' that may allocate the whole length ahead, as 'boundedBytes' may.
ownedBoundedBytes :: Int -> Parser B.ByteString
ownedBoundedBytes n = ownedBytes n n

-- The slow path gathers through 'chunk', never 'chunkOrDiscard': metadata has to be
-- parsed even in a drain, so it can't be given up on as a value can.
contiguous :: (B.ByteString -> B.ByteString) -> Int -> Int -> Parser B.ByteString
contiguous borrowed ahead n = parser $ \bs pos ->
  if n < 0 then run (fail "negative byte count") bs pos
  else if n <= remaining bs pos
    then Parsed (borrowed (slice bs pos n)) (pos + n)
    else contiguousSlow ahead n bs pos
{-# INLINE contiguous #-}

contiguousSlow :: Int -> Int -> B.ByteString -> Int -> Result B.ByteString
contiguousSlow ahead n = run (gather n (accumulator (Just (fromIntegral n))))
  where
    gather 0 a = effect (finish a)
    gather remaining a = do
      bytes <- chunk remaining
      next <- effect (append ahead a bytes)
      gather (remaining - B.length bytes) next
{-# NOINLINE contiguousSlow #-}

-- | Between 1 and this many bytes, as a slice of the current payload, waiting for a
-- payload if there are none left.  Asking for zero gives an empty result without
-- needing input.  Loop to read more than one payload holds, and copy what you keep.
chunk :: Int -> Parser B.ByteString
chunk n = parser $ \bs pos ->
  if n < 0 then run (fail "negative byte count") bs pos
  else if n == 0 then Parsed B.empty pos
  else if pos >= B.length bs then await (chunk n)
  else let k = min n (remaining bs pos)
       in Parsed (slice bs pos k) (pos + k)

-- | 'chunk' for a recipe that collects a value.  It gives 'Nothing' if the response
-- started being thrown away ('Discard') while this read was waiting for input.  The
-- recipe should then release what it has collected and 'skip' the rest of the value,
-- because 'Nothing' reads no bytes.
chunkOrDiscard :: Int -> Parser (Maybe B.ByteString)
chunkOrDiscard n = parser $ \bs pos ->
  if n <= 0 || pos < B.length bs then run (Just <$> chunk n) bs pos
  else Suspended $ Step $ NeedMore $ \feed -> case feed of
    Discard next -> pure (Done Nothing next)
    More next -> stream next (run (chunkOrDiscard n) next 0)
    EndOfMessage -> stream B.empty (run (fail "message ended inside a value") B.empty 0)

-- | Pass over this many bytes, across any number of payloads, keeping none of them.
skip :: Int -> Parser ()
skip n = parser $ \bs pos ->
  if n < 0 then run (fail "negative byte count") bs pos
  else if n <= remaining bs pos then Parsed () (pos + n)
  else await (skip (n - remaining bs pos))

-- | A B_VARCHAR: a string of UTF-16LE with a one-byte length in characters.
bVarChar :: Parser Text
bVarChar = word8 >>= \n -> Utf16.decodeUtf16LE <$> boundedBytes (2 * fromIntegral n)

-- | A US_VARCHAR: a string of UTF-16LE with a two-byte length in characters.
usVarChar :: Parser Text
usVarChar = word16le >>= \n -> Utf16.decodeUtf16LE <$> boundedBytes (2 * fromIntegral n)

-- | Run a recipe this many times and collect the results in order.  A negative count
-- is a 'ProtocolError'.
count :: Int -> Parser a -> Parser [a]
count n recipe
  | n < 0 = fail "negative item count"
  | otherwise = go n []
  where
    go 0 acc = pure (reverse acc)
    go remaining acc = recipe >>= \a -> go (remaining - 1) (a : acc)

-- | Run a recipe on exactly the next @n@ bytes, for a token that declares its own
-- length.  The recipe can't read past them, and it is a 'ProtocolError' if it leaves
-- any unread.  The bytes are collected first, so this suits short tokens rather than
-- anything large or anything repeated per row.  Compare 'limited'.
isolate :: Int -> Parser a -> Parser a
isolate n p = do
  bs <- boundedBytes n
  effect $ do
    (a, rest) <- parseChunks p [bs]
    if all B.null rest then pure a else throwIO (ProtocolError "unconsumed bytes in token envelope")

-- | Run a recipe, with a 'ProtocolError' if it receives more than this many bytes
-- before it finishes.  This is for a token with no overall length of its own, so that
-- the lengths inside it can't make the reader wait or collect without end.  Unlike
-- 'isolate', it collects nothing first, and the recipe may finish early.
limited :: Int -> Parser a -> Parser a
limited limit p = parser $ \bs pos -> case run p bs pos of
  Parsed a end
    | end - pos <= limit -> Parsed a end
    | otherwise -> run (fail "metadata token exceeds its size limit") bs pos
  Suspended s -> Suspended (bound (remaining bs pos) s)
  Failed failure end -> Failed failure end
  where
    bound received s = Effect $ inspect s >>= \case
      Left outcome
        | received - B.length (outcomeRest outcome) <= limit -> pure (Return outcome)
        | otherwise -> throwIO (ProtocolError ("token still unfinished after " ++ show received ++ " bytes"))
      Right (NeedMore k)
        | received > limit -> throwIO (ProtocolError ("token still unfinished after " ++ show received ++ " bytes"))
        | otherwise -> pure $ Step $ NeedMore $ \feed ->
            bound (received + maybe 0 B.length (feedBytes feed)) (k feed)
      Right (RunConsumer live io k) -> pure $ Step $ RunConsumer live io (bound received . k)

------------------------------------------------------------------------------
-- Value ownership and assembly

-- | A value's bytes, and whether they are cheap to keep.  'Borrowed' bytes are a slice
-- of a receive buffer.  Nothing overwrites them, but holding them keeps the whole buffer
-- alive.  'Owned' bytes are in a buffer of their own.  The difference lets a decoder
-- that keeps bytes copy only when it has to, and lets one that only looks at them, such
-- as an integer's, never copy.
data ValueBytes = Borrowed !B.ByteString | Owned !B.ByteString

-- | The bytes, to look at now.  Keeping them may keep a receive buffer alive.
valueBytes :: ValueBytes -> B.ByteString
valueBytes (Borrowed bs) = bs
valueBytes (Owned bs) = bs
{-# INLINE valueBytes #-}

-- | The bytes, cheap to keep, because 'Borrowed' bytes are copied.
keepBytes :: ValueBytes -> B.ByteString
keepBytes (Borrowed bs) = B.copy bs
keepBytes (Owned bs) = bs
{-# INLINE keepBytes #-}

-- | A value of a known length, given the allocation bound of 'bytes' and the length.
-- 'Nothing' means that the response started being thrown away while the value was
-- being assembled.  The partial value has been released and its remaining bytes
-- skipped, so the recipe can carry on with what follows.
bytesValue :: Int -> Int -> Parser (Maybe ValueBytes)
bytesValue ahead n = parser $ \bs pos ->
  if n < 0 then run (fail "negative byte count") bs pos
  else if n <= remaining bs pos then Parsed (Just (Borrowed (slice bs pos n))) (pos + n)
  else bytesValueSlow ahead n bs pos
{-# INLINE bytesValue #-}

-- | Read a value of a known length, as 'bytesValue' does, and convert it.  A value
-- that lies within the current payload goes to the first conversion as a slice of it,
-- and one that crossed payloads goes to the second, assembled in a buffer of its own.
-- A 'Left' from either is a failed value ('failValue') after the bytes, and a value
-- that a drain threw away is 'ReadDiscarded'.
convertBytes :: Int -> Int -> (B.ByteString -> Either ReadFailure a)
  -> (B.ByteString -> Either ReadFailure a) -> Parser a
-- Nearly every cell is a value lying in the buffer.  Given to the conversion here, it
-- needs no 'Maybe', 'ValueBytes' or boxed slice: bound through 'bytesValue', those
-- reached the conversion because its continuation was shared with the suspended
-- branch, and a 'SqlRow' cell built 80 bytes of them, by ticky.
convertBytes ahead n borrowed owned = parser $ \bs pos ->
  if n >= 0 && n <= remaining bs pos
    then case borrowed (slice bs pos n) of
           Right a -> Parsed a (pos + n)
           Left failure -> Failed failure (pos + n)
    else convertBytesSlow ahead n borrowed owned bs pos
{-# INLINE convertBytes #-}

-- | A value that lies in the payload, converted as 'convertBytes' converts one, or
-- else another recipe. Its delimiter is a length prefix of one or two bytes,
-- little-endian, with a value that means NULL, or no prefix and a fixed length: the
-- delimiter arguments are the prefix's width and the NULL value, or 0 and the length.
-- A NULL runs the first recipe after the prefix. A value that doesn't lie wholly in
-- the payload, or any other width, runs the second from the delimiter, which it must
-- read itself.  The environment is passed to both recipes unread.
prefixedValue :: Int -> Int -> (B.ByteString -> Either ReadFailure a) -> Recipe env a -> Recipe env a -> Recipe env a
prefixedValue width marker convert (Recipe null) (Recipe other) = Recipe $ \env bs pos ->
  prefixedAt 0 B.empty width marker convert null other env bs pos
{-# INLINE prefixedValue #-}

-- | 'prefixedValue' for a column of a row, whose environment is the NBCROW bitmap
-- (empty for a ROW token) and whose first argument is the column's index from
-- zero.  A column the bitmap marks NULL has no delimiter, and runs the NULL recipe
-- at once.
prefixedRowValue :: Int -> Int -> Int -> (B.ByteString -> Either ReadFailure a) -> Recipe B.ByteString a -> Recipe B.ByteString a -> Recipe B.ByteString a
prefixedRowValue column width marker convert (Recipe null) (Recipe other) = Recipe $ \bitmap bs pos ->
  prefixedAt column bitmap width marker convert null other bitmap bs pos
{-# INLINE prefixedRowValue #-}

-- The dispatch of both entry points, on the unwrapped recipe functions, so that
-- neither builds a 'Recipe' to run per value.  Inlined into each, a built-in
-- conversion still has one call site, given the slice's fields unboxed.
prefixedAt :: Int -> B.ByteString -> Int -> Int
  -> (B.ByteString -> Either ReadFailure a)
  -> (env -> B.ByteString -> Int -> Result a)
  -> (env -> B.ByteString -> Int -> Result a)
  -> env -> B.ByteString -> Int -> Result a
prefixedAt column bitmap width marker convert null other env bs pos =
  case valueSpan column bitmap width marker bs pos of
    (# start, n #)
      | isTrue# (n >=# 0#) -> case convert (slice bs (I# start) (I# n)) of
          Right a -> Parsed a (I# (start +# n))
          Left failure -> Failed failure (I# (start +# n))
      | isTrue# (n ==# -1#) -> null env bs (I# start)
      | otherwise -> other env bs pos
{-# INLINE prefixedAt #-}

-- Where a prefixed value starts and its length, or -1 for a NULL (and where its
-- prefix ends), or -2 for anything else.  The bitmap test is here, out of line,
-- rather than in each built-in decoder: inlined there it cost 22,688 bytes of
-- code and 56 bytes of recipe setup per column, for the same allocation per row
-- (GHC 9.12.4, 2026-11-04).
valueSpan :: Int -> B.ByteString -> Int -> Int -> B.ByteString -> Int -> (# Int#, Int# #)
valueSpan column bitmap width marker bs pos
  | not (B.null bitmap) && testBit (B.index bitmap (column `div` 8)) (column `mod` 8) = found pos (-1)
  | otherwise = case width of
      0 | marker <= remaining bs pos -> found pos marker
      1 | remaining bs pos >= 1 -> prefixed 1 (fromIntegral (Read.word8At bs pos))
      2 | remaining bs pos >= 2 -> prefixed 2 (fromIntegral (Read.word16LeAt bs pos))
      _ -> other
  where
    prefixed w n
      | n == marker = found (pos + w) (-1)
      | n <= remaining bs (pos + w) = found (pos + w) n
      | otherwise = other
    found (I# start) (I# n) = (# start, n #)
    other = (# 0#, -2# #)
{-# NOINLINE valueSpan #-}

convertBytesSlow :: Int -> Int -> (B.ByteString -> Either ReadFailure a)
  -> (B.ByteString -> Either ReadFailure a) -> B.ByteString -> Int -> Result a
convertBytesSlow ahead n borrowed owned = run $ bytesValue ahead n >>= \case
  Just (Borrowed bytes) -> either failValue pure (borrowed bytes)
  Just (Owned bytes) -> either failValue pure (owned bytes)
  Nothing -> failValue ReadDiscarded
{-# NOINLINE convertBytesSlow #-}

bytesValueSlow :: Int -> Int -> B.ByteString -> Int -> Result (Maybe ValueBytes)
bytesValueSlow ahead n = run (gather n (accumulator (Just (fromIntegral n))))
  where
    gather 0 a = Just . Owned <$> effect (finish a)
    gather remaining a = chunkOrDiscard remaining >>= \case
      Nothing -> skip remaining >> pure Nothing
      Just bytes -> do
        next <- effect (append ahead a bytes)
        gather (remaining - B.length bytes) next
{-# NOINLINE bytesValueSlow #-}

-- A buffer under construction has no immutable view until it is retired.
data Buffer = Buffer !(ForeignPtr Word8) !Int !Int
--
-- The one mutable thing in the module, and its rule is run-once. Copying each slice
-- in as its packet arrives is what keeps no packet alive and makes one copy. But
-- 'append' writes in place into a buffer that 'finish' can hand out as a ByteString
-- without copying, while a Stream value can in principle be run twice. A suspended
-- value's continuation holds an Accumulator, so running one twice would write into
-- bytes that may already be frozen. Every driver therefore saves the step it got from
-- 'inspect', never the Stream it inspected, before it can be interrupted, so no effect
-- is repeated. This rule reaches outside the module: the drivers are 'feedRunner',
-- 'runFrom', and stepCore and readPiece in Hmssql.Connection.Internal. Nothing tests
-- a violation. Consuming packets as a list and joining at the end would be pure, but
-- peaks at twice the value and keeps whole receive buffers alive.

-- | A long value being assembled from pieces as they arrive.  Use each one only once,
-- because 'append' may write into the same memory and its result replaces its argument.
-- A recipe holding one must not be run twice, as 'runFrom' explains.
data Accumulator
  = Known !Int !Buffer
  | Unknown !Int ![B.ByteString] !Buffer

-- | Start a value with this declared length, or with an unknown one.
accumulator :: Maybe Word64 -> Accumulator
accumulator total = case total of
  Just n -> Known (fromIntegral (min n (fromIntegral (maxBound :: Int)))) empty
  Nothing -> Unknown 0 [] empty
  where empty = Buffer BI.nullForeignPtr 0 0

-- | Add a piece to the value, which is copied, so the piece's packet can be released.
-- Use the result in place of the argument.
--
-- The first argument bounds what a declared length alone can allocate.  A server that
-- declares a huge value and doesn't send it costs that much memory, and after that at
-- most three times what it has actually sent.  A value that turns out longer than it
-- declared carries on as a value of unknown length.
append :: Int -> Accumulator -> B.ByteString -> IO Accumulator
-- Quarters because doubling reached twice the value just over a power of two; pieces
-- because doubling an unknown value's buffer peaks near three times it.
append ahead a src = case a of
  Known total (Buffer fp cap len)
    | k > maxBound - len -> throwIO (ProtocolError "value length exceeds addressable memory")
    | needed <= cap -> do
        copy fp cap len src
        pure (Known total (Buffer fp cap needed))
    | cap == 0 || needed <= total -> do
        let size | cap == 0 = max k (until (<= max 0 ahead) (`quot` 4) total)
                 | otherwise = max needed (if cap > total `quot` 4 then total else 4 * cap)
        fp' <- BI.mallocByteString size
        copy fp' size 0 (BI.BS fp len)
        copy fp' size len src
        pure (Known total (Buffer fp' size needed))
    | otherwise -> append ahead (Unknown 0 [] (Buffer fp cap len)) src
    where needed = len + k
  Unknown before full (Buffer fp cap len)
    | k > maxBound - len || cap > maxBound - before -> throwIO (ProtocolError "value length exceeds addressable memory")
    | len + k <= cap -> do
        copy fp cap len src
        pure (Unknown before full (Buffer fp cap (len + k)))
    | otherwise -> do
        let m = cap - len
            size = max (k - m) (if cap == 0 then min 65536 (max 0 ahead) else min 1048576 (max 65536 (before + cap)))
        copy fp cap len (B.take m src)
        fp' <- BI.mallocByteString size
        copy fp' size 0 (B.drop m src)
        let full' = if cap == 0 then full else BI.BS fp cap : full
        pure (Unknown (before + cap) full' (Buffer fp' size (k - m)))
  where k = B.length src

-- A bounded memcpy between buffers known to be alive, hence unsafeWithForeignPtr.
-- The check can't fail by the arithmetic in 'append'. It is here because a mistake in
-- that arithmetic would otherwise write outside the allocation.
copy :: ForeignPtr Word8 -> Int -> Int -> B.ByteString -> IO ()
copy dst capacity at (BI.BS src n)
  | at < 0 || at > capacity || n > capacity - at = throwIO (ProtocolError "value copy outside allocated buffer")
  | n == 0 = pure ()
  | otherwise = BI.unsafeWithForeignPtr dst $ \d -> BI.unsafeWithForeignPtr src $ \s ->
      copyBytes (d `plusPtr` at) s n

-- | The assembled value, which is safe to keep.  Don't use the 'Accumulator' again.
finish :: Accumulator -> IO B.ByteString
finish = \case
  Known _ b -> pure $! finishBuffer b
  Unknown _ [] b -> pure $! finishBuffer b
  Unknown _ full (Buffer fp _ len) -> pure $! B.concat (reverse (BI.BS fp len : full))
  where
    finishBuffer (Buffer fp cap len)
      | len == 0 = B.empty
      | cap - len <= max 16 (len `div` 16) = BI.BS fp len
      | otherwise = B.copy (BI.BS fp len)

------------------------------------------------------------------------------
-- Drivers

-- | Start a recipe on a payload, as a suspended computation for a driver to run with
-- 'inspect'.  Pass an empty payload to start with no input.  A failed value that the
-- recipe didn't 'recover' from is a 'ProtocolError'.
parse :: Parser a -> B.ByteString -> Stream Await IO (Got a)
parse p bs = case run p bs 0 of
  Parsed a pos -> Return (Got a (unread bs pos))
  Suspended s -> got s
  Failed failure _ -> uncaught failure

-- | Start a recipe on a payload.  The result is 'Right' if it finished within the
-- payload, and otherwise 'Left' with the suspended computation.  This lets a loop
-- handle the common case without a 'Stream'.
runParser :: Parser a -> B.ByteString -> Either (Stream Await IO (Got a)) (Got a)
runParser p bytes = case run p bytes 0 of
  Parsed value pos -> Right (Got value (unread bytes pos))
  Suspended continuation -> Left (got continuation)
  Failed failure _ -> Left (uncaught failure)
{-# INLINE runParser #-}

-- | 'runParser' from a position in the payload, for a driver that reads one
-- recipe after another from the same payload, as the connection reads rows, and
-- handles a failed value itself.  A recipe that finishes within the payload gives
-- where it got to as a position in it, so the driver keeps the payload and a
-- position rather than building the unread bytes after each recipe.  A failed
-- value that nothing recovered is 'FailedAt' rather than a 'ProtocolError'; a row's
-- recipe ('Hmssql.Decoding.CompiledRow') leaves its failure for the driver this
-- way.  A recipe that suspends gives its failure as a 'Left' at the end.
runParserAt :: Parser a -> B.ByteString -> Int -> Either (Stream Await IO (Got (Either ReadFailure a))) (At a)
runParserAt p bytes (I# pos) = let !box = boxPosition pos in case run p bytes box of
  Parsed value end -> Right (At value end)
  Suspended continuation -> Left (gotEither continuation)
  Failed failure end -> Right (FailedAt failure end)
{-# INLINE runParserAt #-}

-- A suspended computation as drivers see it.
got :: Stream Await IO (Outcome a) -> Stream Await IO (Got a)
got s = s >>= \case
  Done a rest -> Return (Got a rest)
  Stopped failure _ -> uncaught failure

gotEither :: Stream Await IO (Outcome a) -> Stream Await IO (Got (Either ReadFailure a))
gotEither s = s >>= \case
  Done a rest -> Return (Got (Right a) rest)
  Stopped failure rest -> Return (Got (Left failure) rest)

uncaught :: ReadFailure -> Stream Await IO r
uncaught failure = Effect (throwIO (ProtocolError ("a failed value reached the driver: " ++ show failure)))

-- A result as a suspended computation, given the payload its position is in.
stream :: B.ByteString -> Result a -> Stream Await IO (Outcome a)
stream bs (Parsed a pos) = Return (Done a (unread bs pos))
stream _ (Suspended s) = s
stream bs (Failed failure pos) = Return (Stopped failure (unread bs pos))
{-# INLINE stream #-}

outcomeRest :: Outcome a -> B.ByteString
outcomeRest (Done _ rest) = rest
outcomeRest (Stopped _ rest) = rest

-- | Run a recipe over payloads already in memory, followed by the end of the message.
-- The result is the recipe's value and whatever input it didn't read.
parseChunks :: Parser a -> [B.ByteString] -> IO (a, [B.ByteString])
parseChunks p chunks = do
  input <- newIORef chunks
  let feed = atomicModifyIORef' input $ \case
        [] -> ([], EndOfMessage)
        c : cs -> (cs, More c)
  Got a rest <- runFrom feed p B.empty
  later <- readIORef input
  pure (a, if B.null rest then later else rest : later)

-- | A 'Runner' that gets payloads from this action.  Its caller decides what to mask
-- and what to do about exceptions.  It saves its progress before each step, so that
-- retrying after a failed fetch, or looking again at a finished value, repeats nothing.
-- A value's recipe that asks to run a consumer of its own is a 'ProtocolError', and it
-- stays failed in the reference, so that later cleanup can't run the consumer.
feedRunner :: IO Feed -> Runner
feedRunner feed = Runner $ \current ->
  let loop = readIORef current >>= inspect >>= \case
        Left got -> writeIORef current (pure got) >> pure got
        Right await@(NeedMore k) -> do
          writeIORef current (S.wrap await)
          next <- feed
          writeIORef current (k next)
          loop
        Right RunConsumer{} -> do
          let err = ProtocolError "a value recipe cannot invoke a nested consumer"
          -- The outer consumer may catch this exception. Its subsequent drain
          -- must encounter the failure, not hand the rejected action to a driver.
          writeIORef current (Effect (throwIO err))
          throwIO err
   in loop

-- | Run a recipe to its end, starting with this payload and fetching the rest from the
-- action.  It also runs any consumers the recipe holds, with 'feedRunner' for their
-- pulls.  The result includes the unread part of the last payload.
--
-- This is the driver to use unless you need something it doesn't do.  A driver of your
-- own must follow one rule: it must run each step of a suspended recipe only once.
-- After 'inspect', save what 'inspect' returned, and not the computation it was given,
-- before anything can interrupt the driver.  Running a step twice repeats its effects,
-- and an 'Accumulator' it holds would write into memory it may already have given away.
runFrom :: IO Feed -> Parser a -> B.ByteString -> IO (Got a)
runFrom feed p initial = do
  current <- newIORef (parse p initial)
  let runner = feedRunner feed
      loop = readIORef current >>= inspect >>= \case
        Left got -> writeIORef current (pure got) >> pure got
        Right await@(NeedMore k) -> do
          writeIORef current (S.wrap await)
          next <- feed
          writeIORef current (k next)
          loop
        Right await@(RunConsumer _ io k) -> do
          writeIORef current (S.wrap await)
          result <- io runner
          writeIORef current (k (Just result))
          loop
  loop

-- | Give a stream of bytes to a function that reads it as the bytes arrive, then carry
-- on with the recipe.  This is how a caller's code reads a large value without it being
-- in memory ('Hmssql.Decoding.streamField' is built on it).  The result is what the
-- function returned, or 'Nothing' when the driver is throwing the response away and
-- didn't run it.  Whatever part of the stream the function didn't read is read past
-- afterwards, so the recipe continues in the right place either way.  An exception
-- the function throws ends the driver instead ('RunConsumer'); the saved step then
-- still holds the value, and a drain that resumes it reads past the rest.
--
-- The driver runs the function ('RunConsumer'), and each pull goes through the driver's
-- 'Runner'.  Each chunk is a copy, so it can be kept.  Pulling the same part of the
-- stream twice, or pulling after the function has returned, throws 'ResultAbandoned'.
consume :: Stream (Of B.ByteString) Parser ()
  -> (Stream (Of B.ByteString) IO () -> IO a) -> Parser (Maybe a)
consume source use = parser $ \bs pos -> Suspended $ Effect $ do
  current <- newIORef (parse (S.inspect source) (unread bs pos))
  active <- newIORef (Just (0 :: Int))
  let pull runner generation = S.effect $ mask_ $ do
        valid <- atomicModifyIORef' active $ \state -> case state of
          Just n | n == generation -> (Just (n + 1), True)
          _ -> (state, False)
        unless valid (throwIO ResultAbandoned)
        Got step rest <- runAwait runner current
        case step of
          Left () -> pure (pure ())
          Right (chunk :> next) -> do
            writeIORef current (parse (S.inspect next) rest)
            pure (S.yield (B.copy chunk) >> pull runner (generation + 1))
      finishConsumer result = Effect $ do
        remaining <- readIORef current
        pure (drain remaining result)
      drain remaining result = remaining >>= \(Got step rest) -> case step of
        Left () -> Effect $ do
          writeIORef current (pure (Got (Left ()) B.empty))
          pure (pure (Done result rest))
        Right (_ :> next) -> drain (parse (S.inspect next) rest) result
  pure $ Step $ RunConsumer True (\runner -> use (pull runner 0) `finally` writeIORef active Nothing) finishConsumer

-- | 'consume' for a value already read whole: the function gets a stream of one
-- chunk, these bytes (none, for an empty value), which it may keep, and the recipe goes on after it with no
-- reading of its own.  The driver runs the function as it runs 'consume''s, and the
-- stream has the same rules, but the function never pulls from the response, so a
-- driver can run it among the rows it has already read.  This is what
-- 'Hmssql.Decoding.streamField' does with a value small enough to read whole first,
-- where 'consume''s references, masked pulls and drain per value cost several
-- times what the value does.
consumeWhole :: B.ByteString -> (Stream (Of B.ByteString) IO () -> IO a) -> Parser (Maybe a)
consumeWhole bytes use = parser $ \bs pos ->
  Suspended $ Step $ RunConsumer False start (\result -> pure (Done result (unread bs pos)))
  where
    start _ = do
      active <- newIORef True
      let once = S.effect $ do
            valid <- atomicModifyIORef' active (\v -> (False, v))
            unless valid (throwIO ResultAbandoned)
            pure (if B.null bytes then pure () else S.yield bytes)
      use once `finally` writeIORef active False

------------------------------------------------------------------------------
-- Read failures
--
-- These live here because the recipes throw them or fail with them; "Hmssql.Errors"
-- re-exports the exceptions, and "Hmssql.Decoding" re-exports 'ReadFailure'.

-- | Why a value or a row was read past without a result.
data ReadFailure
  = DecodeFailed !DecodeError
    -- ^ The value was read but can't be decoded, or the row doesn't have the
    -- columns its decoder expects.
  | ReadDiscarded
    -- ^ The response is being thrown away, so the value wasn't assembled and its
    -- consumer didn't run.  Nothing reads this result.

instance Show ReadFailure where
  showsPrec p = \case
    DecodeFailed a -> showCon1 p "DecodeFailed"# a
    ReadDiscarded -> showString "ReadDiscarded"
  {-# OPAQUE showsPrec #-}

-- | A row or value from the server did not fit the requested Haskell type:
-- a column count or SQL type the row type doesn't accept (found when the
-- result set's columns arrive, before any row), or a value that doesn't
-- decode (a NULL for a non-'Maybe' field, an out-of-range integer, a
-- 'Hmssql.Decoding.refineField' that said no).  The rest of the response
-- is read before it is thrown, so the connection stays usable.
data DecodeError = DecodeError
  { decodeErrorColumn :: !(Maybe Text)
    -- ^ The column at fault, when the error is one column's.
  , decodeErrorMessage :: !String
  }

instance Show DecodeError where
  showsPrec p (DecodeError a b) =
    showRecord p "DecodeError"# ["decodeErrorColumn"# := a, "decodeErrorMessage"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq DecodeError where
  DecodeError a b == DecodeError a' b' = eq a a' && eq b b'
  {-# OPAQUE (==) #-}

instance Exception DecodeError

-- | The byte stream from the server could not be interpreted.  The connection
-- is unusable afterwards.
newtype ProtocolError = ProtocolError String

instance Show ProtocolError where
  showsPrec p (ProtocolError a) = showCon1 p "ProtocolError"# a
  {-# OPAQUE showsPrec #-}

instance Exception ProtocolError

-- | A result stream was consumed after a newer request was started on the
-- same connection, which discards any unread results, or after a read of
-- it was interrupted by an asynchronous exception, which cancels the
-- statement (see 'Hmssql.Query.queryS').  Also thrown when pulling again
-- from a stream that was already read to its end.
--
-- On a MARS connection ('Hmssql.Connection.connectMars') a newer request
-- leaves the stream open, so this is thrown only by a stream that was
-- canceled: by 'Hmssql.Query.cancelResponse' or the end of its
-- 'Hmssql.Query.withQueryS', by 'Hmssql.Connection.cancelActiveStatement',
-- a 'Hmssql.Connection.reset', the rollback of a transaction it was open
-- in, or an interrupted read.
data ResultAbandoned = ResultAbandoned
  deriving stock (Show)

instance Exception ResultAbandoned
