-- | The client against malformed, adversarial or unusual server responses,
-- served by the in-process mock.  Every test bounds the client with a
-- timeout; the client must produce a result or a documented hmssql exception,
-- and leave the connection usable or cleanly broken ('ConnectionBroken').
module Protocol.MalformedSpec (spec) where

import Control.Exception
import Control.Monad (forM_)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.IORef
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time (Day, LocalTime (..), TimeOfDay (..), fromGregorian, midnight)
import Data.Word (Word16, Word32, Word64, Word8)
import System.Timeout (timeout)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.BatchQuery (runBatchQuery, batchQueryMulti)
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Connection (connectionContext)
import Hmssql.Tds.Client (Login7 (..), encryptionWord, putPrelogin)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (putBVarChar)
import Hmssql.Tds.TypeInfo (putTypeInfo)
import MockServer
import TestDb (serial, withTestDb)
import Protocol.MockTokens

spec :: Spec
spec = do
  packetLayer
  closing
  loginPhase
  tokenLayer
  values
  memory
  liveServer

------------------------------------------------------------------------------
-- Builders

bvarchar :: Text -> B.ByteString
bvarchar = LB.toStrict . Put.runPut . putBVarChar

-- | Token type, USHORT length, body.
lengthPrefixed :: Word8 -> Put -> Put
lengthPrefixed ty body = do
  let bytes = Put.runPut body
  Put.putWord8 ty
  Put.putWord16le (fromIntegral (LB.length bytes))
  Put.putLazyByteString bytes

loginAckRaw :: Word32 -> Put
loginAckRaw version = lengthPrefixed 0xAD $ do
  Put.putWord8 1
  Put.putWord32be version
  putBVarChar "Microsoft SQL Server"
  mapM_ Put.putWord8 [17, 0, 3, 232]

featureExtAck :: [(Word8, B.ByteString)] -> Put
featureExtAck feats = do
  Put.putWord8 0xAE
  forM_ feats $ \(fid, dat) -> do
    Put.putWord8 fid
    Put.putWord32le (fromIntegral (B.length dat))
    Put.putByteString dat
  Put.putWord8 0xFF

sspiToken :: B.ByteString -> Put
sspiToken bs = Put.putWord8 0xED >> Put.putWord16le (fromIntegral (B.length bs)) >> Put.putByteString bs

-- | DONEPROC (0xFE) and DONEINPROC (0xFF), laid out like DONE.
doneProcToken, doneInProcToken :: Word16 -> Word64 -> Put
doneProcToken status rows = Put.putWord8 0xFE >> Put.putWord16le status >> Put.putWord16le 0 >> Put.putWord64le rows
doneInProcToken status rows = Put.putWord8 0xFF >> Put.putWord16le status >> Put.putWord16le 0 >> Put.putWord64le rows

returnStatus :: Int32 -> Put
returnStatus n = Put.putWord8 0x79 >> Put.putInt32le n

packetSizeEnvChange :: Text -> Put
packetSizeEnvChange new = envChangeToken 4 (bvarchar new <> bvarchar "4096")

msg :: Text -> ServerMessage
msg t = ServerMessage 50000 1 16 t "mock" "" 1

intCol :: [(Text, TypeInfo)]
intCol = [("x", TIIntN 4)]

-- | COLMETADATA for one column with the given raw TYPE_INFO bytes.
rawColumn :: [Word8] -> Put
rawColumn typeInfo = do
  Put.putWord8 0x81
  Put.putWord16le 1
  Put.putWord32le 0
  Put.putWord16le 1
  mapM_ Put.putWord8 typeInfo
  putBVarChar "c"

bytes :: [Word8] -> Put
bytes = mapM_ Put.putWord8

-- | A response a query would get: one int column, two rows, final DONE.
twoRows :: [Put]
twoRows =
  [ colMetaData intCol
  , row [(TIIntN 4, int32 1)]
  , row [(TIIntN 4, int32 2)]
  , doneToken 0x10 2
  ]

intsQuery :: Connection -> IO (Either SomeException [Only Int32])
intsQuery conn = trySync (query conn "SELECT x" >>= forceShow)

------------------------------------------------------------------------------

