-- | Volume on top of the existing 4096-column boundary test.
--
-- "Shapes.BatchesSpec" already checks that 1024, 4096 (the maximum a
-- @SELECT@ list can produce), and 4097 (a clean server error) columns work,
-- but only with a single row. This adds volume: 4096 columns times 1000
-- rows in one result set, decoded dynamically (a static row type can't have
-- 4096 fields).
module Scale.WideResultSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import TestDb

numCols :: Int
numCols = 4096

numRows :: Int
numRows = 1000

-- | A CTE of @numRows@ sequential numbers (from a self cross join of
-- @sys.all_columns@, comfortably larger than 1000 rows), then @numCols@
-- columns computed from that number, so every cell has a known, distinct,
-- cheaply-checkable value without needing a physical 4096-column table
-- (regular tables cap at 1024 columns).
wideQuery :: Text
wideQuery =
  "WITH nums AS ( \
  \  SELECT TOP " <> T.pack (show numRows) <> " \
  \    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n \
  \  FROM sys.all_columns x CROSS JOIN sys.all_columns y \
  \) \
  \SELECT " <> T.intercalate ", " [colExpr i | i <- [1 .. numCols]] <> " \
  \FROM nums ORDER BY n"
  where
    colExpr i = "n + " <> T.pack (show (i - 1 :: Int)) <> " AS c" <> T.pack (show i)

-- | A name of 128 characters (the most a column name can have) ending in
-- the column's number.
longName :: Int -> Text
longName i = T.justifyRight 128 'n' (T.pack (show i))

spec :: Spec
spec = around withTestDb $ do
  -- The COLMETADATA is about 1.1 MB: per column 6 bytes, an nvarchar's
  -- type info of 8 and a name of 257.  The largest token other than a row
  -- that SQL Server sends, well under what hmssql holds of one
  -- ('Hmssql.Tds.Token.tokenSizeLimit').
  describe "4096 columns with names of 128 characters" $
    it "are all read, with their names" $ \conn -> do
      let sql = "SELECT " <> T.intercalate ", "
            [ "CAST(N'v" <> T.pack (show i) <> "' AS nvarchar(4000)) AS [" <> longName i <> "]" | i <- [1 .. numCols] ]
      [ResultSet cols rows] <- queryMulti conn (rawSql sql)
      map columnName cols `shouldBe` map longName [1 .. numCols]
      map sqlRowValues rows `shouldBe` [[SqlText ("v" <> T.pack (show i)) | i <- [1 .. numCols]]]

  describe "4096 columns x 1000 rows" $
    -- Materializing (rather than streaming) is the natural choice here: the
    -- whole point is to check that a wide *and* deep result set decodes
    -- correctly as a unit, and 4096 * 1000 = ~4.1M bigint cells is a modest
    -- amount of data (a few tens of MB), so there's no memory-pressure
    -- reason to stream it.
    it "decodes every cell correctly" $ \conn -> do
      [ResultSet cols rows] <- queryMulti conn (rawSql wideQuery)
      length cols `shouldBe` numCols
      map columnName cols `shouldBe` ["c" <> T.pack (show i) | i <- [1 .. numCols]]
      length rows `shouldBe` numRows

      let expectedRow :: Int -> [SqlValue]
          expectedRow n = [SqlInt64 (fromIntegral (n + i - 1)) | i <- [1 .. numCols]]

      -- Spot-check the first row, the last row, and a row in the middle,
      -- rather than every one of the 4.1M cells.
      map sqlRowValues [rows !! 0] `shouldBe` [expectedRow 1]
      map sqlRowValues [rows !! (numRows `div` 2)] `shouldBe` [expectedRow (numRows `div` 2 + 1)]
      map sqlRowValues [last rows] `shouldBe` [expectedRow numRows]

      -- but do check every row has exactly the right width
      map (length . sqlRowValues) rows `shouldBe` replicate numRows numCols
