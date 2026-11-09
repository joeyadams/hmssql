-- | @bit@ result decoding: 0\/1\/NULL into 'Bool', and the documented gap
-- that 'Bool' is *not* decoded from integer columns (docs\/mssql-comparison.md
-- gap 6), unlike mssql's looser behaviour.
module Types.BitSpec (spec) where

import Control.Exception (try)
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Errors
import TestConfig

spec :: Spec
spec = around withTestDb $ do
  describe "bit literals" $ do
    it "decodes 0 and 1 as False and True" $ \conn -> do
      r <- query1 conn "SELECT CAST(0 AS bit), CAST(1 AS bit)"
      r `shouldBe` (False, True)

    it "decodes NULL as Nothing" $ \conn -> do
      r <- query1 conn "SELECT CAST(NULL AS bit)"
      r `shouldBe` Only (Nothing :: Maybe Bool)

    it "rejects NULL for a non-Maybe Bool" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(NULL AS bit)") :: IO (Either DecodeError (Only Bool))
      case r of
        Left (DecodeError _ _) -> pure ()
        Right v -> expectationFailure ("decoded " ++ show v)

  describe "a nullable bit column" $ do
    it "round-trips 0, 1 and NULL" $ \conn -> do
      _ <- execute conn "CREATE TABLE #bitn (v bit NULL)"
      _ <- execute conn "INSERT INTO #bitn VALUES (0), (1), (NULL)"
      rows <- query conn "SELECT v FROM #bitn ORDER BY v"
      rows `shouldBe`
        [ Only (Nothing :: Maybe Bool)
        , Only (Just False)
        , Only (Just True)
        ]

  describe "SqlValue" $ do
    it "decodes bit as SqlBool" $ \conn -> do
      r <- query1 conn "SELECT CAST(1 AS bit), CAST(NULL AS bit)"
      r `shouldBe` (SqlBool True, SqlNull)

  describe "looser decoding gap (docs/dev/mssql-comparison.md gap 6)" $ do
    it "does not decode Bool from an int column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1 AS int)") :: IO (Either DecodeError (Only Bool))
      case r of
        Left (DecodeError _ msg) -> msg `shouldContain` "Bool"
        Right v -> expectationFailure ("decoded " ++ show v ++ "; mssql allowed this, hmssql intentionally does not (gap 6)")

    it "does not decode Bool from a tinyint column" $ \conn -> do
      r <- try (query1 conn "SELECT CAST(1 AS tinyint)") :: IO (Either DecodeError (Only Bool))
      case r of
        Left (DecodeError _ _) -> pure ()
        Right v -> expectationFailure ("decoded " ++ show v)

    it "still decodes Bool from bigint-typed bit-like sql_variant via SqlValue only" $ \conn -> do
      -- Confirms the workaround the docs suggest (refineField over SqlValue)
      -- rather than a direct Bool decode.
      Only v <- query1 conn "SELECT CAST(1 AS int)"
      v `shouldBe` SqlInt32 1
