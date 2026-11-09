{-# LANGUAGE ScopedTypeVariables #-}

-- | Regression tests from a review of the cumulative effect of the bug fixes
-- since e17877d: interactions between fixes made separately, and costs they
-- added to the hot path.
module Review.CumulativeSpec (spec, withStalledTlsServer, untilSettled) where

import qualified Hmssql.Tds.Parser as P
import Hmssql.Query (bytesBody)
import Hmssql.Errors (EncodeError)
import RecipeParameters
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, forever, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal)
import Data.Int (Int32)
import Data.IORef
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GHC.Conc (getAllocationCounter)
import qualified Network.Socket as Socket
import qualified Network.TLS as TLS
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Mock
import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Query (responseS, rpcRequest)
import Hmssql.Query.Types (Request (..))
import Compat (connSocket)
import Hmssql.Connection.Backend (Backend (..))
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Decoding
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Token (compileResultSet)
import Hmssql.Tds.TypeInfo (maxLength)
import MockServer
import Security.TlsSpec (mockKey, recvTdsMessage, serverAuthCert, trusting)
import TestDb

-- | The decoding function 'fieldDecoder' compiles for a column of this type.
compiledFor :: forall a. FromSqlField a => TypeInfo -> IO (Maybe B.ByteString -> Either String a)
compiledFor ti = either (throwIO . userError) (pure . decodeCell) $
  compileField (fieldDecoder @a) defaultTdsContext (ColumnInfo "c" ti 0x0001 0 Nothing)

-- | Bytes allocated per value by decoding each of the values.
allocationPer :: (Maybe B.ByteString -> Either String a) -> [B.ByteString] -> IO Double
allocationPer decode values = do
  _ <- evaluate (sum (map B.length values))
  let run = forM_ values $ \v -> void (evaluate (decode (Just v)))
  run  -- warm up (CAFs)
  before <- getAllocationCounter
  run
  after <- getAllocationCounter
  -- The counter counts down.
  pure (fromIntegral (before - after) / fromIntegral (length values))

-- | The wire form of a @decimal(p,s)@ value with a 16-byte magnitude.
decimalBytes :: Integer -> B.ByteString
decimalBytes m = B.pack (1 : [fromIntegral (m `div` (256 ^ i)) | i <- [0 .. 15 :: Int]])

-- | A strict-encryption server for one client: TLS handshake, LOGIN7
-- answered with a LOGINACK, then it stops reading (until the action
-- returns), so the client's sends eventually block.  The action gets the
-- port.
withStalledTlsServer :: (Text -> IO a) -> IO a
withStalledTlsServer client = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
    Socket.setSocketOption lsock Socket.ReuseAddr 1
    Socket.bind lsock (Socket.addrAddress addr)
    Socket.listen lsock 4
    port <- Socket.socketPort lsock
    stop <- newEmptyMVar
    let serve = do
          (sock, _) <- Socket.accept lsock
          flip finally (Socket.close sock) $ do
            creds <- either (throwIO . userError) pure (TLS.credentialLoadX509FromMemory serverAuthCert mockKey)
            ctx <- TLS.contextNew sock TLS.defaultParamsServer
              { TLS.serverShared = (TLS.serverShared TLS.defaultParamsServer) { TLS.sharedCredentials = TLS.Credentials [creds] }
              , TLS.serverHooks = TLS.defaultServerHooks { TLS.onALPNClientSuggest = Just (\_ -> pure "tds/8.0") }
              }
            TLS.handshake ctx
            buf <- newIORef B.empty
            recvTdsMessage ctx buf  -- LOGIN7
            let response = Put.runPut (loginAckToken Tds80 "mock" >> doneToken 0 0)
            mapM_ (TLS.sendData ctx . LB.fromStrict) (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) response)
            takeMVar stop
    bracket (forkIO serve) killThread $ \_ -> client (T.pack (show port)) `finally` tryPutMVar stop ()

-- | Wait until the counter stops changing for a while.
untilSettled :: IORef Int -> IO ()
untilSettled ref = go (-1)
  where
    go prev = do
      threadDelay 200_000
      n <- readIORef ref
      if n == prev then pure () else go n

isErrorCall :: Either SomeException a -> Bool
isErrorCall = \case
  Left e -> isJust (fromException e :: Maybe ErrorCall)
  Right _ -> False

