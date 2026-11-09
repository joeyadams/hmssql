-- | The whole client against a local mock server: every request is
-- answered at once with the same canned response (the synthetic result
-- sets of "Bench.Tokens"), over plaintext TCP on 127.0.0.1.  This measures
-- what "Bench.Decode" leaves out (sending the request, the reader thread,
-- packet reassembly, 'nextToken' with its lock and IORefs, the result
-- stream) without a real server's own time and noise.
--
-- The mock runs in this process, on its own threads (so its CPU time is
-- measured too); it only reads the request's packets and writes prebuilt
-- bytes, so it adds little.
module Bench.Mock (benchmarks) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.DeepSeq (NFData (..))
import Control.Exception
import Control.Monad (forM_, forever, unless, void)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Data.IORef
import qualified Data.Text as T
import Data.Word (Word16, Word8)
import Foreign.ForeignPtr (ForeignPtr)
import Foreign.Ptr (castPtr)
import qualified Network.Socket as Socket
import qualified Network.Socket.ByteString as SocketB
import qualified Streaming.Prelude as S
import System.Info (os)
import Test.Tasty.Bench

import Hmssql
import Hmssql.Connection.Backend (Backend (..), tcpBackend)
import Hmssql.Query
import Hmssql.Tds.Client (Prelogin (..), PreloginOption (..), encryptionWord, putPrelogin)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives (putBVarChar)

import Bench.Tokens

-- | A mock server answering with one response, and a connection to it.
data Mock = Mock
  { mockListener :: Socket.Socket
  , mockAcceptor :: ThreadId
  , mockStopping :: IORef Bool
    -- ^ Set before the listener is closed under the acceptor (on Windows).
  , mockPort :: T.Text
  , mockConn :: Connection
  }

instance NFData Mock where
  rnf m = m `seq` ()

benchmarks :: Benchmark
benchmarks = bgroup "Mock"
  [ withMock (tokenBytes [done 0]) $ \m -> bgroup "round trip"
      [ bench "execute, bare DONE" $ whnfIO (execute (mockConn m) "SELECT 1")
      , bench "execute with 1 param, bare DONE" $ whnfIO (execute (mockConn m) ("SELECT " <> param (1 :: Int32)))
      , bench "connect+close plaintext" $ whnfIO (connect (resetOnClose (mockConnectInfo (mockPort m))) >>= close)
      ]
  , bgroup "query"
      [ withMock (responseBody ds) $ \m -> case dsTyped ds of
          Typed _ dec -> bgroup (dsName ds)
            [ bench "typed" $ nfIO (queryWith dec (mockConn m) "SELECT")
            , bench "typed streamed" $ whnfIO (querySWith dec (mockConn m) "SELECT" >>= S.length_)
            , bench "typed folded" $ whnfIO (queryFoldWith dec (mockConn m) "SELECT" (0 :: Int) (\n _ -> pure (n + 1)))
              -- Every value forced, as users pay for them (counting the
              -- rows missed work left in a lazy SqlRow).
            -- execute consumes and discards every row, exercising the drain
            -- recipes without decoding or retaining a result list.
            , bench "drain" $ whnfIO (execute (mockConn m) "SELECT")
            , bench "stream callback per row" $ whnfIO
                (querySWith dec (mockConn m) "SELECT" >>= S.mapM_ (evaluate . rnf))
            , bench "SqlRow" $ nfIO (concatMap resultRows <$> queryMulti (mockConn m) "SELECT")
            ]
      | ds <- datasets
      , dsName ds `elem` mockDatasets || take 5 (dsName ds) == "tuple" || take 11 (dsName ds) == "refineField"
      ]
  , bgroup "output parameter"
      [ withMock (outBody o) $ \m -> case outName o of
          "nvarchar(max) 4MB" -> bench (outName o) $ nfIO (outputValue (mockConn m) T.empty)
          "int" -> bench (outName o) $ nfIO (outputValue (mockConn m) (0 :: Int32))
          _ -> bench (outName o) $ nfIO (outputValue (mockConn m) B.empty)
      | o <- outputs
      ]
  , bgroup "output types"
      [ withMock body $ \m -> bench name $ nfIO (outputValue (mockConn m) initial)
      | (name, initial, body) <- valueOutputs
      ]
  ]
  where
    mockDatasets =
      [ "int bigint x10000", "nvarchar(50) x10000", "decimal(18,4) x10000"
      , "varbinary(max) 4MB x1", "nvarchar(max) 4MB x1", "nullable half NULL NBCROW x10000"
      , "nvarchar(max) short x10000", "nvarchar(max) short streamed x10000", "varbinary(max) short x10000"
      , "varbinary(max) short streamed x10000", "varbinary(max) 4MB streamed x1", "nvarchar(max) 4MB streamed x1"
      , "varbinary(max) short folded x10000", "varbinary(max) 4MB folded x1"
      , "50 columns byColumn x1000", "50 columns x1000"
      , "int bigint record x10000", "nullable half NULL NBCROW record x10000"
      , "int bigint applicative x10000", "nullable half NULL NBCROW applicative x10000"
      ]

