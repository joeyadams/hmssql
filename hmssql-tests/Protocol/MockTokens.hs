-- | Helpers for feeding hand-made (often malformed) server responses to the
-- client through "MockServer", and for classifying what the client did.
module Protocol.MockTokens
  ( -- * Bytes
    tokenBytes
  , rawPacket
  , packet
  , packetsOf
  , packetize

    -- * Tokens
  , colMetaData
  , row
  , nbcRow
  , putRowValue
  , int32
  , latin1
  , loginResponseBytes

    -- * Scripted servers
  , After (..)
  , scriptedServer
  , withScripted
  , withScriptedCounting
  , withScriptedTokens
  , resetOnClose
  , goodResponse
  , goodQuery
  , firstQuery
  , forceShow
  , trySync

    -- * Outcomes
  , within
  , withinSecs
  , isHmssqlException
  , describeException
  , expectProtocolError
  , expectConnectionClosed
  , expectDecodeError
  , expectBroken
  , expectUsable
  , expectCleanOutcome
  , allocatedDuring
  ) where

import Control.Exception
import Control.Monad (forM_)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits (setBit)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.IORef
import qualified Data.List as List
import Data.Maybe (isJust)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Typeable (typeOf)
import Data.Word (Word16, Word64, Word8)
import GHC.Stats (allocated_bytes, getRTSStats, getRTSStatsEnabled)
import System.Mem (performMajorGC)
import qualified Network.Socket as Socket
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Compat (connSocketMaybe, timeoutInSlices)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (putBVarChar, putUsVarChar)
import Hmssql.Tds.TypeInfo (putTypeInfo, putValue)
import MockServer

------------------------------------------------------------------------------
-- Bytes

tokenBytes :: [Put] -> B.ByteString
tokenBytes = LB.toStrict . Put.runPut . sequence_

-- | A packet with every header field given explicitly.
rawPacket :: Word8 -> Word8 -> Word16 -> Word16 -> Word8 -> B.ByteString -> B.ByteString
rawPacket ty status len spid pid body =
  LB.toStrict (Put.runPut (putHeader hdr)) <> body
  where
    hdr = Header
      { headerType = packetTypeFromWord ty
      , headerStatus = PacketStatus status
      , headerPacketLength = len
      , headerSpid = spid
      , headerPacketId = pid
      , headerWindow = 0
      }

-- | A well-formed tabular-result packet, with or without END_OF_MESSAGE.
packet :: Bool -> B.ByteString -> B.ByteString
packet eom body = rawPacket 0x04 (if eom then 1 else 0) (fromIntegral (B.length body + 8)) 0 1 body

-- | A message body split into packets of at most @n@ payload bytes.
packetsOf :: Int -> B.ByteString -> [B.ByteString]
packetsOf n = packetize [n]

-- | A message body split into packets with the given payload sizes (cycled);
-- the last packet carries END_OF_MESSAGE.
packetize :: [Int] -> B.ByteString -> [B.ByteString]
packetize sizes0 body0 = go (cycle (case filter (> 0) sizes0 of [] -> [4088]; s -> s)) body0
  where
    go (n : ns) body
      | B.length body <= n = [packet True body]
      | otherwise = let (a, b) = B.splitAt n body in packet False a : go ns b
    go [] body = [packet True body]

------------------------------------------------------------------------------
-- Tokens

-- | COLMETADATA for nullable columns of the given names and types.
colMetaData :: [(Text, TypeInfo)] -> Put
colMetaData cols = do
  Put.putWord8 0x81
  Put.putWord16le (fromIntegral (length cols))
  forM_ cols $ \(name, ti) -> do
    Put.putWord32le 0
    Put.putWord16le 0x0001
    putTypeInfo defaultTdsContext ti
    case ti of
      TIText{} -> tableName
      TINText{} -> tableName
      TIImage{} -> tableName
      _ -> pure ()
    putBVarChar name
  where
    tableName = Put.putWord8 1 >> putUsVarChar "t"

-- | A value as it appears in a ROW token (text/ntext/image carry a text
-- pointer and timestamp).
putRowValue :: TypeInfo -> Maybe B.ByteString -> Put
putRowValue ti v = case ti of
  TIText{} -> textPtr
  TINText{} -> textPtr
  TIImage{} -> textPtr
  _ -> putValue defaultTdsContext ti v
  where
    textPtr = case v of
      Nothing -> Put.putWord8 0
      Just bs -> do
        Put.putWord8 16
        Put.putByteString (B.replicate 16 0)
        Put.putByteString (B.replicate 8 0)
        Put.putWord32le (fromIntegral (B.length bs))
        Put.putByteString bs

