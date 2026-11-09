-- | One SNAPSHOT transaction shared by the sessions of a MARS connection
-- (docs/dev/mars-research.md A33), through the public API: a parent stream and child
-- streams open together inside 'withTransactionLevel' 'Snapshot' read one
-- consistent state while other connections commit changes, and the
-- snapshot is taken at the transaction's first read of a user table, not
-- at the begin.
--
-- The invariant: each parent row carries the count and the sum of its
-- children's values; the writers keep it true, each change in a
-- transaction of its own.  A reader that mixed two states would see a
-- parent disagree with its children.
--
-- Nothing here depends on how fast the writers commit beside the reader:
-- each read waits, with the parents in hand and the children not yet asked
-- for, until a change has been made and committed.  A commit waits for
-- the server's disk, which a read doesn't, and where a log flush takes
-- 5 ms a reader left to itself is through 30 runs in the time of 14
-- commits.
module MarsTx.SnapshotSpec (spec) where

import Control.Concurrent.Async (forConcurrently_, wait, waitCatchSTM, withAsync)
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, join, unless, void, when)
import Data.Int (Int64)
import Data.IORef
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Errors
import MarsTx.Harness
import TestDb

-- | The parents the writers change: 1 .. 'parents'.
parents :: Int
parents = 20

-- | A parent no writer touches.
quietParent :: Int
quietParent = 1000

-- | The parent table and the child table, in a schema of the run's own:
-- concurrent runs share the companion database.
data Tables = Tables Text Text

tablesIn :: Text -> Tables
tablesIn s = Tables (s <> ".parent") (s <> ".child")

-- | Schema @s@ in the companion database, which allows SNAPSHOT isolation,
-- with the tables seeded: each parent with 20 children, and its count and
-- sum.
withZipSchema :: Text -> (ConnectInfo -> IO ()) -> IO ()
withZipSchema s act = do
  ci <- companionConnectInfo
  let Tables parent child = tablesIn s
  withSchema ci s $ do
    withConnection ci $ \conn ->
      void $ execute conn $ rawSql $
        "CREATE TABLE " <> parent <> " (id int PRIMARY KEY, n int NOT NULL, total bigint NOT NULL); \
        \CREATE TABLE " <> child <> " (id int IDENTITY PRIMARY KEY, parent_id int NOT NULL, v int NOT NULL); \
        \CREATE INDEX child_parent ON " <> child <> " (parent_id); \
        \INSERT INTO " <> child <> " (parent_id, v) \
        \  SELECT p.id, p.id * 100 + c.k FROM \
        \    (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS id FROM sys.all_columns) AS p \
        \    CROSS JOIN (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_columns) AS c; \
        \INSERT INTO " <> child <> " (parent_id, v) VALUES (1000, 7); \
        \INSERT INTO " <> parent <> " (id, n, total) \
        \  SELECT parent_id, COUNT(*), SUM(CAST(v AS bigint)) FROM " <> child <> " GROUP BY parent_id"
    act ci

-- | A change that keeps the invariant, in one batch: add a child with a
-- value, remove a parent's oldest child, or move it to another parent.
change :: Tables -> Int -> Int -> Int -> Query
change (Tables parent child) op p q = case op `mod` 3 of
  0 -> mkQuery
    ( "INSERT INTO " <> child <> " (parent_id, v) VALUES (@p1, @p2); \
      \UPDATE " <> parent <> " SET n = n + 1, total = total + @p2 WHERE id = @p1" ) (p, q * 7 + 1)
  1 -> mkQuery
    ( "DECLARE @c int, @v int; \
      \SELECT TOP (1) @c = id, @v = v FROM " <> child <> " WITH (UPDLOCK) WHERE parent_id = @p1 ORDER BY id; \
      \IF @c IS NOT NULL BEGIN \
      \  DELETE FROM " <> child <> " WHERE id = @c; \
      \  UPDATE " <> parent <> " SET n = n - 1, total = total - @v WHERE id = @p1 END" ) (Only p)
  _ -> mkQuery
    ( "DECLARE @c int, @v int; \
      \SELECT TOP (1) @c = id, @v = v FROM " <> child <> " WITH (UPDLOCK) WHERE parent_id = @p1 ORDER BY id; \
      \IF @c IS NOT NULL BEGIN \
      \  UPDATE " <> child <> " SET parent_id = @p2 WHERE id = @c; \
      \  UPDATE " <> parent <> " SET n = n - 1, total = total - @v WHERE id = @p1; \
      \  UPDATE " <> parent <> " SET n = n + 1, total = total + @v WHERE id = @p2 END" ) (p, q)

