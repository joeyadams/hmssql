-- | Truncated and randomly corrupted server responses, fed through the mock.
--
-- The client must finish within a timeout with a result or a documented
-- hmssql exception (never 'ErrorCall', a pattern-match failure, an
-- 'ArithException', a 'UnicodeException', ...), and leave the connection
-- usable or cleanly broken.
module Protocol.FuzzSpec (spec) where

import Control.Exception
import Control.Monad (forM, forM_, when)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (complementBit)
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Data.Maybe (catMaybes)
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word16, Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Numeric (showHex)
import System.IO.Error (isUserError)
import System.Timeout (timeout)
import Control.Concurrent (forkIO, killThread, threadDelay)
import System.Exit (ExitCode (..))
import System.IO (hFlush, hPutStrLn, stderr)
import Compat (exitImmediately)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxShrinks)
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Client (encryptionWord)
import Hmssql.Tds.Primitives (timeLength)
import MockServer
import Protocol.MockTokens
import TestDb (slow, withCases)

spec :: Spec
spec = do
  truncation
  -- Each item has a flag of its own for "a case has hung" ('runCase').
  describe "random corruption of a response's tokens" $ before (newIORef False) $ do
    modifyMaxShrinks (const 50) $ withCases 300 $
      it "ends cleanly" $ hedgehog . tokenFuzz
    slow $ modifyMaxShrinks (const 50) $ withCases 50000 $
      it "ends cleanly, many iterations" $ hedgehog . tokenFuzz
  describe "random corruption of a response's packets, then the server closes" $ before (newIORef False) $ do
    modifyMaxShrinks (const 50) $ withCases 150 $
      it "ends cleanly" $ hedgehog . packetFuzz
    slow $ modifyMaxShrinks (const 50) $ withCases 50000 $
      it "ends cleanly, many iterations" $ hedgehog . packetFuzz
  describe "random corruption of the login response" $ do
    withCases 150 $
      it "ends cleanly" $ hedgehog loginFuzz
    -- An iteration whose login fails leaves no client socket in TIME_WAIT
    -- only because the mock resets the connection once the client has
    -- closed it (see 'withMockServer'): macOS has 16384 ephemeral ports.
    slow $ withCases 20000 $
      it "ends cleanly, many iterations" $ hedgehog loginFuzz

------------------------------------------------------------------------------
-- Truncation at every offset

-- | A valid response with many kinds of token, as separately encoded tokens
-- (so the token boundaries are known).
richResponse :: [B.ByteString]
richResponse = map (tokenBytes . pure)
  [ databaseEnvChange "old" "new"
  , infoToken (ServerMessage 5701 2 0 "Changed database context" "mock" "" 1)
  , colMetaData cols
  , row (zip types [int32 1, Just (T.encodeUtf16LE "héllo"), Just (B.replicate 20 9), Just "abc", Just (B.pack [0x38, 0, 5, 0, 0, 0])])
  , nbcRow (zip types [int32 2, Nothing, Just B.empty, Nothing, Nothing])
  , doneToken 0x11 2
  , colMetaData [("y", TIBitN)]
  , row [(TIBitN, Just "\1")]
  , Put.putWord8 0x79 >> Put.putInt32le 0
  , doneToken 0x10 1
  ]
  where
    cols = [("i", TIIntN 4), ("s", TINVarChar 0xFFFF latin1), ("b", TIBigVarBinary 0xFFFF), ("t", TIText 0x7FFFFFFF latin1), ("v", TISqlVariant 8016)]
    types = map snd cols

-- | Offsets at which a token starts (excluding 0 and the end).
boundaries :: [Int]
boundaries = init (drop 1 (scanl (+) 0 (map B.length richResponse)))