-- | The value of the procedure's one output parameter (of the type of
-- the given value).
outputValue :: (ToSqlField a, FromSqlField a) => Connection -> a -> IO a
outputValue conn v = do
  res <- callProcedure conn "p" [outParam "@out" v]
  case map decodeReturnValue (procOutputValues res) of
    [Right x] -> pure x
    r -> fail ("outputValue: " ++ show (length r) ++ " values, or not decoded")

-- | An 'envWithCleanup' with a mock answering every request with this
-- token stream, and a connection to it.
withMock :: B.ByteString -> (Mock -> Benchmark) -> Benchmark
withMock body k = envWithCleanup (startMock body) stopMock (\ ~m -> k m)

startMock :: B.ByteString -> IO Mock
startMock body = do
  let hints = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }
  addr : _ <- Socket.getAddrInfo (Just hints) (Just "127.0.0.1") (Just "0")
  lsock <- Socket.openSocket addr
  Socket.setSocketOption lsock Socket.ReuseAddr 1
  Socket.bind lsock (Socket.addrAddress addr)
  Socket.listen lsock 16
  port <- T.pack . show <$> Socket.socketPort lsock
  let response = B.concat (framedResponse body)
  stopping <- newIORef False
  acceptor <- forkIO $ handle (\(e :: IOException) -> readIORef stopping >>= \s -> unless s (throwIO e)) $ forever $ do
    (sock, _) <- Socket.accept lsock
    Socket.setSocketOption sock Socket.NoDelay 1
    void $ forkIO $ serve sock response `finally` Socket.close sock
  conn <- connect (mockConnectInfo port)
  pure (Mock lsock acceptor stopping port conn)

