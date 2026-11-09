-- | A non-streaming request ('query', 'execute', 'queryFold', ...)
-- interrupted part-way.  Its caller has no handle to the response, so the
-- connection must not keep it: the response stays on its session only
-- until the connection's next request (or transaction check), which drains
-- it, and a transaction can begin afterwards.  This holds in both modes,
-- wherever the interruption lands: in a read of a response that has fully
-- arrived (no Attention is needed), outside any read (in a fold's step, or
-- just after the request was sent), or in a read of a response still
-- arriving.  The statement is cancelled at once, not by the next request,
-- unless the response had fully arrived; plain and MARS connections alike.
module Concurrency.InterruptedRequestSpec (spec) where

import qualified RecipeState
import Control.Concurrent
import Control.Exception
import Control.Monad (forM_, replicateM_)
import Data.IORef
import Data.Int (Int64)
import System.Timeout (timeout)
import Test.Hspec

import Concurrency.Harness (Interrupt (..), isAsync, nextId, within)
import Hmssql
import Hmssql.BatchQuery (batchQueryFold, runBatchQuery)
import Hmssql.Connection.Internal (ActiveResponse (..), Session (..), allSessions)
import OpenResponses (openResponses, openStatements)
import TestDb

-- | After the interruption: the connection's next request leaves nothing
-- open, and a transaction begins and commits.
nothingLeftAfterNextRequest :: Connection -> IO ()
nothingLeftAfterNextRequest conn = do
  query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
  openStatements conn `shouldReturn` []
  withTransaction conn (query1 conn "SELECT 3") `shouldReturn` Only (3 :: Int)
  openStatements conn `shouldReturn` []

spec :: Spec
spec = do
  it "interrupted in a read of a response that has fully arrived (in a callback), is drained by the next request" $ do
    callback <- newIORef (\_ -> pure ())
    ci <- defaultTestConnectInfo
    withConnection ci { connectOnInfoMessage = \m -> readIORef callback >>= ($ m) } $ \conn -> do
      writeIORef callback (\_ -> threadDelay 300_000)
      timeout 100_000 (execute conn "PRINT 'a'; SELECT 1") `shouldReturn` Nothing
      writeIORef callback (\_ -> pure ())
      openStatements conn `shouldReturn` ["PRINT 'a'; SELECT 1"]
      nothingLeftAfterNextRequest conn

  it "interrupted outside a read (in a fold's step), after the response has fully arrived, is drained by the next request" $
    withTestDb $ \conn -> do
      let sql = "SELECT 1 UNION ALL SELECT 2"
      r <- timeout 100_000 $ queryFold conn (rawSql sql) () $ \() (Only (_ :: Int)) -> threadDelay 1_000_000
      r `shouldBe` Nothing
      openStatements conn `shouldReturn` [sql]
      nothingLeftAfterNextRequest conn

  it "interrupted outside a read (in a fold's step), while the response still arrives, is cancelled at once and drained by the next request" $
    withTestDb $ \conn -> do
      let sql = "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      r <- timeout 100_000 $ queryFold conn (rawSql sql) () $ \() (Only (_ :: Int64)) -> threadDelay 1_000_000
      r `shouldBe` Nothing
      [ar] <- openResponses conn
      arStatement ar `shouldBe` Just sql
      -- The Attention went out from the handler, on a plain connection too.
      RecipeState.attentionSent ar `shouldReturn` True
      nothingLeftAfterNextRequest conn

  it "a batch query interrupted outside a read (in a batchQueryFold step), while the response still arrives, is cancelled at once and drained by the next request" $
    withTestDb $ \conn -> do
      let sql = "SELECT TOP 1000000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      r <- timeout 100_000 $ runBatchQuery conn $
        batchQueryFold (rawSql sql) () (\() (Only (_ :: Int64)) -> threadDelay 1_000_000)
      r `shouldBe` Nothing
      [ar] <- openResponses conn
      arStatement ar `shouldBe` Just sql
      RecipeState.attentionSent ar `shouldReturn` True
      nothingLeftAfterNextRequest conn

  it "interrupted just after the request was sent, leaves nothing open once the next request has run (100 times)" $
    withTestDb $ \conn -> within 120 $ forM_ [1 .. 100 :: Int] $ \i -> do
      -- The generation is bumped right after the request is on the wire,
      -- before the response is registered; summed over the sessions, as
      -- under MARS the request may take any.
      let generation = allSessions conn >>= fmap sum . mapM (readIORef . sessGeneration)
      g0 <- generation
      v <- nextId
      result <- newEmptyMVar
      tid <- mask_ $ forkIOWithUnmask $ \unmask ->
        try (unmask (query conn (mkQuery "SELECT @p1" (Only v)))) >>= putMVar result
      let spin = generation >>= \g -> if g /= g0 then pure () else yield >> spin
      spin
      replicateM_ (i `mod` 4) yield
      throwTo tid Interrupt
      takeMVar result >>= \case
        Right rows -> rows `shouldBe` [Only v]
        Left e -> (show e, isAsync e) `shouldSatisfy` snd
      nothingLeftAfterNextRequest conn