truncation :: Spec
truncation = describe "a response cut short at every offset" $ do
  let body = B.concat richResponse
      offsets = [0 .. B.length body - 1]
      midToken = filter (`notElem` (0 : boundaries)) offsets

  it "the full response is read correctly" $
    withScripted (packetsOf 50 body) ThenServe $ \conn -> do
      r <- within (firstQuery conn)
      case r of
        Right [ResultSet _ rows1, ResultSet _ rows2] -> (length rows1, length rows2) `shouldBe` (2, 1)
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "with END_OF_MESSAGE in the middle of a token: ProtocolError, then broken" $
    everyOffset midToken $ \k -> withScripted [packet True (B.take k body)] ThenServe $ \conn -> do
      r <- within (firstQuery conn)
      b <- within (trySync (goodQuery conn))
      pure $ case (r, b) of
        (Left e, Left e')
          | Just (ProtocolError _) <- fromException e
          , Just (ConnectionBroken _) <- fromException e' -> Nothing
        _ -> Just (outcome r b)

  it "with END_OF_MESSAGE at a token boundary before the final DONE: ProtocolError, then broken" $
    everyOffset (0 : boundaries) $ \k -> withScripted [packet True (B.take k body)] ThenServe $ \conn -> do
      r <- within (firstQuery conn)
      b <- within (trySync (goodQuery conn))
      pure $ case (r, b) of
        (Left e, Left e')
          | Just (ProtocolError _) <- fromException e
          , Just (ConnectionBroken _) <- fromException e' -> Nothing
        _ -> Just (outcome r b)

  it "without END_OF_MESSAGE, then the server closes: ConnectionClosed, then broken" $
    everyOffset offsets $ \k -> withScripted [packet False (B.take k body)] ThenClose $ \conn -> do
      r <- within (firstQuery conn)
      b <- within (trySync (goodQuery conn))
      pure $ case (r, b) of
        (Left e, Left e')
          | Just ConnectionClosed <- fromException e
          , Just (ConnectionBroken _) <- fromException e' -> Nothing
        _ -> Just (outcome r b)

  it "cut anywhere in the packet stream (headers included), then the server closes: ConnectionClosed, then broken" $ do
    let stream = B.concat (packetsOf 40 body)
    everyOffset [0 .. B.length stream - 1] $ \k -> withScripted [B.take k stream] ThenClose $ \conn -> do
      r <- within (firstQuery conn)
      b <- within (trySync (goodQuery conn))
      pure $ case (r, b) of
        (Left e, Left e')
          | Just ConnectionClosed <- fromException e
          , Just (ConnectionBroken _) <- fromException e' -> Nothing
        _ -> Just (outcome r b)

  -- Including at the token boundaries: an empty message, and LOGINACK
  -- without the DONE.
  it "a login response cut anywhere (END_OF_MESSAGE set): ProtocolError" $ do
    let login = loginResponseBytes
    everyOffset [0 .. B.length login - 1] $ \k -> do
      r <- loginWithResponse [packet True (B.take k login)]
      pure $ case r of
        Left e | Just (ProtocolError _) <- fromException e -> Nothing
        _ -> Just (either describeException show r)

  it "a login response cut anywhere, then the server closes: ConnectionClosed" $ do
    let stream = packet True loginResponseBytes
    everyOffset [0 .. B.length stream - 1] $ \k -> do
      r <- loginWithResponse [B.take k stream]
      pure $ case r of
        Left e | Just ConnectionClosed <- fromException e -> Nothing
        _ -> Just (either describeException show r)
  where
    outcome r b = "first request: " ++ either describeException (take 200 . show) r
      ++ "; next request: " ++ either describeException show b

-- | Run the check at every offset; fail listing the offsets that went wrong.
everyOffset :: [Int] -> (Int -> IO (Maybe String)) -> Expectation
everyOffset ks check = do
  failures <- catMaybes <$> forM ks (\k -> fmap (\m -> (k, m)) <$> check k)
  unless' (null failures) $
    expectationFailure $ show (length failures) ++ " of " ++ show (length ks) ++ " offsets failed, e.g.:\n"
      ++ unlines [ "  offset " ++ show k ++ ": " ++ m | (k, m) <- take 5 failures ]
  where
    unless' c a = if c then pure () else a

-- | PRELOGIN and LOGIN7 as usual, then the given raw bytes as the login
-- response, then close.  The client's outcome of connecting and running a
-- batch.
loginWithResponse :: [B.ByteString] -> IO (Either SomeException ())
loginWithResponse chunks = withMockServer handler $ \srv ->
  within (trySync (withConnection (mockConnectInfo srv) (\conn -> (() <$ execute conn "SELECT 1") `finally` resetOnClose conn)))
  where
    handler mc = do
      _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
      _ <- expectLogin7 mc
      mapM_ (sendRaw mc) chunks

------------------------------------------------------------------------------
-- Generators

nullable :: Gen B.ByteString -> Gen (Maybe B.ByteString)
nullable g = Gen.frequency [(1, pure Nothing), (5, Just <$> g)]

fixed :: Int -> Gen B.ByteString
fixed n = Gen.bytes (Range.singleton n)

utf16 :: Int -> Gen B.ByteString
utf16 n = T.encodeUtf16LE <$> Gen.text (Range.linear 0 n) Gen.unicode

ascii :: Int -> Gen B.ByteString
ascii n = T.encodeUtf8 <$> Gen.text (Range.linear 0 n) Gen.alphaNum

-- | A well-formed sql_variant value.
variantValue :: Gen B.ByteString
variantValue = B.pack <$> Gen.choice
  [ ([0x38, 0] ++) <$> bytesOf 4
  , ([0x7F, 0] ++) <$> bytesOf 8
  , do s <- utf16 10
       pure ([0xE7, 7, 0x09, 0x04, 0xD0, 0, 0x34, fromIntegral (B.length s), 0] ++ B.unpack s)
  , do scale <- Gen.word8 (Range.linear 0 7)
       ([0x29, 1, scale] ++) <$> bytesOf (timeLength scale)
  , ([0x6A, 2, 18, 2, 1] ++) <$> bytesOf 8
  ]
  where bytesOf n = B.unpack <$> fixed n

-- | Column types with generators of values valid for them (the bytes may
-- still decode to out-of-range values, which must give 'DecodeError').
columnKinds :: [(TypeInfo, Gen (Maybe B.ByteString))]
columnKinds =
  [ (TIIntN 4, nullable (fixed 4))
  , (TIIntN 8, nullable (fixed 8))
  , (TIInt4, Just <$> fixed 4)
  , (TIBitN, nullable (fixed 1))
  , (TIFltN 8, nullable (fixed 8))
  , (TIDecimalN 18 2, nullable (B.cons 1 <$> fixed 8))
  , (TIMoneyN 8, nullable (fixed 8))
  , (TIGuid, nullable (fixed 16))
  , (TIDateN, nullable (fixed 3))
  , (TITimeN 3, nullable (fixed 4))
  , (TIDateTime2N 7, nullable (fixed 8))
  , (TIDateTimeOffsetN 7, nullable (fixed 10))
  , (TIDateTimeN 8, nullable (fixed 8))
  , (TINVarChar 40 latin1, nullable (utf16 20))
  , (TINVarChar 0xFFFF latin1, nullable (utf16 50))
  , (TIBigVarChar 20 latin1, nullable (ascii 20))
  , (TIBigVarBinary 30, nullable (Gen.bytes (Range.linear 0 30)))
  , (TIBigVarBinary 0xFFFF, nullable (Gen.frequency [(9, Gen.bytes (Range.linear 0 100)), (1, Gen.bytes (Range.linear 7990 8010))]))
  , (TISqlVariant 8016, nullable variantValue)
  , (TIXml Nothing, nullable (utf16 20))
  , (TIText 0x7FFFFFFF latin1, nullable (ascii 30))
  ]

genMessage :: Gen ServerMessage
genMessage = do
  t <- Gen.text (Range.linear 0 30) Gen.alphaNum
  n <- Gen.int32 (Range.linear 0 60000)
  pure (ServerMessage n 1 16 t "mock" "" 1)

genResultSet :: Gen [Put]
genResultSet = do
  kinds <- Gen.list (Range.linear 1 6) (Gen.element columnKinds)
  let types = map fst kinds
      names = [T.pack ("c" ++ show i) | i <- [1 .. length kinds]]
  rows <- Gen.list (Range.linear 0 4) $ do
    vals <- mapM snd kinds
    nbc <- Gen.bool
    pure ((if nbc then nbcRow else row) (zip types vals))
  pure ([colMetaData (zip names types)] ++ rows ++ [doneToken 0x11 (fromIntegral (length rows))])

genItem :: Gen [Put]
genItem = Gen.frequency
  [ (6, genResultSet)
  , (1, pure . infoToken <$> genMessage)
  , (1, (\m -> [errorToken m { msgClass = 16 }]) <$> genMessage)
  , (1, pure [databaseEnvChange "a" "b"])
  , (1, (\b -> [envChangeToken 99 b]) <$> Gen.bytes (Range.linear 0 5))
  , (1, pure [Put.putWord8 0xA9 >> Put.putWord16le 2 >> Put.putWord16le 1])
  , (1, (\i -> [Put.putWord8 0x79 >> Put.putInt32le i]) <$> Gen.int32 Range.linearBounded)
  , (1, pure [Put.putWord8 0xFF >> Put.putWord16le 0x11 >> Put.putWord16le 0xC1 >> Put.putWord64le 1])
  ]

genResponse :: Gen B.ByteString
genResponse = do
  items <- Gen.list (Range.linear 0 4) genItem
  final <- Gen.element [doneToken 0x10 0, doneToken 0 0, Put.putWord8 0xFE >> Put.putWord16le 0 >> Put.putWord16le 0 >> Put.putWord64le 0]
  pure (tokenBytes (concat items ++ [final]))

data Mutation
  = FlipBit !Int !Int
  | SetByte !Int !Word8
  | SetWord16 !Int !Word16
  | InsertByte !Int !Word8
  | DeleteBytes !Int !Int
  | Truncate !Int
  deriving (Show)

-- | Positions are taken modulo the length of the bytes being mutated.
genMutation :: Gen Mutation
genMutation = Gen.frequency
  [ (3, FlipBit <$> pos <*> Gen.int (Range.constant 0 7))
  , (2, SetByte <$> pos <*> Gen.element [0, 1, 0x7F, 0x80, 0xFE, 0xFF])
  , (1, SetByte <$> pos <*> Gen.enumBounded)
  , (2, SetWord16 <$> pos <*> Gen.element [0, 1, 0x7FFF, 0x8000, 0xFFFE, 0xFFFF])
  , (1, InsertByte <$> pos <*> Gen.enumBounded)
  , (1, DeleteBytes <$> pos <*> Gen.int (Range.linear 1 8))
  , (1, Truncate <$> pos)
  ]
  where pos = Gen.int (Range.constant 0 1_000_000)

mutate :: B.ByteString -> Mutation -> B.ByteString
mutate bs m
  | B.null bs = bs
  | otherwise = case m of
      FlipBit p b -> modifyAt (at p) (`complementBit` b)
      SetByte p w -> modifyAt (at p) (const w)
      SetWord16 p w -> let i = at p in B.take i bs <> B.pack [fromIntegral w, fromIntegral (w `div` 256)] <> B.drop (i + 2) bs
      InsertByte p w -> let i = p `mod` (B.length bs + 1) in B.take i bs <> B.singleton w <> B.drop i bs
      DeleteBytes p n -> let i = at p in B.take i bs <> B.drop (i + n) bs
      Truncate p -> B.take (at p) bs
  where
    at p = p `mod` B.length bs
    modifyAt i f = B.take i bs <> B.singleton (f (B.index bs i)) <> B.drop (i + 1) bs

genPacketSizes :: Gen [Int]
genPacketSizes = Gen.choice
  [ pure [4088]
  , pure [1]
  , Gen.list (Range.linear 1 5) (Gen.int (Range.linear 1 600))
  ]

hexdump :: B.ByteString -> String
hexdump = concatMap (\w -> (if w < 16 then "0" else "") ++ showHex w "") . B.unpack

------------------------------------------------------------------------------
-- Properties

-- | hmssql's own exceptions; anything else ('ErrorCall', a pattern-match
-- failure, an 'ArithException', a 'UnicodeException', ...) is a bug.
acceptable :: SomeException -> Bool
acceptable = isHmssqlException

-- | A transport error, e.g. a connection reset by the closing server.
isTransportError :: SomeException -> Bool
isTransportError e = case fromException e :: Maybe IOException of
  Just io -> not (isUserError io)
  Nothing -> False

-- | Judge the first request's outcome and the connection's state after it.
judge :: Bool -> Int -> Maybe (Either SomeException a) -> Maybe (Either SomeException [Only Int32]) -> Either String ()
judge closed attentions r1 r2 = do
  first <- maybe (Left "the first request hung, in this case or in one before it (its packets are on stderr)") Right r1
  case first of
    Left e | not (acceptable e || (closed && isTransportError e)) ->
      Left ("the first request threw " ++ describeException e)
    _ -> Right ()
  second <- maybe (Left "the next request hung") Right r2
  let firstWasProtocolError = case first of
        Left e | Just (ProtocolError _) <- fromException e -> True
        _ -> False
  case second of
    Right [Only 42] | not closed -> Right ()
    -- The first request failed before its response was read, so the next
    -- one sent an Attention.  A corrupted response may itself contain a
    -- DONE with DONE_ATTN, which the client (like Microsoft's) takes as the
    -- acknowledgement; the real one then answers the next request.  No
    -- client can tell these apart.
    Right [] | attentions > 0, Left _ <- first -> Right ()
    Right _ | closed -> Right ()
    Left e | Just (ConnectionBroken _) <- fromException e -> Right ()
    -- The rest of an undrained response failed to parse.
    Left e | Just (ProtocolError _) <- fromException e, not firstWasProtocolError -> Right ()
    Left e | closed, acceptable e || isTransportError e -> Right ()
    other -> Left ("after the first request, the next request gave " ++ either describeException show other)

-- | Run a case, unless a case of this property has hung already: then
-- answer "hung" at once, without running it.
--
-- A case that hangs fails the property, and hedgehog then shrinks it, each
-- smaller case perhaps as slow.  Its limit on shrinks counts the steps
-- taken, not the cases tried at each step, so it doesn't bound the time:
-- with a response of 16 KB in packets of one byte, which takes over 5 s
-- under load with the row walk of the time (docs/dev/bugs-found.md, "Memory
-- and performance"), a matrix run spent
-- eight hours shrinking at full CPU and printed nothing (2026-10-02), and
-- three runs at once were stopped after one to two hours of it
-- (2026-10-05).  So the hung case is printed at once ('reportHang'), and
-- the shrinking after it runs nothing: the case hedgehog then reports is
-- not a smaller one that hangs.
runCase :: IORef Bool -> [B.ByteString] -> After -> IO (Int, Maybe (Either SomeException [ResultSet SqlRow]), Maybe (Either SomeException [Only Int32]))
runCase hung chunks after = readIORef hung >>= \case
  True -> pure (0, Nothing, Nothing)
  False -> watchdog 60 chunks $ withinSecs 30 $ withScriptedCounting chunks after $ \attns conn -> do
    r1 <- timeout 5_000_000 (firstQuery conn)
    r2 <- timeout 5_000_000 (trySync (goodQuery conn))
    when (null r1 || null r2) $ do
      writeIORef hung True
      reportHang chunks (if null r1 then "first" else "next")
    n <- readIORef attns
    pure (n, r1, r2)

-- | Print a hung case's packets to stderr, for the first few hangs of the
-- process.
reportHang :: [B.ByteString] -> String -> IO ()
reportHang chunks which = do
  k <- atomicModifyIORef' hangsReported (\i -> (i + 1, i))
  when (k < 3) $ do
    hPutStrLn stderr ("Protocol.Fuzz: the " ++ which ++ " request hung for 5 s; the case's packets:\n"
      ++ unlines (map hexdump chunks))
    hFlush stderr

hangsReported :: IORef Int
hangsReported = unsafePerformIO (newIORef 0)
{-# NOINLINE hangsReported #-}

-- | End the process, printing the case, if the action outlives the
-- seconds: a guard against a hang no timeout can end (work inside
-- 'mask_', or a loop that doesn't allocate), which 'withinSecs' wouldn't.
watchdog :: Int -> [B.ByteString] -> IO a -> IO a
watchdog secs chunks act = bracket (forkIO bark) killThread (const act)
  where
    bark = do
      threadDelay (secs * 1_000_000)
      hPutStrLn stderr ("Protocol.Fuzz: a case hung for " ++ show secs ++ " s, uninterruptibly; its packets:\n"
        ++ unlines (map hexdump chunks))
      hFlush stderr
      exitImmediately (ExitFailure 3)

tokenFuzz :: IORef Bool -> PropertyT IO ()
tokenFuzz hung = do
  body <- forAllWith hexdump genResponse
  muts <- forAll (Gen.list (Range.linear 1 4) genMutation)
  sizes <- forAll genPacketSizes
  let body' = foldl mutate body muts
  annotate ("mutated: " ++ hexdump body')
  (attns, r1, r2) <- evalIO (runCase hung (packetize sizes body') ThenServe)
  classifyOutcome r1
  when (attns > 0) (label "Attention")
  either (\m -> annotate m >> failure) pure (judge False attns r1 r2)

packetFuzz :: IORef Bool -> PropertyT IO ()
packetFuzz hung = do
  body <- forAllWith hexdump genResponse
  sizes <- forAll genPacketSizes
  muts <- forAll (Gen.list (Range.linear 1 4) genMutation)
  let stream = foldl mutate (B.concat (packetize sizes body)) muts
  annotate ("mutated stream: " ++ hexdump stream)
  (attns, r1, r2) <- evalIO (runCase hung [stream] ThenClose)
  classifyOutcome r1
  either (\m -> annotate m >> failure) pure (judge True attns r1 r2)

classifyOutcome :: Maybe (Either SomeException a) -> PropertyT IO ()
classifyOutcome r = do
  forM_ r $ \o -> do
    label' "result" (either (const False) (const True) o)
    label' "ProtocolError" (is (Proxy @ProtocolError) o)
    label' "DecodeError" (is (Proxy @DecodeError) o)
    label' "SqlServerError" (is (Proxy @SqlServerError) o)
    label' "SevereError" (is (Proxy @SevereError) o)
    label' "ConnectionClosed" (is (Proxy @ConnectionClosed) o)
  where
    label' name c = when c (label name)
    is :: forall e b. Exception e => Proxy e -> Either SomeException b -> Bool
    is _ = \case
      Left e -> case fromException e :: Maybe e of
        Just _ -> True
        Nothing -> False
      Right _ -> False

-- | Corrupt the login response: 'connect' must succeed or fail cleanly.
loginFuzz :: PropertyT IO ()
loginFuzz = do
  extra <- forAllWith hexdump (Gen.element (map tokenBytes [[], [databaseEnvChange "master" "mockdb"], [infoToken (ServerMessage 5701 2 0 "ctx" "mock" "" 1)]]))
  let body = extra <> tokenBytes defaultLoginResponse
  muts <- forAll (Gen.list (Range.linear 1 4) genMutation)
  sizes <- forAll genPacketSizes
  let body' = foldl mutate body muts
  annotate ("mutated: " ++ hexdump body')
  let handler mc = do
        _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
        _ <- expectLogin7 mc
        mapM_ (sendRaw mc) (packetize sizes body')
        serveRequests (\_ _ -> pure goodResponse) mc
  r <- evalIO $ withMockServer handler $ \srv ->
    timeout 10_000_000 (trySync (withConnection (mockConnectInfo srv) (\conn -> goodQuery conn `finally` resetOnClose conn)))
  case r of
    Nothing -> annotate "hung" >> failure
    Just (Left e) | not (acceptable e) -> annotate (describeException e) >> failure
    Just (Right v) | v /= [Only 42] -> annotate ("wrong result " ++ show v) >> failure
    Just _ -> pure ()
