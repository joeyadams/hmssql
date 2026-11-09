-- Source collation is observable sql_variant metadata. Schema changes must
-- not be hidden by reading only the Unicode value or SQL string equality.
module Bulk.CollationContextSpec (spec) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import TestDb

spec :: Spec
spec = skipOnAzure "owned database collation probe" $
    it "compares ordinary and bulk source collation after a default change" $
        withScratchDatabase "variant_context" $ \ci -> withConnection ci $ \conn ->
            forM_ ["Greek_CI_AS", "SQL_Latin1_General_CP850_CI_AS"] $ \coll -> do
                void $ execute conn (rawSql ("ALTER DATABASE CURRENT COLLATE " <> coll))
                void $ execute conn "CREATE TABLE dbo.vctx(id int,v sql_variant)"
                void $ execute conn (mkQuery "INSERT dbo.vctx VALUES(1,@p1)" (Only ("Ωé  " :: Text)))
                bulkInsert conn "dbo.vctx" [(2 :: Int, "Ωé  " :: Text)] `shouldReturn` 1
                actual <- query conn "SELECT id,CONVERT(nvarchar(128),SQL_VARIANT_PROPERTY(v,'Collation')),CONVERT(nvarchar(40),v) FROM dbo.vctx ORDER BY id" :: IO [(Int, Text, Text)]
                actual `shouldBe` [(1, coll, "Ωé  "), (2, coll, "Ωé  ")]
                void $ execute conn "DROP TABLE dbo.vctx"
