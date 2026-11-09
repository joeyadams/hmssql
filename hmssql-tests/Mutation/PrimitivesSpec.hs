-- | Tests found by mutation testing of "Hmssql.Tds.Primitives": behaviour
-- that no other test pinned down.
module Mutation.PrimitivesSpec (spec) where

import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Tds.Primitives (putDecimal)
import TestDb

runPut :: Put.Put -> B.ByteString
runPut = LB.toStrict . Put.runPut

spec :: Spec
spec = do
  describe "putDecimal" $ do
    -- [MS-TDS] 2.2.5.5.1.3: the sign byte is 1 for positive, 0 for negative;
    -- zero is not negative.
    it "writes zero with the positive sign byte" $ do
      B.take 1 (runPut (putDecimal 5 0 0)) `shouldBe` B.singleton 1
      B.take 1 (runPut (putDecimal 10 2 (Decimal 2 0 :: Decimal))) `shouldBe` B.singleton 1
    it "writes a value that rounds to zero with the positive sign byte" $
      B.take 1 (runPut (putDecimal 5 0 (Decimal 1 4 :: Decimal))) `shouldBe` B.singleton 1

  around withTestDb $ do
    it "a zero Decimal parameter is zero, not negative zero, to the server" $ \conn -> do
      r <- query conn $ mkQuery
        "SELECT CAST(@p1 AS varchar(50)), CAST(@p2 AS varchar(50)), SIGN(@p1), CASE WHEN @p2 < 0 THEN 1 ELSE 0 END"
        (0 :: Decimal, Decimal 3 0 :: Decimal)
      r `shouldBe` [("0" :: Text, "0.000" :: Text, 0 :: Decimal, 0 :: Int)]
