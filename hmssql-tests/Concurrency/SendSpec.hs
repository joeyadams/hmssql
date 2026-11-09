{-# LANGUAGE ViewPatterns #-}
-- | Interrupting a request while it is being sent.
--
-- A send runs with asynchronous exceptions masked, so it can only be
-- interrupted while it actually blocks: on a peer that doesn't read, or on
-- the TLS session's write lock.  An interruption that lands there breaks the
-- connection (the server may hold part of a message, and nothing tells it to
-- discard it): the socket is shut down, nothing more is sent, the
-- interruption reaches the caller, and every later request throws
-- 'ConnectionBroken' carrying it.  An interruption that arrives while a send
-- doesn't block is deferred until the send is over, and lands in the wait
-- for the response, which leaves the connection usable.  So a request
-- interrupted around its send leaves the connection usable, or broken by
-- that interruption; never out of step, never hung.
module Concurrency.SendSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent
import Control.Concurrent.Async (AsyncCancelled (..), race)
import Control.Exception
import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int64)
import qualified Data.Text as T
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Compat (blockingCallStopsProcess, windowsNetworkTcp)
import Concurrency.Harness
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Errors
import Hmssql.Tds.Packet
import MockServer
import TestDb

-- | Every packet the client sends until the connection ends: (status, body
-- length) of each that arrived whole, and whether the stream ended part-way
-- through a packet.
recvUntilEnd :: MockConn -> IO ([(Word, Int)], Bool)
recvUntilEnd mc = go []
  where
    go acc = try (recvPacket mc) >>= \case
      Right Nothing -> pure (reverse acc, False)
      Right (Just (hdr, body)) -> do
        let PacketStatus st = headerStatus hdr
        go ((fromIntegral st, B.length body) : acc)
      Left (MockUnexpected _) -> pure (reverse acc, True)
      Left MockClientClosed -> pure (reverse acc, False)

-- | Run a request on a connection kept in the holder, interrupting it with
-- 'Interrupt' after the delay; then check the connection.  Usable, or broken
-- with the interruption as the cause (and then replaced); the request itself
-- ends with its result or the interruption.
interruptedRequest :: ConnHolder -> Delay -> (Connection -> IO (Either String ())) -> IO (Bool, Health)
interruptedRequest holder delay act = withHeldConnection holder $ \conn -> do
  r <- interruptWith ViaThrowTo delay (act conn)
  interrupted <- case r of
    Right (Right ()) -> pure False
    Right (Left wrong) -> throwIO (userError wrong)
    Left e
      | isInterrupt e -> pure True
      | otherwise -> throwIO (userError ("the request ended with " ++ show e ++ ", not the interruption"))
  h <- expectUsableOrBrokenBy isInterrupt conn
  case h of
    Broken _ -> do
      -- The interruption reached the request, which is the only way a send
      -- can break the connection here.
      if interrupted then closeHolder holder else throwIO (userError "broken, but the request was not interrupted")
    Usable -> pure ()
  pure (interrupted, h)

