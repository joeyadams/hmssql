-- | "Hmssql.SqlType" without a server: names round-trip over the whole
-- closed list of types, the arguments are checked and rendered the way
-- T-SQL wants them, and the two views of a type (the catalog's 'SqlType'
-- and the wire's 'TypeInfo') agree wherever the wire can say.
module Catalog.SqlTypeSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Either (isLeft, isRight)
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog
import TestDb (withCases)

import Hmssql.Decoding (compileField, decodeCell, fieldDecoderForTypes)
import Hmssql.SqlType
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Primitives (Collation (..))
import Hmssql.Tds.Token (ColumnInfo (..))
import Hmssql.Tds.TypeInfo

import Wire.TypeInfoSpec (genTypeInfo)

allTypes :: [SqlDataType]
allTypes = [minBound .. maxBound]

spec :: Spec
spec = do
  describe "dataTypeName / dataTypeFromName" $ do
    it "round-trips every type" $
      forM_ allTypes $ \t -> dataTypeFromName (dataTypeName t) `shouldBe` Just t

    it "ignores case and surrounding space" $ do
      dataTypeFromName "NVARCHAR" `shouldBe` Just TyNVarChar
      dataTypeFromName "  DateTime2 " `shouldBe` Just TyDateTime2

    it "accepts the catalog's aliases: timestamp is rowversion, sysname is nvarchar" $ do
      dataTypeFromName "timestamp" `shouldBe` Just TyRowVersion
      dataTypeFromName "sysname" `shouldBe` Just TyNVarChar
      dataTypeName TyRowVersion `shouldBe` "rowversion"

    it "knows no user-defined or future type" $ do
      dataTypeFromName "phone" `shouldBe` Nothing
      dataTypeFromName "dbo.phone" `shouldBe` Nothing
      dataTypeFromName "" `shouldBe` Nothing
      dataTypeFromName "table" `shouldBe` Nothing
      dataTypeFromName "cursor" `shouldBe` Nothing

    it "names are lower-case T-SQL names" $
      forM_ allTypes $ \t -> dataTypeName t `shouldSatisfy` \n -> not (T.null n) && T.toLower n == n

  describe "dataTypeCategory" $ do
    it "puts the character types in the two string categories" $ do
      map dataTypeCategory [TyChar, TyVarChar, TyText] `shouldBe` replicate 3 CharacterString
      map dataTypeCategory [TyNChar, TyNVarChar, TyNText] `shouldBe` replicate 3 UnicodeCharacterString

    it "puts every integer, decimal and money type in ExactNumeric" $
      map dataTypeCategory [TyBit, TyTinyInt, TySmallInt, TyInt, TyBigInt, TyDecimal, TyNumeric, TyMoney, TySmallMoney]
        `shouldBe` replicate 9 ExactNumeric

  describe "sqlTypeName" $ do
    it "renders each kind of argument as T-SQL declares it" $ do
      sqlTypeName (SqlType TyInt NoArgs) `shouldBe` "int"
      sqlTypeName (SqlType TyNVarChar (LengthArg (Length 50))) `shouldBe` "nvarchar(50)"
      sqlTypeName (SqlType TyVarBinary (LengthArg Max)) `shouldBe` "varbinary(max)"
      sqlTypeName (SqlType TyDecimal (PrecisionScaleArg 10 2)) `shouldBe` "decimal(10,2)"
      sqlTypeName (SqlType TyTime (ScaleArg 4)) `shouldBe` "time(4)"
      sqlTypeName (SqlType TyVector (DimensionsArg 3)) `shouldBe` "vector(3)"
      sqlTypeName (SqlType TyXml (XmlSchemaArg "dbo" "Person]")) `shouldBe` "xml([dbo].[Person]]])"
      sqlTypeName (SqlType TyRowVersion NoArgs) `shouldBe` "rowversion"

  describe "sqlTypeProblem" $ do
    it "accepts every type with the arguments it takes" $ do
      let fine =
            [ SqlType TyChar (LengthArg (Length 8000)), SqlType TyVarChar (LengthArg Max)
            , SqlType TyNChar (LengthArg (Length 4000)), SqlType TyNVarChar (LengthArg (Length 1))
            , SqlType TyBinary (LengthArg (Length 1)), SqlType TyVarBinary (LengthArg Max)
            , SqlType TyDecimal (PrecisionScaleArg 38 38), SqlType TyNumeric (PrecisionScaleArg 1 0)
            , SqlType TyTime (ScaleArg 0), SqlType TyDateTime2 (ScaleArg 7), SqlType TyDateTimeOffset (ScaleArg 3)
            , SqlType TyVector (DimensionsArg 1998)
            , SqlType TyXml NoArgs, SqlType TyXml (XmlSchemaArg "dbo" "S")
            ]
      forM_ fine $ \t -> (t, sqlTypeProblem t) `shouldSatisfy` isNothing . snd
      forM_ [t | t <- allTypes, t `notElem` parameterized] $ \t ->
        (t, sqlTypeProblem (SqlType t NoArgs)) `shouldSatisfy` isNothing . snd

    it "rejects a missing argument" $
      forM_ parameterized $ \t -> (t, sqlTypeProblem (SqlType t NoArgs)) `shouldSatisfy` isJust . snd

    it "rejects an argument the type doesn't take" $ do
      sqlTypeProblem (SqlType TyInt (LengthArg (Length 4))) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyNVarChar (ScaleArg 3)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyDecimal (ScaleArg 3)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyVarChar (XmlSchemaArg "dbo" "S")) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyXml (LengthArg Max)) `shouldSatisfy` isJust

    it "rejects an argument out of range" $ do
      sqlTypeProblem (SqlType TyChar (LengthArg (Length 0))) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyChar (LengthArg (Length 8001))) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyChar (LengthArg Max)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyNVarChar (LengthArg (Length 4001))) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyDecimal (PrecisionScaleArg 0 0)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyDecimal (PrecisionScaleArg 39 0)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyDecimal (PrecisionScaleArg 10 11)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyTime (ScaleArg 8)) `shouldSatisfy` isJust
      sqlTypeProblem (SqlType TyVector (DimensionsArg 0)) `shouldSatisfy` isJust

  describe "typeInfoSqlType" $ do
    it "reads the wire's lengths in bytes as characters" $ do
      typeInfoSqlType (TINVarChar 100 (Collation 0 0)) `shouldBe` Just (SqlType TyNVarChar (LengthArg (Length 50)))
      typeInfoSqlType (TINChar 8 (Collation 0 0)) `shouldBe` Just (SqlType TyNChar (LengthArg (Length 4)))
      typeInfoSqlType (TIBigVarChar 30 (Collation 0 0)) `shouldBe` Just (SqlType TyVarChar (LengthArg (Length 30)))
      typeInfoSqlType (TINVarChar maxLength (Collation 0 0)) `shouldBe` Just (SqlType TyNVarChar (LengthArg Max))
      typeInfoSqlType (TIBigVarBinary maxLength) `shouldBe` Just (SqlType TyVarBinary (LengthArg Max))

    it "tells the nullable encodings' widths apart" $ do
      typeInfoSqlType (TIIntN 2) `shouldBe` Just (SqlType TySmallInt NoArgs)
      typeInfoSqlType (TIMoneyN 4) `shouldBe` Just (SqlType TySmallMoney NoArgs)
      typeInfoSqlType (TIDateTimeN 4) `shouldBe` Just (SqlType TySmallDateTime NoArgs)
      typeInfoSqlType (TIFltN 4) `shouldBe` Just (SqlType TyReal NoArgs)
      typeInfoSqlType (TIIntN 3) `shouldBe` Nothing

    it "knows the CLR system types and no other UDT" $ do
      let udt schema name = TIUdt (UdtInfo 0xFFFF "db" schema name "Microsoft.SqlServer.Types...")
      typeInfoSqlType (udt "sys" "hierarchyid") `shouldBe` Just (SqlType TyHierarchyId NoArgs)
      typeInfoSqlType (udt "sys" "geography") `shouldBe` Just (SqlType TyGeography NoArgs)
      typeInfoSqlType (udt "sys" "Geometry") `shouldBe` Just (SqlType TyGeometry NoArgs)
      typeInfoSqlType (udt "dbo" "Point") `shouldBe` Nothing
      typeInfoSqlType TINull `shouldBe` Nothing

    it "keeps an xml schema collection" $
      typeInfoSqlType (TIXml (Just (XmlSchema "db" "dbo" "S"))) `shouldBe` Just (SqlType TyXml (XmlSchemaArg "dbo" "S"))

    withCases 500 $ it "renders the same name as typeInfoSqlName for every wire type" $ hedgehog $ do
      ti <- forAll genTypeInfo
      case typeInfoSqlType ti of
        Nothing -> ti === TINull
        Just st -> case ti of
          -- typeInfoSqlName leaves the schema collection out
          TIXml (Just _) -> sqlDataType st === TyXml
          _ -> sqlTypeName st === typeInfoSqlName ti

  describe "typeInfoDataType" $ do
    withCases 500 $ it "is typeInfoSqlType without the arguments, for every wire type" $ hedgehog $ do
      ti <- forAll genTypeInfo
      typeInfoDataType ti === fmap sqlDataType (typeInfoSqlType ti)

    it "knows no width the wire doesn't have" $ do
      typeInfoDataType (TIIntN 3) `shouldBe` Nothing
      typeInfoDataType (TIMoneyN 2) `shouldBe` Nothing
      typeInfoDataType (TIFltN 8) `shouldBe` Just TyFloat

  describe "fieldDecoderForTypes" $ do
    let column ti = ColumnInfo "c" ti 1 0 Nothing
        lengthOf = fieldDecoderForTypes "Length" (== TyInt) (\_ _ bs -> Right (B.length bs))
        compileOn ti = compileField lengthOf defaultTdsContext (column ti)
        -- the compiled decoder is a function, so only whether it compiled
        outcome ti = either Left (const (Right ())) (compileOn ti)
    it "accepts a type however the wire encodes it" $ do
      outcome TIInt4 `shouldSatisfy` isRight
      outcome (TIIntN 4) `shouldSatisfy` isRight
      either (const Nothing) (\decode -> either (const Nothing) Just (decodeCell decode (Just (B.pack [1, 2, 3, 4])))) (compileOn (TIIntN 4))
        `shouldBe` Just 4

    it "rejects other types, naming the column's type" $ do
      outcome (TIIntN 8) `shouldSatisfy` isLeft
      outcome (TINVarChar 100 (Collation 0 0)) `shouldSatisfy` isLeft
      either id (const "") (outcome (TINVarChar 100 (Collation 0 0)))
        `shouldBe` "SQL type nvarchar(50) cannot be decoded as Length"

  describe "sqlTypeTypeInfo" $ do
    it "declares parameters the way Hmssql.Encoding does" $ do
      sqlTypeTypeInfo (SqlType TyInt NoArgs) `shouldBe` Just (TIIntN 4)
      sqlTypeTypeInfo (SqlType TyNVarChar (LengthArg (Length 50))) `shouldBe` Just (TINVarChar 100 (Collation 0 0))
      sqlTypeTypeInfo (SqlType TyNVarChar (LengthArg Max)) `shouldBe` Just (TINVarChar maxLength (Collation 0 0))
      sqlTypeTypeInfo (SqlType TyDecimal (PrecisionScaleArg 10 2)) `shouldBe` Just (TIDecimalN 10 2)
      sqlTypeTypeInfo (SqlType TyRowVersion NoArgs) `shouldBe` Just (TIBigBinary 8)
      sqlTypeTypeInfo (SqlType TyXml (XmlSchemaArg "dbo" "S")) `shouldBe` Just (TIXml (Just (XmlSchema "" "dbo" "S")))

    it "has no wire type for json, vector, the CLR types or a bad type" $ do
      sqlTypeTypeInfo (SqlType TyJson NoArgs) `shouldBe` Nothing
      sqlTypeTypeInfo (SqlType TyVector (DimensionsArg 3)) `shouldBe` Nothing
      sqlTypeTypeInfo (SqlType TyHierarchyId NoArgs) `shouldBe` Nothing
      sqlTypeTypeInfo (SqlType TyNVarChar NoArgs) `shouldBe` Nothing
      sqlTypeTypeInfo (SqlType TyChar (LengthArg (Length 0))) `shouldBe` Nothing

    withCases 500 $ it "round-trips through typeInfoSqlType" $ hedgehog $ do
      ti <- forAll genTypeInfo
      case typeInfoSqlType ti of
        Just st | isNothing (sqlTypeProblem st) -> fmap typeInfoSqlType (sqlTypeTypeInfo st) === Just (Just st)
        _ -> pure ()

    withCases 300 $ it "round-trips every sendable type built by hand" $ hedgehog $ do
      st <- forAll genSqlType
      case sqlTypeTypeInfo st of
        Nothing -> assert (isJust (sqlTypeProblem st) || sqlDataType st `elem` [TyJson, TyVector, TyHierarchyId, TyGeometry, TyGeography])
        -- a rowversion is sent, and comes back, as binary(8)
        Just ti | sqlDataType st == TyRowVersion -> typeInfoSqlType ti === Just (SqlType TyBinary (LengthArg (Length 8)))
        Just ti -> typeInfoSqlType ti === Just st
  where
    parameterized =
      [ TyChar, TyVarChar, TyNChar, TyNVarChar, TyBinary, TyVarBinary
      , TyDecimal, TyNumeric, TyTime, TyDateTime2, TyDateTimeOffset, TyVector ]

-- | Any type with any arguments, valid or not.
genSqlType :: Gen SqlType
genSqlType = SqlType <$> Gen.enumBounded <*> Gen.choice
  [ pure NoArgs
  , LengthArg <$> Gen.choice [pure Max, Length <$> Gen.integral (Range.constantFrom 0 0 9000)]
  , PrecisionScaleArg <$> Gen.word8 (Range.constantFrom 1 0 40) <*> Gen.word8 (Range.constantFrom 0 0 40)
  , ScaleArg <$> Gen.word8 (Range.constantFrom 0 0 9)
  , DimensionsArg <$> Gen.int (Range.constantFrom 1 0 2000)
  , XmlSchemaArg <$> Gen.text (Range.constantFrom 1 1 10) Gen.alpha <*> Gen.text (Range.constantFrom 1 1 10) Gen.alpha
  ]
