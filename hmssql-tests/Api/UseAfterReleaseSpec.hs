{-# LANGUAGE DerivingStrategies #-}

-- | A 'Connection' handle used after 'release', against the lease rules in
-- 'Hmssql.Connection.release', 'Hmssql.Connection.renew' and
-- 'ConnectionReleased':
--
-- * every operation through a released handle throws 'ConnectionReleased'
--   before anything is sent, whatever the connection's state (fine,
--   closed, broken), and leaves the connection as it was for the handle
--   'renew' made;
-- * so do the streams the handle produced, both from the rows of a batch
--   already in hand and when they must read on;
-- * only 'close' works through a released handle, and it closes the
--   connection for every handle;
-- * the read-only 'connectionContext', 'connectionMars' and
--   'inTransaction' still answer, with the connection's state;
-- * 'renew' makes every earlier handle stale, a renewed one included;
--   'connect's handle needs no 'renew'.
--
-- Mock server only: it records every message the client sends, so "nothing
-- was sent" is exact.
module Api.UseAfterReleaseSpec (spec) where

import qualified RecipeState
import Control.Exception
import Control.Monad (forM_, void)
import Data.Binary.Put (Put)
import Data.Int (Int32, Int64)
import Data.IORef
import Data.Text (Text)
import qualified Data.ByteString as B
import Streaming (Of (..), Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (within)
import Concurrency.Mock
import Hmssql
import Hmssql.BulkCopy (bulkCopy, bulkInsert, bulkInsertSWith)
import Hmssql.Connection (cancelActiveStatement, connectionContext, connectionMars, reset)
import Hmssql.Connection.Internal (ActiveResponse (..), ReadState (..), renewLease)
import Hmssql.Errors
import Hmssql.Query (callProcedure)
import Hmssql.Tds.Context (TdsContext (..))
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Transaction (inTransaction, rollback)
import MockServer (MockError (..), doneToken, envChangeToken)
import OpenResponses (openResponses)

------------------------------------------------------------------------------
-- Mock helpers

-- | What the client sent after the scripted part.
data Seen = Batch Text | Rpc | BulkLoad | Attention
  deriving stock (Eq, Show)

-- | Answer @SELECT n@ batches with @n@, @BEGIN TRANSACTION@ with a
-- begin-transaction ENVCHANGE, anything else with a bare DONE, and
-- acknowledge Attentions, recording every message, until the client closes
-- the connection.  RPCs and bulk loads are answered too, so that a client
-- that wrongly sends one fails the comparison rather than hanging.
serveRecording :: MockIO -> IO [Seen]
serveRecording io = go []
  where
    go acc = try (mRecv io 30_000_000) >>= \case
      Left MockClientClosed -> pure (reverse acc)
      Left e -> throwIO e
      Right Nothing -> throwIO (MockUnexpected "client idle for 30 s")
      Right (Just (PTAttention, _)) -> mSendMessage io [doneAttn] >> go (Attention : acc)
      Right (Just (PTSqlBatch, body)) -> do
        let sql = batchText body
        mSendMessage io $ case sql of
          "BEGIN TRANSACTION" -> [begin, doneFinal 0]
          _ -> maybe [doneFinal 0] answerSelect (selectedNumber sql)
        go (Batch sql : acc)
      Right (Just (PTRpc, _)) -> mSendMessage io [doneToken 0 0] >> go (Rpc : acc)
      Right (Just (PTBulkLoad, _)) -> mSendMessage io [doneFinal 0] >> go (BulkLoad : acc)
      Right (Just (ptype, _)) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))

-- | Begin-transaction ENVCHANGE (type 8): an 8-byte descriptor as the new
-- value, none as the old.
begin :: Put
begin = envChangeToken 8 (B.pack ([8, 1, 2, 3, 4, 5, 6, 7, 8] ++ [0]))

mockOutcome :: Either SomeException r -> IO r
mockOutcome = either (\e -> throwIO (userError ("mock: " ++ show e))) pure

-- | 'ConnectionReleased' as 'Nothing', so that results compare with
-- 'shouldBe' (the exception has no 'Eq').
releasedOr :: Either ConnectionReleased a -> Maybe a
releasedOr = either (\ConnectionReleased -> Nothing) Just

-- | Fail unless the action threw 'ConnectionReleased'; any other exception
-- propagates.
expectReleased :: Show a => String -> Either ConnectionReleased a -> Expectation
expectReleased what = \case
  Left ConnectionReleased -> pure ()
  Right a -> expectationFailure (what ++ " went through a released handle: " ++ show a)