spec :: Spec
spec = do
  describe "mock server" $ do
    it "a message interrupted part-way breaks the connection: nothing more is sent, the socket is shut down, and later requests throw ConnectionBroken carrying the interruption" $ do
     -- A pipe's send is interruptible on every path, TCP's everywhere but
     -- on network's Windows path.
     transport <- mockTransport
     if windowsNetworkTcp && transport == MockTcp
      then pendingWith "on Windows with TCP through network's calls a send blocks in a foreign call that no exception reaches, so nothing interrupts a message part-way; the next test states the consequence, and this one runs with the mock on a pipe (HMSSQL_TEST_MOCK_TRANSPORT=pipe)"
      else do
      gotFirst <- newEmptyMVar
      sawEnd <- newEmptyMVar
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            -- Take the first packet, then stop reading: the client's send
            -- blocks, and is interrupted meanwhile.
            first <- recvPacket mc
            putMVar gotFirst ()
            threadDelay 600_000
            (rest, cut) <- recvUntilEnd mc
            putMVar sawEnd ()
            pure (fmap (B.length . snd) first, rest, cut)
      withMockServer handler $ \srv -> do
        let big = "SELECT 1 -- " <> T.replicate 8_000_000 "x"
        r <- within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
          -- Interrupt once the first packet is out: a fixed timeout could
          -- fire while the batch is still being encoded, before anything
          -- was sent.  'race' cancels the losing send with AsyncCancelled.
          t <- race (execute conn (rawSql big)) (takeMVar gotFirst >> threadDelay 100_000)
          five <- try (query1 conn "SELECT 5" :: IO (Only Int64))
          -- The connection is still open here: the mock must nevertheless
          -- see the end of the stream (the socket was shut down).
          ended <- timeout 10_000_000 (takeMVar sawEnd)
          pure (either (const Nothing) Just t, five, ended)
        case r of
          (t, five, ended) -> do
            t `shouldBe` Just ()
            case five of
              Left (ConnectionBroken (reasonCause -> cause)) -> fromException cause `shouldBe` Just AsyncCancelled
              Right v -> expectationFailure ("the broken connection answered " ++ show v)
            ended `shouldBe` Just ()
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right (first, rest, _cut) -> do
            first `shouldSatisfy` maybe False (> 0)
            -- Far from all 16 MB was sent, the message was never ended (no
            -- END_OF_MESSAGE, no IGNORE packet), and nothing followed it
            -- (not SELECT 5).  The last packet may have been cut short.
            sum (map snd rest) `shouldSatisfy` (< 15_000_000)
            rest `shouldSatisfy` all ((== 0) . fst)

    -- The consequence of the blocking send on that path (design.md,
    -- "Windows: GHC's native I/O manager"): the interruption is deferred
    -- until the server has taken the whole message, and lands in the wait
    -- for the response, so the statement is cancelled with an Attention
    -- and the connection stays usable.
    it "on Windows with TCP through network's calls, an interruption during a blocked send waits for the whole message to go out, then cancels it, and the connection stays usable" $ do
     if not windowsNetworkTcp
      then pendingWith "only on Windows with TCP through network's calls"
      else if blockingCallStopsProcess
      then pendingWith "without -threaded the blocked send stops every thread, the mock server's too, so it can't read the message this test waits for (Compat.blockingCallStopsProcess)"
      else do
      gotFirst <- newEmptyMVar
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            first <- recvPacket mc
            putMVar gotFirst ()
            threadDelay 600_000
            -- The rest of the message, to its END_OF_MESSAGE.
            let rest acc = recvPacket mc >>= \case
                  Nothing -> pure (reverse acc)
                  Just (hdr, body) -> do
                    let PacketStatus st = headerStatus hdr
                        acc' = (fromIntegral st :: Word, B.length body) : acc
                    if odd st then pure (reverse acc') else rest acc'
            whole <- rest []
            -- Then the Attention, answered, and the next batch.
            (attn, _) <- recvMessage mc
            sendTokens mc [doneToken 0x0020 0]
            (next, _) <- recvMessage mc
            sendTokens mc [doneToken 0 0]
            pure (fmap (B.length . snd) first, whole, attn, next)
      -- TCP whatever the mock transport: a pipe's send is interruptible
      -- on that path too.
      withTcpMockServer handler $ \srv -> do
        let big = "SELECT 1 -- " <> T.replicate 8_000_000 "x"
        r <- within 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
          t <- race (execute conn (rawSql big)) (takeMVar gotFirst >> threadDelay 100_000)
          next <- try (execute conn "SELECT 1")
          pure (either (const Nothing) Just t, next)
        case r of
          (t, next) -> do
            t `shouldBe` Just ()
            either (\(e :: SomeException) -> expectationFailure ("the next request failed: " ++ show e)) (const (pure ())) next
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right (first, whole, attn, next) -> do
            first `shouldSatisfy` maybe False (> 0)
            -- All of it, ended: the 16,000,024 bytes of the text, and the
            -- headers before it.
            (maybe 0 id first + sum (map snd whole)) `shouldSatisfy` (>= 16_000_024)
            (attn, next) `shouldBe` (PTAttention, PTSqlBatch)

  describe "live server" $ do
    it "a multi-packet request interrupted at random points leaves the connection usable, or broken (ConnectionBroken carrying the interruption), never out of step" $ do
      ci <- defaultTestConnectInfo
      -- 512-byte packets: a 200,000-character parameter takes ~800 of them.
      holder <- newConnHolder ci { connectPacketSize = 512 } (\_ -> pure ())
      interrupted <- newIORef (0 :: Int)
      broken <- newIORef (0 :: Int)
      within 300 $ forM_ [0 .. 149 :: Int] $ \i -> do
        v <- nextId
        let delay = if even i then Yields (i `mod` 40) else Micros ((i * 97) `mod` 20_000)
        (int, h) <- interruptedRequest holder delay $ \conn -> do
          rows <- query conn (mkQuery "SELECT @p1, LEN(@p2)" (v, T.replicate 200_000 "y"))
          pure (if rows == [(v, 200_000 :: Int)] then Right () else Left ("wrong result " ++ show rows))
        if int then modifyIORef' interrupted (+ 1) else pure ()
        case h of
          Broken _ -> modifyIORef' broken (+ 1)
          Usable -> pure ()
      closeHolder holder
      n <- readIORef interrupted
      b <- readIORef broken
      hPutStrLn stderr ("    [multi-packet send] interrupted " ++ show n ++ " of 150, of which broken " ++ show b)
      n `shouldSatisfy` (> 0)

    -- A reset is consumed by the request that carries it, under the same mask
    -- as its send.  If that send is interrupted, the connection is broken and
    -- the reset is lost with it: nothing more runs in that session, and a
    -- fresh connection is needed (which starts clean).  If the interruption
    -- lands anywhere else, the reset has happened by the time the next
    -- request is answered.
    it "a pending reset: lost with the connection when the send carrying it is interrupted (a fresh connection starts clean), otherwise done by the next request" $ do
      ci <- defaultTestConnectInfo
      holder <- newConnHolder ci { connectPacketSize = 512 } (\_ -> pure ())
      broken <- newIORef (0 :: Int)
      within 300 $ forM_ [0 .. 59 :: Int] $ \i -> do
        h <- withHeldConnection holder $ \conn -> do
          _ <- execute conn "IF OBJECT_ID('tempdb..#r') IS NULL CREATE TABLE #r (i int)"
          reset conn
          let delay = if even i then Yields (i `mod` 30) else Micros ((i * 211) `mod` 10_000)
          _ <- interruptWith ViaThrowTo delay (query conn (mkQuery "SELECT LEN(@p1)" (Only (T.replicate 100_000 "z"))) :: IO [Only Int])
          try (query1 conn "SELECT OBJECT_ID('tempdb..#r')" :: IO (Only (Maybe Int))) >>= \case
            Right t -> do
              -- Wherever the interruption landed, the reset has happened.
              t `shouldBe` Only Nothing
              expectUsable conn
              pure Usable
            Left (ConnectionBroken (reasonCause -> cause)) -> do
              isInterrupt cause `shouldBe` True
              -- Every later request is refused too: the session that missed
              -- its reset is never used again.
              Broken <$> expectBrokenBy isInterrupt conn
        case h of
          Usable -> pure ()
          Broken _ -> do
            modifyIORef' broken (+ 1)
            closeHolder holder
            -- The replacement starts clean.
            withHeldConnection holder $ \conn ->
              query1 conn "SELECT OBJECT_ID('tempdb..#r')" `shouldReturn` Only (Nothing :: Maybe Int)
      closeHolder holder
      b <- readIORef broken
      hPutStrLn stderr ("    [reset carried by an interrupted send] broken " ++ show b ++ " of 60")