row :: [(TypeInfo, Maybe B.ByteString)] -> Put
row vals = Put.putWord8 0xD1 >> mapM_ (uncurry putRowValue) vals

nbcRow :: [(TypeInfo, Maybe B.ByteString)] -> Put
nbcRow vals = do
  Put.putWord8 0xD2
  let n = length vals
      bitmap = List.foldl' (\bs (i, (_, v)) -> if isJust v then bs else setAt i bs) (replicate ((n + 7) `div` 8) 0) (zip [0 ..] vals)
      setAt i bs = [if j == i `div` 8 then setBit b (i `mod` 8) else b | (j, b) <- zip [0 :: Int ..] bs]
  mapM_ Put.putWord8 (bitmap :: [Word8])
  mapM_ (\(ti, v) -> maybe (pure ()) (\_ -> putRowValue ti v) v) vals

int32 :: Int32 -> Maybe B.ByteString
int32 = Just . LB.toStrict . Put.runPut . Put.putInt32le

-- | Latin1_General_CI_AS.
latin1 :: Collation
latin1 = Collation 0x00D00409 0x34

loginResponseBytes :: B.ByteString
loginResponseBytes = tokenBytes defaultLoginResponse

------------------------------------------------------------------------------
-- Scripted servers

-- | What the mock does after sending its scripted reply to the first request.
data After
  = ThenServe
    -- ^ Answer every further request with 'goodResponse'.
  | ThenClose
    -- ^ Close the connection.
  | ThenHold
    -- ^ Keep the connection open and never answer.

-- | Log in normally, answer the first request with the given chunks (each
-- written with its own send), then carry on as 'After' says.
scriptedServer :: [B.ByteString] -> After -> MockConn -> IO ()
scriptedServer = scriptedServerCounting Nothing

