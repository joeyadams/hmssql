-- | Tests found by the third round of mutation testing, of code that needs
-- no server: the decimal checks of 'getDecimal', datetimeoffset offsets, the money ranges, LOGIN7's length
-- bound and its 'Show', the RPC encoders' own checks, and the character
-- classes of parameter names.
module Mutation.Round3PureSpec (spec) where

import Wire.PrimitiveGet (getDecimal)
import RecipeParameters
import Control.Exception (ErrorCall, evaluate, try)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Either (isLeft, isRight)
import Data.Fixed (Fixed (..))
import Data.Int (Int32, Int64)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Data.Time
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.Encoding
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.TypeInfo (RawBytes, putValue)

-- | Whether two ByteStrings start at the same address (share a buffer).

-- | A decimal value on the wire: sign byte, then a 16-byte magnitude.
decimalBytes :: Word8 -> Integer -> Int -> B.ByteString
decimalBytes sign mag width =
  B.cons sign (B.pack [fromIntegral (mag `div` (256 ^ i)) | i <- [0 .. width - 1 :: Int]])

runDecimal :: Precision -> Scale -> B.ByteString -> Either String Decimal
runDecimal p s bs = case Get.runGetOrFail (getDecimal p s (B.length bs)) (LB.fromStrict bs) of
  Left (_, _, e) -> Left e
  Right (_, _, d) -> Right d

decimalColumn :: Precision -> ColumnInfo
decimalColumn p = ColumnInfo "c" (TIDecimalN p 0) 0x0001 0 Nothing

numericColumn :: Precision -> ColumnInfo
numericColumn p = ColumnInfo "c" (TINumericN p 0) 0x0001 0 Nothing

decodeWith :: FieldDecoder a -> ColumnInfo -> RawBytes -> Either String a
decodeWith dec col v = compileField dec defaultTdsContext col >>= \decode -> decodeCell decode v

throwsErrorCall :: forall a. a -> Expectation
throwsErrorCall a = (try (evaluate a) :: IO (Either ErrorCall a)) >>= \case
  Left _ -> pure ()
  Right _ -> expectationFailure "no error"

