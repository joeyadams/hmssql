-- | 'Money' is a 'Data.Fixed.Fixed' with 4 decimal places, which is
-- unbounded, but @money@ is a signed 64-bit count of 1\/10000ths
-- ([MS-TDS] 2.2.5.5.1.4: -922,337,203,685,477.5808 through
-- 922,337,203,685,477.5807) and @smallmoney@ a signed 32-bit one.  A value
-- outside the range must be refused, not sent modulo 2^64 (which turns the
-- maximum plus 0.0001 into the minimum).
module Wire.MoneyRangeSpec (spec) where

import Control.Exception (ErrorCall, SomeException, evaluate, fromException, try)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft, isRight)
import Data.Fixed (Fixed (..))
import Data.Maybe (isJust)
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Encoding (RowEncoder (..))
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives (putMoney4, putMoney8)
import TestDb

moneyOf :: Integer -> Money
moneyOf = Money . MkFixed

maxMoney, minMoney :: Integer
maxMoney = 9223372036854775807
minMoney = -9223372036854775808

encoded :: Put.Put -> IO (Either ErrorCall Int)
encoded p = try (evaluate (fromIntegral (LB.length (Put.runPut p))))

isEncodeError :: Either SomeException a -> Bool
isEncodeError = \case
  Left e -> isJust (fromException e :: Maybe EncodeError)
  Right _ -> False

spec :: Spec
spec = do
  describe "encoding (pure)" $ do
    it "putMoney8 refuses values outside the 64-bit range instead of wrapping" $ do
      encoded (putMoney8 (moneyOf (maxMoney + 1))) >>= (`shouldSatisfy` isLeft)
      encoded (putMoney8 (moneyOf (minMoney - 1))) >>= (`shouldSatisfy` isLeft)
      encoded (putMoney8 (moneyOf maxMoney)) >>= (`shouldSatisfy` isRight)
      encoded (putMoney8 (moneyOf minMoney)) >>= (`shouldSatisfy` isRight)
    it "putMoney4 refuses values outside the 32-bit range instead of wrapping" $ do
      encoded (putMoney4 (moneyOf 2147483648)) >>= (`shouldSatisfy` isLeft)
      encoded (putMoney4 (moneyOf (-2147483649))) >>= (`shouldSatisfy` isLeft)
      encoded (putMoney4 (moneyOf 2147483647)) >>= (`shouldSatisfy` isRight)
    it "the Money parameter encoder reports the range" $ do
      let enc v = case encodeParams (rowEncoder @(Only Money)) v of
            [(_, f)] -> f defaultTdsContext
            ps -> error ("expected one parameter, got " ++ show (length ps))
      enc (Only (moneyOf (maxMoney + 1))) `shouldSatisfy` isLeft
      enc (Only (moneyOf maxMoney)) `shouldSatisfy` isRight

  describe "against the server" $ around withTestDb $ do
    it "a Money parameter one unit above the maximum is an EncodeError, not the minimum" $ \conn -> do
      r <- try (query conn ("SELECT " <> param (moneyOf (maxMoney + 1))) :: IO [Only Money])
      r `shouldSatisfy` isEncodeError
      query conn ("SELECT " <> param (moneyOf maxMoney)) `shouldReturn` [Only (moneyOf maxMoney)]

    it "one unit below the minimum too, and through SqlValue" $ \conn -> do
      r1 <- try (query conn ("SELECT " <> param (moneyOf (minMoney - 1))) :: IO [Only Money])
      r1 `shouldSatisfy` isEncodeError
      r2 <- try (query conn ("SELECT " <> param (SqlMoney (moneyOf (2 ^ (70 :: Int))))) :: IO [Only Money])
      r2 `shouldSatisfy` isEncodeError
      query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]