-- | Commit changes to parents 1 .. 'parents' until told to stop, counting
-- the commits.  A deadlock with the other writer (1205) loses a change,
-- which is rolled back whole.
writer :: ConnectInfo -> Tables -> Int -> IORef Bool -> TVar Int -> IO ()
writer ci ts seed stop commits = withConnection ci $ \conn -> do
  rng <- newIORef seed
  let next = atomicModifyIORef' rng (\x -> let x' = (x * 1103515245 + 12345) `mod` 2147483648 in (x', x' `div` 65536))
      loop = do
        done <- readIORef stop
        unless done $ do
          op <- next
          p <- (+ 1) . (`mod` parents) <$> next
          q <- (+ 1) . (`mod` parents) <$> next
          r <- try (withTransaction conn (void (execute conn (change ts op p (if q == p then q `mod` parents + 1 else q)))))
          case r of
            Right () -> atomically (modifyTVar' commits (+ 1))
            Left (e :: SqlServerError) | sqlErrorNumber e == 1205 -> pure ()
                                       | otherwise -> throwIO e
          loop
  loop

-- | Run the action with two writers committing meanwhile.  The action is
-- given a wait for a change made and committed entirely within the wait:
-- of three commits by two writers, one writer made two, and it began the
-- second after the first.
withWriters :: ConnectInfo -> Tables -> (IO () -> IO a) -> IO a
withWriters ci ts act = do
  stop <- newIORef False
  commits <- newTVarIO 0
  withAsync (forConcurrently_ [1, 2] $ \seed -> writer ci ts seed stop commits) $ \writers -> do
    let awaitChange = do
          n <- readTVarIO commits
          join $ atomically $
            (readTVar commits >>= \m -> check (m >= n + 3) >> pure (pure ()))
              `orElse` (either throwIO (\() -> fail "the writers stopped") <$> waitCatchSTM writers)
    -- Let the writers start (or report why they didn't).
    awaitChange
    a <- act awaitChange `finally` writeIORef stop True
    wait writers
    pure a

type Parent = (Int, Int, Int64)

-- | The stream, with its first row read and the action then run.  The
-- parents fit in one packet, so with the first in hand the server has read
-- them all, and what the action waits for comes after.
afterFirst :: IO () -> Stream (Of a) IO () -> IO (Stream (Of a) IO ())
afterFirst between s = do
  first <- S.next s
  between
  pure (either pure (\(a, rest) -> S.yield a >> rest) first)

-- | Parents whose count or sum disagrees with their children, read by a
-- parent stream zipped with one stream of every child ordered by parent.
-- The action runs with the parents read and before the child stream is
-- opened.
zipInconsistencies :: Tables -> Connection -> IO () -> IO Int
zipInconsistencies (Tables parent child) conn between =
  withQueryS conn (rawSql ("SELECT id, n, total FROM " <> parent <> " ORDER BY id")) $ \ps0 -> do
    ps <- afterFirst between ps0
    withQueryS conn (rawSql ("SELECT parent_id, v FROM " <> child <> " ORDER BY parent_id")) $ \cs -> do
      bad <- newIORef 0
      let go :: Stream (Of Parent) IO () -> Stream (Of (Int, Int)) IO () -> IO ()
          go pstream cstream = S.next pstream >>= \case
            Left () -> pure ()
            Right ((pid, n, total), prest) -> do
              ((k, s), crest) <- childrenOf pid cstream (0, 0)
              when (k /= n || s /= total) $ modifyIORef' bad (+ 1)
              go prest crest
          childrenOf pid cstream acc@(k, s) = S.next cstream >>= \case
            Left () -> pure (acc, pure ())
            Right ((cp, v), crest)
              | cp == pid -> childrenOf pid crest (k + 1, s + fromIntegral v)
              | otherwise -> pure (acc, S.yield (cp, v) >> crest)
      go ps cs
      readIORef bad

-- | The same, with a child stream per parent, each opened while the
-- parent stream is open.
nestedInconsistencies :: Tables -> Connection -> IO () -> IO Int
nestedInconsistencies (Tables parent child) conn between =
  withQueryS conn (rawSql ("SELECT id, n, total FROM " <> parent <> " ORDER BY id")) $ \ps0 -> do
    ps <- afterFirst between ps0
    bad <- newIORef 0
    flip S.mapM_ (ps :: Stream (Of Parent) IO ()) $ \(pid, n, total) ->
      withQueryS conn (mkQuery ("SELECT v FROM " <> child <> " WHERE parent_id = @p1") (Only pid)) $ \cs -> do
        vs <- map fromOnly <$> S.toList_ (cs :: Stream (Of (Only Int)) IO ())
        when (length vs /= n || sum (map fromIntegral vs) /= (total :: Int64)) $ modifyIORef' bad (+ (1 :: Int))
    readIORef bad

-- | Serial: each test's writers would change what another test checks.  The
-- run's schema is named while the tree is built, so that the tests can name
-- its tables.
spec :: Spec
spec = runIO (uniqueName "marstx_snap") >>= \s -> aroundAll (withZipSchema s) $ serial $ do
  let ts = tablesIn s
      Tables parent child = ts
  describe "A33: one SNAPSHOT transaction is shared by every session" $ do
    it "parent and child streams open together read one consistent state while two other connections commit changes: no inconsistency in 30 runs" $ \ci -> withMarsConnTo ci $ \conn -> do
      counts <- withWriters ci ts $ \awaitChange ->
        forM [1 .. 30 :: Int] $ \_ -> withTransactionLevel Snapshot conn $
          (,) <$> zipInconsistencies ts conn awaitChange <*> nestedInconsistencies ts conn awaitChange
      counts `shouldBe` replicate 30 (0, 0)
      -- And the writers kept the invariant (read with nobody writing).
      zipInconsistencies ts conn (pure ()) `shouldReturn` 0

    -- The checker's power: the same reads at READ UNCOMMITTED mix states,
    -- every one of them, since a change is committed between a read's
    -- parents and its children.
    it "control: the same reads at READ UNCOMMITTED see inconsistencies, each of them" $ \ci -> withMarsConnTo ci $ \conn -> do
      counts <- withWriters ci ts $ \awaitChange ->
        forM [1 .. 10 :: Int] $ \_ -> withTransactionLevel ReadUncommitted conn $
          (,) <$> zipInconsistencies ts conn awaitChange <*> nestedInconsistencies ts conn awaitChange
      counts `shouldSatisfy` all (\(z, nested) -> z > 0 && nested > 0)

    it "the snapshot is taken at the first read of a user table, not at the begin; a session opened later reads the same snapshot" $ \ci -> withMarsConnTo ci $ \conn -> withConnection ci $ \other -> do
      let bump = void $ withTransaction other $ execute other $
            mkQuery ("INSERT INTO " <> child <> " (parent_id, v) VALUES (@p1, 1); \
                     \UPDATE " <> parent <> " SET n = n + 1, total = total + 1 WHERE id = @p1") (Only quietParent)
          countOf :: IO Int
          countOf = fromOnly <$> query1 conn (mkQuery ("SELECT n FROM " <> parent <> " WHERE id = @p1") (Only quietParent))
      before <- countOf
      withTransactionLevel Snapshot conn $ do
        -- Not a user table: no snapshot yet.
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
        bump
        -- The first user-table read takes it: the change is seen.  Its
        -- row is read before the next change, so the statement has run;
        -- its end is not, so its session stays busy.
        withQueryS conn (mkQuery ("SELECT n FROM " <> parent <> " WHERE id = @p1") (Only quietParent)) $ \s1 -> do
          Right (first, _) <- S.next s1
          first `shouldBe` Only (before + 1)
          bump
          -- A stream opened now, on another session, reads the same
          -- snapshot: the second change is not seen.
          withQueryS conn (mkQuery ("SELECT COUNT(*) FROM " <> child <> " WHERE parent_id = @p1") (Only quietParent)) $ \s2 -> do
            busySids conn `shouldReturn` [0, 1]
            S.toList_ s2 `shouldReturn` [Only (before + 1)]
        countOf `shouldReturn` (before + 1)
      countOf `shouldReturn` (before + 2)
