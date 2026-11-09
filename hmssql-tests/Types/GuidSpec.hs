-- | @uniqueidentifier@ (byte order, all-zero/all-FF, round trips) and
-- @rowversion@/@timestamp@.
module Types.GuidSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID.Types (UUID)
import qualified Data.UUID.Types as UUID
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Query (ResultSet (..), queryMulti)
import Hmssql.SqlType (SqlDataType (..), SqlType (..), TypeArgs (..), columnSqlType)
import Hmssql.Tds.Token (columnName)
import LiveProperty (liveHedgehog)
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "special values" $ do
    it "round trips the all-zero GUID" $ \conn -> do
      Only u <- query1 conn "SELECT CAST('00000000-0000-0000-0000-000000000000' AS uniqueidentifier)"
      u `shouldBe` UUID.nil

    it "round trips the all-FF GUID" $ \conn -> do
      Only u <- query1 conn "SELECT CAST('ffffffff-ffff-ffff-ffff-ffffffffffff' AS uniqueidentifier)"
      u `shouldBe` UUID.fromWords 0xffffffff 0xffffffff 0xffffffff 0xffffffff

    it "distinguishes NULL from a GUID value" $ \conn -> do
      r <- query1 conn "SELECT CAST(NULL AS uniqueidentifier), CAST('00000000-0000-0000-0000-000000000001' AS uniqueidentifier)"
      r `shouldBe` (Nothing :: Maybe UUID, UUID.fromWords 0 0 0 1)

  describe "byte order" $ do
    it "matches SQL Server's canonical string form for a server-generated GUID" $ \conn -> do
      (u, s) <- query1 conn "DECLARE @g uniqueidentifier = NEWID(); SELECT @g, CONVERT(varchar(36), @g)"
      T.toLower (UUID.toText u) `shouldBe` T.toLower (s :: Text)

    it "sends a parameter GUID with the byte order the server expects" $ \conn -> do
      let u = UUID.fromWords 0x01020304 0x05060708 0x090a0b0c 0x0d0e0f10
      Only (s :: Text) <- query1 conn ("SELECT CONVERT(varchar(36), " <> param u <> ")")
      T.toLower s `shouldBe` "01020304-0506-0708-090a-0b0c0d0e0f10"

  describe "hedgehog: GUID round trips" $
    it "round trips arbitrary GUIDs as parameters" $ \conn -> liveHedgehog $ do
      let w32 = Gen.word32 Range.linearBounded
      u <- forAll $ UUID.fromWords <$> w32 <*> w32 <*> w32 <*> w32
      Only u' <- evalIO $ query1 conn ("SELECT " <> param u)
      u' === u

  describe "decoding mismatches and NULL" $ do
    it "rejects NULL into a non-Maybe UUID, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS uniqueidentifier) AS n" :: IO (Only UUID))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects decoding an int column as UUID, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT 1 AS n" :: IO (Only UUID))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "rowversion/timestamp" $ do
    it "decodes rowversion as an 8-byte ByteString that increases across inserts" $ \conn -> do
      _ <- execute conn "CREATE TABLE #rv (i int, rv rowversion)"
      _ <- execute conn "INSERT INTO #rv (i) VALUES (1), (2)"
      rows <- query conn "SELECT i, rv FROM #rv ORDER BY i" :: IO [(Int, B.ByteString)]
      case rows of
        [(_, rv1), (_, rv2)] -> do
          B.length rv1 `shouldBe` 8
          B.length rv2 `shouldBe` 8
          rv1 `shouldNotBe` rv2
        _ -> expectationFailure ("expected 2 rows, got " ++ show (length rows))

    it "is named rowversion by columnSqlType, which reads the column's user-type tag" $ \conn -> do
      _ <- execute conn "CREATE TABLE #rvt (i int, rv rowversion)"
      [ResultSet cols _] <- queryMulti conn "SELECT i, rv FROM #rvt"
      map columnName cols `shouldBe` ["i", "rv"]
      map columnSqlType cols `shouldBe`
        [Just (SqlType TyInt NoArgs), Just (SqlType TyRowVersion NoArgs)]
