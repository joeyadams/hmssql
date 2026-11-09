-- | CLR user-defined types against the real server: hmssql doesn't decode
-- them, but selecting one must not break the connection.  Decoding one is a
-- 'DecodeError' naming the type and suggesting a conversion; 'RawValue'
-- gets the serialized bytes (the same as @CAST(... AS varbinary(max))@).
-- 'MiscTypesSpec' checks the wording of the error; this module checks that
-- the connection survives it.
module Types.UdtSpec (spec) where

import Control.Exception (SomeException, finally, fromException, try)
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Token (ReturnValue (..))
import Hmssql.Tds.TypeInfo (UdtInfo (..))
import TestDb

isUdtDecodeError :: Either SomeException a -> Bool
isUdtDecodeError = \case
  Left e | Just (DecodeError _ why) <- fromException e -> "user-defined type" `isInfixOf` why
  _ -> False

stillUsable :: Connection -> Expectation
stillUsable conn = query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

spec :: Spec
spec = around withTestDb $ do
  it "a hierarchyid column decoded as Text is a DecodeError, and the connection stays usable" $ \conn -> do
    r <- try (query conn "SELECT hierarchyid::Parse('/1/2/') AS h, 1 AS x" :: IO [(Text, Int)])
    r `shouldSatisfy` isUdtDecodeError
    stillUsable conn

  it "geography and geometry columns too" $ \conn -> do
    r1 <- try (query conn "SELECT geography::STGeomFromText('POINT(1 2)', 4326)" :: IO [Only Text])
    r1 `shouldSatisfy` isUdtDecodeError
    r2 <- try (query conn "SELECT geometry::STGeomFromText('LINESTRING(0 0, 1 1)', 0)" :: IO [Only (Maybe Text)])
    r2 `shouldSatisfy` isUdtDecodeError
    stillUsable conn

  it "queryMulti (SqlValue) rejects it the same way" $ \conn -> do
    r <- try (queryMulti conn "SELECT 1 AS a, hierarchyid::GetRoot() AS h")
    r `shouldSatisfy` isUdtDecodeError
    stillUsable conn

  it "RawValue gets the serialized value, the same bytes as CAST(... AS varbinary(max))" $ \conn -> do
    rows :: [(Maybe RawValue, Maybe B.ByteString)] <- query conn
      "SELECT v, CAST(v AS varbinary(max)) FROM (VALUES \
      \(hierarchyid::Parse('/1/2/')), (hierarchyid::GetRoot()), (CAST(NULL AS hierarchyid))) t(v)"
    length rows `shouldBe` 3
    [raw | (Just (RawValue raw), _) <- rows] `shouldBe` [b | (_, Just b) <- rows]
    [() | (Nothing, Nothing) <- rows] `shouldBe` [()]
    (RawValue g, gb) <- query1 conn
      "SELECT g, CAST(g AS varbinary(max)) FROM (SELECT geography::STGeomFromText('POINT(1 2)', 4326) AS g) t"
    g `shouldBe` (gb :: B.ByteString)
    stillUsable conn

  it "a table with a UDT column can be read around it, and SELECT * fails cleanly" $ \conn -> do
    _ <- execute conn "CREATE TABLE #udt (id int PRIMARY KEY, node hierarchyid, name nvarchar(10))"
    _ <- execute conn "INSERT #udt VALUES (1, hierarchyid::Parse('/1/'), N'a'), (2, NULL, N'b')"
    query conn "SELECT id, name FROM #udt ORDER BY id" `shouldReturn` [(1 :: Int, "a" :: Text), (2, "b")]
    query conn "SELECT id, node.ToString() FROM #udt ORDER BY id" `shouldReturn` [(1 :: Int, Just ("/1/" :: Text)), (2, Nothing)]
    r <- try (query conn "SELECT * FROM #udt ORDER BY id" :: IO [(Int, Maybe Text, Text)])
    r `shouldSatisfy` isUdtDecodeError
    stillUsable conn

  it "a UDT parameter (RawParam) is an EncodeError: hmssql doesn't send UDTs" $ \conn -> do
    let ti = TIUdt (UdtInfo 892 "hmssql_test" "sys" "hierarchyid" "")
    r <- try (query conn (mkQuery "SELECT CAST(@p1 AS varbinary(max))" (Only (RawParam (ti, Just (B.pack [0x5B, 0x40]))))) :: IO [Only B.ByteString])
    case r of
      Left (e :: SomeException) | Just (EncodeError why) <- fromException e -> why `shouldSatisfy` ("user-defined type" `isInfixOf`)
      other -> expectationFailure ("expected EncodeError, got " ++ show other)
    stillUsable conn

  it "a scalar function returning hierarchyid, called by RPC: its RETURNVALUE is read, decoding it is a DecodeError" $ \conn -> do
    fn <- uniqueName "hmssql_wire_udtfn"
    let qualified = "dbo." <> fn
    _ <- execute conn (rawSql ("CREATE FUNCTION " <> qualified <> "() RETURNS hierarchyid AS BEGIN RETURN hierarchyid::Parse('/1/2/') END"))
    flip finally (execute conn (rawSql ("DROP FUNCTION IF EXISTS " <> qualified))) $ do
      res <- callProcedure conn qualified []
      case procOutputValues res of
        [rv] -> do
          rvStatus rv `shouldBe` 0x02
          rvValue rv `shouldBe` Just (B.pack [0x5B, 0x40])
          (decodeReturnValue rv :: Either DecodeError Text) `shouldSatisfy` either (const True) (const False)
        other -> expectationFailure ("expected one return value, got " ++ show other)
      stillUsable conn
