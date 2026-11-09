-- | Many concurrent TLS connections, each doing real work, to catch
-- per-connection TLS state bugs (context confusion, buffer sharing) or
-- resource exhaustion that a single connection's tests can't reveal.
-- Covers both TLS code paths used elsewhere in "Scale": 'EncryptStrict'
-- (TLS from byte 0) and 'EncryptOn' (TLS negotiated inside PRELOGIN).
module Scale.TlsConcurrencySpec (spec) where

import Control.Concurrent (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Concurrent.Async (forConcurrently_)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket, bracket_)
import Control.Monad (when)
import qualified Data.ByteString as B
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import TestDb

-- | Enough concurrent connections to make per-connection state bugs likely
-- to show up (e.g. two connections' TLS contexts or buffers getting mixed
-- up), without taking so long the suite is unpleasant to run.
connectionCount :: Int
connectionCount = 64

-- | How many connections are opened at once.  The server's accept queue is
-- short: opening all of them at once, while other test runs do the same,
-- overflows it, and although most of the dropped connection attempts are
-- retried, now and then Docker's port forwarding gives up on one and
-- closes it, which fails the connect (PRELOGIN or the TLS handshake meets
-- the end of the stream).  The connections are still all open, and all
-- working, at the same time.
connectingAtOnce :: Int
connectingAtOnce = 8

-- | Put one connection through a few round trips of real,
-- connection-specific data, so a mix-up between connections' TLS state
-- would very likely produce a mismatch rather than silently passing.
doWork :: Int -> Connection -> IO ()
doWork i conn = do
  let tag = fromIntegral (i `mod` 256) :: Word8
      payload = B.cons tag (B.replicate (64 * 1024) tag)
  Only b <- query1 conn (mkQuery "SELECT @p1" (Only payload))
  b `shouldBe` payload
  Only n <- query1 conn ("SELECT " <> param i <> " * 2") :: IO (Only Int)
  n `shouldBe` i * 2
  Only b2 <- query1 conn (mkQuery "SELECT @p1" (Only payload))
  b2 `shouldBe` payload

-- | Open 'connectionCount' connections, 'connectingAtOnce' at a time, and
-- once all are open, run 'doWork' on each of them concurrently.
concurrently :: Encryption -> IO ()
concurrently enc = do
  ci <- testConnectInfo enc
  sem <- newQSem connectingAtOnce
  opened <- newMVar (0 :: Int)
  allOpen <- newEmptyMVar
  forConcurrently_ [1 .. connectionCount] $ \i ->
    bracket (bracket_ (waitQSem sem) (signalQSem sem) (connect ci)) close $ \conn -> do
      modifyMVar_ opened $ \k -> do
        when (k + 1 == connectionCount) $ putMVar allOpen ()
        pure (k + 1)
      readMVar allOpen
      doWork i conn

spec :: Spec
spec = describe "many concurrent TLS connections" $ do
  it (show connectionCount ++ " concurrent EncryptStrict connections each round trip connection-specific data") $
    concurrently EncryptStrict

  it (show connectionCount ++ " concurrent EncryptOn connections each round trip connection-specific data") $
    concurrently EncryptOn
