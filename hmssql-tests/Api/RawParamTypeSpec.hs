-- | A hand-built parameter type ('RawParam', or a 'ProcParam' constructed
-- directly) with a precision or scale SQL Server doesn't have: a
-- @decimal@\/@numeric@ precision outside 1 through 38 or a scale above the
-- precision ([MS-TDS] 2.2.5.5.1.3), or a @time@\/@datetime2@\/
-- @datetimeoffset@ scale above 7 (2.2.5.4.2).  It must be refused before
-- anything is sent (an 'EncodeError', from a 'Left' out of
-- 'procParamEncode'), not sent as written nor, for 'outParam', silently
-- widened to a valid @decimal(38, s)@ that hides the mistake.
module Api.RawParamTypeSpec (spec) where

import RecipeParameters
import Control.Exception (SomeException, fromException, try)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Precision, Scale, putDecimal)
import Hmssql.Tds.TypeInfo (RawBytes, typeInfoProblem)
import TestDb

decimalValue :: Precision -> Scale -> Decimal -> RawBytes
decimalValue p s d = Just (LB.toStrict (Put.runPut (putDecimal p s d)))

badDecimals :: [(Precision, Scale)]
badDecimals = [(0, 0), (39, 0), (40, 0), (255, 0), (10, 11), (38, 39), (1, 2)]

goodDecimals :: [(Precision, Scale)]
goodDecimals = [(1, 0), (1, 1), (18, 4), (38, 0), (38, 38)]

isEncodeErrorWith :: String -> Either SomeException a -> Bool
isEncodeErrorWith what = \case
  Left e | Just (EncodeError why) <- fromException e -> what `isInfixOf` why
  _ -> False

stillUsable :: Connection -> Expectation
stillUsable conn = query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

spec :: Spec
spec = do
  describe "typeInfoProblem" $ do
    it "refuses a decimal or numeric precision outside 1..38, or a scale above it" $
      mapM_ (\(p, s) -> do
        typeInfoProblem (TIDecimalN p s) `shouldSatisfy` isJust
        typeInfoProblem (TINumericN p s) `shouldSatisfy` isJust) badDecimals
    it "accepts every valid decimal and numeric precision and scale" $
      mapM_ (\(p, s) -> do
        typeInfoProblem (TIDecimalN p s) `shouldBe` Nothing
        typeInfoProblem (TINumericN p s) `shouldBe` Nothing)
        [(p, s) | p <- [1 .. 38], s <- [0 .. p]]
    it "refuses a time, datetime2 or datetimeoffset scale above 7, accepts 0..7" $ do
      mapM_ (\s -> [TITimeN s, TIDateTime2N s, TIDateTimeOffsetN s] `shouldSatisfy` all (isJust . typeInfoProblem)) [8, 9, 13, 255]
      mapM_ (\s -> [TITimeN s, TIDateTime2N s, TIDateTimeOffsetN s] `shouldSatisfy` all (isNothing . typeInfoProblem)) [0 .. 7]

  describe "outParam" $ do
    let encoded p = encodedBytes (procParamEncode p defaultTdsContext)
    it "refuses an invalid decimal or numeric type instead of widening it" $
      mapM_ (\(p, s) -> do
        encoded (outParam "@x" (RawParam (TIDecimalN p s, Nothing))) `shouldSatisfy` isLeft
        encoded (outParam "@x" (RawParam (TINumericN p s, Nothing))) `shouldSatisfy` isLeft) badDecimals
    it "names the problem" $
      either id (const "") (encoded (outParam "@x" (RawParam (TIDecimalN 40 0, Nothing))))
        `shouldSatisfy` ("precision" `isInfixOf`)
    it "still widens a valid one to decimal(38, s)" $
      mapM_ (\(p, s) -> encoded (outParam "@x" (RawParam (TIDecimalN p s, Nothing)))
        `shouldSatisfy` \case
          Right (TIDecimalN 38 s', Nothing) -> s' >= s
          _ -> False) goodDecimals

  around withTestDb $ describe "sending" $ do
    it "a RawParam of an invalid decimal type is an EncodeError, and the connection stays usable" $ \conn -> do
      r <- try (query conn (mkQuery "SELECT @p1" (Only (RawParam (TIDecimalN 40 0, decimalValue 38 0 5))))) :: IO (Either SomeException [Only Decimal])
      r `shouldSatisfy` isEncodeErrorWith "precision"
      r' <- try (query conn (mkQuery "SELECT @p1" (Only (RawParam (TINumericN 10 11, Nothing))))) :: IO (Either SomeException [Only (Maybe Decimal)])
      r' `shouldSatisfy` isEncodeErrorWith "scale"
      stillUsable conn
    it "a RawParam of time(8) is an EncodeError" $ \conn -> do
      r <- try (query conn (mkQuery "SELECT @p1" (Only (RawParam (TITimeN 8, Nothing))))) :: IO (Either SomeException [Only (Maybe Int)])
      r `shouldSatisfy` isEncodeErrorWith "scale"
      stillUsable conn
    it "callProcedure refuses a ProcParam of an invalid decimal type (not widened by outParam)" $ \conn -> do
      let p = rawOutParam "@stmt" (TIDecimalN 39 2, decimalValue 38 2 (Decimal 2 1234))
      r <- try (callProcedure conn "sp_executesql" [p]) :: IO (Either SomeException ProcResult)
      r `shouldSatisfy` isEncodeErrorWith "precision"
      stillUsable conn
    it "callProcedure refuses a rawInParam of an invalid decimal type" $ \conn -> do
      let p = rawInParam "@x" (TIDecimalN 39 2, decimalValue 38 2 (Decimal 2 1234))
      r <- try (callProcedure conn "sp_executesql" [p]) :: IO (Either SomeException ProcResult)
      r `shouldSatisfy` isEncodeErrorWith "precision"
      stillUsable conn
    it "a rawInParam and a rawOutParam of a valid exact type round trip" $ \conn -> do
      res <- callProcedure conn "sp_executesql"
        [ inParam "" ("SET @out = @x * 2" :: Text)
        , inParam "" ("@x decimal(20,4), @out decimal(20,4) OUTPUT" :: Text)
        , rawInParam "@x" (TIDecimalN 20 4, decimalValue 20 4 (Decimal 4 123456))
        , rawOutParam "@out" (TIDecimalN 20 4, Nothing) ]
      map decodeReturnValue (procOutputValues res) `shouldBe` [Right (Decimal 4 246912 :: Decimal)]
    it "a valid hand-built decimal type still works" $ \conn ->
      query conn (mkQuery "SELECT @p1" (Only (RawParam (TIDecimalN 20 4, decimalValue 20 4 (Decimal 4 123456)))))
        `shouldReturn` [Only (Decimal 4 123456 :: Decimal)]