-- | Close the connection and stop the mock.  On Windows no exception
-- reaches a thread inside network's accept, so 'killThread' on the
-- acceptor never returned and the benchmark hung at the end of its group;
-- there the listener is closed first, the accept fails, and the acceptor
-- ends on that (as the test suite's MockServer does).  Elsewhere the
-- acceptor is killed first, since closing a socket under a thread waiting
-- on it can wedge GHC's I/O manager.
stopMock :: Mock -> IO ()
stopMock m = do
  close (mockConn m)
  if os == "mingw32"
    then do
      writeIORef (mockStopping m) True
      Socket.close (mockListener m)
      killThread (mockAcceptor m)
    else do
      killThread (mockAcceptor m)
      Socket.close (mockListener m)

-- | Plaintext, and no session setup batch (which the mock would answer
-- with its canned result).
mockConnectInfo :: T.Text -> ConnectInfo
mockConnectInfo port = defaultConnectInfo
  { connectHost = "127.0.0.1"
  , connectPort = port
  , connectUser = "mockuser"
  , connectPassword = "mockpassword"
  , connectDatabase = "mockdb"
  , connectEncryption = EncryptNotSup
  , connectSessionSetup = []
  }

-- | The same connection, closed with a reset.  A socket closed in the
-- ordinary way keeps its port for a while afterwards (TIME_WAIT), and a
-- benchmark that connects and closes as fast as it can runs out of
-- ports: macOS has 16,384 of them, the wall-clock run used them up in
-- about a second, and every later connect of the group then failed with
-- "Can't assign requested address".  With a linger time of zero the
-- close sends a reset, and the port is free at once.
resetOnClose :: ConnectInfo -> ConnectInfo
resetOnClose info = info
  { connectProtocol = ProtocolCustom $ do
      backend <- tcpBackend (T.unpack (connectHost info)) (T.unpack (connectPort info))
      pure backend
        { backendClose = do
            forM_ (backendSocket backend) $ \sock ->
              Socket.setSockOpt sock Socket.Linger (Socket.StructLinger 1 0)
                `catch` \(_ :: IOException) -> pure ()
            backendClose backend
        }
  }

-- | PRELOGIN, LOGIN7, then the response to every request until the client
-- closes the connection.  An Attention is acknowledged.
serve :: Socket.Socket -> B.ByteString -> IO ()
serve sock response = do
  buf <- newRecvBuffer
  let -- The type of the next whole message (its payload is not needed).
      recvMessage = recvPacket sock buf >>= \case
        Nothing -> pure Nothing
        Just (hdr, _)
          | PacketStatus st <- headerStatus hdr, st .&. 0x01 /= 0 -> pure (Just (headerType hdr))
          | otherwise -> recvMessage
      send = SocketB.sendAll sock
      message ptype = mapM_ send . splitIntoPackets defaultTdsContext ptype (PacketStatus 0) . Put.runPut
      loop = recvMessage >>= \case
        Nothing -> pure ()
        Just PTAttention -> send (B.concat (framedResponse (tokenBytes [done 0x0020]))) >> loop
        Just _ -> send response >> loop
  _ <- recvMessage  -- PRELOGIN
  message PTTabularResult $ putPrelogin $ Prelogin
    [PLVersion 17 0 1000 0, PLEncryption (encryptionWord EncryptNotSup), PLInstance "", PLThreadId Nothing, PLMars 0]
  _ <- recvMessage  -- LOGIN7
  message PTTabularResult (loginAck >> done 0)
  loop

-- | The next packet, or Nothing at the end of the stream.  Received into a
-- buffer the mock keeps ('RecvBuffer'), so the mock allocates little of
-- what a benchmark measures ('SocketB.recv' allocates the whole size it
-- asks for on every call: 64 KiB per request).
recvPacket :: Socket.Socket -> RecvBuffer -> IO (Maybe (Header, B.ByteString))
recvPacket sock (RecvBuffer scratch buf) = fill headerLength >>= \case
  False -> pure Nothing
  True -> do
    hdr <- Get.runGet getHeader . LB.fromStrict <$> readIORef buf
    let total = fromIntegral (headerPacketLength hdr)
    ok <- fill total
    if not ok
      then pure Nothing
      else do
        (pkt, rest) <- B.splitAt total <$> readIORef buf
        writeIORef buf rest
        pure (Just (hdr, B.drop headerLength pkt))
  where
    fill n = do
      have <- readIORef buf
      if B.length have >= n
        then pure True
        else do
          n' <- BI.unsafeWithForeignPtr scratch $ \p -> Socket.recvBuf sock p scratchSize
            `catch` \(_ :: IOException) -> pure 0
          if n' == 0
            then pure False
            else do
              more <- BI.unsafeWithForeignPtr scratch $ \p -> B.packCStringLen (castPtr p, n')
              writeIORef buf (have <> more) >> fill n

-- | A scratch buffer to receive into, and what has been received but not
-- consumed.
data RecvBuffer = RecvBuffer (ForeignPtr Word8) (IORef B.ByteString)

newRecvBuffer :: IO RecvBuffer
newRecvBuffer = RecvBuffer <$> BI.mallocByteString scratchSize <*> newIORef B.empty

scratchSize :: Int
scratchSize = 65536

loginAck :: Put.Put
loginAck = do
  let body = Put.runPut $ do
        Put.putWord8 1
        Put.putWord32be (tdsVersionWord Tds74)
        putBVarChar "Microsoft SQL Server"
        mapM_ Put.putWord8 [17, 0, 3, 232]
  Put.putWord8 0xAD
  Put.putWord16le (fromIntegral (LB.length body))
  Put.putLazyByteString body

done :: Word16 -> Put.Put
done status = do
  Put.putWord8 0xFD
  Put.putWord16le status
  Put.putWord16le 0
  Put.putWord64le 0
