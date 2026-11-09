-- | 1000 parameters in a single call, each a large (near the 4000-character
-- non-MAX maximum) @nvarchar@ value: payload *size* at *volume*, as opposed
-- to "Types.ParamMatrixSpec" and "Shapes.ParametersSpec", which push
-- parameter *count* (up to 2098) with small scalar values.
--
-- Uses a plain positional @[SqlParam]@ list (there's a @ToSqlField a =>
-- ToSqlRow [a]@ instance, and 'SqlParam' itself has a 'ToSqlField' instance,
-- so a homogeneous @[SqlParam]@ works directly) rather than 'NamedParams',
-- since there's no need to name 1000 parameters individually -- the row
-- index is spliced into the SQL text as a plain integer literal instead
-- (it's our own loop counter, not untrusted data).
module Scale.ManyParametersSpec (spec) where

import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import TestDb

paramCount :: Int
paramCount = 1000

valueWidth :: Int
valueWidth = 4000

-- | A distinct, exactly-@valueWidth@-character value per index, so a mixup
-- between rows would be caught.
valueFor :: Int -> Text
valueFor i = T.justifyLeft valueWidth 'x' (T.pack (show i) <> "-")

spec :: Spec
spec = around withTestDb $
  describe "1000 large nvarchar(4000) parameters in one call" $
    it "round-trips every value via a temp table" $ \conn -> do
      let values = map valueFor [1 .. paramCount]

      _ <- execute conn "CREATE TABLE #wide (idx int NOT NULL, v nvarchar(4000) NOT NULL)"

      let sql = "INSERT INTO #wide (idx, v) VALUES "
            <> T.intercalate ", " ["(" <> T.pack (show i) <> ", @p" <> T.pack (show i) <> ")" | i <- [1 .. paramCount]]
      n <- execute conn (mkQuery sql [SqlParam v | v <- values])
      n `shouldBe` fromIntegral paramCount

      rows <- query conn "SELECT idx, v FROM #wide ORDER BY idx" :: IO [(Int, Text)]
      length rows `shouldBe` paramCount
      rows `shouldBe` zip [1 .. paramCount] values
