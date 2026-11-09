{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Property-based / fuzz tests for the bulk copy wire encoding
-- ('Hmssql.BulkCopy.bulkInsert').  Where "Bulk.TypesSpec" and
-- "Bulk.PolicySpec" are example-based, these hedgehog properties fuzz the
-- values that hit the wire-format boundaries:
--
--   1. __PLP chunk boundaries__ — the bulk PLP chunk is 8000 bytes
--      ('Hmssql.BulkCopy.bulkChunk'); values at and around multiples of 8000
--      bytes for @varbinary(max)@, @nvarchar(max)@, @varchar(max)@ (UTF-8),
--      @text@, @ntext@ and @image@.
--   2. __Packet-size boundaries__ — several negotiated packet sizes
--      ('connectPacketSize'); many small rows and single large values sized
--      so rows/values straddle packet boundaries, exercising @writeRow@'s
--      split-across-packets path and the full-intermediate-packet rule.
--   3. __varchar\/nvarchar length limits__ — string lengths around @n@,
--      @n-1@, @n+1@ and the @nvarchar(4000)@\/@varchar(8000)@ vs @(max)@
--      thresholds; a fitting value round-trips and equals @executeMany@, an
--      over-long value into a bounded column fails cleanly (client
--      'EncodeError' or server rejection) storing nothing.
--   4. __Surrogate-pair \/ UTF-16 length discrepancies__ — @nvarchar(n)@
--      counts UTF-16 code units (a non-BMP char is 2), a UTF-8 @varchar(n)@
--      counts bytes (a non-BMP char is 4); embedded NUL and combining marks.
--   5. __A general equivalence fuzz__ — random values across a spread of
--      types.
--
-- Every property loads a value both by 'bulkInsert' and by 'executeMany'
-- and asserts, through "Bulk.Harness", that the two store byte-identical
-- data (value-for-value and by @DATALENGTH@) and round-trip to the input —
-- or, for a value that does not fit a bounded column, that bulk copy fails
-- cleanly and stores nothing ('expectRejected'), never silently truncating.
module Bulk.FuzzSpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.ByteString (ByteString)
import Data.Decimal (Decimal, DecimalRaw (..))
import Data.Int (Int32, Int64)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, fromGregorian)
import Data.Word (Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import TestDb

import Bulk.Harness
import LiveProperty (liveHedgehog)

------------------------------------------------------------------------------
-- The spec

spec :: Spec
spec = do
  around withTestDb $ do
    describe "1. PLP chunk-size boundaries (8000-byte chunks)" plpSpec
    describe "3. varchar/nvarchar length limits" lengthSpec
    describe "4. surrogate-pair / UTF-16 length discrepancies" surrogateSpec
    describe "5. general equivalence fuzz" generalSpec
  -- Packet-size properties open their own connection (a specific negotiated
  -- packet size), so they run outside the shared 'withTestDb' connection.
  describe "2. packet-size boundaries" packetSpec

------------------------------------------------------------------------------
-- Shared helpers

-- | Load a value list into a fresh @#temp@ pair by both paths and assert
-- round trip + equivalence (value-for-value and by @DATALENGTH@).
equiv :: (FromSqlField b, Eq b, Show b) => Connection -> String -> Text -> [Cell b] -> PropertyT IO ()
equiv conn name ddl cells = evalIO $ checkTypeCase conn (TypeCase name ddl "v" True cells)

-- | Assert that bulk copy rejects a value that does not fit the column and
-- stores nothing (client 'EncodeError' preferred, server rejection allowed).
reject :: Connection -> Text -> SqlParam -> PropertyT IO ()
reject conn ddl v = evalIO $ expectRejected conn ddl v

-- | A connection at a specific negotiated packet size (drives bulk framing).
withPacketSize :: Word32 -> (Connection -> IO a) -> IO a
withPacketSize sz act = do
  ci <- defaultTestConnectInfo
  withConnection ci { connectPacketSize = sz } act

tshow :: Int -> Text
tshow = T.pack . show

-- | A BMP scalar value (one UTF-16 code unit), never a surrogate.
genBmp :: Gen Char
genBmp = Gen.choice [Gen.enum '\x0001' '\xD7FF', Gen.enum '\xE000' '\xFFFD']

-- | A non-BMP (astral) scalar value (a surrogate pair: two UTF-16 code
-- units, four UTF-8 bytes).
genAstral :: Gen Char
genAstral = Gen.choice [Gen.enum '\x1F300' '\x1FAFF', Gen.enum '\x10000' '\x10FFFF']

-- | Exactly @c@ BMP code units of text (byte length @2*c@ as UTF-16).
genBmpText :: Int -> Gen Text
genBmpText c = T.pack <$> Gen.list (Range.singleton (max 0 c)) genBmp

-- | Exactly @l@ printable-ASCII characters (byte length @l@ single-byte or
-- UTF-8).
genAsciiText :: Int -> Gen Text
genAsciiText l = T.pack <$> Gen.list (Range.singleton (max 0 l)) (Gen.enum ' ' '~')

------------------------------------------------------------------------------
-- 1. PLP chunk-size boundaries

-- | Byte lengths at and around multiples of the 8000-byte PLP chunk, plus a
-- random spread over several chunks.
boundaryBytes :: [Int]
boundaryBytes =
  [ 0, 1, 2, 7999, 8000, 8001, 8002
  , 15999, 16000, 16001, 23999, 24000, 24001, 31999, 32000, 32001 ]

genByteLen :: Gen Int
genByteLen = Gen.choice [Gen.element boundaryBytes, Gen.integral (Range.linear 0 32001)]

-- | One PLP-carrying column type and how to build a value of a target byte
-- length for it.  (Each closure is monomorphic in its read-back type.)
plpSpecs :: [(String, Connection -> Int -> PropertyT IO ())]
plpSpecs =
  [ ( "varbinary(max)"
    , \conn l -> do b <- forAll (Gen.bytes (Range.singleton l)); equiv conn "varbinary(max)" "varbinary(max)" [same b] )
  , ( "image"
    , \conn l -> do b <- forAll (Gen.bytes (Range.singleton l)); equiv conn "image" "image" [same b] )
  , ( "nvarchar(max)"
    , \conn l -> do t <- forAll (genBmpText (l `div` 2)); equiv conn "nvarchar(max)" "nvarchar(max)" [same t] )
  , ( "ntext"
    , \conn l -> do t <- forAll (genBmpText (l `div` 2)); equiv conn "ntext" "ntext" [same t] )
  , ( "varchar(max) UTF-8"
    , \conn l -> do t <- forAll (genAsciiText l)
                    equiv conn "varchar(max) utf8" "varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8" [same t] )
  , ( "text"
    , \conn l -> do t <- forAll (genAsciiText l); equiv conn "text" "text" [same t] )
  ]

plpSpec :: SpecWith Connection
plpSpec = forM_ plpSpecs $ \(name, build) ->
  (if "UTF-8" `isInfixOf` name then skipBeforeSql2019 "UTF-8 collations" else id) $
  withCases 20 $ it ("round-trips " <> name <> " at chunk boundaries") $ \conn -> liveHedgehog $ do
    l <- forAll genByteLen
    build conn l

------------------------------------------------------------------------------
-- 2. Packet-size boundaries

packetSpec :: Spec
packetSpec = forM_ ([512, 517, 1000, 4096, 8192, 32767] :: [Word32]) $ \sz ->
  describe ("negotiated packet size " <> show sz) $ around (withPacketSize sz) $ do
    withCases 15 $ it "many small rows straddle packet boundaries" $ \conn -> liveHedgehog $ do
      nrows <- forAll (Gen.int (Range.linear 200 400))
      rows  <- forAll (Gen.list (Range.singleton nrows) (Gen.bytes (Range.linear 0 40)))
      equiv conn "many small varbinary rows" "varbinary(64)" (map same rows)
    withCases 25 $ it "a single value larger than one packet" $ \conn -> liveHedgehog $ do
      let payload = fromIntegral sz - 8 :: Int
      l      <- forAll (Gen.int (Range.linear (max 0 (payload - 4)) (3 * payload + 8)))
      useBin <- forAll Gen.bool
      if useBin
        then do b <- forAll (Gen.bytes (Range.singleton l)); equiv conn "big varbinary(max)" "varbinary(max)" [same b]
        else do t <- forAll (genBmpText (l `div` 2)); equiv conn "big nvarchar(max)" "nvarchar(max)" [same t]

------------------------------------------------------------------------------
-- 3. varchar/nvarchar length limits

lengthSpec :: SpecWith Connection
lengthSpec = do
  withCases 60 $ it "bounded char/nchar/varchar/nvarchar at n-1, n, n+1" $ \conn -> liveHedgehog $ do
    kind  <- forAll (Gen.element ["nvarchar", "nchar", "varchar", "char"])
    n     <- forAll (Gen.integral (Range.linear 1 300))
    delta <- forAll (Gen.element [-2, -1, 0, 1, 2 :: Int])
    let len = max 0 (n + delta)
        val = T.replicate len "a"
        ddl = T.pack kind <> "(" <> tshow n <> ")"
    if len <= n
      then case kind of
        "char"  -> equiv conn "char"  ddl [into val (T.justifyLeft n ' ' val)]
        "nchar" -> equiv conn "nchar" ddl [into val (T.justifyLeft n ' ' val)]
        _       -> equiv conn kind    ddl [same val]
      else reject conn ddl (SqlParam val)

  withCases 30 $ it "nvarchar(4000) vs nvarchar(max) at the 4000/4001 threshold" $ \conn -> liveHedgehog $ do
    len <- forAll (Gen.integral (Range.linear 3990 4010))
    let val = T.replicate len "a"
    if len <= 4000
      then equiv conn "nvarchar(4000)" "nvarchar(4000)" [same val]
      else reject conn "nvarchar(4000)" (SqlParam val)
    equiv conn "nvarchar(max)" "nvarchar(max)" [same val]

  withCases 30 $ it "varchar(8000) vs varchar(max) at the 8000/8001 threshold" $ \conn -> liveHedgehog $ do
    len <- forAll (Gen.integral (Range.linear 7990 8010))
    let val = T.replicate len "a"
    if len <= 8000
      then equiv conn "varchar(8000)" "varchar(8000)" [same val]
      else reject conn "varchar(8000)" (SqlParam val)
    equiv conn "varchar(max)" "varchar(max)" [same val]

  skipBeforeSql2019 "UTF-8 collations" $ withCases 40 $ it "varchar(n) UTF-8: byte-length boundary (bytes != chars)" $ \conn -> liveHedgehog $ do
    c <- forAll (Gen.integral (Range.linear 0 150))
    n <- forAll (Gen.integral (Range.linear 1 300))
    let val   = T.replicate c "\x00E9"    -- U+00E9 é: two UTF-8 bytes
        nbyte = 2 * c
        ddl   = "varchar(" <> tshow n <> ") COLLATE Latin1_General_100_CI_AS_SC_UTF8"
    if nbyte <= n
      then equiv conn "utf8 varchar fit" ddl [same val]
      else reject conn ddl (SqlParam val)

------------------------------------------------------------------------------
-- 4. Surrogate-pair / UTF-16 length discrepancies

surrogateSpec :: SpecWith Connection
surrogateSpec = do
  withCases 30 $ it "nvarchar(n) counts UTF-16 code units, mixing BMP and astral" $ \conn -> liveHedgehog $ do
    parts <- forAll (Gen.list (Range.linear 2 40) (Gen.choice [genBmp, genAstral]))
    let t  = T.pack parts
        cu = sum [if c > '\xFFFF' then 2 else 1 | c <- parts]   -- UTF-16 code units
    -- n code units fit nvarchar(cu); one fewer is rejected.
    equiv conn "mixed BMP/astral fits nvarchar(cu)" ("nvarchar(" <> tshow cu <> ")") [same t]
    reject conn ("nvarchar(" <> tshow (cu - 1) <> ")") (SqlParam t)

  skipBeforeSql2019 "UTF-8 collations" $ withCases 30 $ it "astral chars into varchar(n) UTF-8 are 4 bytes each" $ \conn -> liveHedgehog $ do
    k  <- forAll (Gen.integral (Range.linear 1 40))
    cs <- forAll (Gen.list (Range.singleton k) genAstral)
    let t      = T.pack cs
        nbyte  = 4 * k
        utf8 n = "varchar(" <> tshow n <> ") COLLATE Latin1_General_100_CI_AS_SC_UTF8"
    equiv conn "astral fits varchar(4k) utf8" (utf8 nbyte) [same t]
    reject conn (utf8 (nbyte - 1)) (SqlParam t)

  withCases 40 $ it "nvarchar(max) round-trips NUL, combining marks, BMP and astral" $ \conn -> liveHedgehog $ do
    t <- forAll (Gen.text (Range.linear 0 200)
                   (Gen.choice [pure '\0', Gen.enum '\x0300' '\x036F', genBmp, genAstral]))
    equiv conn "messy nvarchar(max)" "nvarchar(max)" [same t]

------------------------------------------------------------------------------
-- 5. General equivalence fuzz

generalSpec :: SpecWith Connection
generalSpec = do
  withCases 80 $ it "int" $ \conn -> liveHedgehog $ do
    v <- forAll (Gen.integral Range.linearBounded :: Gen Int32)
    equiv conn "int" "int" [same v]

  withCases 80 $ it "bigint" $ \conn -> liveHedgehog $ do
    v <- forAll (Gen.integral Range.linearBounded :: Gen Int64)
    equiv conn "bigint" "bigint" [same v]

  withCases 80 $ it "decimal(38,4) (exact Decimal, no Double divergence)" $ \conn -> liveHedgehog $ do
    m <- forAll (Gen.integral (Range.linearFrom 0 (negate (10 ^ (38 :: Int) - 1)) (10 ^ (38 :: Int) - 1)) :: Gen Integer)
    equiv conn "decimal(38,4)" "decimal(38,4)" [same (Decimal 4 m)]

  withCases 80 $ it "float" $ \conn -> liveHedgehog $ do
    d <- forAll (Gen.double (Range.linearFracFrom 0 (-1.0e15) 1.0e15))
    equiv conn "float" "float" [same d]

  withCases 60 $ it "nvarchar(200) unicode (BMP)" $ \conn -> liveHedgehog $ do
    t <- forAll (Gen.text (Range.linear 0 200) genBmp)
    equiv conn "nvarchar(200)" "nvarchar(200)" [same t]

  withCases 60 $ it "varbinary(200)" $ \conn -> liveHedgehog $ do
    b <- forAll (Gen.bytes (Range.linear 0 200))
    equiv conn "varbinary(200)" "varbinary(200)" [same (b :: ByteString)]

  withCases 60 $ it "date" $ \conn -> liveHedgehog $ do
    y  <- forAll (Gen.integral (Range.linear 1 9999) :: Gen Int)
    mo <- forAll (Gen.integral (Range.linear 1 12) :: Gen Int)
    d  <- forAll (Gen.integral (Range.linear 1 28) :: Gen Int)
    equiv conn "date" "date" [same (fromGregorian (fromIntegral y) mo d :: Day)]
