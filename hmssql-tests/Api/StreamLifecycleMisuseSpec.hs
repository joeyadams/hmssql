-- | Three 'queryS' stream-lifecycle misuses at the API level (connection-pool
-- and reconnect semantics are a different area's territory):
--
-- 1. Pulling from a 'queryS' stream a second time after it has already been
--    fully drained. A 'Streaming.Prelude' 'Streaming.Stream' is an
--    effectful, re-runnable /description/, not a mutable cursor: replaying
--    it re-invokes the same underlying IO actions from the top rather than
--    resuming where the first run left off. Empirically (confirmed against
--    the real server, not just reasoned about) this throws 'ResultAbandoned'
--    rather than yielding an empty stream or replaying rows: once a response
--    is fully read, @nextToken@'s completion path
--    (@Hmssql.Connection.Internal@, the @loop@ inside @nextToken@) sets the
--    connection's current-response reference to 'Nothing', and @nextToken@
--    throws 'ResultAbandoned' whenever that reference no longer matches the
--    'Hmssql.Connection.Internal.ActiveResponse' the caller's stream closed
--    over -- which covers "there is no active response at all anymore", not
--    only the "superseded by a newer request" case.  'ResultAbandoned''s
--    Haddock now documents this ("pulling again from a stream that was
--    already read to its end"), as it does a stream whose read was
--    interrupted (tested in Concurrency.StreamSpec).
-- 2. Closing the connection (with 'close') while a stream obtained from it
--    is still live and only partially consumed, then pulling more from that
--    same stream, in the same thread, sequentially (no concurrent request
--    involved).  This is different from
--    'Connection.LifecycleSpec'\'s \"closing from another thread cancels a
--    concurrent, in-flight query\" (a second thread blocked inside a
--    materializing call at the moment of close) and from its \"using the
--    connection after close throws synchronously\" (a fresh request on an
--    already-closed connection, no live stream involved); neither exercises
--    a stream the caller already holds being pulled again post-close.
-- 3. Running a stream again, after 'close', from before the point where its
--    statement failed.  The response's withheld server error lives in the
--    cursor, not in the stream, so the second run must not report it (as
--    the error of a response the server ended by closing the connection);
--    it gets the 'ConnectionClosed' every use after 'close' gets.
--
-- All must fail cleanly (or, for the first, succeed with no rows) within a
-- 'System.Timeout.timeout' -- never hang.
module Api.StreamLifecycleMisuseSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Int (Int64)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "pulling from a queryS stream after it has already been fully drained" $
    it "throws ResultAbandoned rather than replaying rows, silently returning [], or hanging" $ \conn -> do
      s <- queryS conn "SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3"
      rows1 <- S.toList_ s :: IO [Only Int]
      rows1 `shouldBe` [Only 1, Only 2, Only 3]
      r <- timeout 10_000_000 (try (S.toList_ s) :: IO (Either ResultAbandoned [Only Int]))
      case r of
        Nothing -> expectationFailure "hung on the second pull instead of erroring"
        Just (Left ResultAbandoned) -> pure ()
        Just (Right rows) -> expectationFailure ("replayed " ++ show rows ++ " instead of throwing")
      -- the connection itself is unaffected
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)

  describe "closing the connection while a live stream from it is only partially consumed" $
    it "fails the next pull cleanly, not with a hang" $ \_ -> do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      s <- queryS conn
        "SELECT TOP 300000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) \
        \FROM sys.all_columns a CROSS JOIN sys.all_columns b"
      firstFew <- S.toList_ (S.take 5 s) :: IO [Only Int64]
      length firstFew `shouldBe` 5
      close conn
      r <- timeout 10_000_000 (try (S.toList_ s) :: IO (Either SomeException [Only Int64]))
      case r of
        Nothing -> expectationFailure "hung instead of erroring after the connection was closed mid-stream"
        Just (Right rows) -> expectationFailure ("read " ++ show (length rows) ++ " more rows after close")
        Just (Left _) -> pure () -- some exception; which one is incidental (see docs/dev/limitations.md)

  describe "a stream whose statement failed, run again after close" $
    it "throws ConnectionClosedBy ClosedByClient, not the statement's error again" $ \_ -> do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      s <- queryS conn "SELECT x FROM hmssql_no_such_table_for_this_test"
      first <- try (S.toList_ s) :: IO (Either SqlServerError [Only Int])
      case first of
        Left _ -> pure ()
        Right rows -> expectationFailure ("the missing table gave rows: " ++ show rows)
      close conn
      again <- try (S.toList_ s) :: IO (Either ConnectionClosed [Only Int])
      case again of
        Left (ConnectionClosedBy ClosedByClient) -> pure ()
        Left (ConnectionClosedBy reason) -> expectationFailure ("closed by " ++ show reason)
        Right rows -> expectationFailure ("read " ++ show rows ++ " after close")