packetLayer :: Spec
packetLayer = describe "packet layer" $ do
  forM_ [0, 1, 7] $ \len ->
    it ("rejects a packet header length of " ++ show len) $
      withScripted [rawPacket 0x04 1 len 0 1 (tokenBytes twoRows)] ThenServe $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

  forM_ [(0x01, "SQLBatch"), (0x12, "PRELOGIN"), (0x06, "Attention"), (0x99, "unknown")] $ \(ty, name) ->
    it ("rejects a response packet of type " ++ name) $ do
      let body = tokenBytes twoRows
      withScripted [rawPacket ty 1 (fromIntegral (B.length body + 8)) 0 1 body] ThenServe $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

  it "handles a packet longer than the negotiated packet size" $ do
    let big = B.replicate 20000 7
        body = tokenBytes [colMetaData [("b", TIBigVarBinary 0xFFFF)], row [(TIBigVarBinary 0xFFFF, Just big)], doneToken 0x10 1]
    withScripted [packet True body] ThenServe $ \conn -> do
      r <- within (trySync (query conn "SELECT b" >>= forceShow))
      case r of
        Right [Only v] -> v `shouldBe` big
        other -> expectCleanOutcome conn other

  it "ignores nonsense SPID, packet ID and window fields" $ do
    let body = tokenBytes twoRows
        (a, b) = B.splitAt 10 body
        pkts = [rawPacket 0x04 0 (fromIntegral (B.length a + 8)) 0xFFFF 200 a, rawPacket 0x04 1 (fromIntegral (B.length b + 8)) 1234 7 b]
    withScripted pkts ThenServe $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1, Only 2])
      expectUsable conn

  it "handles a response packet with the IGNORE status bit" $
    withScripted [rawPacket 0x04 0x03 (fromIntegral (B.length (tokenBytes twoRows) + 8)) 0 1 (tokenBytes twoRows)] ThenServe $ \conn ->
      within (intsQuery conn) >>= expectCleanOutcome conn

  it "reassembles a response written one byte per send" $ do
    let body = tokenBytes
          [ colMetaData [("x", TIIntN 4), ("s", TINVarChar 40 latin1)]
          , row [(TIIntN 4, int32 1), (TINVarChar 40 latin1, Just (T.encodeUtf16LE "héllo"))]
          , nbcRow [(TIIntN 4, int32 2), (TINVarChar 40 latin1, Nothing)]
          , doneToken 0x10 2
          ]
        stream = B.concat (packetsOf 17 body)
    withScripted (map B.singleton (B.unpack stream)) ThenServe $ \conn -> do
      r <- within (trySync (query conn "SELECT x, s" >>= forceShow))
      either (expectationFailure . describeException) (`shouldBe` [(1 :: Int32, Just ("héllo" :: Text)), (2, Nothing)]) r
      expectUsable conn

  it "reassembles a response of one-byte packets" $
    withScripted (packetsOf 1 (tokenBytes twoRows)) ThenServe $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1, Only 2])
      expectUsable conn

  it "skips empty packets inside a message" $ do
    let pkts = concat [[packet False B.empty, p] | p <- packetsOf 5 (tokenBytes twoRows)]
    withScripted pkts ThenServe $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1, Only 2])
      expectUsable conn

  it "rejects END_OF_MESSAGE in the middle of a token" $ do
    let body = tokenBytes twoRows
        (a, b) = B.splitAt (B.length body - 5) body
    withScripted [packet True a, packet True b] ThenServe $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  it "does not take the rest of a message ended early (END_OF_MESSAGE before the final DONE) as the next response" $ do
    let first = tokenBytes [colMetaData intCol, row [(TIIntN 4, int32 1)]]
        rest = tokenBytes [colMetaData intCol, row [(TIIntN 4, int32 7)], doneToken 0x10 1]
    withScripted [packet True first, packet True rest] ThenServe $ \conn -> do
      r1 <- within (intsQuery conn)
      r2 <- within (trySync (goodQuery conn))
      case (r1, r2) of
        (Left e, _) | Just (ProtocolError _) <- fromException e -> expectBroken conn
        _ -> expectationFailure $ "first query: " ++ show (either describeException show r1)
               ++ "; second query (should be [Only 42]): " ++ either describeException show r2

  it "rejects a response whose last token is a DONE with DONE_MORE" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x11 1] $ \conn -> do
      within (intsQuery conn) >>= expectProtocolError
      expectBroken conn

  it "rejects a response whose last token is a DONEPROC with DONE_MORE" $
    withScriptedTokens [returnStatus 0, doneProcToken 0x11 0] $ \conn -> do
      within (trySync (execute conn "EXEC p")) >>= expectProtocolError
      expectBroken conn

  it "rejects a response whose last token is a DONEINPROC" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneInProcToken 0x11 1] $ \conn -> do
      within (intsQuery conn) >>= expectProtocolError
      expectBroken conn

  it "accepts a response that ends with a DONEPROC" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneInProcToken 0x11 1, returnStatus 0, doneProcToken 0 0] $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1])
      expectUsable conn

  it "rejects a response message ended early, even when the next message completes it" $ do
    let first = tokenBytes [colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x11 1]
        rest = tokenBytes [doneToken 0 0]
    withScripted [packet True first, packet True rest] ThenServe $ \conn -> do
      within (intsQuery conn) >>= expectProtocolError
      expectBroken conn

  it "rejects an empty response message" $
    withScripted [packet True B.empty] ThenServe $ \conn -> do
      within (trySync (execute conn "UPDATE t SET x = 1")) >>= expectProtocolError
      expectBroken conn

------------------------------------------------------------------------------

closing :: Spec
closing = describe "server closing the connection" $ do
  let body = tokenBytes twoRows
      whole = packet True body
      cases =
        [ ("before any response", [])
        , ("mid-header", [B.take 5 whole])
        , ("mid-packet", [B.take 20 whole])
        , ("mid-token (after a packet without END_OF_MESSAGE)", [packet False (B.take 12 body)])
        , ("between tokens", [packet False (tokenBytes [colMetaData intCol, row [(TIIntN 4, int32 1)]])])
        , ("after the final DONE but before END_OF_MESSAGE", [packet False body])
        ]
  forM_ cases $ \(name, chunks) ->
    it name $ withScripted chunks ThenClose $ \conn -> do
      within (firstQuery conn) >>= expectConnectionClosed
      expectBroken conn

  it "after an ERROR token: reports the server's error, then the connection is broken" $
    withScripted [packet False (tokenBytes [errorToken (msg "going away")])] ThenClose $ \conn -> do
      r <- within (trySync (execute conn "SELECT 1"))
      case r of
        Left e | Just err <- fromException e -> sqlErrorMessage err `shouldBe` "going away"
        other -> expectationFailure ("expected SqlServerError, got " ++ either describeException show other)
      expectBroken conn

  it "while the client streams a result, mid-stream" $
    withScripted [packet False (tokenBytes [colMetaData intCol, row [(TIIntN 4, int32 1)]])] ThenClose $ \conn -> do
      seen <- newIORef (0 :: Int)
      r <- within $ trySync $ do
        s <- queryS conn "SELECT x"
        S.mapM_ (\(Only (_ :: Int32)) -> modifyIORef' seen (+ 1)) s
      expectConnectionClosed r
      readIORef seen `shouldReturn` 1
      expectBroken conn

------------------------------------------------------------------------------

-- | A mock handler for the login phase; the client's 'connect' must end
-- (with success or a clean exception) and close the socket if it failed.
loginWith :: (MockConn -> IO ()) -> IO (Either SomeException ())
loginWith handler = withMockServer handler $ \srv -> do
  r <- within (trySync (withConnection (mockConnectInfo srv) (\conn -> () <$ execute conn "SELECT 1")))
  -- The handler has finished: the client closed its socket or the handler gave up.
  _ <- nextResult srv
  pure r

preloginBytes :: B.ByteString
preloginBytes = B.concat $ splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0)
  (Put.runPut (putPrelogin (preloginReply (encryptionWord EncryptNotSup))))