-- | Where the strings of a login end ('login7Problem''s bound is 65535).
loginEnd :: Login7 -> Int
loginEnd l = 94 + (if null (l7Features l) then 0 else 4)
  + 2 * sum (map T.length [l7HostName l, l7UserName l, l7Password l, l7AppName l, l7ServerName l, l7LibraryName l, l7Language l, l7Database l])

-- | The login with its application name padded so its strings end at the
-- given (even) offset.
endingAt :: Int -> Login7 -> Login7
endingAt end l = l { l7AppName = T.replicate ((end - loginEnd l { l7AppName = "" }) `div` 2) "a" }

tooLongParam :: RpcParam
tooLongParam = byteParam (T.replicate 300 "a") 0 (TIIntN 4) (Just "\1\0\0\0")

okParam :: RpcParam
okParam = byteParam "@a" 0 (TIIntN 4) (Just "\1\0\0\0")

spec :: Spec
spec = do
  describe "getDecimal" $ do
    it "accepts 10^p - 1 and refuses 10^p, for every precision" $
      mapM_ (\p -> do
          (p, runDecimal p 0 (decimalBytes 1 (10 ^ p - 1) 16)) `shouldBe` (p, Right (Decimal 0 (10 ^ p - 1)))
          (p, isLeft (runDecimal p 0 (decimalBytes 1 (10 ^ p) 16))) `shouldBe` (p, True))
        [1 .. 38]

    it "accepts each of the four magnitude lengths, and refuses others" $ do
      mapM_ (\w -> (w, runDecimal 5 2 (decimalBytes 1 12345 w)) `shouldBe` (w, Right (Decimal 2 12345))) [4, 8, 12, 16]
      mapM_ (\w -> (w, isLeft (runDecimal 5 2 (decimalBytes 1 1 w))) `shouldBe` (w, True)) [1, 2, 3, 5, 6, 7, 15, 17]

    it "refuses a sign byte other than 0 and 1" $ do
      runDecimal 5 0 (decimalBytes 0 7 4) `shouldBe` Right (Decimal 0 (-7))
      mapM_ (\s -> (s, isLeft (runDecimal 5 0 (decimalBytes s 7 4))) `shouldBe` (s, True)) [2, 3, 0x80, 0xFF]

    it "is applied with the column's precision when decoding decimal and numeric columns" $ do
      decodeWith (fieldDecoder @Decimal) (decimalColumn 2) (Just (decimalBytes 1 99 4)) `shouldBe` Right (Decimal 0 99)
      decodeWith (fieldDecoder @Decimal) (decimalColumn 2) (Just (decimalBytes 1 100 4)) `shouldSatisfy` isLeft
      decodeWith (fieldDecoder @Decimal) (numericColumn 2) (Just (decimalBytes 1 99 4)) `shouldBe` Right (Decimal 0 99)
      decodeWith (fieldDecoder @Decimal) (numericColumn 2) (Just (decimalBytes 1 100 4)) `shouldSatisfy` isLeft

  describe "outParam" $
    it "checks a decimal value against its precision before widening it to decimal(38)" $ do
      let raw m = RawParam (TIDecimalN 2 0, Just (decimalBytes 1 m 4))
          encoded m = procParamEncode (outParam "@x" (raw m)) defaultTdsContext
      isRight (encoded 99) `shouldBe` True
      isLeft (encoded 100) `shouldBe` True

  describe "datetimeoffset offsets" $ do
    let t = UTCTime (fromGregorian 2024 1 2) 3600
        zoned mins = ZonedTime (LocalTime (fromGregorian 2024 1 2) midnight) (minutesToTimeZone mins)
    it "are sent from -14:00 through +14:00" $ do
      isRight (putDateTimeOffset 7 (DateTimeOffset t (-840))) `shouldBe` True
      isRight (putDateTimeOffset 7 (DateTimeOffset t 840)) `shouldBe` True
      isLeft (putDateTimeOffset 7 (DateTimeOffset t (-841))) `shouldBe` True
      isLeft (putDateTimeOffset 7 (DateTimeOffset t 841)) `shouldBe` True

    it "of a ZonedTime are sent from -14:00 through +14:00" $ do
      let enc z = encodeParam (fieldEncoder @ZonedTime) defaultTdsContext z
      enc (zoned (-840)) `shouldSatisfy` isRight
      enc (zoned 840) `shouldSatisfy` isRight
      enc (zoned 841) `shouldSatisfy` isLeft
      enc (zoned (-841)) `shouldSatisfy` isLeft

    it "of a ZonedTime are clamped to Int16, not wrapped or narrowed further" $ do
      dtoOffsetMinutes (zonedTimeToDateTimeOffset (zoned 40000)) `shouldBe` 32767
      dtoOffsetMinutes (zonedTimeToDateTimeOffset (zoned (-40000))) `shouldBe` (-32768)
      dtoOffsetMinutes (zonedTimeToDateTimeOffset (zoned (-1200))) `shouldBe` (-1200)
      dtoOffsetMinutes (zonedTimeToDateTimeOffset (zoned 1200)) `shouldBe` 1200

    it "a NULL ZonedTime is a datetimeoffset(7)" $
      fmap fst (encodeParam (fieldEncoder @(Maybe ZonedTime)) defaultTdsContext Nothing) `shouldBe` Right (TIDateTimeOffsetN 7)

  describe "money ranges" $ do
    it "include their bounds" $ do
      money4Problem (Money (MkFixed (toInteger (maxBound :: Int32)))) `shouldBe` Nothing
      money4Problem (Money (MkFixed (toInteger (minBound :: Int32)))) `shouldBe` Nothing
      money8Problem (Money (MkFixed (toInteger (maxBound :: Int64)))) `shouldBe` Nothing
      money8Problem (Money (MkFixed (toInteger (minBound :: Int64)))) `shouldBe` Nothing
      money4Problem (Money (MkFixed (toInteger (maxBound :: Int32) + 1))) `shouldSatisfy` isJust
      money8Problem (Money (MkFixed (toInteger (maxBound :: Int64) + 1))) `shouldSatisfy` isJust

    it "putMoney4 and putMoney8 fail outside them rather than wrap" $ do
      throwsErrorCall (LB.length (Put.runPut (putMoney4 (Money (MkFixed (toInteger (maxBound :: Int32) + 1))))))
      throwsErrorCall (LB.length (Put.runPut (putMoney8 (Money (MkFixed (toInteger (maxBound :: Int64) + 1))))))

  describe "login7Problem" $ do
    let noFeatures = defaultLogin7 { l7Features = [] }
        withFeatures = defaultLogin7 { l7Features = [featureUtf8Support] }
    it "allows strings ending at 65534 and refuses 65536, without features" $ do
      login7Problem (endingAt 65534 noFeatures) `shouldBe` Nothing
      login7Problem (endingAt 65536 noFeatures) `shouldSatisfy` isJust

    it "counts the feature extension's 4-byte offset" $ do
      loginEnd (endingAt 65536 withFeatures) `shouldBe` 65536
      login7Problem (endingAt 65534 withFeatures) `shouldBe` Nothing
      login7Problem (endingAt 65536 withFeatures) `shouldSatisfy` isJust

    it "counts every string, the password and the database among them" $ do
      login7Problem noFeatures { l7Password = T.replicate 33000 "p" } `shouldSatisfy` isJust
      login7Problem noFeatures { l7Database = T.replicate 33000 "d" } `shouldSatisfy` isJust
      login7Problem noFeatures { l7LibraryName = T.replicate 33000 "l" } `shouldSatisfy` isJust

    it "putLogin7 fails on such a login rather than write offsets modulo 65536" $
      throwsErrorCall (LB.length (Put.runPut (putLogin7 (endingAt 65536 noFeatures))))

  describe "Login7's Show" $ do
    it "shows a non-empty password as <redacted>, and an empty one as \"\"" $ do
      show defaultLogin7 { l7Password = "secret" } `shouldSatisfy` ("l7Password = <redacted>" `isInfixOf`)
      show defaultLogin7 { l7Password = "" } `shouldSatisfy` ("l7Password = \"\"" `isInfixOf`)

    it "is parenthesized as an argument, like a derived Show" $
      show (Just defaultLogin7) `shouldSatisfy` ("Just (Login7 {" `isPrefixOf`)

    it "shows every field, at precedence 0" $ do
      let s = show defaultLogin7 { l7TimeZone = -60, l7Features = [featureUtf8Support] }
      s `shouldSatisfy` ("l7TimeZone = -60," `isInfixOf`)
      s `shouldSatisfy` ("l7Features = [" `isInfixOf`)
      s `shouldSatisfy` ("l7ClientId = " `isInfixOf`)

  describe "the RPC encoders' own checks" $ do
    it "rpcRequestProblem checks every parameter, not just the first" $
      rpcRequestProblem (RpcRequest (RpcProcName "p") 0 [okParam, tooLongParam]) `shouldSatisfy` isJust

    it "putRpcRequest fails on a parameter name too long for its length prefix" $
      throwsErrorCall (LB.length (Put.runPut (putRpcRequest defaultTdsContext [RpcRequest (RpcProcName "p") 0 [tooLongParam]])))

    it "putValue fails on a value too long for its length prefix" $
      throwsErrorCall (LB.length (Put.runPut (putValue defaultTdsContext (TIBigVarBinary 8000) (Just (B.replicate 70000 0)))))

  describe "paramNameProblem" $ do
    let ok n = (n, paramNameProblem n) `shouldBe` (n, Nothing)
        bad n = (n, isJust (paramNameProblem n)) `shouldBe` (n, True)
    it "accepts letters of every case class, modifier and other letters, marks, digits and letter numbers" $
      mapM_ ok
        [ "@Xy", "@x\x01C5"       -- titlecase letter (Dz with caron)
        , "@x\x02B0"              -- modifier letter small h
        , "@\x0915\x093E"         -- Devanagari ka + vowel sign aa (a spacing combining mark)
        , "@e\x0301", "@x\x2163", "@x\x0661", "@x_1", "@x$", "@x#", "@x@"
        ]
    it "refuses a bare @, surrogates, other numbers and spaces" $
      mapM_ bad ["@", "@x\x1D400", "@x\x00B2", "@x y", "x"]
