{-# LANGUAGE ViewPatterns #-}
-- | Cancelling an unfinished response with an Attention, against servers
-- that acknowledge it late, oddly, or never.
module Protocol.AttentionSpec (spec) where

import UnusableCause (reasonCause)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, fromException)
import Control.Monad (forM_)
import Data.Binary.Put (Put)
import Data.Int (Int32)
import Data.IORef
import Data.Maybe (isJust)
import qualified Streaming.Prelude as S
import System.Timeout (Timeout, timeout)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Packet (PacketType (..))
import MockServer
import Protocol.MockTokens

rowOf :: Int32 -> Put
rowOf i = row [(TIIntN 4, int32 i)]

-- | The start of a long response: metadata and two rows, without END_OF_MESSAGE.
firstPart :: [Put]
firstPart = [colMetaData [("x", TIIntN 4)], rowOf 1, rowOf 2]

-- | Answer requests with 'goodResponse' and Attentions with an
-- acknowledgement, counting the Attentions.
serveCounting :: IORef Int -> MockConn -> IO ()
serveCounting attns mc = recvMessageMaybe mc >>= \case
  Nothing -> pure ()
  Just (PTAttention, _) -> do
    modifyIORef' attns (+ 1)
    sendTokens mc [doneToken 0x20 0]
    serveCounting attns mc
  Just _ -> sendTokens mc goodResponse >> serveCounting attns mc

-- | Log in, answer the first request with 'firstPart', wait for the
-- Attention, then run the given reaction and serve further requests.
attentionServer :: IORef Int -> (MockConn -> IO ()) -> MockConn -> IO ()
attentionServer attns react mc = do
  _ <- serveLogin defaultLoginResponse mc
  _ <- recvMessage mc
  sendRaw mc (packet False (tokenBytes firstPart))
  (ptype, _) <- recvMessage mc
  if ptype == PTAttention
    then modifyIORef' attns (+ 1)
    else throwMock ("expected an Attention, got " ++ show ptype)
  react mc
  serveCounting attns mc
  where
    throwMock = ioError . userError

-- | Further use throws 'ConnectionBroken' carrying the timeout that
-- interrupted the wait for the acknowledgement.
expectBrokenByTimeout :: Connection -> Expectation
expectBrokenByTimeout conn = within (trySync (goodQuery conn)) >>= \case
  Left e | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, isTimeout cause -> pure ()
  other -> expectationFailure ("expected ConnectionBroken carrying the timeout, got " ++ either describeException (\a -> "result " ++ show a) other)

isTimeout :: SomeException -> Bool
isTimeout e = isJust (fromException @Timeout e)

-- | Read one row of a query, abandon the rest, then run another query.
abandonAndQuery :: Connection -> IO [Only Int32]
abandonAndQuery conn = do
  s <- queryS conn "SELECT x FROM big"
  firstRows <- S.toList_ (S.take 1 s) :: IO [Only Int32]
  firstRows `shouldBe` [Only 1]
  goodQuery conn

spec :: Spec
spec = do
  it "discards rows after an Attention up to the DONE_ATTN" $ do
    attns <- newIORef 0
    let react mc = sendRaw mc (packet True (tokenBytes [rowOf 3, doneToken 0x20 0]))
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn ->
        within (abandonAndQuery conn) `shouldReturn` [Only 42]
    readIORef attns `shouldReturn` 1

  it "waits for a late DONE_ATTN" $ do
    attns <- newIORef 0
    let react mc = threadDelay 1_000_000 >> sendRaw mc (packet True (tokenBytes [doneToken 0x20 0]))
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn ->
        within (abandonAndQuery conn) `shouldReturn` [Only 42]
    readIORef attns `shouldReturn` 1

  it "reads a DONE_ATTN sent as its own message after the response completed" $ do
    attns <- newIORef 0
    let react mc = do
          sendRaw mc (packet True (tokenBytes [rowOf 3, doneToken 0x10 3]))
          sendTokens mc [doneToken 0x20 0]
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn ->
        within (abandonAndQuery conn) `shouldReturn` [Only 42]
    readIORef attns `shouldReturn` 1

  it "a wait for the DONE_ATTN can be interrupted when the server never sends one, which breaks the connection" $ do
    attns <- newIORef 0
    let react _ = threadDelay 5_000_000
    withMockServer (attentionServer attns react) $ \srv ->
      within $ withConnection (mockConnectInfo srv) $ \conn -> do
        r <- timeout 500_000 (abandonAndQuery conn)
        r `shouldBe` Nothing
        expectBrokenByTimeout conn

  -- An interrupted wait for the acknowledgement leaves the position in the
  -- cancelled response unknown, so the connection is broken rather than a
  -- second Attention sent (its acknowledgement would be read as the next
  -- response).
  it "an interrupted wait for the DONE_ATTN breaks the connection without sending a second Attention" $ do
    attns <- newIORef 0
    let react mc = threadDelay 1_500_000 >> sendRaw mc (packet True (tokenBytes [doneToken 0x20 0]))
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn -> do
        r <- timeout 300_000 (abandonAndQuery conn)
        r `shouldBe` Nothing
        expectBrokenByTimeout conn
        expectBrokenByTimeout conn
    readIORef attns `shouldReturn` 1

  -- Once the wait is interrupted, nothing resumes it: every later request,
  -- with a timeout of its own or not, is refused at once, carrying the
  -- first interruption, and sends nothing (the acknowledgement arriving
  -- later is never read as a response).
  it "after an interrupted wait for the DONE_ATTN, several later requests all throw ConnectionBroken carrying the timeout, still with one Attention" $ do
    attns <- newIORef 0
    let react mc = threadDelay 1_500_000 >> sendRaw mc (packet True (tokenBytes [doneToken 0x20 0]))
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn -> do
        timeout 300_000 (abandonAndQuery conn) `shouldReturn` Nothing
        forM_ [1 .. 2 :: Int] $ \_ -> within (trySync (timeout 300_000 (goodQuery conn))) >>= \case
          Left e | Just (ConnectionBroken (reasonCause -> cause)) <- fromException e, isTimeout cause -> pure ()
          other -> expectationFailure ("expected ConnectionBroken carrying the timeout, got " ++ either describeException (\a -> "result " ++ show a) other)
        -- After the acknowledgement has arrived, too.
        threadDelay 1_500_000
        expectBrokenByTimeout conn
        expectBrokenByTimeout conn
    readIORef attns `shouldReturn` 1

  it "an interrupted wait for a DONE_ATTN due after the response's own message ended breaks the connection" $ do
    attns <- newIORef 0
    let react mc = do
          sendRaw mc (packet True (tokenBytes [rowOf 3, doneToken 0x10 3]))
          threadDelay 1_500_000
          sendTokens mc [doneToken 0x20 0]
    withMockServer (attentionServer attns react) $ \srv ->
      withConnection (mockConnectInfo srv) $ \conn -> do
        timeout 500_000 (abandonAndQuery conn) `shouldReturn` Nothing
        expectBrokenByTimeout conn
        expectBrokenByTimeout conn
    readIORef attns `shouldReturn` 1