-- | PRELOGIN and LOGIN7 as usual, then the given raw bytes as the login
-- response, then answer requests with a bare DONE.
loginResponse :: [B.ByteString] -> MockConn -> IO ()
loginResponse chunks mc = do
  _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
  _ <- expectLogin7 mc
  mapM_ (sendRaw mc) chunks
  serveRequests (\_ _ -> pure [doneToken 0 0]) mc

loginTokens :: [Put] -> MockConn -> IO ()
loginTokens toks = loginResponse (packetsOf 4088 (tokenBytes toks))

expectLoginProtocolError :: [Put] -> Expectation
expectLoginProtocolError toks = loginWith (loginTokens toks) >>= expectProtocolError

loginPhase :: Spec
loginPhase = describe "login phase" $ do
  it "server closes before the PRELOGIN response" $
    loginWith (\mc -> () <$ recvMessage mc) >>= expectConnectionClosed

  it "server closes after PRELOGIN, before the login response" $
    loginWith (\mc -> respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc >> () <$ expectLogin7 mc)
      >>= expectConnectionClosed

  it "server closes in the middle of the login response" $
    loginWith (\mc -> do
      _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
      _ <- expectLogin7 mc
      sendRaw mc (B.take 20 (packet True loginResponseBytes)))
      >>= expectConnectionClosed

  it "a non-TDS server (an HTTP error page) gives a clean error" $ do
    r <- loginWith (\mc -> do
      _ <- recvPacket mc
      sendRaw mc "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    case r of
      Left e | Just (ProtocolError _) <- fromException e -> pure ()
             | Just ConnectionClosed <- fromException e -> pure ()
      other -> expectationFailure ("expected ProtocolError or ConnectionClosed, got " ++ either describeException show other)

  it "accepts a PRELOGIN response written one byte per send" $
    loginWith (\mc -> do
      _ <- recvMessage mc
      mapM_ (sendRaw mc . B.singleton) (B.unpack preloginBytes)
      _ <- expectLogin7 mc
      sendTokens mc defaultLoginResponse
      serveRequests (\_ _ -> pure [doneToken 0 0]) mc)
      >>= either (expectationFailure . describeException) pure

  it "accepts a login response written one byte per send" $
    loginWith (loginResponse (map B.singleton (B.unpack (B.concat (packetsOf 9 loginResponseBytes)))))
      >>= either (expectationFailure . describeException) pure

  it "rejects a PRELOGIN response whose option points into the option table" $ do
    -- ENCRYPTION at offset 0 (the table itself), then the real value.
    let body = B.pack [0x01, 0, 0, 0, 1, 0xFF, encryptionWord EncryptNotSup]
    loginWith (\mc -> recvMessage mc >> sendRaw mc (packet True body))
      >>= expectProtocolError

  it "rejects a PRELOGIN response with a header length below 8" $
    loginWith (\mc -> recvMessage mc >> sendRaw mc (rawPacket 0x04 1 4 0 1 (B.drop 8 preloginBytes)))
      >>= expectProtocolError

  it "rejects a login response of the wrong packet type" $
    loginWith (loginResponse [rawPacket 0x12 1 (fromIntegral (B.length loginResponseBytes + 8)) 0 1 loginResponseBytes])
      >>= expectProtocolError

  it "rejects a login response without LOGINACK" $
    expectLoginProtocolError [doneToken 0 0]

  it "rejects an unknown token in the login response" $
    expectLoginProtocolError [loginAckToken Tds74 "x", bytes [0x01, 0, 0], doneToken 0 0]

  it "rejects a LOGINACK with an unsupported TDS version" $ do
    r <- loginWith (loginTokens [loginAckRaw 0x730B0003, doneToken 0 0])
    expectProtocolError r

  it "names an unsupported TDS version in hex" $ do
    r <- loginWith (loginTokens [loginAckRaw 0x730B0003, doneToken 0 0])
    case r of
      Left e | Just (ProtocolError m) <- fromException e -> m `shouldSatisfy` ("730b0003" `isInfixOf`) . map toLowerAscii
      other -> expectationFailure (either describeException show other)

  it "ignores unknown FEATUREEXTACK features" $
    loginWith (loginTokens [loginAckToken Tds74 "x", featureExtAck [(0x42, "abc"), (0x0A, "\1"), (0x77, B.empty)], doneToken 0 0])
      >>= either (expectationFailure . describeException) pure

  it "rejects an SSPI token instead of LOGINACK" $
    expectLoginProtocolError [sspiToken "NTLMSSP\0", doneToken 0 0]

  it "handles an unexpected SSPI token alongside LOGINACK" $ do
    r <- loginWith (loginTokens [sspiToken "NTLMSSP\0", loginAckToken Tds74 "x", doneToken 0 0])
    case r of
      Right () -> pure ()
      Left e | Just (ProtocolError _) <- fromException e -> pure ()
      Left e -> expectationFailure (describeException e)

  it "rejects a non-numeric packet size ENVCHANGE" $
    expectLoginProtocolError [loginAckToken Tds74 "x", packetSizeEnvChange "abc", doneToken 0 0]

  forM_ ["0", "7", "8", "511", "32768", "65536", "4294967808", "18446744073709551616"] $ \size ->
    it ("rejects a packet size ENVCHANGE of " ++ T.unpack size ++ " (outside 512..32767)") $
      expectLoginProtocolError [loginAckToken Tds74 "x", packetSizeEnvChange size, doneToken 0 0]

  forM_ [("512", 512), ("32767", 32767)] $ \(size, n) ->
    it ("accepts a packet size ENVCHANGE of " ++ T.unpack size) $ do
      let handler mc = do
            _ <- serveLogin [loginAckToken Tds74 "x", packetSizeEnvChange size, doneToken 0 0] mc
            serveRequests (\_ _ -> pure [doneToken 0 0]) mc
      withMockServer handler $ \srv ->
        within $ withConnection (mockConnectInfo srv) $ \conn -> do
          (tdsPacketSize <$> connectionContext conn) `shouldReturn` n
          execute conn "SELECT 1" `shouldReturn` 0

  it "rejects a packet size ENVCHANGE of 2^31, before framing a request with it" $ do
    let sql = T.replicate 40000 "x"
        handler mc = do
          _ <- serveLogin [loginAckToken Tds74 "x", packetSizeEnvChange "2147483648", doneToken 0 0] mc
          (ptype, body) <- recvMessage mc
          sendTokens mc [doneToken 0 0]
          pure (ptype, B.length body)
    withMockServer handler $ \srv -> do
      r <- within (trySync (withConnection (mockConnectInfo srv) (\conn -> execute conn (rawSql sql))))
      expectProtocolError r

  -- The requested size is clamped to 512..32767 before LOGIN7 is framed.
  forM_ [(0, 512), (8, 512), (511, 512), (32768, 32767), (0xFFFFFFFF, 32767)] $ \(requested, sent) ->
    it ("asks for a " ++ show sent ++ "-byte packet size when configured with " ++ show requested) $ do
      let sql = T.replicate 40000 "x"
          handler mc = do
            l7 <- serveLogin defaultLoginResponse mc
            (_, body) <- recvMessage mc
            sendTokens mc [doneToken 0 0]
            pure (l7PacketSize l7, B.length body)
      withMockServer handler $ \srv -> do
        _ <- within (withConnection (mockConnectInfo srv) { connectPacketSize = requested } (\conn -> execute conn (rawSql sql)))
        -- ALL_HEADERS (22 bytes) and the UTF-16 text
        nextResult srv >>= either (expectationFailure . show) (`shouldBe` (sent, 22 + 80000))
  where
    toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

------------------------------------------------------------------------------

tokenLayer :: Spec
tokenLayer = describe "token layer" $ do
  it "rejects an unknown token type" $
    withScriptedTokens [colMetaData intCol, bytes [0x01, 0x02, 0x03], doneToken 0x10 0] $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  it "rejects ROW before COLMETADATA" $
    withScriptedTokens [row [(TIIntN 4, int32 1)], doneToken 0x10 1] $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  it "does not reuse a previous batch statement's COLMETADATA" $
    withScriptedTokens
      [ colMetaData intCol
      , row [(TIIntN 4, int32 1)]
      , doneProcToken 0x81 0
      , row [(TIIntN 4, int32 2)]
      , doneProcToken 0 0
      ] $ \conn -> do
        outcome <- within $ trySync $ runBatchQuery conn $
          (,) <$> batchQueryMulti "SELECT 1" <*> batchQueryMulti "SELECT 2"
        expectProtocolError outcome
        expectBroken conn

  it "rejects NBCROW before COLMETADATA" $
    withScriptedTokens [nbcRow [(TIIntN 4, Nothing)], doneToken 0x10 1] $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  it "handles COLMETADATA with zero columns" $
    withScriptedTokens [colMetaData [], row [], doneToken 0x10 1] $ \conn ->
      within (firstQuery conn) >>= expectCleanOutcome conn

  it "handles COLMETADATA with no metadata (0xFFFF)" $
    withScriptedTokens [bytes [0x81, 0xFF, 0xFF], doneToken 0x10 0] $ \conn -> do
      within (trySync (execute conn "SELECT 1")) >>= either (expectationFailure . describeException) (`shouldBe` 0)
      expectUsable conn

  it "reads more than 4096 columns" $ do
    let n = 5000
    withScriptedTokens [colMetaData (replicate n ("c", TIIntN 4)), row (replicate n (TIIntN 4, int32 3)), doneToken 0x10 1] $ \conn -> do
      r <- within (firstQuery conn)
      case r of
        Right [ResultSet cols [SqlRow _ vals]] -> do
          length cols `shouldBe` n
          vals `shouldBe` replicate n (SqlInt32 3)
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "rejects a truncated COLMETADATA claiming 65534 columns" $
    withScriptedTokens [bytes [0x81, 0xFE, 0xFF], doneToken 0x10 0] $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  forM_ [ ("an unknown type code", [0x99])
        , ("a CLR UDT whose UDT_INFO runs past the token", [0xF0, 0x10, 0x00])
        , ("datetime2 with scale 8", [0x2A, 8])
        , ("time with scale 255", [0x29, 0xFF])
        , ("intn with length 3", [0x26, 3])
        , ("floatn with length 2", [0x6D, 2])
        , ("guid with length 8", [0x24, 8])
        , ("datetimeoffset with scale 13", [0x2B, 13])
        , ("decimal with precision 39", [0x6A, 17, 39, 0])
        , ("numeric with precision 0", [0x6C, 5, 0, 0])
        , ("decimal with a scale above its precision", [0x6A, 5, 5, 6])
        ] $ \(name, ti) ->
    it ("rejects COLMETADATA with " ++ name) $
      withScriptedTokens [rawColumn ti, doneToken 0x10 0] $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

  -- The server flagged the request as failed without a message, as SQL
  -- Server does for a killed session (Azure SQL Database: one DONE with
  -- both flags, then the gateway resets the connection).  A success with
  -- no rows would hide the failure.
  it "fails a DONE with DONE_ERROR but no ERROR token with SevereError, and stays usable" $
    withScriptedTokens [doneToken 0x02 0] $ \conn -> do
      r <- within (trySync (execute conn "SELECT 1"))
      case r of
        Left e | Just err <- fromException e -> do
          severeErrorServerError err `shouldBe` False
          severeErrorStatement err `shouldBe` Just "SELECT 1"
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "fails a DONE with DONE_SRVERROR but no ERROR token with SevereError, after the rows" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x100 0] $ \conn -> do
      r <- within (intsQuery conn)
      case r of
        Left e | Just err <- fromException e -> severeErrorServerError err `shouldBe` True
        other -> expectationFailure (either describeException show other)
      expectBroken conn

  it "fails a DONEINPROC with DONE_ERROR inside a procedure's response with SevereError" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x02 0, doneToken 0 0] $ \conn -> do
      r <- within (intsQuery conn)
      case r of
        Left e | Just SevereError{} <- fromException e -> pure ()
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "reports the ERROR token, not SevereError, when a flagged DONE follows one" $
    withScriptedTokens [errorToken (msg "boom"), doneToken 0x102 0] $ \conn -> do
      r <- within (trySync (execute conn "SELECT 1"))
      case r of
        Left e | Just err <- fromException e -> sqlErrorMessage err `shouldBe` "boom"
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "treats DONE_ATTN without an Attention as the end of the response" $
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x20 0] $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1])
      expectUsable conn

  it "reports an ERROR token and stays usable" $
    withScriptedTokens [errorToken (msg "boom"), doneToken 0x02 0] $ \conn -> do
      r <- within (trySync (execute conn "SELECT 1"))
      case r of
        Left e | Just err <- fromException e -> sqlErrorMessage err `shouldBe` "boom"
        other -> expectationFailure (either describeException show other)
      expectUsable conn

  it "rejects an ERROR token whose length runs past the message" $
    withScriptedTokens [bytes [0xAA, 0xFF, 0xFF], bytes (replicate 30 0), doneToken 0x02 0] $ \conn -> do
      within (trySync (execute conn "SELECT 1")) >>= expectProtocolError
      expectBroken conn

  it "rejects an ERROR token whose message text runs past the token" $ do
    let body = Put.runPut $ do
          Put.putInt32le 50000 >> Put.putWord8 1 >> Put.putWord8 16
          Put.putWord16le 0xFFFF >> Put.putByteString (T.encodeUtf16LE "short")
          putBVarChar "mock" >> putBVarChar "" >> Put.putInt32le 1
        tok = Put.putWord8 0xAA >> Put.putWord16le (fromIntegral (LB.length body)) >> Put.putLazyByteString body
    withScriptedTokens [tok, doneToken 0x02 0] $ \conn -> do
      within (trySync (execute conn "SELECT 1")) >>= expectProtocolError
      expectBroken conn

  it "ignores an ENVCHANGE of an unknown type" $
    withScriptedTokens [envChangeToken 99 "\1\2\3", doneToken 0 0] $ \conn -> do
      within (trySync (execute conn "SELECT 1")) >>= either (expectationFailure . describeException) (`shouldBe` 0)
      expectUsable conn

  it "rejects an empty ENVCHANGE" $
    withScriptedTokens [bytes [0xE3, 0, 0], doneToken 0 0] $ \conn -> do
      within (trySync (execute conn "SELECT 1")) >>= expectProtocolError
      expectBroken conn

  it "handles an unexpected SSPI token in a query response" $
    withScriptedTokens [sspiToken "junk", colMetaData intCol, row [(TIIntN 4, int32 1)], doneToken 0x10 1] $ \conn ->
      within (intsQuery conn) >>= expectCleanOutcome conn

  it "ignores an unexpected RETURNVALUE in a query response" $ do
    let rv = do
          Put.putWord8 0xAC
          Put.putWord16le 1
          putBVarChar "@out"
          Put.putWord8 1 >> Put.putWord32le 0 >> Put.putWord16le 0
          putTypeInfo defaultTdsContext (TIIntN 4)
          Put.putWord8 4 >> Put.putInt32le 9
    withScriptedTokens [colMetaData intCol, row [(TIIntN 4, int32 1)], rv, doneToken 0x10 1] $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1])
      expectUsable conn

  it "handles an NBCROW whose null bitmap disagrees with the data" $ do
    -- Bitmap says both columns are NULL, but the values follow anyway.
    let tok = bytes [0xD2, 0x03] >> bytes [4, 1, 0, 0, 0] >> bytes [4, 2, 0, 0, 0]
    withScriptedTokens [colMetaData (intCol ++ [("y", TIIntN 4)]), tok, doneToken 0x10 1] $ \conn ->
      within (firstQuery conn) >>= expectCleanOutcome conn

  it "rejects an ORDER token with an odd length" $
    withScriptedTokens [colMetaData intCol, bytes [0xA9, 3, 0, 1, 0, 2], row [(TIIntN 4, int32 1)], doneToken 0x10 1] $ \conn -> do
      within (firstQuery conn) >>= expectProtocolError
      expectBroken conn

  it "reads an ORDER token" $
    withScriptedTokens [colMetaData intCol, bytes [0xA9, 2, 0, 1, 0], row [(TIIntN 4, int32 1)], doneToken 0x10 1] $ \conn -> do
      within (intsQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only 1])
      expectUsable conn

  it "decodes a column name that is not valid UTF-16 without an exception from Data.Text" $ do
    let name = Put.putWord8 1 >> bytes [0x00, 0xD8]
        tok = do
          Put.putWord8 0x81 >> Put.putWord16le 1 >> Put.putWord32le 0 >> Put.putWord16le 1
          putTypeInfo defaultTdsContext (TIIntN 4)
          name
    withScriptedTokens [tok, row [(TIIntN 4, int32 1)], doneToken 0x10 1] $ \conn ->
      within (firstQuery conn) >>= expectCleanOutcome conn

  it "decodes an error message that is not valid UTF-16 without an exception from Data.Text" $ do
    let body = Put.runPut $ do
          Put.putInt32le 50000 >> Put.putWord8 1 >> Put.putWord8 16
          Put.putWord16le 1 >> bytes [0x00, 0xDC]
          putBVarChar "mock" >> putBVarChar "" >> Put.putInt32le 1
        tok = Put.putWord8 0xAA >> Put.putWord16le (fromIntegral (LB.length body)) >> Put.putLazyByteString body
    withScriptedTokens [tok, doneToken 0x02 0] $ \conn -> do
      r <- within (trySync (execute conn "SELECT 1"))
      forced <- try (forceShow (either describeException show r))
      case forced of
        Left (e :: SomeException) -> expectationFailure ("showing the outcome threw " ++ describeException e)
        Right _ -> pure ()
      expectCleanOutcome conn r

