{-# LANGUAGE ViewPatterns #-}
-- | Interrupting a request at arbitrary points (here with 'timeout') must
-- never leave the connection out of step with the server: the next request
-- gets its own response.  An interruption that lands while the request
-- waits for or reads its response leaves the connection usable (the
-- interrupted request sends an Attention, and the next request drains the
-- cancelled response).  One that lands while the request's send blocks
-- breaks the connection instead: the next request throws 'ConnectionBroken'
-- carrying the timeout, and a fresh connection takes over.
module RequestInterruptSpec (spec) where

import UnusableCause (reasonCause)
import Control.Exception (try)
import Control.Monad (forM_)
import Data.IORef
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (closeHolder, isTimeout, newConnHolder, withHeldConnection)
import Hmssql
import Hmssql.Errors
import TestDb

-- | For each (i, delay): run the request with a timeout of @delay@
-- microseconds, then a sentinel query on the same connection, which must
-- return its own value, or throw 'ConnectionBroken' carrying the timeout
-- (then the connection is replaced).  Returns how many times it broke.
pairedAfterTimeouts :: [(Int, Int)] -> (Connection -> Int -> IO ()) -> IO Int
pairedAfterTimeouts cases request = do
  ci <- defaultTestConnectInfo
  holder <- newConnHolder ci (\_ -> pure ())
  broken <- newIORef (0 :: Int)
  forM_ cases $ \(i, delay) -> withHeldConnection holder $ \conn -> do
    _ <- timeout delay (request conn i)
    try (query1 conn (mkQuery "SELECT @p1" (Only (negate i)))) >>= \case
      Right r -> r `shouldBe` Only (negate i)
      Left (ConnectionBroken (reasonCause -> cause)) -> do
        (show cause, isTimeout cause) `shouldSatisfy` snd
        modifyIORef' broken (+ 1)
        closeHolder holder
  closeHolder holder
  readIORef broken

spec :: Spec
spec = do
  it "keeps requests and responses paired when interrupted at any point, or breaks the connection (ConnectionBroken carrying the timeout)" $ do
    -- Delays around one round trip, so the interruption lands anywhere from
    -- before the send to after the response.
    let cases = zip [1 :: Int ..] (concat (replicate 150 [0, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300, 500]))
    b <- pairedAfterTimeouts cases $ \conn i -> () <$ (query1 conn (mkQuery "SELECT @p1" (Only i)) :: IO (Only Int))
    hPutStrLn stderr ("    [request interrupted at any point] broken " ++ show b ++ " of " ++ show (length cases))

  it "keeps requests and responses paired when a long query is cancelled at any point, or breaks the connection (ConnectionBroken carrying the timeout)" $ do
    -- Interruptions while the response is arriving make the interrupted
    -- request send an Attention, and the next request drain.
    let cases = zip [1 :: Int ..] (concat (replicate 10 [0, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]))
    b <- pairedAfterTimeouts cases $ \conn _ ->
      () <$ (query conn "SELECT TOP 20000 a.object_id FROM sys.all_columns a CROSS JOIN sys.all_columns b" :: IO [Only Int])
    hPutStrLn stderr ("    [long query cancelled at any point] broken " ++ show b ++ " of " ++ show (length cases))
