{-# LANGUAGE ViewPatterns #-}
-- | Tests found by mutation testing of "Hmssql.Connection.Internal".
module Mutation.ConnectionSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int32, Int64)
import qualified Data.Text as T
import Data.Word (Word8)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Compat (timeoutInSlices, windowsNetworkTcp)
import Test.Hspec

import Concurrency.Mock (answerSelect, batchText, selectedNumber)
import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Transaction
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Packet
import MockServer
import Mutation.TokenSpec (doneFamily)
import Protocol.MockTokens (colMetaData, int32, packet, row, tokenBytes)
import TestDb

-- | The header of every packet the client sends until the connection ends
-- (a packet cut short by the end is left out).
recvAllPackets :: MockConn -> IO [Header]
recvAllPackets mc = try (recvPacket mc) >>= \case
  Right (Just (hdr, _)) -> (hdr :) <$> recvAllPackets mc
  Right Nothing -> pure []
  Left (_ :: MockError) -> pure []

withinSecs :: Int -> IO a -> IO a
withinSecs n act = timeoutInSlices (n * 1_000_000) act >>= maybe (throwIO (userError "hung")) pure

spec :: Spec
spec = do
  describe "a message interrupted part-way (mock server)" $
    -- MS-TDS 2.2.3.1.3: packet IDs increase by one per packet of a
    -- message.  An interrupted send is not ended with an IGNORE packet any
    -- more: the connection is broken and its socket shut down, so the
    -- message just stops.
    it "is cut off, not ended: the message's packet type, consecutive packet IDs, no IGNORE or END_OF_MESSAGE bit, then the end of the stream" $ do
     if windowsNetworkTcp
      then pendingWith "on Windows with TCP through network's calls nothing interrupts a send part-way; Concurrency.Send states the consequence"
      else do
      gotFirst <- newEmptyMVar
      sawEnd <- newEmptyMVar
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            first <- recvPacket mc
            putMVar gotFirst ()
            threadDelay 600_000
            rest <- recvAllPackets mc
            putMVar sawEnd ()
            pure (fmap fst first, rest)
      withMockServer handler $ \srv -> do
        let big = rawSql ("SELECT 1 -- " <> T.replicate 8_000_000 "x")
        r <- withinSecs 30 $ withConnection (mockConnectInfo srv) $ \conn -> do
          -- Interrupt once the first packet is out: a fixed timeout could
          -- fire while the batch is still being encoded, before anything
          -- was sent.
          t <- either Just (const Nothing) <$> race (execute conn big) (takeMVar gotFirst >> threadDelay 100_000)
          five <- try (query1 conn "SELECT 5" :: IO (Only Int64))
          -- Still connected: the end of the stream comes from the shutdown.
          ended <- timeout 10_000_000 (takeMVar sawEnd)
          pure (t, either (\(ConnectionBroken _) -> Nothing) Just five, ended)
        r `shouldBe` (Nothing, Nothing, Just ())
        nextResult srv >>= \case
          Left e -> expectationFailure ("mock: " ++ show e)
          Right (first, rest) -> do
            let hdrs = maybe [] pure first ++ rest
                ids = map headerPacketId hdrs
            map headerType hdrs `shouldSatisfy` all (== PTSqlBatch)
            -- Neither END_OF_MESSAGE (0x01) nor IGNORE (0x02) on any packet.
            map (\h -> let PacketStatus st = headerStatus h in st) hdrs `shouldSatisfy` all (== 0)
            -- Consecutive IDs (modulo 256) up to where the message stops.
            zipWith (\a b -> b - a) ids (drop 1 ids) `shouldSatisfy` all (== 1)

  describe "RESETCONNECTION acknowledgement" $ do
    it "ends the transaction the client was tracking (mock server)" $ do
      count <- newIORef (0 :: Int)
      let respond _ _ = do
            n <- atomicModifyIORef' count (\c -> (c + 1, c))
            pure $ case n of
              -- BEGIN TRANSACTION: a begin-transaction ENVCHANGE.
              0 -> [envChangeToken 8 (B.pack ([8, 1, 2, 3, 4, 5, 6, 7, 8] ++ [0])), doneToken 0 0]
              -- The next request carries RESETCONNECTION; the server
              -- acknowledges it (and reports nothing else).
              _ -> [envChangeToken 18 (B.pack [0, 0]), doneToken 0 0]
      withMockServer (\mc -> serveLogin defaultLoginResponse mc >> serveRequests respond mc) $ \srv ->
        withConnection (mockConnectInfo srv) $ \conn -> withinSecs 10 $ do
          _ <- execute conn "BEGIN TRANSACTION"
          inTransaction conn `shouldReturn` True
          reset conn
          _ <- execute conn "SELECT 1"
          inTransaction conn `shouldReturn` False
    it "ends the transaction the client was tracking (live server, no session setup)" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectSessionSetup = [] } $ \conn -> do
        begin conn
        inTransaction conn `shouldReturn` True
        reset conn
        query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
        inTransaction conn `shouldReturn` False
    it "ends the transaction the client was tracking (live server, with session setup)" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectSessionSetup = ["SET NOCOUNT ON"] } $ \conn -> do
        begin conn
        reset conn
        query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
        inTransaction conn `shouldReturn` False

  describe "a broken connection's cause" $
    it "stays the first failure, not a later failed cleanup" $ do
      count <- newIORef (0 :: Int)
      let respond _ _ = do
            n <- atomicModifyIORef' count (\c -> (c + 1, c))
            pure $ case n of
              0 -> [envChangeToken 8 (B.pack ([8, 1, 2, 3, 4, 5, 6, 7, 8] ++ [0])), doneToken 0 0]
              -- An unknown token: a protocol error that breaks the connection.
              _ -> [Put.putWord8 0x01]
      withMockServer (\mc -> serveLogin defaultLoginResponse mc >> serveRequests respond mc) $ \srv ->
        withConnection (mockConnectInfo srv) $ \conn -> withinSecs 10 $ do
          -- The body fails; the rollback then fails too, the connection
          -- being broken already.
          r <- try (withTransaction conn (execute conn "UPDATE t SET x = 1"))
          case r of
            Left (ProtocolError _) -> pure ()
            other -> expectationFailure ("withTransaction: " ++ show other)
          try (execute conn "SELECT 1") >>= \case
            Left (ConnectionBroken (reasonCause -> cause))
              | Just (ProtocolError _) <- fromException cause -> pure ()
            other -> expectationFailure ("later use: " ++ show other)

  describe "transaction ENVCHANGEs (mock server)" $ do
    -- Each request is answered with the ENVCHANGE it names; the client's
    -- idea of the transaction follows them.
    let desc = [8, 1, 2, 3, 4, 5, 6, 7, 8]
        begin = B.pack (desc ++ [0])        -- new: descriptor, old: empty
        ended = B.pack ([0] ++ desc)        -- new: empty, old: descriptor
        answer sql = pure $ case T.words (batchText sql) of
          ["ENV", n, "NEW"] -> [envChangeToken (read (T.unpack n)) begin, doneToken 0 0]
          ["ENV", n, "OLD"] -> [envChangeToken (read (T.unpack n)) ended, doneToken 0 0]
          _ -> [doneToken 0 0]
        run = withMockServer (\mc -> serveLogin defaultLoginResponse mc >> serveRequests (const answer) mc)
        step conn sql = withinSecs 10 (execute conn sql) >> inTransaction conn
    it "begin (8) and enlist DTC (11) start one; commit, rollback, defect, ended (9, 10, 12, 17) end it" $
      run $ \srv -> withConnection (mockConnectInfo srv) $ \conn -> do
        r <- mapM (step conn)
          [ "ENV 8 NEW", "ENV 9 OLD", "ENV 8 NEW", "ENV 10 OLD", "ENV 11 NEW", "ENV 12 OLD"
          , "ENV 8 NEW", "ENV 17 OLD", "ENV 11 NEW", "ENV 12 NEW" ]
        r `shouldBe` [True, False, True, False, True, False, True, False, True, False]

  describe "the Attention acknowledgement (mock server)" $ do
    -- The DONE_ATTN bit on any DONE-family token ends the wait.
    let server ty mc = do
          _ <- serveLogin defaultLoginResponse mc
          _ <- recvMessage mc
          -- A result that never ends...
          sendRaw mc $ packet False $ tokenBytes [colMetaData [("x", TIIntN 4)], row [(TIIntN 4, int32 1)]]
          -- ...until the Attention.
          (PTAttention, _) <- recvMessage mc
          sendRaw mc $ packet True $ tokenBytes [doneFamily ty 0x20 0]
          (_, body) <- recvMessage mc
          forM' (selectedNumber (batchText body)) (sendTokens mc . answerSelect)
    it "is recognised on a DONEPROC and on a DONEINPROC too" $
      mapM_ (\ty -> withMockServer (server ty) $ \srv -> withConnection (mockConnectInfo srv) $ \conn -> do
          s <- queryS conn "SELECT 1" :: IO (Stream (Of (Only Int32)) IO ())
          _ <- S.next s
          -- The next request cancels the unfinished one.
          withinSecs 10 (query1 conn "SELECT 5") `shouldReturn` Only (5 :: Int64))
        [0xFE, 0xFF :: Word8]

  describe "after the server closed the connection (mock server)" $
    it "a request fails without sending anything" $ do
      let handler mc = do
            _ <- serveLogin defaultLoginResponse mc
            shutdownSend mc
            -- Anything the client sends from now on arrives here.
            timeout 2_000_000 (recvPacket mc)
      withMockServer handler $ \srv -> do
        withConnection (mockConnectInfo srv) $ \conn -> do
          -- Let the reader thread see the end of the stream.
          threadDelay 300_000
          r <- try (execute conn "SELECT 1")
          case r of
            Left e | Just (ConnectionClosedBy ClosedByServer) <- fromException e -> pure ()
            other -> expectationFailure ("got " ++ show other)
        nextResult srv >>= \case
          Right (Just Nothing) -> pure ()   -- the client closed without sending
          Right Nothing -> pure ()
          other -> expectationFailure ("the mock received " ++ show other)
  where
    forM' m f = maybe (pure ()) f m