------------------------------------------------------------------------------

-- | A result of one column of the given type holding the given raw value.
oneValue :: TypeInfo -> Put -> [Put]
oneValue ti value = [colMetaData [("v", ti)], Put.putWord8 0xD1 >> value, doneToken 0x10 1]

sqlValueQuery :: Connection -> IO (Either SomeException [Only SqlValue])
sqlValueQuery conn = trySync (query conn "SELECT v" >>= forceShow)

-- | sql_variant bytes: base type, property bytes, then the rest.
variant :: [Word8] -> Put
variant bs = Put.putWord32le (fromIntegral (length bs)) >> bytes bs

plp :: Word64 -> [B.ByteString] -> Put
plp total chunks = do
  Put.putWord64le total
  forM_ chunks $ \c -> Put.putWord32le (fromIntegral (B.length c)) >> Put.putByteString c
  Put.putWord32le 0

values :: Spec
values = describe "values" $ do
  it "rejects varchar data in an unknown collation as Text, but reads its bytes" $ do
    let col = Collation 0x000FFFFF 0
        toks = [colMetaData [("v", TIBigVarChar 10 col)], row [(TIBigVarChar 10 col, Just "abc")], doneToken 0x10 1]
    withScriptedTokens toks $ \conn -> do
      within (trySync (query conn "SELECT v" >>= forceShow) :: IO (Either SomeException [Only Text])) >>= expectDecodeError
      expectUsable conn
    withScriptedTokens toks $ \conn ->
      within (trySync (query conn "SELECT v" >>= forceShow)) >>= either (expectationFailure . describeException) (`shouldBe` [Only ("abc" :: B.ByteString)])

  describe "PLP" $ do
    let vbin = TIBigVarBinary 0xFFFF
    it "reads the chunks when the total length disagrees with them" $
      withScriptedTokens (oneValue vbin (plp 10 ["abcde"])) $ \conn -> do
        r <- within (trySync (query conn "SELECT v" >>= forceShow))
        case r of
          Right [Only v] -> v `shouldBe` ("abcde" :: B.ByteString)
          other -> expectCleanOutcome conn other

    it "rejects a chunk longer than the rest of the message" $
      withScriptedTokens (oneValue vbin (Put.putWord64le 100 >> Put.putWord32le 100 >> bytes [1, 2, 3])) $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

    it "rejects a value without its terminator" $
      withScriptedTokens [colMetaData [("v", vbin)], Put.putWord8 0xD1 >> Put.putWord64le 3 >> Put.putWord32le 3 >> bytes [1, 2, 3], doneToken 0x10 1] $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

    it "reads an empty value" $
      withScriptedTokens (oneValue vbin (plp 0 [])) $ \conn ->
        within (trySync (query conn "SELECT v" >>= forceShow)) >>= either (expectationFailure . describeException) (`shouldBe` [Only ("" :: B.ByteString)])

    it "reads a value of unknown length in many chunks" $
      withScriptedTokens (oneValue vbin (plp 0xFFFFFFFFFFFFFFFE (replicate 50 "xy"))) $ \conn ->
        within (trySync (query conn "SELECT v" >>= forceShow)) >>= either (expectationFailure . describeException) (`shouldBe` [Only (B.concat (replicate 50 "xy"))])

  describe "sql_variant" $ do
    let sv = TISqlVariant 8016
        expectVariantDecodeError bs = withScriptedTokens (oneValue sv (variant bs)) $ \conn -> do
          within (sqlValueQuery conn) >>= expectDecodeError
          expectUsable conn
    it "reads a well-formed int" $
      withScriptedTokens (oneValue sv (variant [0x38, 0, 7, 0, 0, 0])) $ \conn ->
        within (sqlValueQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only (SqlInt32 7)])
    it "rejects an int with three data bytes" $ expectVariantDecodeError [0x38, 0, 7, 0, 0]
    it "rejects property bytes on an int" $ expectVariantDecodeError [0x38, 2, 0, 0, 7, 0, 0, 0]
    it "rejects an unknown base type" $ expectVariantDecodeError [0x99, 0, 1]
    it "rejects a nested sql_variant" $ expectVariantDecodeError [0x62, 0, 0x38, 0, 1, 0, 0, 0]
    it "rejects a time with scale 255" $
      expectVariantDecodeError [0x29, 1, 255, 1, 2, 3, 4, 5]
    it "rejects a datetime2 with scale 9" $
      expectVariantDecodeError [0x2A, 1, 9, 1, 2, 3, 4, 5, 1, 0, 0]
    it "rejects a time with scale 8" $ expectVariantDecodeError [0x29, 1, 8, 1, 2, 3, 4, 5]
    it "rejects a time with scale 13" $ expectVariantDecodeError [0x29, 1, 13, 1, 2, 3, 4, 5]
    it "rejects a datetimeoffset with scale 12" $ expectVariantDecodeError [0x2B, 1, 12, 1, 2, 3, 4, 5, 1, 0, 0, 0, 0]
    it "reads a well-formed time(7)" $
      withScriptedTokens (oneValue sv (variant [0x29, 1, 7, 0x80, 0x96, 0x98, 0, 0])) $ \conn ->
        within (sqlValueQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only (SqlTime (TimeOfDay 0 0 1))])
    it "rejects a decimal with precision 39" $ expectVariantDecodeError [0x6A, 2, 39, 0, 1, 1, 0, 0, 0]
    it "rejects a decimal with precision 0" $ expectVariantDecodeError [0x6A, 2, 0, 0, 1, 1, 0, 0, 0]
    it "rejects a decimal with a scale above its precision" $ expectVariantDecodeError [0x6A, 2, 5, 6, 1, 1, 0, 0, 0]
    it "rejects a time without its scale property byte" $ expectVariantDecodeError [0x29, 0, 1, 2, 3]
    it "rejects a time with two property bytes" $ expectVariantDecodeError [0x29, 2, 7, 0, 1, 2, 3, 4, 5]
    it "rejects a decimal with one property byte" $ expectVariantDecodeError [0x6A, 1, 5, 1, 1, 0, 0, 0]
    it "rejects a varbinary with three property bytes" $ expectVariantDecodeError [0xA5, 3, 10, 0, 0, 1, 2]
    it "rejects an nvarchar with eight property bytes" $
      expectVariantDecodeError [0xE7, 8, 0x09, 0x04, 0xD0, 0, 0x34, 4, 0, 0, 0x61, 0]
    it "handles too few property bytes for an nvarchar" $
      withScriptedTokens (oneValue sv (variant [0xE7, 2, 0x09, 0x04, 0xD0, 0, 0x34, 4, 0, 0x61, 0])) $ \conn ->
        within (sqlValueQuery conn) >>= expectCleanOutcome conn
    it "rejects a length running past the message" $
      withScriptedTokens (oneValue sv (Put.putWord32le 5000 >> bytes [0x38, 0, 7, 0, 0, 0])) $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn

  describe "decimal" $ do
    it "rejects a precision above 38" $
      withScriptedTokens (oneValue (TIDecimalN 60 2) (bytes (17 : 1 : replicate 16 0xFF))) $ \conn -> do
        within (sqlValueQuery conn) >>= expectProtocolError
        expectBroken conn
    it "rejects a scale above the precision" $
      withScriptedTokens (oneValue (TIDecimalN 5 30) (bytes [5, 1, 1, 0, 0, 0])) $ \conn -> do
        within (sqlValueQuery conn) >>= expectProtocolError
        expectBroken conn
    it "rejects an output parameter (RETURNVALUE) with a precision above 38" $ do
      let rv = do
            Put.putWord8 0xAC >> Put.putWord16le 1 >> putBVarChar "@out"
            Put.putWord8 1 >> Put.putWord32le 0 >> Put.putWord16le 0
            bytes [0x6A, 17, 39, 0] >> bytes [5, 1, 1, 0, 0, 0]
      withScriptedTokens [rv, doneToken 0 0] $ \conn -> do
        within (firstQuery conn) >>= expectProtocolError
        expectBroken conn
    it "handles a value of only a sign byte" $
      withScriptedTokens (oneValue (TIDecimalN 10 0) (bytes [1, 1])) $ \conn ->
        within (sqlValueQuery conn) >>= expectCleanOutcome conn

  describe "date and time" $ do
    it "rejects a date beyond 9999-12-31" $ do
      let toks = oneValue TIDateN (bytes [3, 0xFF, 0xFF, 0xFF])
      withScriptedTokens toks $ \conn -> do
        within (trySync (query conn "SELECT v" >>= forceShow) :: IO (Either SomeException [Only Day])) >>= expectDecodeError
        expectUsable conn
      withScriptedTokens toks $ \conn -> do
        within (sqlValueQuery conn) >>= expectDecodeError
        expectUsable conn
    it "rejects a datetime2 value of the wrong length for its scale" $
      withScriptedTokens (oneValue (TIDateTime2N 7) (bytes [3, 1, 2, 3])) $ \conn -> do
        within (sqlValueQuery conn) >>= expectDecodeError
        expectUsable conn
    it "rejects a time beyond midnight" $
      withScriptedTokens (oneValue (TITimeN 7) (bytes [5, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])) $ \conn -> do
        within (sqlValueQuery conn) >>= expectDecodeError
        expectUsable conn
    forM_ [("before 1753-01-01", -53691), ("after 9999-12-31", 2958464)] $ \(name, days) ->
      it ("rejects a datetime " ++ name) $
        withScriptedTokens (oneValue (TIDateTimeN 8) (Put.putWord8 8 >> Put.putInt32le days >> Put.putWord32le 0)) $ \conn -> do
          within (sqlValueQuery conn) >>= expectDecodeError
          expectUsable conn
    forM_ [("1753-01-01", -53690, fromGregorian 1753 1 1), ("9999-12-31", 2958463, fromGregorian 9999 12 31)] $ \(name, days, day) ->
      it ("reads a datetime on " ++ name) $
        withScriptedTokens (oneValue (TIDateTimeN 8) (Put.putWord8 8 >> Put.putInt32le days >> Put.putWord32le 0)) $ \conn ->
          within (sqlValueQuery conn) >>= either (expectationFailure . describeException) (`shouldBe` [Only (SqlDateTime (LocalTime day midnight))])
    it "rejects a datetime tick count beyond midnight" $
      withScriptedTokens (oneValue (TIDateTimeN 8) (bytes [8, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])) $ \conn -> do
        within (sqlValueQuery conn) >>= expectDecodeError
        expectUsable conn

