{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An equivalence and round-trip harness for the bulk copy feature
-- ('Hmssql.BulkCopy.bulkInsert'), and a data-loss probe for the
-- truncation policy tests.
--
-- The idea of the equivalence harness ('checkTypeCase'): for a column type
-- and a list of values, load one @#temp@ table with 'bulkInsert' and an
-- identical one with 'executeMany' of the equivalent parameterized
-- @INSERT@, then assert
--
--   1. __round trip__: reading the bulk-loaded table back gives the values
--      that were put in (allowing for a lossless, documented transform such
--      as @char@ padding or @decimal@ scale rounding, carried in each
--      'Cell''s expected value); and
--   2. __equivalence__: the two tables hold the same data, read back
--      value-for-value, and byte-for-byte by @DATALENGTH@.
--
-- Each row carries an explicit @int@ order key @k@ (1, 2, 3, ...) so
-- @ORDER BY k@ is deterministic and the two tables line up cell for cell;
-- reading the column back into a precise Haskell type is byte-faithful
-- (Unicode text to exact code points, single-byte text through the code
-- page, binary to exact bytes, decimal/money/date to exact values), so a
-- value comparison plus a @DATALENGTH@ comparison catches any real
-- divergence between the two load paths, including collation-masked or
-- padding differences that a naive @EXCEPT@ on a CI/AS column would hide.
--
-- __Reuse by the later fuzzing phase.__  A hedgehog property produces a
-- generated value list; wrap each in a 'Cell' (via 'same'\/'into'\/'nullCell'
-- or by hand) and build a 'TypeCase', then call 'checkTypeCase'.  For
-- boundary-shaped properties (PLP chunk / packet size / varchar-nvarchar
-- limit / surrogate pairs) the building blocks 'createPair', 'loadBulk',
-- 'loadBatch', 'readColumn' and 'readDataLengths' compose directly, and
-- 'probeBulk' \/ 'probeBatch' classify a rejection (client 'EncodeError' vs
-- server 'SqlServerError' vs silent store) for the data-loss properties.
-- Everything runs on one connection and only creates @#temp@ tables, so it
-- is safe to call many times per connection (each call makes a fresh
-- uniquely named pair).
module Bulk.Harness
  ( -- * Equivalence + round-trip harness
    TypeCase (..)
  , Cell (..)
  , typeCase
  , typeCaseNoLen
  , same
  , into
  , nullCell
  , nullBinary
  , nullVariant
  , checkTypeCase
  , typeCaseSpec

    -- * Data-loss / truncation policy
  , RejectKind (..)
  , probeBulk
  , probeBatch
  , expectRejected
  , rejected

    -- * Building blocks (reused by the fuzzing phase)
  , Row
  , orderKeyRows
  , createPair
  , createTable
  , loadBulk
  , loadBatch
  , readColumn
  , readDataLengths
  ) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (void, when)
import qualified Data.ByteString as B
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Tuple.Only (fromOnly)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Encoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb (skipBeforeSql2019, uniqueName)

------------------------------------------------------------------------------
-- Cases

-- | A value to insert, paired with what a lossless round trip should read
-- back.  The value is sent as any 'ToSqlField' type ('SqlParam'), so one
-- case's list may mix the Haskell types that all convert to the column
-- (e.g. 'Int32' and 'Bool' into a @bit@ column).
data Cell b = Cell
  { cellInsert :: SqlParam
    -- ^ How the value is sent to the column.
  , cellExpect :: Maybe b
    -- ^ The expected read-back; 'Nothing' is a SQL NULL.
  }

-- | Send a value and expect to read the same value back.
same :: ToSqlField a => a -> Cell a
same a = Cell (SqlParam a) (Just a)

-- | Send a value of one type; expect a (possibly transformed) read-back
-- value, e.g. @"ab" \`into\` "ab    "@ for a @char(6)@ column, or a rounded
-- decimal.
into :: ToSqlField a => a -> b -> Cell b
into a b = Cell (SqlParam a) (Just b)

-- | A SQL NULL for a column the server converts an @nvarchar@ NULL to
-- (everything but the binary types and @sql_variant@).  Bulk copy ignores
-- a NULL's source type; the @nvarchar@ NULL is chosen so the equivalent
-- @executeMany@ @INSERT@ (which does send a typed NULL parameter) is
-- accepted by the column.
nullCell :: Cell b
nullCell = Cell (SqlParam SqlNull) Nothing

-- | A SQL NULL for a @binary@\/@varbinary@\/@image@ column (a @varbinary@
-- NULL; an @nvarchar@ NULL is refused there through @executeMany@).
nullBinary :: Cell b
nullBinary = Cell (SqlParam (Nothing :: Maybe B.ByteString)) Nothing

-- | A SQL NULL for a @sql_variant@ column (a typed @sql_variant@ NULL; an
-- @nvarchar@ NULL is refused there, error 206).
nullVariant :: Cell b
nullVariant = Cell (SqlParam (RawParam (TISqlVariant 8016, Nothing))) Nothing

-- | One column type with the values to exercise it.  Existentially over the
-- read-back type @b@ (all cells of a case share it, since they share a
-- column).
data TypeCase = forall b. (FromSqlField b, Eq b, Show b) => TypeCase
  { tcName :: String
    -- ^ The example's name.
  , tcDdl :: Text
    -- ^ The column type as T-SQL declares it, e.g. @"decimal(10,2)"@ or
    -- @"varchar(50) COLLATE Latin1_General_100_CI_AS_SC_UTF8"@.
  , tcRead :: Text
    -- ^ The @SELECT@ expression that reads the column back (usually @"v"@;
    -- @"CAST(v AS nvarchar(max))"@ for a type the read-back Haskell type
    -- can't decode directly, such as @xml@).
  , tcCheckLen :: Bool
    -- ^ Whether to compare @DATALENGTH@ between the two tables (off for the
    -- few types whose two wire encodings are stored equal but sized
    -- differently, e.g. @sql_variant@).
  , tcCells :: [Cell b]
  }

-- | A case that reads the column back as @v@ and compares @DATALENGTH@.
typeCase :: (FromSqlField b, Eq b, Show b) => String -> Text -> [Cell b] -> TypeCase
typeCase name ddl = TypeCase name ddl "v" True

-- | 'typeCase' without the @DATALENGTH@ comparison.
typeCaseNoLen :: (FromSqlField b, Eq b, Show b) => String -> Text -> [Cell b] -> TypeCase
typeCaseNoLen name ddl = TypeCase name ddl "v" False

-- | An hspec example that runs one 'TypeCase' against the connection.
typeCaseSpec :: TypeCase -> SpecWith Connection
typeCaseSpec tc = utf8 $ it (tcName tc) $ \conn -> checkTypeCase conn tc
  where
    utf8 | "_UTF8" `T.isInfixOf` tcDdl tc = skipBeforeSql2019 "UTF-8 collations"
         | otherwise = id

------------------------------------------------------------------------------
-- The core check

-- | Run a 'TypeCase': load both tables, assert round trip and equivalence.
checkTypeCase :: Connection -> TypeCase -> IO ()
checkTypeCase conn (TypeCase name ddl readExpr checkLen cells) = do
  (tb, te) <- createPair conn ddl
  let rows = orderKeyRows cells
      expected = map cellExpect cells
      n = fromIntegral (length cells) :: Int64
  nb <- loadBulk conn tb rows
  annotate "bulk row count" $ nb `shouldBe` n
  counts <- loadBatch conn te rows
  annotate "executeMany row count" $ sum counts `shouldBe` n
  bulkVals <- readColumn conn readExpr tb
  batchVals <- readColumn conn readExpr te
  annotate "round trip (bulk read-back == input)" $ bulkVals `shouldBe` expected
  annotate "equivalence (bulk read-back == executeMany read-back)" $ batchVals `shouldBe` bulkVals
  when checkLen $ do
    lb <- readDataLengths conn tb
    le <- readDataLengths conn te
    annotate "equivalence (DATALENGTH bulk == executeMany)" $ lb `shouldBe` le
  where
    annotate what act = act `catchLabelled` what
    catchLabelled act what = do
      r <- try act
      case r of
        Right () -> pure ()
        Left (e :: SomeException) ->
          expectationFailure ("[" <> name <> "] " <> what <> ": " <> show e)

------------------------------------------------------------------------------
-- Building blocks

-- | One bulk-copy / @INSERT@ row: the order key and the value.
type Row = [SqlParam]

-- | Number the cells 1, 2, 3, ... into rows @[k, value]@.
orderKeyRows :: [Cell b] -> [Row]
orderKeyRows cells = [[SqlParam (i :: Int32), cellInsert c] | (i, c) <- zip [1 ..] cells]

-- | Create two identical @#temp@ tables @(k int, v <ddl>)@ with fresh
-- unique names, for the bulk load and the @executeMany@ load.
createPair :: Connection -> Text -> IO (Text, Text)
createPair conn ddl = do
  tb <- createTable conn ddl
  te <- createTable conn ddl
  pure (tb, te)

-- | Create one @#temp@ table @(k int NOT NULL, v <ddl> NULL)@ with a fresh
-- unique name.
createTable :: Connection -> Text -> IO Text
createTable conn ddl = do
  suf <- uniqueName "bulk_eq"
  let t = "#" <> suf
  void $ execute conn (rawSql ("CREATE TABLE " <> t <> " (k int NOT NULL, v " <> ddl <> " NULL)"))
  pure t

-- | Load a table with 'bulkInsert' (default 'InsertableColumns': k then v).
loadBulk :: Connection -> Text -> [Row] -> IO Int64
loadBulk = bulkInsert

-- | Load a table with 'executeMany' of the equivalent parameterized
-- @INSERT@.
loadBatch :: Connection -> Text -> [Row] -> IO [Int64]
loadBatch conn t = executeMany conn ("INSERT INTO " <> t <> " (k, v) VALUES (@p1, @p2)")

-- | Read the column back, ordered by the key.
readColumn :: FromSqlField b => Connection -> Text -> Text -> IO [Maybe b]
readColumn conn readExpr t =
  map fromOnly <$> query conn (rawSql ("SELECT " <> readExpr <> " FROM " <> t <> " ORDER BY k"))

-- | Read each row's @DATALENGTH(v)@, ordered by the key (NULL stays NULL).
readDataLengths :: Connection -> Text -> IO [Maybe Int64]
readDataLengths conn t =
  map fromOnly <$> query conn (rawSql ("SELECT DATALENGTH(v) FROM " <> t <> " ORDER BY k"))

------------------------------------------------------------------------------
-- Data-loss / truncation policy

-- | How a load treated a value that does not fit its column.
data RejectKind
  = ClientEncode String
    -- ^ 'EncodeError' on the client: the row was never sent (preferred).
  | ServerReject Int32
    -- ^ 'SqlServerError' with this number: the server refused the row.
  | OtherError String
    -- ^ Some other exception.
  | NotRejected
    -- ^ Stored without error (a data-loss hazard if the value did not fit).
  deriving stock (Show)

-- | Whether the value was rejected one way or the other (not silently
-- stored).
rejected :: RejectKind -> Bool
rejected = \case
  ClientEncode _ -> True
  ServerReject _ -> True
  _ -> False

-- | Bulk-insert one value into a fresh @(k, v <ddl>)@ table and report how
-- it was (or wasn't) rejected, and how many rows ended up stored.
probeBulk :: Connection -> Text -> SqlParam -> IO (RejectKind, Int32)
probeBulk conn ddl v = do
  t <- createTable conn ddl
  r <- try (bulkInsert conn t [[SqlParam (1 :: Int32), v]])
  cnt <- fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t))
  pure (either classify (const NotRejected) r, cnt)

-- | As 'probeBulk', but through 'executeMany' of the equivalent @INSERT@:
-- for comparing the server's behaviour on the two paths.
probeBatch :: Connection -> Text -> SqlParam -> IO (RejectKind, Int32)
probeBatch conn ddl v = do
  t <- createTable conn ddl
  r <- try (loadBatch conn t [[SqlParam (1 :: Int32), v]])
  cnt <- fromOnly <$> query1 conn (rawSql ("SELECT COUNT(*) FROM " <> t))
  pure (either classify (const NotRejected) r, cnt)

classify :: SomeException -> RejectKind
classify e
  | Just (EncodeError m) <- fromException e = ClientEncode m
  | Just se <- fromException e = ServerReject (sqlErrorNumber se)
  | otherwise = OtherError (show e)

-- | Assert that bulk copy rejects a value that does not fit @ddl@ (client
-- 'EncodeError' or server 'SqlServerError') and stores no row.
expectRejected :: Connection -> Text -> SqlParam -> IO ()
expectRejected conn ddl v = do
  (kind, cnt) <- probeBulk conn ddl v
  case kind of
    ClientEncode _ -> pure ()
    ServerReject _ -> pure ()
    NotRejected ->
      expectationFailure ("expected bulk copy into " <> T.unpack ddl <> " to be rejected, but it stored the value")
    OtherError m ->
      expectationFailure ("bulk copy into " <> T.unpack ddl <> " failed with an unexpected exception: " <> m)
  cnt `shouldBe` 0
