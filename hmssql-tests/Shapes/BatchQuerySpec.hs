-- | 'BatchQuery' ("Hmssql.BatchQuery"): several statements in one request,
-- each with its own consumer.  Every consumer against the plain query
-- function it mirrors, a statement's results delimited from its
-- neighbours' (however many result sets and DONE counts each has),
-- unread remainders skipped, the last statement streamed, errors thrown
-- for their statement after the rest ran, batches split into several
-- messages, and misuse refused before anything is sent.
module Shapes.BatchQuerySpec (spec) where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.IORef
import Data.Int (Int32, Int64)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Control.Concurrent.Async (race)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.BatchQuery
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  mars <- runIO testMars
  describe "consumers" $ do
    it "runs no request for a batch of no statements" $ \conn ->
      runBatchQuery conn (pure (3 :: Int)) `shouldReturn` 3

    it "pairs each statement with its result" $ \conn -> do
      makeTable conn
      (n, one, rows, may, ()) <- runBatchQuery conn $ (,,,,)
        <$> batchExecute (insert 1)
        <*> batchQuery1 (mkQuery "SELECT @p1 * 2" (Only (21 :: Int32)))
        <*> batchQuery "SELECT 1 UNION ALL SELECT 2"
        <*> batchQueryMay (mkQuery "SELECT id FROM #em WHERE id = @p1" (Only (99 :: Int32)))
        <*> batchExecute_ (insert 2)
      n `shouldBe` 1
      one `shouldBe` Only (42 :: Int32)
      rows `shouldBe` [Only (1 :: Int32), Only 2]
      may `shouldBe` (Nothing :: Maybe (Only Int32))
      ids `shouldReturnFrom` conn $ [1, 2]

    it "gives every consumer what its plain counterpart gives" $ \conn -> do
      makeTable conn
      void $ executeStatements conn [insert 1, insert 2, insert 3]
      let rowsQ = mkQuery "SELECT id, v FROM #em WHERE id > @p1 ORDER BY id" (Only (1 :: Int32))
          multiQ = "SELECT 1; SELECT 'a', 'b'; UPDATE #em SET v = v WHERE 1 = 0; SELECT 3"
          setsQ = "DECLARE @x int = 1; SELECT 1; SELECT 'two'"
          sets = (,) <$> resultSet <*> resultSet :: ResultSets ([Only Int32], [Only T.Text])
          countQ = "UPDATE #em SET v = v + 1; DELETE FROM #em WHERE id = 0"
          typedMultiQ = "SELECT 1; SELECT 2 WHERE 1 = 0; SELECT 3"
      (a, b, c, d, e, f, g, h) <- runBatchQuery conn $ (,,,,,,,)
        <$> batchQuery rowsQ
        <*> batchQueryWith rowDecoder rowsQ
        <*> batchQueryMWith sqlRowDecoder rowsQ
        <*> batchQueryMulti multiQ
        <*> batchQueryResultSets sets setsQ
        <*> batchExecute countQ
        <*> batchQueryMultiWith (rowDecoder :: RowDecoder (Only Int32)) typedMultiQ
        <*> batchQueryMultiMWith sqlRowDecoder multiQ
      a `shouldBe` [(2 :: Int32, 0 :: Int32), (3, 0)]
      b `shouldBe` a
      map sqlRowValues c `shouldBe` [[SqlInt32 2, SqlInt32 0], [SqlInt32 3, SqlInt32 0]]
      queryMulti conn multiQ `shouldReturn` d
      map (map sqlRowValues . resultRows) d `shouldBe` [[[SqlInt32 1]], [[SqlText "a", SqlText "b"]], [[SqlInt32 3]]]
      queryResultSets sets conn setsQ `shouldReturn` e
      f `shouldBe` 3
      execute conn countQ `shouldReturn` f
      map (map fromOnly . resultRows) g `shouldBe` [[1], [], [3 :: Int32]]
      queryMultiMWith sqlRowDecoder conn multiQ `shouldReturn` h

    it "folds a statement's rows with the connection lock held" $ \conn -> do
      (total, n) <- runBatchQuery conn $ (,)
        <$> batchQueryFold "SELECT TOP 5000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
              (0 :: Int64) (\acc (Only i) -> pure (acc + i))
        <*> batchQuery1 "SELECT 7"
      total `shouldBe` 5000 * 5001 `div` 2
      n `shouldBe` Only (7 :: Int32)

    it "takes a row decoder for one row and for at most one" $ \conn -> do
      let dec = singleField (fieldDecoder :: FieldDecoder Int32)
      (a, b, c) <- runBatchQuery conn $ (,,)
        <$> batchQuery1With dec "SELECT 7"
        <*> batchQueryMayWith dec "SELECT 7"
        <*> batchQueryMayWith dec "SELECT TOP 0 7"
      a `shouldBe` 7
      b `shouldBe` Just 7
      c `shouldBe` Nothing

  describe "statement boundaries" $ do
    it "keeps a statement's several result sets and counts to itself" $ \conn -> do
      makeTable conn
      (first, second, third) <- runBatchQuery conn $ (,,)
        <$> batchQuery "SELECT 1; SELECT 2; SELECT 3"
        <*> batchExecute (mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 0); INSERT INTO #em (id, v) VALUES (@p2, 0); SELECT 9" (4 :: Int32, 5 :: Int32))
        <*> batchQuery "SELECT 'last'"
      first `shouldBe` [Only (1 :: Int32)]
      second `shouldBe` 3
      third `shouldBe` [Only ("last" :: T.Text)]

    it "gives a statement with no result set no rows, and the next its own" $ \conn -> do
      (none, some) <- runBatchQuery conn $ (,)
        <$> batchQuery "DECLARE @x int = 1"
        <*> batchQuery "SELECT 5"
      none `shouldBe` ([] :: [Only Int32])
      some `shouldBe` [Only (5 :: Int32)]

    it "throws UnexpectedResult for a result set the statement doesn't have, having read the batch" $ \conn -> do
      r <- try $ runBatchQuery conn $ (,)
        <$> batchQueryResultSets ((,) <$> resultSet <*> resultSet) "SELECT 1"
        <*> batchQuery "SELECT 2"
      case r of
        Left (UnexpectedResult msg) -> msg `shouldBe` "expected another result set"
        Right (v :: (([Only Int32], [Only Int32]), [Only Int32])) -> expectationFailure ("succeeded with " ++ show v)
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

    it "counts a procedure a statement calls as the statement's" $ \conn -> do
      makeTable conn
      (n, rows) <- runBatchQuery conn $ (,)
        <$> batchExecute "EXEC sp_executesql N'INSERT INTO #em (id, v) VALUES (2, 0); SELECT 1'"
        <*> batchQuery "SELECT id FROM #em"
      n `shouldBe` 2
      rows `shouldBe` [Only (2 :: Int32)]

    it "skips the rows a fold's exception left, and leaves the connection usable" $ \conn -> do
      r <- try $ runBatchQuery conn $ (,)
        <$> batchQueryFold "SELECT TOP 3000 a.name FROM sys.all_columns a CROSS JOIN sys.all_columns b"
              (0 :: Int) (\acc (Only (_ :: T.Text)) -> if acc == 5 then ioError (userError "enough") else pure (acc + 1))
        <*> batchQuery "SELECT 1"
      either (\(e :: IOException) -> show e) (\(_, v :: [Only Int32]) -> show v) r `shouldBe` "user error (enough)"
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

  describe "streaming" $ do
    it "streams the last statement's rows after the batch has returned" $ \conn -> do
      makeTable conn
      (n, s) <- runBatchQuery conn $ (,)
        <$> batchExecute (insert 1)
        <*> batchQueryS "SELECT TOP 10000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b; SELECT 'after'"
      n `shouldBe` 1
      count <- newIORef (0 :: Int)
      S.mapM_ (\(Only (_ :: Int64)) -> modifyIORef' count (+ 1)) s
      readIORef count `shouldReturn` 10000
      -- the second set was drained with the stream
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

    it "streams a result set of zero rows, and one of a statement with none" $ \conn -> do
      s <- runBatchQuery conn (batchQueryS "SELECT TOP 0 1")
      (S.toList_ s :: IO [Only Int32]) `shouldReturn` []
      s' <- runBatchQuery conn ((\_ st -> st) <$> batchExecute "DECLARE @y int = 2" <*> batchQuerySWith rowDecoder "DECLARE @x int = 1")
      (S.toList_ s' :: IO [Only Int32]) `shouldReturn` []
      s'' <- runBatchQuery conn (batchQuerySMWith sqlRowDecoder "SELECT 1; SELECT 2")
      map sqlRowValues <$> S.toList_ s'' `shouldReturn` [[SqlInt32 1]]
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

    it "throws the streaming statement's error from the stream, after the rows before it" $ \conn -> do
      s <- runBatchQuery conn (batchQueryS "SELECT 1 UNION ALL SELECT 2; RAISERROR('later', 16, 1)")
      rows <- newIORef []
      r <- try (S.mapM_ (\(Only (i :: Int32)) -> modifyIORef' rows (i :)) s)
      either sqlErrorMessage (const "") r `shouldBe` "later"
      reverse <$> readIORef rows `shouldReturn` [1, 2]
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

    it "throws an earlier statement's error from runBatchQuery, not the stream" $ \conn -> do
      r <- try $ runBatchQuery conn $ (,)
        <$> batchExecute "RAISERROR('first', 16, 1)"
        <*> batchQueryS "SELECT 1"
      case r of
        Left e -> sqlErrorMessage e `shouldBe` "first"
        Right (_, _ :: S.Stream (S.Of (Only Int32)) IO ()) -> expectationFailure "succeeded"
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)

    -- Under MARS the next request runs beside the stream, which it leaves
    -- alone: the stream reads on to its end.
    it (if mars
          then "leaves a stream that isn't consumed before the next request open, to be read on to its end (MARS)"
          else "abandons a stream that isn't consumed before the next request") $ \conn -> do
      s <- runBatchQuery conn (batchQueryS "SELECT TOP 5000 a.name FROM sys.all_columns a CROSS JOIN sys.all_columns b")
      firstFew S.:> rest <- S.toList (S.splitAt 2 (s :: S.Stream (S.Of (Only T.Text)) IO ()))
      length firstFew `shouldBe` 2
      query1 conn "SELECT 8" `shouldReturn` Only (8 :: Int32)
      if mars
        then S.length_ rest `shouldReturn` 4998
        else do
          r <- try (S.toList_ (S.take 1 (S.drop 2 s)) :: IO [Only T.Text])
          either (\ResultAbandoned -> True) (const False) r `shouldBe` True

    it "refuses a streaming statement that isn't the last, sending nothing" $ \conn -> do
      makeTable conn
      r <- try $ runBatchQuery conn $ (,)
        <$> batchQueryS "SELECT 1"
        <*> batchExecute (insert 1)
      case r of
        Left (EncodeError msg) -> msg `shouldSatisfy` ("statement 0 " `isInfixOf`)
        Right (_ :: S.Stream (S.Of (Only Int32)) IO (), _) -> expectationFailure "succeeded"
      ids `shouldReturnFrom` conn $ []

  describe "errors" $ do
    it "throws the first failing statement's error, with its text, after the rest ran" $ \conn -> do
      makeTable conn
      let dup = mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 1)" (Only (1 :: Int32))
      r <- try $ runBatchQuery conn $ (,,,,)
        <$> batchExecute (insert 1)
        <*> batchQuery1 dup
        <*> batchExecute (insert 2)
        <*> batchExecute "RAISERROR('later', 16, 1)"
        <*> batchExecute (insert 3)
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 2627
          sqlErrorStatement e `shouldBe` Just (queryText dup)
        Right (v :: (Int64, Only Int32, Int64, Int64, Int64)) -> expectationFailure ("succeeded with " ++ show v)
      ids `shouldReturnFrom` conn $ [1, 2, 3]

    it "throws an error that comes after the rows a consumer read" $ \conn -> do
      makeTable conn
      r <- try $ runBatchQuery conn $ (,)
        <$> batchQuery "SELECT 1; RAISERROR('after', 16, 1)"
        <*> batchExecute (insert 1)
      either sqlErrorMessage (\(_ :: [Only Int32], _) -> "") r `shouldBe` "after"
      ids `shouldReturnFrom` conn $ [1]

    it "stops at an error that aborts the batch" $ \conn -> do
      makeTable conn
      r <- try $ runBatchQuery conn $ (,,)
        <$> batchExecute (insert 1)
        <*> batchExecute "THROW 50001, 'boom', 1"
        <*> batchExecute (insert 2)
      either sqlErrorNumber (const 0) r `shouldBe` 50001
      ids `shouldReturnFrom` conn $ [1]

    it "is undone by withTransaction when it throws" $ \conn -> do
      makeTable conn
      r <- try $ withTransaction conn $ runBatchQuery conn $ (,,)
        <$> batchExecute (insert 1)
        <*> batchExecute (insert 1)
        <*> batchExecute (insert 2)
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      ids `shouldReturnFrom` conn $ []

    it "throws EncodeError naming the statement, and sends nothing" $ \conn -> do
      makeTable conn
      r <- try $ runBatchQuery conn $ (,,)
        <$> batchExecute (insert 1)
        <*> batchQuery (mkQuery "SELECT @p1" ())
        <*> batchExecute (insert 2)
      case r of
        Left (EncodeError msg) -> msg `shouldSatisfy` ("statement 1 " `isInfixOf`)
        Right (v :: (Int64, [Only Int32], Int64)) -> expectationFailure ("succeeded with " ++ show v)
      ids `shouldReturnFrom` conn $ []

    it "drains the batch before a decode error is thrown, leaving the connection usable" $ \conn -> do
      makeTable conn
      r <- try $ runBatchQuery conn $ (,)
        <$> batchQuery "SELECT 'text'"
        <*> batchExecute (insert 1)
      case r of
        Left (DecodeError _ _) -> pure ()
        Right (v :: ([Only Int32], Int64)) -> expectationFailure ("succeeded with " ++ show v)
      ids `shouldReturnFrom` conn $ [1]

    it "is cancelled by an interruption, leaving the statements before it run and the connection usable" $ \conn -> withTestDb $ \observer -> do
      makeTable conn
      me <- sessionIdentity conn
      -- Interrupted once the server shows the WAITFOR, as in
      -- "Shapes.ExecuteManySpec".
      r <- race (awaitWaitfor observer me) $ runBatchQuery conn $ (,,)
        <$> batchExecute (insert 1)
        <*> batchExecute "WAITFOR DELAY '00:00:10'"
        <*> batchExecute (insert 2)
      void r `shouldBe` Left ()
      ids `shouldReturnFrom` conn $ [1]
      runBatchQuery conn (batchExecute (insert 3)) `shouldReturn` 1
      ids `shouldReturnFrom` conn $ [1, 3]

  describe "several messages" $ do
    it "sends a long batch in several messages, every statement once, each result its own" $ \conn -> do
      makeTable conn
      let n = 12000 :: Int32
          row :: Int32 -> Query
          row i = mkQuery "INSERT INTO #em (id, s) VALUES (@p1, @p2); SELECT @p1" (i, T.replicate 20 "x")
      results <- runBatchQuery conn $ (,)
        <$> traverse (\i -> batchQuery1 (row i)) [1 .. n]
        <*> batchQuery1 "SELECT COUNT(*) FROM #em"
      fst results `shouldBe` [Only i | i <- [1 .. n]]
      snd results `shouldBe` Only (fromIntegral n :: Int)

    it "goes on to the next message after a statement's error, as within one" $ \conn -> do
      makeTable conn
      let n = 12000 :: Int32
          row :: Int32 -> T.Text -> Query
          row i s = mkQuery "INSERT INTO #em (id, s) VALUES (@p1, @p2)" (i, s)
      r <- try $ runBatchQuery conn $ traverse batchExecute $
        [row i (T.replicate 20 "x") | i <- [1 .. 10]] ++ [row 1 "dup"] ++ [row i (T.replicate 20 "x") | i <- [11 .. n]]
      either sqlErrorNumber (const 0) r `shouldBe` 2627
      query1 conn "SELECT COUNT(*) FROM #em" `shouldReturn` Only (fromIntegral n :: Int)

    it "streams the last statement of a batch of several messages" $ \conn -> do
      makeTable conn
      let n = 12000 :: Int32
      (counts, s) <- runBatchQuery conn $ (,)
        <$> traverse (\i -> batchExecute (mkQuery "INSERT INTO #em (id, s) VALUES (@p1, @p2)" (i, T.replicate 20 "x"))) [1 .. n]
        <*> batchQueryS "SELECT id FROM #em ORDER BY id"
      sum counts `shouldBe` fromIntegral n
      (S.toList_ s :: IO [Only Int32]) `shouldReturn` [Only i | i <- [1 .. n]]
  where
    makeTable conn = void $ execute conn "DROP TABLE IF EXISTS #em; CREATE TABLE #em (id int NOT NULL PRIMARY KEY, v int NOT NULL DEFAULT 0, s nvarchar(50) NULL)"
    insert :: Int32 -> Query
    insert i = mkQuery "INSERT INTO #em (id, v) VALUES (@p1, 0)" (Only i)
    ids conn = map fromOnly <$> query conn "SELECT id FROM #em ORDER BY id"
    shouldReturnFrom :: (Connection -> IO [Int32]) -> Connection -> [Int32] -> Expectation
    shouldReturnFrom act conn expected = act conn `shouldReturn` expected