-- | Whether the last packet of the pending response (on any session) has
-- been read.
responseComplete :: Connection -> IO (Maybe Bool)
responseComplete conn = openResponses conn >>= \case
  [] -> pure Nothing
  [ar] -> Just . RecipeState.ended <$> readIORef (arState ar)
  ars -> fail (show (length ars) ++ " responses pending")

-- | Every operation that takes the connection, on a handle.  Each would
-- send something if it got through (the mock records it).
staleOps :: [(String, Connection -> IO ())]
staleOps =
  [ ("execute", \c -> void (execute c "SELECT 1"))
  , ("query", \c -> void (query c "SELECT 1" :: IO [Only Int64]))
  , ("queryS", \c -> (queryS c "SELECT 1" :: IO (Stream (Of (Only Int64)) IO ())) >>= S.effects)
  , ("queryFold", \c -> void (queryFold c "SELECT 1" (0 :: Int) (\n (Only (_ :: Int64)) -> pure (n + 1))))
  , ("callProcedure", \c -> void (callProcedure c "sp_who" []))
  , ("executeStatements", \c -> void (executeStatements c ["SELECT 1", "SELECT 2"]))
  , ("reset", reset)
  , ("cancelActiveStatement", cancelActiveStatement)
  , ("rollback", rollback)
  , ("withTransaction", \c -> withTransaction c (void (execute c "SELECT 1")))
  , ("release", \c -> void (release c))
  , ("bulkInsert", \c -> void (bulkInsert c "dbo.t" [Only (1 :: Int32)]))
  , ("bulkInsertSWith", \c -> void (bulkInsertSWith (bulkCopy "dbo.t") c (S.each [Only (1 :: Int32)])))
  ]

------------------------------------------------------------------------------