-- | 'connect' is still running after half a second (it would throw if it
-- took an exception from the timeout for something else).
shouldTimeOut :: IO Connection -> Expectation
shouldTimeOut act = timeout 500_000 (tryJust synchronous act) >>= \case
  Nothing -> pure ()
  Just (Right conn) -> close conn >> expectationFailure "connected"
  Just (Left e) -> expectationFailure ("connect threw " ++ show e)
  where
    synchronous e = case fromException e of
      Just (_ :: SomeAsyncException) -> Nothing
      Nothing -> Just e

spec :: Spec
spec = do
  -- tls turns exceptions from the handshake into HandshakeFailed; one from
  -- a timeout must still reach the timeout.
  describe "a timeout during a TLS handshake that gets no answer" $ do
    it "ends connect with strict encryption" $
      withMockServer (\mc -> recvBytes mc 5 >> recvBytes mc maxBound) $ \srv ->
        shouldTimeOut (connect (mockConnectInfo srv) { connectEncryption = EncryptStrict })
    it "ends connect with EncryptOn" $
      withMockServer (\mc -> respondPrelogin (preloginReply 1) mc >> recvMessageMaybe mc >> recvMessageMaybe mc) $ \srv ->
        shouldTimeOut (connect (mockConnectInfo srv) { connectEncryption = EncryptOn })

  describe "close" $
    -- close says goodbye to a TLS server (close_notify), which can block
    -- when the server doesn't read.  It caught every exception from that,
    -- asynchronous ones included, so a thread killed there carried on
    -- after close as if nothing had happened.
    it "doesn't swallow an asynchronous exception while it says goodbye" $ withStalledTlsServer $ \port -> do
      let ci = defaultConnectInfo
            { connectHost = "127.0.0.1", connectPort = port, connectUser = "u", connectPassword = "p"
            , connectEncryption = EncryptStrict, connectTls = trusting serverAuthCert, connectSessionSetup = [] }
      conn <- connect ci
      -- Fill the socket's send buffer behind hmssql's back: big writes,
      -- then single bytes, which get in until there is no space at all.
      -- The writers are stopped before the close (the buffer stays full):
      -- closing the socket under threads sending on it can leave a stale
      -- registration in GHC's IO manager, which breaks a later close of
      -- another socket (see Hmssql.Connection.Internal.closeSocket).
      let fillWith n = do
            count <- newIORef 0
            t <- forkIO $ handle (\(_ :: IOException) -> pure ()) $ forever $ do
              -- Through the connection's backend, which off Windows is
              -- this same send on the socket.  On Windows a thread inside
              -- network's own send can't be killed, as these are below.
              backendSend (connBackend conn) (B.replicate n 0)
              atomicModifyIORef' count (\c -> (c + 1, ()))
            untilSettled count
            pure t
      big <- fillWith 65536
      small <- fillWith 1
      mapM_ killThread [big, small]
      continued <- newEmptyMVar
      closer <- forkIO $ close conn >> putMVar continued ()
      threadDelay 300_000
      killThread closer
      r <- timeout 2_000_000 (takeMVar continued)
      Socket.close (connSocket conn)
      -- The killed thread must not get past close.
      r `shouldBe` Nothing

  describe "decoding cost" $ do
    -- 224f560 checked each decimal value against 10 ^ precision, computed
    -- per value with the generic (^), which made reading rows of (int,
    -- nvarchar(50), decimal) about a third slower.
    it "checking a decimal against its precision costs the same at every precision" $ do
      dec38 <- compiledFor @Decimal (TIDecimalN 38 0)
      dec1 <- compiledFor @Decimal (TIDecimalN 1 0)
      -- The same values, with the same 16-byte magnitudes.
      let values = [decimalBytes (i `mod` 10) | i <- [1 .. 10_000]]
      dec38 (Just (decimalBytes 5)) `shouldBe` Right 5
      per38 <- allocationPer dec38 values
      per1 <- allocationPer dec1 values
      -- With (^), 10 ^ 38 cost over 1.5 KB more than 10 ^ 1.
      per38 `shouldSatisfy` (< per1 + 256)

    -- de37fce made the ByteString decoders copy, so that a small value
    -- doesn't keep its packet alive.  A large value (varbinary(max)) is
    -- already in a buffer of its own, joined from its chunks; copying it
    -- again doubled the memory it takes to read it.
    it "a ByteString that owns its buffer is not copied again" $ do
      dec <- compiledFor @B.ByteString (TIBigVarBinary maxLength)
      let big = B.copy (B.replicate (1024 * 1024) 7)
      Right out <- pure (dec (Just big))
      out `shouldBe` big
      fst (BI.toForeignPtr0 out) `shouldBe` fst (BI.toForeignPtr0 big)
    -- Ownership is the row's: a cell that is a slice of the packet the
    -- row was parsed from is copied, wherever in the packet it lies.
    it "a value borrowed from the row's packet is copied" $ do
      let col = ColumnInfo "c" (TIBigVarBinary 8000) 0x0001 0 Nothing
          rs = compileResultSet [col]
          -- A ROW token of one 10-byte value, at the start of a packet
          -- and then after 100 bytes of another row's worth of padding.
          rowBytes = B.pack ([0xD1, 10, 0] ++ replicate 10 7)
          packet = B.copy (rowBytes <> B.replicate 100 0 <> rowBytes <> B.replicate 4000 0)
      compiled <- either (throwIO . userError . show) pure (compileRowDecoder (singleField (fieldDecoder @B.ByteString)) defaultTdsContext [col])
      forM_ [0, 113] $ \at -> do
        (result, _) <- P.parseChunks (rowRecipe compiled 1048576) [B.drop at packet]
        out <- either (throwIO . userError . show) pure result
        out `shouldBe` B.replicate 10 7
        fst (BI.toForeignPtr0 out) `shouldNotBe` fst (BI.toForeignPtr0 packet)

    it "a value in a buffer of its own is not copied, whatever its size" $ do
      dec <- compiledFor @B.ByteString (TIBigVarBinary 8000)
      let small = B.copy (B.replicate 10 7)
      Right out <- pure (dec (Just small))
      fst (BI.toForeignPtr0 out) `shouldBe` fst (BI.toForeignPtr0 small)
    it "RawValue and SqlBinary don't copy a buffer they own either" $ do
      decRaw <- compiledFor @RawValue (TIBigVarBinary maxLength)
      decValue <- compiledFor @SqlValue (TIBigVarBinary maxLength)
      let big = B.copy (B.replicate 100_000 1)
      Right (RawValue r) <- pure (decRaw (Just big))
      fst (BI.toForeignPtr0 r) `shouldBe` fst (BI.toForeignPtr0 big)
      Right (SqlBinary v) <- pure (decValue (Just big))
      fst (BI.toForeignPtr0 v) `shouldBe` fst (BI.toForeignPtr0 big)

  describe "withTransaction cleanup" $
    -- The rollback after a failure is interrupted by a second asynchronous
    -- exception: the connection is marked broken (as intended), but the
    -- second exception must not be lost.  Here the outer timeout's
    -- exception was swallowed, so the inner timeout returned Nothing and the
    -- outer one reported success after its deadline.
    it "doesn't swallow an asynchronous exception that interrupts the rollback" $ do
      let script io = do
            _ <- expectTmBegin io
            mSendMessage io [envChangeToken 8 (B.pack ([8, 1, 2, 3, 4, 5, 6, 7, 8] ++ [0])), doneFinal 0]
            _ <- expectBatch io  -- the body's request: never answered
            expectAttention io   -- nor is the Attention
            void (collectFor io 5_000_000)
      (r, _) <- withScripted script $ \ci -> withConnection ci $ \conn ->
        timeout 1_500_000 $ timeout 200_000 $ withTransaction conn $ execute conn "SELECT 1"
      r `shouldBe` Nothing

  describe "a request whose body fails to encode" $ around withTestDb $ do
    -- The low-level Request API lets a body fail (with 'error') while it is
    -- framed into packets.  The body is forced before anything is sent, so
    -- nothing was sent and the connection stays usable.
    it "before anything is sent leaves the connection usable" $ \conn -> do
      let bad = byteParam (T.replicate 300 "a") 0 (TIIntN 4) (Just (B.pack [1, 0, 0, 0]))
      r <- try (rpcRequest "sp_executesql" [bad] >>= responseS conn >>= S.effects)
      r `shouldSatisfy` either (\e -> case fromException e of Just (_ :: EncodeError) -> True; _ -> False) (const False)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int32)
    it "part-way through the message sends nothing and leaves the connection usable" $ \conn -> do
      let sql = "SELECT 1 -- " <> T.replicate 50_000 "x"
          good = RpcRequest procSpExecuteSql 0
            [byteParam "" 0 (TINVarChar maxLength (Collation 0 0)) (Just (T.encodeUtf16LE sql))]
          bad = RpcRequest (RpcProcName (T.replicate 70_000 "p")) 0 []
          req = Request PTRpc (bytesBody (\ctx -> rpcRequestBody ctx [good, bad])) Nothing
      r <- try (responseS conn req >>= S.effects)
      r `shouldSatisfy` isErrorCall
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int32)
      -- And the server never saw any of it: nothing was left half-sent.
      forM_ [1 .. 3 :: Int] $ \_ -> query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int32)
