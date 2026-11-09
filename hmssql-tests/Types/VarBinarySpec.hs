-- | binary/varbinary (fixed, variable and @(max)@), NULL/empty handling,
-- fixed-length zero padding, PLP boundary sizes, and decoding into every
-- supported Haskell binary type.
module Types.VarBinarySpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM_)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestDb

isMaxParam :: ToSqlField a => Connection -> a -> IO Bool
isMaxParam conn v = do
  r <- try (query1 conn (mkQuery "SELECT CAST(SQL_VARIANT_PROPERTY(CAST(@p1 AS sql_variant), 'MaxLength') AS int)" (Only v))
             :: IO (Only (Maybe Int32)))
  case r of
    Left e | sqlErrorNumber e == 529 -> pure True
           | otherwise -> throwIO e
    Right _ -> pure False

spec :: Spec
spec = around withTestDb $ do
  describe "empty vs NULL" $ do
    it "distinguishes empty varbinary from NULL" $ \conn -> do
      r <- query1 conn "SELECT CAST(0x AS varbinary(10)), CAST(NULL AS varbinary(10))"
      r `shouldBe` (B.empty :: B.ByteString, Nothing :: Maybe B.ByteString)

    it "round trips an empty ByteString parameter" $ \conn -> do
      Only b <- query1 conn ("SELECT " <> param B.empty)
      b `shouldBe` B.empty

  describe "binary(n) zero padding" $ do
    it "right-pads binary(n) with zero bytes" $ \conn -> do
      Only b <- query1 conn "SELECT CAST(0x0102 AS binary(5))"
      b `shouldBe` B.pack [1, 2, 0, 0, 0]

  describe "boundary: varbinary(n) vs varbinary(max) parameter encoding" $ do
    it "declares a bounded type at exactly 8000 bytes" $ \conn -> do
      isMaxParam conn (B.replicate 8000 0xAB) `shouldReturn` False

    it "switches to varbinary(max) at 8001 bytes" $ \conn -> do
      isMaxParam conn (B.replicate 8001 0xAB) `shouldReturn` True

  describe "sizes around PLP chunk/packet boundaries" $ do
    let sizes = [0, 1, 2, 7999, 8000, 8001, 8002, 15999, 16000, 16001, 23999, 24000, 24001] :: [Int]
    forM_ sizes $ \n ->
      it ("round trips a varbinary(max) parameter of length " ++ show n) $ \conn -> do
        let b = B.replicate n 0x5A
        Only b' <- query1 conn ("SELECT " <> param b)
        b' `shouldBe` b
        Only dlen <- query1 conn ("SELECT DATALENGTH(" <> param b <> ")") :: IO (Only Int)
        dlen `shouldBe` n

  describe "decoding mismatches and NULL" $ do
    it "rejects decoding an int column as ByteString, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT 42 AS n" :: IO (Only B.ByteString))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects decoding an nvarchar column as ByteString, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT N'x' AS n" :: IO (Only B.ByteString))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

    it "rejects NULL into a non-Maybe ByteString, naming the column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS varbinary(10)) AS n" :: IO (Only B.ByteString))
      case r of
        Left (DecodeError col _) -> col `shouldBe` Just "n"
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "decoding into every supported binary type" $ do
    it "decodes varbinary into lazy ByteString" $ \conn -> do
      Only b <- query1 conn "SELECT CAST(0xDEADBEEF AS varbinary(4))" :: IO (Only LB.ByteString)
      b `shouldBe` LB.pack [0xDE, 0xAD, 0xBE, 0xEF]

    it "decodes image (legacy) into ByteString" $ \conn -> do
      _ <- execute conn "CREATE TABLE #img (v image NULL)"
      _ <- execute conn "INSERT INTO #img VALUES (0x010203), (NULL)"
      rows <- query conn "SELECT v FROM #img ORDER BY CASE WHEN v IS NULL THEN 1 ELSE 0 END" :: IO [Only (Maybe B.ByteString)]
      rows `shouldBe` [Only (Just (B.pack [1, 2, 3])), Only Nothing]

  describe "SqlValue dynamic decoding" $ do
    it "decodes varbinary and NULL binary columns as SqlValue" $ \conn -> do
      [ResultSet cols [SqlRow _ vals]] <- queryMulti conn
        "SELECT CAST(0x0102 AS varbinary(5)) AS a, CAST(NULL AS varbinary(5)) AS b"
      map columnName cols `shouldBe` ["a", "b"]
      vals `shouldBe` [SqlBinary (B.pack [1, 2]), SqlNull]

  describe "hedgehog: ByteString round trips" $ do
    it "round trips arbitrary bytes via SELECT @p1" $ \conn -> liveHedgehog $ do
      b <- forAll $ Gen.bytes (Range.linear 0 3000)
      Only b' <- evalIO $ query1 conn ("SELECT " <> param b)
      b' === b

    it "round trips arbitrary bytes through a temp table, matching DATALENGTH" $ \conn -> liveHedgehog $ do
      b <- forAll $ Gen.bytes (Range.linear 0 3000)
      evalIO $ do
        _ <- execute conn "IF OBJECT_ID('tempdb..#hh_vb') IS NULL CREATE TABLE #hh_vb (v varbinary(max))"
        _ <- execute conn "DELETE FROM #hh_vb"
        _ <- execute conn (mkQuery "INSERT INTO #hh_vb (v) VALUES (@p1)" (Only b))
        pure ()
      (b', dlen) <- evalIO (query1 conn "SELECT v, DATALENGTH(v) FROM #hh_vb" :: IO (B.ByteString, Int))
      b' === b
      dlen === B.length b

  slow $ describe "hedgehog: large ByteString round trips (slow)" $ do
    it "round trips bytes up to 100k in length" $ \conn -> liveHedgehog $ do
      b <- forAll $ Gen.bytes (Range.linear 0 100000)
      Only b' <- evalIO $ query1 conn ("SELECT " <> param b)
      b' === b
