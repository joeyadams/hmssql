-- | Tests found by mutation testing of "Hmssql.Encoding": the SQL types
-- parameters are declared with, where a value round trip doesn't show them.
module Mutation.EncodingSpec (spec) where

import Data.Decimal (Decimal)
import Test.Hspec

import Hmssql
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "NULL parameters" $ do
    it "a NULL Decimal is declared decimal(38,10), so ISNULL keeps 10 decimal places" $ \conn ->
      query1 conn ("SELECT ISNULL(" <> param (Nothing :: Maybe Decimal) <> ", 1234567890123.0123456789)")
        `shouldReturn` Only (1234567890123.0123456789 :: Decimal)