spec :: Spec
spec = describe "mock server" $ do
  describe "on a released handle" $
    forM_ staleOps $ \(what, op) ->
      it (what ++ " throws ConnectionReleased and sends nothing, and the renewed handle still works") $ do
        (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $ withConnection ci $ \conn -> do
          ok <- release conn
          conn' <- renew conn
          r <- try (op conn)
          -- A stale 'release' that bumped the lease would make this throw.
          final <- query1 conn' "SELECT 7"
          pure (ok, r, final)
        case results of
          (ok, r, final) -> do
            ok `shouldBe` True
            expectReleased what r
            final `shouldBe` Only (7 :: Int64)
        mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 7"])

  describe "a stream opened before release" $ do
    it "throws ConnectionReleased from the rows of a batch already in hand, not ResultAbandoned or the rows" $ do
      let script io = do
            _ <- expectBatch io
            mSendMessage io [colMetaBigint "n", rowBigint 1, rowBigint 2, rowBigint 3, doneFinal 3]
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        -- The whole response has been read: rows 2 and 3 are in hand, so
        -- the stream needs no read to yield them.
        complete <- responseComplete conn
        ok <- release conn
        conn' <- renew conn
        again <- try (S.toList_ rest)
        final <- query1 conn' "SELECT 4"
        pure (first, complete, ok, releasedOr again, final)
      results `shouldBe` ([Only (1 :: Int64)], Just True, True, Nothing, Only (4 :: Int64))
      -- Nothing sent for the discarded rest, nor for the stale stream.
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 4"])

    it "throws ConnectionReleased when it must read on, and reads nothing" $ do
      let script io = do
            _ <- expectBatch io
            -- One row, then the response goes on: the stream's next row
            -- needs a read.
            mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1])
            -- release cancels the statement.
            expectAttention io
            mSendPacket io True (tokenBytes [rowBigint 2, doneAttn])
            serveRecording io
      (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
        s <- queryS conn "SELECT many"
        first :> rest <- S.toList (S.splitAt 1 s)
        complete <- responseComplete conn
        ok <- release conn
        conn' <- renew conn
        again <- try (S.toList_ rest)
        final <- query1 conn' "SELECT 3"
        pure (first, complete, ok, releasedOr again, final)
      results `shouldBe` ([Only (1 :: Int64)], Just False, True, Nothing, Only (3 :: Int64))
      mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 3"])

  it "close through a released handle closes the connection: the renewed handle then gets ConnectionClosedBy ClosedByClient, the released one still ConnectionReleased" $ do
    (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $ withConnection ci $ \conn -> do
      ok <- release conn
      conn' <- renew conn
      a <- query1 conn' "SELECT 1"
      close conn
      fresh <- try (query1 conn' "SELECT 2" :: IO (Only Int64))
      stale <- try (query1 conn "SELECT 3" :: IO (Only Int64))
      pure (ok, a, fresh, stale)
    case results of
      (ok, a, fresh, stale) -> do
        ok `shouldBe` True
        a `shouldBe` Only (1 :: Int64)
        case fresh of
          Left (ConnectionClosedBy ClosedByClient) -> pure ()
          Left (ConnectionClosedBy reason) -> expectationFailure ("closed by " ++ show reason)
          Right r -> expectationFailure ("the renewed handle went on after close: " ++ show r)
        expectReleased "query1" stale
    mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 1"])

  it "connectionContext, connectionMars and inTransaction still answer through a released handle, with the connection's state; its rollback sends nothing and the transaction stays open" $ do
    (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $ withConnection ci $ \conn -> do
      ok <- release conn
      conn' <- renew conn
      before <- inTransaction conn
      _ <- execute conn' "BEGIN TRANSACTION"
      after <- inTransaction conn
      staleCtx <- connectionContext conn
      freshCtx <- connectionContext conn'
      let staleMars = connectionMars conn
          freshMars = connectionMars conn'
      rolledBack <- try (rollback conn)
      stillOpen <- inTransaction conn'
      pure (ok, before, after, staleCtx, freshCtx, (staleMars, freshMars), rolledBack, stillOpen)
    case results of
      (ok, before, after, staleCtx, freshCtx, (staleMars, freshMars), rolledBack, stillOpen) -> do
        ok `shouldBe` True
        before `shouldBe` False
        after `shouldBe` True
        staleCtx `shouldBe` freshCtx
        staleMars `shouldBe` freshMars
        tdsTransaction staleCtx `shouldSatisfy` (/= Nothing)
        expectReleased "rollback" rolledBack
        stillOpen `shouldBe` True
    mockOutcome outcome >>= (`shouldBe` [Batch "BEGIN TRANSACTION"])

  it "renew makes every earlier handle stale, a renewed one included, with or without a release in between" $ do
    (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $ withConnection ci $ \c0 -> do
      ok <- release c0
      c1 <- renew c0
      c2 <- renew c1
      r1 <- try (query1 c1 "SELECT 1" :: IO (Only Int64))
      r0 <- try (query1 c0 "SELECT 2" :: IO (Only Int64))
      a <- query1 c2 "SELECT 3"
      -- No release: a double borrow's first handle is refused.
      c3 <- renew c2
      r2 <- try (query1 c2 "SELECT 4" :: IO (Only Int64))
      b <- query1 c3 "SELECT 5"
      pure (ok, releasedOr r1, releasedOr r0, a, releasedOr r2, b)
    results `shouldBe` (True, Nothing, Nothing, Only (3 :: Int64), Nothing, Only (5 :: Int64))
    mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 3", Batch "SELECT 5"])

  it "connect's handle works without renew, and can be released" $ do
    (results, outcome) <- withScripted serveRecording $ \ci -> within 30 $
      bracket (connect ci) close $ \conn -> do
        a <- query1 conn "SELECT 1"
        ok <- release conn
        stale <- try (query1 conn "SELECT 2" :: IO (Only Int64))
        pure (a, ok, releasedOr stale)
    results `shouldBe` (Only (1 :: Int64), True, Nothing)
    mockOutcome outcome >>= (`shouldBe` [Batch "SELECT 1"])

  it "a handle both released and broken throws ConnectionReleased, it and its stream, where the renewed handle gets ConnectionBroken" $ do
    let script io = do
          _ <- expectBatch io
          mSendPacket io False (tokenBytes [colMetaBigint "n", rowBigint 1])
          expectAttention io
          -- Returning closes the connection, mid-drain: release fails.
    (results, outcome) <- withScripted script $ \ci -> within 30 $ withConnection ci $ \conn -> do
      s <- queryS conn "SELECT many"
      first :> rest <- S.toList (S.splitAt 1 s)
      ok <- release conn
      conn' <- renewLease conn
      fresh <- try (query1 conn' "SELECT 2" :: IO (Only Int64))
      stale <- try (query1 conn "SELECT 3" :: IO (Only Int64))
      staleStream <- try (S.toList_ rest)
      pure (first, ok, fresh, stale, staleStream)
    case results of
      (first, ok, fresh, stale, staleStream) -> do
        first `shouldBe` [Only (1 :: Int64)]
        ok `shouldBe` False
        case fresh of
          Left (ConnectionBroken _) -> pure ()
          Right r -> expectationFailure ("the renewed handle went on after the connection broke: " ++ show r)
        expectReleased "query1" stale
        expectReleased "the stream" staleStream
    mockOutcome outcome
