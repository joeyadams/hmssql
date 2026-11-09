-- | A row at (or right at the edge of) SQL Server's 8060-byte in-row size
-- limit for fixed/variable-length columns, plus several LOB columns holding
-- substantial off-row data in the same row.
--
-- SQL Server does *not* hard-error when a table's declared or actual
-- variable-length row size exceeds 8060 bytes: variable-length columns that
-- don't fit are transparently pushed to ROW_OVERFLOW_DATA pages. Probed
-- empirically against the test server (via sqlcmd) before writing this:
-- creating and inserting into a table with @varchar(4000) + varchar(4000) +
-- varchar(100)@ (8100 declared/actual bytes, over the 8060 limit) succeeded
-- with no error and no visible warning message from this SQL Server 2025
-- build. LOB columns (@varchar(max)@\/@nvarchar(max)@\/@varbinary(max)@) are
-- always stored (mostly) off-row regardless and don't count against the 8060
-- figure at all.
module Scale.MaxRowSizeSpec (spec) where

import Control.Exception (finally)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import TestDb

fixtureName :: Text
fixtureName = "scale_maxrowsize"

tableName :: Text
tableName = "dbo.scale_maxrowsize_fixture"

-- | id (int, 4 bytes fixed) + a (varchar(4000)) + b (varchar(4000)) +
-- c (varchar(56)) = 4 + 4000 + 4000 + 56 = 8060 bytes: exactly at the in-row
-- limit for fixed/variable-length columns, with three LOB columns besides.
fixture :: [Text]
fixture =
  [ "DROP TABLE IF EXISTS " <> tableName
  , "CREATE TABLE " <> tableName <> " \
    \  ( id int IDENTITY(1,1) NOT NULL PRIMARY KEY \
    \  , a varchar(4000) NOT NULL \
    \  , b varchar(4000) NOT NULL \
    \  , c varchar(56) NOT NULL \
    \  , lob1 varchar(max) NULL \
    \  , lob2 nvarchar(max) NULL \
    \  , lob3 varbinary(max) NULL \
    \  )"
  ]

-- | An ASCII pattern of exactly @n@ characters (safe to round-trip through a
-- single-byte @varchar@ column, unlike arbitrary Unicode).
asciiPattern :: Int -> Text
asciiPattern n = T.take n (T.replicate (n `div` T.length base + 1) base)
  where base = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

-- | A Unicode (but BMP-only, so each 'Char' is exactly 2 bytes in
-- nvarchar's UTF-16LE wire encoding, keeping the DATALENGTH arithmetic
-- below simple) pattern for the @nvarchar(max)@ column. Non-BMP
-- (surrogate-pair) round-tripping is already covered by
-- "Shapes.BatchesSpec".
unicodePattern :: Int -> Text
unicodePattern n = T.take n (T.replicate (n `div` T.length base + 1) base)
  where base = "aábeéiíoóuúñÑ日本語"

binaryPattern :: Int -> B.ByteString
binaryPattern n = B.take n (B.concat (replicate (n `div` B.length base + 1) base))
  where base = B.pack [0 .. 255]

spec :: Spec
spec = withFixture fixtureName fixture $ around withTestDb $
  describe "a row at the 8060-byte in-row size limit, with large LOB columns" $
    it "round-trips every column exactly" $ \conn -> do
      let a = asciiPattern 4000
          b = asciiPattern 4000
          c = asciiPattern 56
          lob1 = asciiPattern 2000000 -- varchar(max)
          lob2 = unicodePattern 1000000 -- nvarchar(max)
          lob3 = binaryPattern 3000000 -- varbinary(max)

      Only (newId :: Int) <- query1 conn $ mkQuery
        ( "INSERT INTO " <> tableName <> " (a, b, c, lob1, lob2, lob3) \
          \OUTPUT INSERTED.id VALUES (@p1, @p2, @p3, @p4, @p5, @p6)" )
        (a, b, c, lob1, lob2, lob3)

      flip finally (execute conn (mkQuery ("DELETE FROM " <> tableName <> " WHERE id = @p1") (Only newId))) $ do
        -- DATALENGTH sanity check: exactly the declared in-row byte budget
        -- for the non-LOB columns, plus the LOB payload sizes.
        lens <- query1 conn $ mkQuery
          ( "SELECT DATALENGTH(a), DATALENGTH(b), DATALENGTH(c), \
            \DATALENGTH(lob1), DATALENGTH(lob2), DATALENGTH(lob3) \
            \FROM " <> tableName <> " WHERE id = @p1" )
          (Only newId)
        (lens :: (Int64, Int64, Int64, Int64, Int64, Int64)) `shouldBe` (4000, 4000, 56, 2000000, 2000000, 3000000)

        row <- query1 conn $ mkQuery
          ( "SELECT a, b, c, lob1, lob2, lob3 FROM " <> tableName <> " WHERE id = @p1" )
          (Only newId)
        (row :: (Text, Text, Text, Text, Text, B.ByteString)) `shouldBe` (a, b, c, lob1, lob2, lob3)