-- | 'scriptedServer', counting the Attentions it acknowledges.
scriptedServerCounting :: Maybe (IORef Int) -> [B.ByteString] -> After -> MockConn -> IO ()
scriptedServerCounting attns chunks after mc = do
  _ <- serveLogin defaultLoginResponse mc
  _ <- recvMessage mc
  mapM_ (sendRaw mc) chunks
  case after of
    ThenServe ->
      let serve = recvMessageMaybe mc >>= \case
            Nothing -> pure ()
            Just (PTAttention, _) -> do
              mapM_ (\r -> modifyIORef' r (+ 1)) attns
              sendTokens mc [doneToken 0x20 0]
              serve
            Just _ -> sendTokens mc goodResponse >> serve
       in serve
    ThenClose -> pure ()
    ThenHold ->
      let loop = recvMessageMaybe mc >>= maybe (pure ()) (const loop)
       in loop `catch` \(_ :: SomeException) -> pure ()

withScripted :: [B.ByteString] -> After -> (Connection -> IO a) -> IO a
withScripted chunks after act = withScriptedCounting chunks after (const act)

-- | 'withScripted', also passing a count of the Attentions the mock has
-- acknowledged.
withScriptedCounting :: [B.ByteString] -> After -> (IORef Int -> Connection -> IO a) -> IO a
withScriptedCounting chunks after act = do
  attns <- newIORef 0
  withMockServer (scriptedServerCounting (Just attns) chunks after) $ \srv ->
    withConnection (mockConnectInfo srv) $ \conn -> act attns conn `finally` resetOnClose conn

-- | Make the client's close reset the connection instead of leaving it in
-- TIME_WAIT: the fuzz tests open thousands of connections, which would
-- otherwise run out of ephemeral ports.  A connection over a pipe has no
-- port to run out of, and nothing is done for it.
resetOnClose :: Connection -> IO ()
resetOnClose conn = forM_ (connSocketMaybe conn) $ \sock ->
  Socket.setSockOpt sock Socket.Linger (Socket.StructLinger 1 0)
    `catch` \(_ :: IOException) -> pure ()

-- | 'withScripted' with the tokens sent as one well-formed message.
withScriptedTokens :: [Put] -> (Connection -> IO a) -> IO a
withScriptedTokens toks = withScripted (packetsOf 4088 (tokenBytes toks)) ThenServe

-- | The mock's answer to every request after the scripted one.
goodResponse :: [Put]
goodResponse = [colMetaData [("x", TIIntN 4)], row [(TIIntN 4, int32 42)], doneToken 0x10 1]

goodQuery :: Connection -> IO [Only Int32]
goodQuery conn = query conn "SELECT 42"

-- | Every result set of the first request, fully forced (so exceptions
-- hidden in lazy fields surface here).
firstQuery :: Connection -> IO (Either SomeException [ResultSet SqlRow])
firstQuery conn = trySync (queryMulti conn "SELECT 1" >>= forceShow)

-- | 'try', except that asynchronous exceptions (such as the one 'timeout'
-- uses) are rethrown.
trySync :: IO a -> IO (Either SomeException a)
trySync act = try act >>= \case
  Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
  r -> pure r

forceShow :: Show a => a -> IO a
forceShow a = evaluate (length (show a)) >> pure a

------------------------------------------------------------------------------
-- Outcomes

-- | Fail the test if the action takes longer than 10 s.
within :: IO a -> IO a
within = withinSecs 10

withinSecs :: Int -> IO a -> IO a
withinSecs secs act = timeoutInSlices (secs * 1_000_000) act >>= \case
  Just a -> pure a
  Nothing -> throwIO (userError ("hung: no outcome within " ++ show secs ++ " s"))

-- | The exceptions hmssql documents for server or protocol trouble.
isHmssqlException :: SomeException -> Bool
isHmssqlException e = or
  [ is (Proxy @ProtocolError), is (Proxy @DecodeError), is (Proxy @SqlServerError)
  , is (Proxy @SevereError), is (Proxy @ConnectionClosed), is (Proxy @ConnectionBroken)
  , is (Proxy @UnexpectedResult), is (Proxy @ResultAbandoned), is (Proxy @LoginError)
  , is (Proxy @LoginRedirected)
  ]
  where
    is :: forall ex. Exception ex => Proxy ex -> Bool
    is _ = isJust (fromException e :: Maybe ex)

describeException :: SomeException -> String
describeException (SomeException inner) = show (typeOf inner) ++ ": " ++ show inner

describeOutcome :: Show a => Either SomeException a -> String
describeOutcome = either describeException (\a -> "result " ++ take 300 (show a))

expectProtocolError :: Show a => Either SomeException a -> Expectation
expectProtocolError = \case
  Left e | Just (ProtocolError _) <- fromException e -> pure ()
  other -> expectationFailure ("expected ProtocolError, got " ++ describeOutcome other)

expectConnectionClosed :: Show a => Either SomeException a -> Expectation
expectConnectionClosed = \case
  Left e | Just ConnectionClosed <- fromException e -> pure ()
  other -> expectationFailure ("expected ConnectionClosed, got " ++ describeOutcome other)

expectDecodeError :: Show a => Either SomeException a -> Expectation
expectDecodeError = \case
  Left e | Just DecodeError{} <- fromException e -> pure ()
  other -> expectationFailure ("expected DecodeError, got " ++ describeOutcome other)

-- | Further use fails cleanly with 'ConnectionBroken'.
expectBroken :: Connection -> Expectation
expectBroken conn = within (trySync (goodQuery conn)) >>= \case
  Left e | Just (ConnectionBroken _) <- fromException e -> pure ()
  other -> expectationFailure ("expected ConnectionBroken on further use, got " ++ describeOutcome other)

-- | The connection still answers a query correctly.
expectUsable :: Connection -> Expectation
expectUsable conn = within (trySync (goodQuery conn)) >>= \case
  Right [Only 42] -> pure ()
  other -> expectationFailure ("expected the connection to stay usable, got " ++ describeOutcome other)

-- | The client produced a result or a documented hmssql exception, and the
-- connection is afterwards either usable or cleanly broken.
expectCleanOutcome :: Show a => Connection -> Either SomeException a -> Expectation
expectCleanOutcome conn r = do
  case r of
    Left e | not (isHmssqlException e) -> expectationFailure ("unexpected exception " ++ describeException e)
    _ -> pure ()
  within (trySync (goodQuery conn)) >>= \case
    Right [Only 42] -> pure ()
    Left e | Just (ConnectionBroken _) <- fromException e -> pure ()
    Left e | Just (ProtocolError _) <- fromException e, Right _ <- r -> pure ()
    other -> expectationFailure ("after " ++ describeOutcome r ++ ", further use gave " ++ describeOutcome other)

-- | Bytes allocated (by the whole program) while running the action.
allocatedDuring :: IO a -> IO (Maybe Word64, a)
allocatedDuring act = do
  enabled <- getRTSStatsEnabled
  if not enabled
    then (\a -> (Nothing, a)) <$> act
    else do
      performMajorGC
      before <- allocated_bytes <$> getRTSStats
      a <- act
      performMajorGC
      after <- allocated_bytes <$> getRTSStats
      pure (Just (after - before), a)
