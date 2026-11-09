-- | Tests found by mutation testing of "Hmssql.Query" (live server): the
-- rest of a response is read after a decode failure, and output parameters
-- of every string and decimal type are widened.
module Mutation.ResultsSpec (spec) where

import Control.Exception
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Primitives (putDecimal)
import TestDb

-- | The statement after a slow one, in the same batch as a result set that
-- fails to decode, still runs: the failed query reads the whole response
-- instead of leaving the next request to cancel it.  (RAISERROR ... WITH
-- NOWAIT makes the server send the result set before the WAITFOR, so the
-- decode fails while the batch is still running.)
restOfBatchRuns :: (Connection -> Text -> IO ()) -> Connection -> Expectation
restOfBatchRuns failingQuery conn = do
  _ <- execute conn "CREATE TABLE #mutation_drain (i int)"
  failingQuery conn
    "; RAISERROR('', 0, 1) WITH NOWAIT; WAITFOR DELAY '00:00:00.500'; INSERT INTO #mutation_drain VALUES (1)"
  query1 conn "SELECT COUNT(*) FROM #mutation_drain" `shouldReturn` Only (1 :: Int32)

expectDecodeError :: IO a -> IO ()
expectDecodeError act = try act >>= \case
  Left (_ :: DecodeError) -> pure ()
  Right _ -> expectationFailure "expected a DecodeError"

-- | Call a temporary procedure with one output parameter and decode it.
outputOf :: FromSqlField a => Connection -> Text -> ProcParam -> IO a
outputOf conn body p = do
  _ <- execute conn (rawSql ("CREATE PROCEDURE #mutation_out " <> body))
  res <- callProcedure conn "#mutation_out" [p]
  case procOutputValues res of
    [rv] -> either throwIO pure (decodeReturnValue rv)
    rvs -> fail ("expected one output value, got " ++ show rvs)

spec :: Spec
spec = around withTestDb $ do
  describe "after a decode failure, the rest of the batch still runs" $ do
    it "when the result set's columns don't fit the row type" $
      restOfBatchRuns $ \conn rest ->
        expectDecodeError (query conn (rawSql ("SELECT N'x' AS v" <> rest)) :: IO [Only Int32])

    it "when a row's value doesn't fit" $
      restOfBatchRuns $ \conn rest ->
        expectDecodeError (query conn (rawSql ("SELECT 300 AS v" <> rest)) :: IO [Only Word8])

  describe "queryMay" $ do
    it "throws UnexpectedResult for two rows, rather than returning the first" $ \conn -> do
      r <- try (queryMay conn "SELECT 1 UNION ALL SELECT 2" :: IO (Maybe (Only Int32)))
      case r of
        Left (UnexpectedResult _) -> pure ()
        Right v -> expectationFailure ("returned " ++ show v)
    it "with parameters too" $ \conn -> do
      r <- try (queryMay conn (mkQuery "SELECT @p1 UNION ALL SELECT @p1" (Only (3 :: Int32))) :: IO (Maybe (Only Int32)))
      case r of
        Left (UnexpectedResult _) -> pure ()
        Right v -> expectationFailure ("returned " ++ show v)

  describe "output parameters are widened" $ do
    it "varchar(n) to varchar(max)" $ \conn ->
      outputOf conn "@v varchar(max) OUTPUT AS SET @v = REPLICATE('y', 30)"
        (outParam "@v" (RawParam (TIBigVarChar 2 (Collation 0 0), Just "ab")))
        `shouldReturn` T.replicate 30 "y"

    it "numeric(p,s) to numeric(38,10)" $ \conn -> do
      let small = LB.toStrict (Put.runPut (putDecimal 5 2 (1.23 :: Decimal)))
      outputOf conn "@v numeric(20,4) OUTPUT AS SET @v = 1234567.8912"
        (outParam "@v" (RawParam (TINumericN 5 2, Just small)))
        `shouldReturn` (1234567.8912 :: Decimal)