------------------------------------------------------------------------------

-- | Absurd length prefixes must not make the client allocate what they
-- claim before the bytes arrive.
memory :: Spec
-- 'allocatedDuring' counts the whole process's allocation: alone.
memory = serial $ describe "absurd length prefixes" $ do
  let limit = 64 * 1024 * 1024 :: Word64
      check name toks = it name $ do
        (alloc, ()) <- allocatedDuring $ withScriptedTokens toks $ \conn -> do
          within (firstQuery conn) >>= expectProtocolError
          expectBroken conn
        case alloc of
          Nothing -> pendingWith "run with +RTS -T"
          Just n -> n `shouldSatisfy` (< limit)
      vbin = TIBigVarBinary 0xFFFF
  check "PLP chunk of 0x7FFFFFFF bytes" (oneValue vbin (Put.putWord64le 0x7FFFFFFF >> Put.putWord32le 0x7FFFFFFF >> bytes [1 .. 100]))
  check "PLP total of 2^62 bytes" (oneValue vbin (Put.putWord64le (2 ^ (62 :: Int)) >> Put.putWord32le 0xFFFFFFF0 >> bytes [1 .. 100]))
  check "text value of 0x7FFFFFFE bytes"
    [ colMetaData [("t", TIText 0x7FFFFFFF latin1)]
    , Put.putWord8 0xD1 >> Put.putWord8 16 >> bytes (replicate 24 0) >> Put.putWord32le 0x7FFFFFFE >> bytes [1 .. 100]
    ]
  check "sql_variant of 0x7FFFFFFF bytes" (oneValue (TISqlVariant 8016) (Put.putWord32le 0x7FFFFFFF >> bytes [0x38, 0, 1, 0, 0, 0]))
  check "SESSIONSTATE of 0xFFFFFFF0 bytes" [Put.putWord8 0xE4 >> Put.putWord32le 0xFFFFFFF0 >> bytes [1 .. 100]]
  check "FEDAUTHINFO of 0xFFFFFFF0 bytes" [Put.putWord8 0xEE >> Put.putWord32le 0xFFFFFFF0 >> bytes [1 .. 100]]
  check "FEATUREEXTACK of 0xFFFFFFFF bytes" [Put.putWord8 0xAE >> Put.putWord8 0x42 >> Put.putWord32le 0xFFFFFFFF >> bytes [1 .. 100]]
  check "promote-transaction ENVCHANGE of 0xFFFFFFFF bytes" [bytes [0xE3, 1, 0, 15] >> Put.putWord32le 0xFFFFFFFF >> bytes [1 .. 100]]

  it "a 0x7FFFFFFF PLP chunk on a held-open connection: the wait is interruptible and allocates little" $ do
    let body = tokenBytes (oneValue vbin (Put.putWord64le 0x7FFFFFFF >> Put.putWord32le 0x7FFFFFFF >> bytes [1 .. 100]))
    (alloc, ()) <- allocatedDuring $ withScripted [packet False (B.take (B.length body - 13) body)] ThenHold $ \conn -> do
      r <- timeout 500_000 (firstQuery conn)
      case r of
        Nothing -> pure ()
        Just other -> expectationFailure ("expected the client to wait for more data, got " ++ either describeException show other)
    maybe (pendingWith "run with +RTS -T") (`shouldSatisfy` (< limit)) alloc

------------------------------------------------------------------------------

-- | SQL Server itself sends UCS-2 that is not valid UTF-16 (NCHAR(0xD800)
-- is a lone surrogate) in names and messages.
liveServer :: Spec
liveServer = describe "a real server sending names and messages that are not valid UTF-16" $ around withTestDb $ do
  it "a column name with a lone surrogate" $ \conn -> do
    r <- within (trySync (queryMulti conn "EXEC(N'SELECT 1 AS [a' + NCHAR(0xD800) + N'b]')" >>= forceShow))
    case r of
      Left e | not (isHmssqlException e) -> expectationFailure (describeException e)
      _ -> pure ()
    query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  it "a RAISERROR message with a lone surrogate" $ \conn -> do
    r <- within (trySync (execute conn "DECLARE @m nvarchar(20) = N'bad ' + NCHAR(0xDC00); RAISERROR(@m, 16, 1)"))
    forced <- trySync (forceShow (either describeException show r))
    case (r, forced) of
      (_, Left e) -> expectationFailure ("showing the outcome threw " ++ describeException e)
      (Left e, _) | Just (_ :: SqlServerError) <- fromException e -> pure ()
      (other, _) -> expectationFailure ("expected SqlServerError, got " ++ either describeException show other)
    query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
