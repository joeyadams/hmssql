-- | 'executeStatements' and 'executeMany': several statements in one request,
-- each an @sp_executesql@ call in one RPC message.  Counts per statement
-- (the same as 'execute' of each), the first error attributed to its
-- statement after the whole response is read, which statements ran after
-- an error, the scoping of a statement without parameters, requests split
-- into several messages, and interruption.
module Shapes.ExecuteManySpec (spec) where

import Control.Exception (try)
import Control.Monad (void)
import Data.IORef
import Data.Int (Int32, Int64)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Control.Concurrent.Async (race)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Types
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "counts" $ do
    it "returns [] for no statements" $ \conn ->
      executeStatements conn [] `shouldReturn` []

    it "returns each statement's count, in order" $ \conn -> do
      makeTable conn
      counts <- executeStatements conn
        [ insert 1
        , insert 2
        , mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 0); INSERT INTO #em (id, v) VALUES (@p2, 0)" (3 :: Int32, 4 :: Int32)
        , "UPDATE #em SET v = v + 1"
        , mkQuery "DELETE FROM #em WHERE id = @p1" (Only (99 :: Int32))
        ]
      counts `shouldBe` [1, 1, 2, 4, 0]

    it "counts as execute does, statement by statement" $ \conn -> do
      makeTable conn
      let stmts =
            [ insert 1
            , "SELECT 1 UNION ALL SELECT 2"
            , mkQuery "UPDATE #em SET v = @p1" (Only (5 :: Int32))
            , "DECLARE @x int = 1"
            , mkQuery "SELECT id FROM #em WHERE id > @p1; SELECT 1" (Only (0 :: Int32))
            , "SET NOCOUNT ON; INSERT INTO #em (id, v) VALUES (10, 0)"
            ]
      many <- executeStatements conn stmts
      void $ execute conn "DELETE FROM #em"
      one <- mapM (execute conn) stmts
      many `shouldBe` one

    it "reads and drops the rows of a statement's result sets" $ \conn -> do
      makeTable conn
      counts <- executeStatements conn
        [ "SELECT TOP 3000 a.name FROM sys.all_columns a CROSS JOIN sys.all_columns b"
        , insert 1
        ]
      counts `shouldBe` [3000, 1]
      query conn "SELECT id FROM #em" `shouldReturn` [Only (1 :: Int32)]

    it "runs a statement calling a procedure as one statement" $ \conn -> do
      makeTable conn
      counts <- executeStatements conn [insert 1, "EXEC sp_executesql N'INSERT INTO #em (id, v) VALUES (2, 0); SELECT 1'", insert 3]
      counts `shouldBe` [1, 2, 1]

    -- sp_executesql's own two (the text and the declaration) count
    -- towards SQL Server's 2100 per call, but not the other calls'.
    it "sends statements with 2098 parameters each" $ \conn -> do
      let big = mkQuery ("SELECT " <> T.intercalate " + " ["@p" <> T.pack (show i) | i <- [1 .. 2098 :: Int]])
                  [SqlParam (1 :: Int32) | _ <- [1 .. 2098 :: Int]]
      executeStatements conn [big, "SELECT 1", big] `shouldReturn` [1, 1, 1]

  describe "a statement without parameters" $ do
    it "runs through sp_executesql: a SET inside it lasts only until it returns" $ \conn -> do
      void $ executeStatements conn ["SET NOCOUNT ON", "SELECT 1"]
      query1 conn "SELECT CAST(@@OPTIONS & 512 AS int)" `shouldReturn` Only (0 :: Int32)

    it "runs through sp_executesql: a #temp table created inside it is dropped" $ \conn -> do
      void $ executeStatements conn ["CREATE TABLE #gone (i int)", "INSERT INTO #gone VALUES (1)"]
        `shouldThrow` (\e -> sqlErrorNumber e == 208)
      query1 conn "SELECT CAST(CASE WHEN OBJECT_ID('tempdb..#gone') IS NULL THEN 0 ELSE 1 END AS int)"
        `shouldReturn` Only (0 :: Int32)

  describe "errors" $ do
    it "throws the first failing statement's error, with its text, after the rest ran" $ \conn -> do
      makeTable conn
      let dup = mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 1)" (Only (1 :: Int32))
      r <- try (executeStatements conn [insert 1, dup, insert 2, "RAISERROR('later', 16, 1)", insert 3])
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 2627
          sqlErrorStatement e `shouldBe` Just (queryText dup)
        Right cs -> expectationFailure ("succeeded with " ++ show cs)
      ids `shouldReturnFrom` conn $ [1, 2, 3]

    it "stops at an error that aborts the batch" $ \conn -> do
      makeTable conn
      r <- try (executeStatements conn [insert 1, "THROW 50001, 'boom', 1", insert 2])
      either sqlErrorNumber (const 0) r `shouldBe` 50001
      ids `shouldReturnFrom` conn $ [1]

    it "stops at any error under XACT_ABORT, and rolls back the transaction" $ \conn -> do
      makeTable conn
      void $ execute conn "SET XACT_ABORT ON"
      r <- try $ withTransaction conn $ executeStatements conn [insert 1, insert 1, insert 2]
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      ids `shouldReturnFrom` conn $ []
      inTransaction conn `shouldReturn` False
      void $ execute conn "SET XACT_ABORT OFF"

    it "is undone by withTransaction when it throws" $ \conn -> do
      makeTable conn
      r <- try $ withTransaction conn $ executeStatements conn [insert 1, insert 1, insert 2]
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      ids `shouldReturnFrom` conn $ []

    it "throws EncodeError naming the statement, and sends nothing" $ \conn -> do
      makeTable conn
      r <- try (executeStatements conn [insert 1, mkQuery "SELECT @p1" (), insert 2])
      case r of
        Left (EncodeError msg) -> msg `shouldSatisfy` ("statement 1 " `isInfixOf`)
        Right cs -> expectationFailure ("succeeded with " ++ show cs)
      ids `shouldReturnFrom` conn $ []

    it "leaves the connection usable after an error" $ \conn -> do
      void (try (executeStatements conn ["SELECT 1/0", "SELECT 1"]) :: IO (Either SqlServerError [Int64]))
      query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int32)

  describe "several messages" $ do
    it "sends a long list in several messages, every statement once" $ \conn -> do
      makeTable conn
      let n = 12000
      counts <- executeMany conn "INSERT INTO #em (id, s) VALUES (@p1, @p2)"
        [(i, T.replicate 20 "x") | i <- [1 .. n :: Int32]]
      counts `shouldBe` replicate (fromIntegral n) 1
      query1 conn "SELECT COUNT(*), COUNT(DISTINCT id) FROM #em" `shouldReturn` (fromIntegral n :: Int, fromIntegral n :: Int)

    it "goes on to the next message after a statement's error, as within one" $ \conn -> do
      makeTable conn
      let n = 12000
      r <- try $ executeMany conn "INSERT INTO #em (id, s) VALUES (@p1, @p2)"
        ([(i, T.replicate 20 "x") | i <- [1 .. 10]] ++ [(1, "dup")] ++ [(i, T.replicate 20 "x") | i <- [11 .. n :: Int32]])
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      query1 conn "SELECT COUNT(*) FROM #em" `shouldReturn` Only (fromIntegral n :: Int)

    it "sends no further message after one that ended early" $ \conn -> do
      makeTable conn
      let n = 12000
      r <- try $ executeStatements conn
        (insert 1 : "THROW 50001, 'boom', 1" : [mkQuery "INSERT INTO #em (id, s) VALUES (@p1, @p2)" (i, T.replicate 20 "x") | i <- [2 .. n :: Int32]])
      either sqlErrorNumber (const 0) r `shouldBe` 50001
      ids `shouldReturnFrom` conn $ [1]

  describe "executeMany" $ do
    it "runs the statement once per row" $ \conn -> do
      makeTable conn
      executeMany conn "INSERT INTO #em (id, v) VALUES (@p1, @p2)" [(i, i * 10) | i <- [1 .. 5 :: Int32]]
        `shouldReturn` replicate 5 1
      query conn "SELECT id, v FROM #em ORDER BY id" `shouldReturn` [(i, i * 10) | i <- [1 .. 5 :: Int32]]

    it "takes named parameters" $ \conn -> do
      makeTable conn
      executeMany conn "INSERT INTO #em (id, v) VALUES (@id, @v)"
        [NamedParams [("id", SqlParam i), ("v", SqlParam (i + 1))] | i <- [1 .. 3 :: Int32]]
        `shouldReturn` [1, 1, 1]
      query conn "SELECT id, v FROM #em ORDER BY id" `shouldReturn` [(i, i + 1) | i <- [1 .. 3 :: Int32]]

    it "declares each row's parameter types, when they change from row to row" $ \conn -> do
      void $ execute conn "CREATE TABLE #var (id int, x sql_variant)"
      counts <- executeMany conn "INSERT INTO #var (id, x) VALUES (@p1, @p2)"
        [ [SqlParam (1 :: Int32), SqlParam (7 :: Int32)]
        , [SqlParam (2 :: Int32), SqlParam (8 :: Int32)]
        , [SqlParam (3 :: Int32), SqlParam ("text" :: T.Text)]
        , [SqlParam (4 :: Int32), SqlParam (2.5 :: Double)]
        , [SqlParam (5 :: Int32), SqlParam (9 :: Int32)]
        ]
      counts `shouldBe` replicate 5 1
      query conn "SELECT CAST(SQL_VARIANT_PROPERTY(x, 'BaseType') AS nvarchar(20)) FROM #var ORDER BY id"
        `shouldReturn` map Only ["int", "int", "nvarchar", "float", "int" :: T.Text]

    it "returns [] for no rows" $ \conn ->
      executeMany conn "INSERT INTO #nosuch VALUES (@p1)" ([] :: [Only Int]) `shouldReturn` []

  describe "outcomes" $ do
    it "reports each statement's count or error, and doesn't throw" $ \conn -> do
      makeTable conn
      outs <- executeStatementsOutcomes conn [insert 1, insert 1, insert 2, "RAISERROR('later', 16, 1)", "SELECT 1 UNION ALL SELECT 2"]
      map summary outs `shouldBe` [Right 1, Left 2627, Right 1, Left 50000, Right 2]

    it "reports the statements after a batch abort as not run" $ \conn -> do
      makeTable conn
      outs <- executeStatementsOutcomes conn [insert 1, "THROW 50001, 'boom', 1", insert 2, insert 3]
      take 2 (map summary outs) `shouldBe` [Right 1, Left 50001]
      drop 2 outs `shouldBe` [StatementNotRun, StatementNotRun]
      ids `shouldReturnFrom` conn $ [1]

    it "reports the messages after one that ended early as not run" $ \conn -> do
      makeTable conn
      let n = 12000
      outs <- executeManyOutcomes conn "INSERT INTO #em (id, s) VALUES (@p1, @p2)"
        ((1, "one") : (1, "dup") : [(i, T.replicate 20 "x") | i <- [2 .. n :: Int32]])
      length outs `shouldBe` fromIntegral n + 1
      take 2 (map summary outs) `shouldBe` [Right 1, Left 2627]
      all (== StatementDone 1) (drop 2 outs) `shouldBe` True
      void $ execute conn "SET XACT_ABORT ON"
      outs' <- executeManyOutcomes conn "INSERT INTO #em (id, s) VALUES (@p1, @p2)"
        ((n + 1, "new") : (1, "dup") : [(i, T.replicate 20 "x") | i <- [n + 2 .. 2 * n]])
      take 2 (map summary outs') `shouldBe` [Right 1, Left 2627]
      length outs' `shouldBe` fromIntegral n + 1
      all (== StatementNotRun) (drop 2 outs') `shouldBe` True
      void $ execute conn "SET XACT_ABORT OFF"
      query1 conn "SELECT COUNT(*) FROM #em" `shouldReturn` Only (fromIntegral n + 1 :: Int)

    it "tells which rows of an executeMany failed" $ \conn -> do
      makeTable conn
      let rows = [(i, 0) | i <- [1, 2, 3, 2, 5, 1 :: Int32]] :: [(Int32, Int32)]
      outs <- executeManyOutcomes conn "INSERT INTO #em (id, v) VALUES (@p1, @p2)" rows
      [i | (i, StatementFailed _) <- zip [0 :: Int ..] outs] `shouldBe` [3, 5]

    it "throws EncodeError as executeStatements does" $ \conn -> do
      r <- try (executeStatementsOutcomes conn [mkQuery "SELECT @p1" ()])
      case r of
        Left (EncodeError _) -> pure ()
        Right outs -> expectationFailure ("succeeded with " ++ show outs)

  describe "info messages and interruption" $ do
    it "passes each statement's info messages to the callback" $ \_ -> do
      msgs <- newIORef []
      ci <- defaultTestConnectInfo
      withConnection ci { connectOnInfoMessage = \m -> modifyIORef' msgs (msgText m :) } $ \conn -> do
        writeIORef msgs []
        executeStatements conn ["PRINT 'one'", "SELECT 1", "PRINT 'two'"] `shouldReturn` [0, 1, 0]
      reverse <$> readIORef msgs `shouldReturn` ["one", "two"]

    it "is cancelled by an interruption, leaving the statements before it run and the connection usable" $ \conn -> withTestDb $ \observer -> do
      makeTable conn
      me <- sessionIdentity conn
      -- Interrupted once the server shows the WAITFOR.  A timeout of 300 ms
      -- from the start fired, in a busy run, before the first statement
      -- had run.
      r <- race (awaitWaitfor observer me) (executeStatements conn [insert 1, "WAITFOR DELAY '00:00:10'", insert 2])
      r `shouldBe` Left ()
      ids `shouldReturnFrom` conn $ [1]
      executeStatements conn [insert 3] `shouldReturn` [1]
      ids `shouldReturnFrom` conn $ [1, 3]
  where
    makeTable conn = void $ execute conn "DROP TABLE IF EXISTS #em; CREATE TABLE #em (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, s nvarchar(50) NULL)"
    insert :: Int32 -> Query
    insert i = mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 0)" (Only i)
    ids conn = map fromOnly <$> query conn "SELECT id FROM #em ORDER BY id"
    summary = \case
      StatementDone c -> Right c
      StatementFailed e -> Left (msgNumber e)
      StatementNotRun -> Left 0
    shouldReturnFrom :: (Connection -> IO [Int32]) -> Connection -> [Int32] -> Expectation
    shouldReturnFrom act conn expected = act conn `shouldReturn` expected

