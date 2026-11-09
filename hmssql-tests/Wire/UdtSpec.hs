{-# LANGUAGE ViewPatterns #-}
-- | CLR user-defined types (@hierarchyid@, @geometry@, @geography@, and
-- user CLR types) in COLMETADATA, ROW and RETURNVALUE tokens.
--
-- hmssql doesn't decode UDT values, but a result that contains one is a
-- well-formed token stream, and the parser must be able to step over it
-- ([MS-TDS] 2.2.5.5.2 UDT_INFO: MAX_BYTE_SIZE USHORT, then DB_NAME,
-- SCHEMA_NAME and TYPE_NAME as B_VARCHAR and ASSEMBLY_QUALIFIED_NAME as
-- US_VARCHAR; the values are PLP whatever MAX_BYTE_SIZE is).  The layouts
-- below are the ones SQL Server 2025 sends for @SELECT
-- hierarchyid::GetRoot(), CAST(NULL AS hierarchyid), 7@, for a geography
-- column, and for an RPC call of a scalar function returning hierarchyid.
module Wire.UdtSpec
  ( spec
    -- * Builders shared with "Protocol.UdtSpec"
  , hierarchyIdInfo
  , geographyInfo
  , udtColumn
  , plpValue
  , plpNull
  ) where

import Wire.RecipeGet (getToken, getTypeInfo)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Text (Text)
import Data.Word (Word16)
import Test.Hspec

import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.Value (rowValues)
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo

-- | UDT_INFO as sent in COLMETADATA and RETURNVALUE.
udtInfoP :: Word16 -> Text -> Text -> Text -> Text -> Put.Put
udtInfoP maxSize db schema ty asm = do
  Put.putWord8 0xF0
  Put.putWord16le maxSize
  putBVarChar db
  putBVarChar schema
  putBVarChar ty
  putUsVarChar asm

hierarchyIdInfo :: Put.Put
hierarchyIdInfo =
  udtInfoP 892 "hmssql_test" "sys" "hierarchyid"
    "Microsoft.SqlServer.Types.SqlHierarchyId, Microsoft.SqlServer.Types, Version=11.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"

hierarchyIdInfo' :: Put.Put
hierarchyIdInfo' = udtInfoP 892 "hmssql_test" "sys" "hierarchyid" "Microsoft.SqlServer.Types.SqlHierarchyId"

geographyInfo :: Put.Put
geographyInfo =
  udtInfoP 0xFFFF "hmssql_test" "sys" "geography"
    "Microsoft.SqlServer.Types.SqlGeography, Microsoft.SqlServer.Types, Version=11.0.0.0, Culture=neutral, PublicKeyToken=89845dcd8080cc91"

-- | One COLMETADATA column entry: UserType, Flags, TYPE_INFO, ColName.
udtColumn :: Put.Put -> Text -> Put.Put
udtColumn typeInfo name = Put.putWord32le 0 >> Put.putWord16le 0x0021 >> typeInfo >> putBVarChar name

plpValue :: B.ByteString -> Put.Put
plpValue bs = do
  Put.putWord64le (fromIntegral (B.length bs))
  if B.null bs then pure () else Put.putWord32le (fromIntegral (B.length bs)) >> Put.putByteString bs
  Put.putWord32le 0

plpNull :: Put.Put
plpNull = Put.putWord64le 0xFFFFFFFFFFFFFFFF

getTokens :: Get.Get [Token]
getTokens = go Nothing
  where
    go cols = Get.isEmpty >>= \case
      True -> pure []
      False -> do
        t <- getToken defaultTdsContext cols
        (t :) <$> go (case t of TColMetaData cs -> Just cs; _ -> cols)

parse :: Put.Put -> Either String [Token]
parse p = case Get.runGetOrFail getTokens (Put.runPut p) of
  Left (_, _, err) -> Left err
  Right (rest, _, toks)
    | LB.null rest -> Right toks
    | otherwise -> Left "trailing bytes"

done :: Put.Put
done = Put.putWord8 0xFD >> Put.putWord16le 0x10 >> Put.putWord16le 0xC1 >> Put.putWord64le 1

spec :: Spec
spec = do
  it "steps over hierarchyid columns (MAX_BYTE_SIZE 892, PLP values) in COLMETADATA and ROW" $ do
    let stream = do
          Put.putWord8 0x81 >> Put.putWord16le 3
          udtColumn hierarchyIdInfo "h"
          udtColumn hierarchyIdInfo "n"
          Put.putWord32le 0 >> Put.putWord16le 0x0020 >> Put.putWord8 0x38 >> putBVarChar "x"
          Put.putWord8 0xD1
          plpValue B.empty  -- hierarchyid::GetRoot() is zero bytes long
          plpNull
          Put.putInt32le 7
          done
    case parse stream of
      Right [TColMetaData cols, TRow (rowValues -> vals), TDone _] -> do
        map (typeInfoSqlName . columnType) cols `shouldBe` ["hierarchyid", "hierarchyid", "int"]
        map columnName cols `shouldBe` ["h", "n", "x"]
        vals `shouldBe` [Just B.empty, Nothing, Just (B.pack [7, 0, 0, 0])]
      other -> expectationFailure (show other)

  it "steps over a geography column (MAX_BYTE_SIZE 0xFFFF) in an NBCROW" $ do
    let point = B.pack [0xE6, 0x10, 0, 0, 1, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F]
        stream = do
          Put.putWord8 0x81 >> Put.putWord16le 2
          udtColumn geographyInfo "g"
          udtColumn geographyInfo "g2"
          Put.putWord8 0xD2 >> Put.putWord8 0x02  -- g2 is NULL
          plpValue point
          done
    case parse stream of
      Right [TColMetaData cols, TRow (rowValues -> vals), TDone _] -> do
        map (typeInfoSqlName . columnType) cols `shouldBe` ["geography", "geography"]
        vals `shouldBe` [Just point, Nothing]
      other -> expectationFailure (show other)

  it "reads a scalar function's hierarchyid RETURNVALUE (status 0x02)" $ do
    let stream = do
          Put.putWord8 0xAC
          Put.putWord16le 0 >> putBVarChar "" >> Put.putWord8 0x02
          Put.putWord32le 0 >> Put.putWord16le 0
          hierarchyIdInfo
          plpValue (B.pack [0x5B, 0x40])
          Put.putWord8 0xFE >> Put.putWord16le 0 >> Put.putWord16le 0xE0 >> Put.putWord64le 0
    case parse stream of
      Right [TReturnValue rv, TDoneProc _] -> do
        rvStatus rv `shouldBe` 0x02
        typeInfoSqlName (rvType rv) `shouldBe` "hierarchyid"
        rvValue rv `shouldBe` Just (B.pack [0x5B, 0x40])
      other -> expectationFailure (show other)

  it "names a user CLR type by its schema, since that is how @params must declare it" $ do
    let stream = do
          Put.putWord8 0x81 >> Put.putWord16le 1
          udtColumn (udtInfoP 20 "db" "app" "Point" "App.Point, App") "p"
          done
    case parse stream of
      Right (TColMetaData [c] : _) -> typeInfoSqlName (columnType c) `shouldBe` "[app].[Point]"
      other -> expectationFailure (show other)

  it "putTypeInfo writes the COLMETADATA form that getTypeInfo reads" $ do
    let ti = TIUdt (UdtInfo 892 "hmssql_test" "sys" "hierarchyid" "Microsoft.SqlServer.Types.SqlHierarchyId")
    Get.runGet (getTypeInfo defaultTdsContext) (Put.runPut (putTypeInfo defaultTdsContext ti)) `shouldBe` ti
    Put.runPut (putTypeInfo defaultTdsContext ti) `shouldBe` Put.runPut hierarchyIdInfo'
    typeInfoProblem ti `shouldSatisfy` maybe False (const True)

  it "still rejects a truncated UDT_INFO" $
    parse (Put.putWord8 0x81 >> Put.putWord16le 1 >> Put.putWord32le 0 >> Put.putWord16le 0 >> Put.putWord8 0xF0 >> Put.putWord16le 16)
      `shouldSatisfy` either (const True) (const False)
