{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Truncation / data-loss policy for bulk copy.  The requirement: a bulk
-- copy must never /silently/ lose data — a value that does not fit its
-- column must fail (a client 'EncodeError', preferred, or a server
-- 'SqlServerError'), storing no truncated row.
--
-- These tests confirm the client-side range and length checks, confirm the
-- server rejects the cases the client doesn't check (char/varchar, remapped
-- to @nvarchar(max)@, have no client length check), verify @decimal@ scale
-- rounding matches @executeMany@, and pin down the one place data is lost
-- silently — a character absent from a single-byte code page is stored as
-- @'?'@ with no error (see the findings report; the same happens through
-- @executeMany@, i.e. it is SQL Server's implicit conversion, but bulk
-- copy could add a client-side check like the one it already has for a
-- @DescribedColumns@ ANSI column).
module Bulk.PolicySpec (spec) where

import Control.Monad (void)
import qualified Data.ByteString as B
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Types
import Hmssql.Errors
import TestDb

import Bulk.Harness

-- | A 'Decimal' with the given scale and mantissa (fixes the otherwise
-- ambiguous @DecimalRaw i@).
dec :: Word8 -> Integer -> Decimal
dec = Decimal

spec :: Spec
spec = around withTestDb $ do
  describe "client-side range checks (EncodeError, nothing sent)" $ do
    it "tinyint above 255" $ \conn -> expectRejected conn "tinyint" (SqlParam (300 :: Int32))
    it "tinyint below 0" $ \conn -> expectRejected conn "tinyint" (SqlParam (-1 :: Int32))
    it "smallint out of range" $ \conn -> expectRejected conn "smallint" (SqlParam (40000 :: Int32))
    it "int out of range" $ \conn -> expectRejected conn "int" (SqlParam (5000000000 :: Int64))
    it "money out of range" $ \conn -> expectRejected conn "money" (SqlParam (Money 1.0e15))
    it "smallmoney out of range" $ \conn -> expectRejected conn "smallmoney" (SqlParam (Money 300000))
    it "decimal needs more integer digits than the precision"
      $ \conn -> expectRejected conn "decimal(4,2)" (SqlParam (dec 2 123456)) -- 1234.56
    it "decimal(5,2) integer overflow"
      $ \conn -> expectRejected conn "decimal(5,2)" (SqlParam (dec 2 1234567)) -- 12345.67

  describe "client-side length checks (EncodeError, nothing sent)" $ do
    it "nvarchar(5) too long" $ \conn -> expectRejected conn "nvarchar(5)" (SqlParam ("toolong" :: Text))
    it "nchar(5) too long" $ \conn -> expectRejected conn "nchar(5)" (SqlParam ("toolong" :: Text))
    it "varbinary(5) too long" $ \conn -> expectRejected conn "varbinary(5)" (SqlParam (B.replicate 6 0xAA))
    it "binary(4) too long" $ \conn -> expectRejected conn "binary(4)" (SqlParam (B.replicate 6 0xAA))

  describe "char/varchar length: checked client-side (independent of ANSI_WARNINGS)" $ do
    -- char/varchar/text are sent as nvarchar but validated against the
    -- real (bounded) type on the client, so an over-long value is an
    -- EncodeError before anything is sent -- not dependent on the server's
    -- ANSI_WARNINGS (which, if OFF, would truncate silently).
    it "varchar(5) too long is a client EncodeError" $ \conn -> do
      (kind, cnt) <- probeBulk conn "varchar(5)" (SqlParam ("toolong" :: Text))
      case kind of ClientEncode _ -> pure (); _ -> expectationFailure ("expected ClientEncode, got " <> show kind)
      cnt `shouldBe` 0
    it "char(4) too long is a client EncodeError" $ \conn -> do
      (kind, cnt) <- probeBulk conn "char(4)" (SqlParam ("toolong" :: Text))
      case kind of ClientEncode _ -> pure (); _ -> expectationFailure ("expected ClientEncode, got " <> show kind)
      cnt `shouldBe` 0
    it "the same value is rejected through executeMany too (server-side)" $ \conn -> do
      (kind, cnt) <- probeBatch conn "varchar(5)" (SqlParam ("toolong" :: Text))
      rejected kind `shouldBe` True
      cnt `shouldBe` 0

  describe "type-family mismatches (EncodeError)" $ do
    it "Text into an int column" $ \conn -> expectRejected conn "int" (SqlParam ("hello" :: Text))
    it "a number into an nvarchar column" $ \conn -> expectRejected conn "nvarchar(20)" (SqlParam (42 :: Int32))
    it "a number into a varchar column" $ \conn -> expectRejected conn "varchar(20)" (SqlParam (42 :: Int32))

  describe "NULL into a NOT NULL column (EncodeError, naming the row)" $
    it "fails naming the row and column" $ \conn -> do
      void $ execute conn "CREATE TABLE #nn (v int NOT NULL)"
      bulkInsert conn "#nn" [Only (Nothing :: Maybe Int32)]
        `shouldThrow` (\(EncodeError m) -> "row 0" `T.isInfixOf` T.pack m && "NOT NULL" `T.isInfixOf` T.pack m)

  describe "decimal scale rounding is lossy-by-design but matches executeMany" $ do
    -- Rounding to the column scale is acceptable IF bulk and executeMany
    -- store identical values.  Exact decimal inputs: half away from zero.
    it "rounds exact decimals half away from zero, identically to executeMany"
      $ \conn -> checkTypeCase conn $ typeCase "decimal(8,2) rounding" "decimal(8,2)"
          [ into (dec 3 2345) (dec 2 235)      -- 2.345 -> 2.35
          , into (dec 3 2355) (dec 2 236)      -- 2.355 -> 2.36
          , into (dec 3 (-2345)) (dec 2 (-235))-- -2.345 -> -2.35
          , into (dec 3 2344) (dec 2 234)      -- 2.344 -> 2.34
          , into (dec 3 2346) (dec 2 235)      -- 2.346 -> 2.35
          ]
    it "Double inputs round as executeMany does, at exact binary ties too"
      $ \conn -> do
          -- The server rounds a float into a decimal from its exact binary
          -- value, half away from zero, and so does bulk copy: at the ties
          -- 0.125 and -0.125, and at 2.355, whose nearest Double is just
          -- below 2.355 and so rounds down on both paths.
          let vals = map (SqlParam @Double) [0.125, 0.375, -0.125, 2.345, 2.355, 1234567.125]
              rows = [[SqlParam (i :: Int32), v] | (i, v) <- zip [1 ..] vals]
          tb <- createTable conn "decimal(10,2)"
          te <- createTable conn "decimal(10,2)"
          _ <- loadBulk conn tb rows
          _ <- loadBatch conn te rows
          bulkVals <- readColumn conn "v" tb :: IO [Maybe Decimal]
          batchVals <- readColumn conn "v" te :: IO [Maybe Decimal]
          batchVals `shouldBe` map (Just . dec 2) [13, 38, -13, 235, 235, 123456713]
          bulkVals `shouldBe` batchVals

  describe "single-byte code-page loss is refused client-side" $
    -- A character absent from the column's single-byte code page would be
    -- stored as '?' by the server (SQL Server's implicit nvarchar->varchar
    -- conversion; executeMany loses it too).  Bulk copy validates the value
    -- against the real varchar collation on the client and refuses it with
    -- an EncodeError, so no data is silently lost.
    it "refuses a CJK character in a CP1252 varchar (client EncodeError, nothing stored)" $ \conn -> do
      let ddl = "varchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS"
      (kindBulk, cntBulk) <- probeBulk conn ddl (SqlParam ("\x65E5\x672C" :: Text)) -- 日本
      case kindBulk of
        ClientEncode _ -> pure ()
        _ -> expectationFailure ("expected ClientEncode, got " <> show kindBulk)
      cntBulk `shouldBe` 0
      -- executeMany (a plain parameterized INSERT) still loses it to '?',
      -- which is SQL Server's own conversion, out of the library's control.
      (kindBatch, _) <- probeBatch conn ddl (SqlParam ("\x65E5\x672C" :: Text))
      rejected kindBatch `shouldBe` False
