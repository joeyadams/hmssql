-- | Pure round-trip properties for the wire encoders; no server needed.
module WireSpec (spec) where

import Wire.PrimitiveGet (getMoney4, getMoney8, getDateTime4, getDateTime8, getDate, getTime, getDateTime2, getDateTimeOffset, getDecimal, getGuid, getCollation, getBVarChar, getUsVarChar)
import Wire.RecipeGet (getToken, getTypeInfo, getValue)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (DecimalRaw (..))
import Data.Fixed (Fixed (..))
import qualified Data.Text as T
import Data.Time
import qualified Data.UUID.Types as UUID
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog

import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives
import Hmssql.Tds.Value (rowValues)
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo

import Wire.Util (genPayload)

roundTrip :: (Eq a, Show a, MonadTest m) => (a -> Put.Put) -> Get.Get a -> a -> m ()
roundTrip put get a = do
  let bytes = Put.runPut (put a)
  case Get.runGetOrFail get bytes of
    Left (_, _, err) -> annotate err >> failure
    Right (rest, _, a') -> do
      LB.null rest === True
      a' === a

-- | For encoders that can reject a value; the generators stay in range.
unsafeRight :: Either String a -> a
unsafeRight = either error id

genCollation :: Gen Collation
genCollation = Collation <$> Gen.word32 Range.linearBounded <*> Gen.word8 Range.linearBounded

genText :: Gen T.Text
genText = Gen.text (Range.linear 0 40) Gen.unicode

genScale :: Gen Scale
genScale = Gen.word8 (Range.linear 0 7)

genDay :: Gen Day
genDay = ModifiedJulianDay <$> Gen.integral (Range.linear (-678575) 2973483)

-- | A time of day exactly representable at the given scale.
genTimeAtScale :: Scale -> Gen TimeOfDay
genTimeAtScale s = do
  units <- Gen.integral (Range.linear 0 (86400 * 10 ^ (fromIntegral s :: Int) - 1))
  pure $ timeToTimeOfDay (picosecondsToDiffTime (units * 10 ^ (12 - fromIntegral s :: Int)))

genTypeInfo :: Gen TypeInfo
genTypeInfo = Gen.choice
  [ Gen.element [TINull, TIBit, TIInt1, TIInt2, TIInt4, TIInt8, TIMoney4, TIMoney8, TIDateTime4, TIDateTime8, TIFlt4, TIFlt8, TIBitN, TIGuid, TIDateN]
  , TIIntN <$> Gen.element [1, 2, 4, 8]
  , TIMoneyN <$> Gen.element [4, 8]
  , TIDateTimeN <$> Gen.element [4, 8]
  , TIFltN <$> Gen.element [4, 8]
  , precisionScale TIDecimalN
  , precisionScale TINumericN
  , TITimeN <$> genScale
  , TIDateTime2N <$> genScale
  , TIDateTimeOffsetN <$> genScale
  , TIBigChar <$> Gen.word16 (Range.linear 1 8000) <*> genCollation
  , TIBigVarChar <$> Gen.choice [Gen.word16 (Range.linear 1 8000), pure maxLength] <*> genCollation
  , TIText <$> Gen.word32 Range.linearBounded <*> genCollation
  , TINChar <$> Gen.word16 (Range.linear 2 8000) <*> genCollation
  , TINVarChar <$> Gen.choice [Gen.word16 (Range.linear 2 8000), pure maxLength] <*> genCollation
  , TINText <$> Gen.word32 Range.linearBounded <*> genCollation
  , TIBigBinary <$> Gen.word16 (Range.linear 1 8000)
  , TIBigVarBinary <$> Gen.choice [Gen.word16 (Range.linear 1 8000), pure maxLength]
  , TIImage <$> Gen.word32 Range.linearBounded
  , pure (TIXml Nothing)
  , TIXml . Just <$> (XmlSchema <$> genText <*> genText <*> genText)
  , TISqlVariant <$> Gen.word32 Range.linearBounded
  ]
  where
    -- 1 <= precision <= 38, scale <= precision
    precisionScale mk = do
      p <- Gen.word8 (Range.linear 1 38)
      mk p <$> Gen.word8 (Range.linear 0 p)

-- | A raw value of the right shape for the type.
genValueFor :: TypeInfo -> Gen RawBytes
genValueFor ti = case ti of
  TINull -> pure Nothing
  TIBit -> fixed 1
  TIInt1 -> fixed 1
  TIInt2 -> fixed 2
  TIInt4 -> fixed 4
  TIInt8 -> fixed 8
  TIMoney4 -> fixed 4
  TIMoney8 -> fixed 8
  TIDateTime4 -> fixed 4
  TIDateTime8 -> fixed 8
  TIFlt4 -> fixed 4
  TIFlt8 -> fixed 8
  TIBitN -> nullable (exactly 1)
  TIIntN n -> nullable (exactly (fromIntegral n))
  TIMoneyN n -> nullable (exactly (fromIntegral n))
  TIDateTimeN n -> nullable (exactly (fromIntegral n))
  TIFltN n -> nullable (exactly (fromIntegral n))
  TIGuid -> nullable (exactly 16)
  TIDecimalN p _ -> nullable (exactly (precisionToLength p + 1))
  TINumericN p _ -> nullable (exactly (precisionToLength p + 1))
  TIDateN -> nullable (exactly 3)
  TITimeN s -> nullable (exactly (timeLength s))
  TIDateTime2N s -> nullable (exactly (timeLength s + 3))
  TIDateTimeOffsetN s -> nullable (exactly (timeLength s + 5))
  -- a non-NULL sql_variant has at least its base type and property-length bytes
  TISqlVariant _ -> nullable (Gen.bytes (Range.linear 2 8016))
  _ -> nullable (Gen.bytes (Range.linear 0 20000))
  where
    fixed n = Just <$> exactly n
    exactly n = Gen.bytes (Range.singleton n)
    nullable g = Gen.frequency [(1, pure Nothing), (4, Just <$> g)]

spec :: Spec
spec = do
  describe "packet header" $
    it "round-trips" $ hedgehog $ do
      hdr <- forAll $ Header
        <$> Gen.element [PTSqlBatch, PTRpc, PTTabularResult, PTAttention, PTLogin7, PTPrelogin, PTOther 0x55]
        <*> (PacketStatus <$> Gen.word8 Range.linearBounded)
        <*> Gen.word16 (Range.linear 8 32767)
        <*> Gen.word16 Range.linearBounded
        <*> Gen.word8 Range.linearBounded
        <*> Gen.word8 Range.linearBounded
      roundTrip putHeader getHeader hdr

  describe "splitIntoPackets" $
    it "frames a message so the bodies concatenate back" $ hedgehog $ do
      size <- forAll $ Gen.word32 (Range.linear 9 600)
      body <- forAll $ Gen.bytes (Range.linear 0 5000)
      let ctx = defaultTdsContext { tdsPacketSize = size }
          packets = splitIntoPackets ctx PTSqlBatch (PacketStatus 0) (LB.fromStrict body)
          parsed = [ (Get.runGet getHeader (LB.fromStrict p), B.drop headerLength p) | p <- packets ]
      B.concat (map snd parsed) === body
      assert $ all (\(h, b) -> fromIntegral (headerPacketLength h) == B.length b + headerLength) parsed
      assert $ all (\(h, _) -> fromIntegral (headerPacketLength h) <= size) parsed
      [ headerStatus h == PacketStatus 1 | (h, _) <- parsed ] === replicate (length packets - 1) False ++ [True]
      map (headerPacketId . fst) parsed === take (length packets) (cycle [0 .. 255])

  describe "frameSegments" $
    it "is splitIntoPackets' packets, as many whole ones per chunk as fit" $ hedgehog $ do
      size <- forAll $ Gen.word32 (Range.linear 9 600)
      body <- forAll $ Gen.bytes (Range.linear 0 5000)
      target <- forAll $ Gen.int (Range.linear 0 3000)
      reset <- forAll Gen.bool
      let ctx = defaultTdsContext { tdsPacketSize = size }
          status = if reset then statusResetConnection else PacketStatus 0
          packets = splitIntoPackets ctx PTRpc status (LB.fromChunks (chunksOf 97 body))
          segments = frameSegments target ctx PTRpc status (LB.fromChunks (chunksOf 97 body))
          perSegment = max 1 (target `div` fromIntegral size)
      B.concat segments === B.concat packets
      map B.length segments === map (sum . map B.length) (groupsOf perSegment packets)

  describe "splitIntoPackets with a packet size the header cannot describe" $
    it "clamps it (at least one byte of payload, at most 32767 bytes per packet)" $ hedgehog $ do
      size <- forAll $ Gen.choice [Gen.word32 (Range.linear 0 8), Gen.word32 (Range.linear 32768 maxBound)]
      body <- forAll $ genPayload 70000
      let ctx = defaultTdsContext { tdsPacketSize = size }
          packets = splitIntoPackets ctx PTSqlBatch (PacketStatus 0) (LB.fromStrict body)
          parsed = [ (Get.runGet getHeader (LB.fromStrict p), B.drop headerLength p) | p <- take 100000 packets ]
      assert $ length parsed < 100000
      B.concat (map snd parsed) === body
      assert $ all (\(h, b) -> fromIntegral (headerPacketLength h) == B.length b + headerLength) parsed
      assert $ all (\(h, _) -> headerPacketLength h <= 32767) parsed

  describe "primitives" $ do
    it "money round-trips" $ hedgehog $ do
      m <- forAll $ Money . MkFixed <$> Gen.integral (Range.linearFrom 0 (-922337203685477) 922337203685477)
      roundTrip putMoney8 getMoney8 m
    it "smallmoney round-trips" $ hedgehog $ do
      m <- forAll $ Money . MkFixed <$> Gen.integral (Range.linearFrom 0 (-2147483648) 2147483647)
      roundTrip putMoney4 getMoney4 m
    it "date round-trips" $ hedgehog $ do
      d <- forAll genDay
      roundTrip (unsafeRight . putDate) getDate d
    it "time round-trips at every scale" $ hedgehog $ do
      s <- forAll genScale
      tod <- forAll (genTimeAtScale s)
      roundTrip (unsafeRight . putTime s) (getTime s) tod
    it "datetime2 round-trips" $ hedgehog $ do
      s <- forAll genScale
      d <- forAll genDay
      tod <- forAll (genTimeAtScale s)
      roundTrip (unsafeRight . putDateTime2 s) (getDateTime2 s) (LocalTime d tod)
    it "datetimeoffset round-trips" $ hedgehog $ do
      s <- forAll genScale
      d <- forAll genDay
      tod <- forAll (genTimeAtScale s)
      off <- forAll $ Gen.int16 (Range.linearFrom 0 (-840) 840)
      roundTrip (unsafeRight . putDateTimeOffset s) (getDateTimeOffset s) (DateTimeOffset (UTCTime d (timeOfDayToTime tod)) off)
    it "legacy datetime round-trips at 1/300s" $ hedgehog $ do
      days <- forAll $ Gen.integral (Range.linear (-53690) 2958463)
      ticks <- forAll $ Gen.integral (Range.linear 0 (300 * 86400 - 1))
      let lt = LocalTime (addDays days (fromGregorian 1900 1 1))
                 (timeToTimeOfDay (picosecondsToDiffTime (ticks * 1_000_000_000_000 `div` 300)))
      roundTrip (unsafeRight . putDateTime8) getDateTime8 lt
    it "smalldatetime round-trips" $ hedgehog $ do
      days <- forAll $ Gen.integral (Range.linear 0 65535)
      mins <- forAll $ Gen.integral (Range.linear 0 (1439 :: Integer))
      let lt = LocalTime (addDays days (fromGregorian 1900 1 1)) (TimeOfDay (fromIntegral (mins `div` 60)) (fromIntegral (mins `mod` 60)) 0)
      roundTrip (unsafeRight . putDateTime4) getDateTime4 lt
    it "decimal round-trips" $ hedgehog $ do
      p <- forAll $ Gen.word8 (Range.linear 1 38)
      s <- forAll $ Gen.word8 (Range.linear 0 p)
      mantissa <- forAll $ Gen.integral (Range.linearFrom 0 (negate (10 ^ (fromIntegral p :: Int) - 1)) (10 ^ (fromIntegral p :: Int) - 1))
      roundTrip (putDecimal p s) (getDecimal p s (precisionToLength p + 1)) (Decimal s mantissa)
    it "guid round-trips" $ hedgehog $ do
      u <- forAll $ UUID.fromWords <$> w32 <*> w32 <*> w32 <*> w32
      roundTrip putGuid getGuid u
    it "guid uses SQL Server byte order" $ do
      let u = UUID.fromWords 0x01020304 0x05060708 0x090a0b0c 0x0d0e0f10
      LB.unpack (Put.runPut (putGuid u)) `shouldBe`
        [4, 3, 2, 1, 6, 5, 8, 7, 9, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10]
    it "collation round-trips" $ hedgehog $ do
      c <- forAll genCollation
      roundTrip putCollation getCollation c
    it "B_VARCHAR / US_VARCHAR round-trip" $ hedgehog $ do
      t <- forAll genText
      roundTrip putBVarChar getBVarChar t
      roundTrip putUsVarChar getUsVarChar t

  describe "TYPE_INFO" $ do
    it "round-trips" $ hedgehog $ do
      ti <- forAll genTypeInfo
      roundTrip (putTypeInfo defaultTdsContext) (getTypeInfo defaultTdsContext) ti
    it "values round-trip for every type" $ hedgehog $ do
      ti <- forAll genTypeInfo
      v <- forAll (genValueFor ti)
      roundTrip (putValue defaultTdsContext ti) (getValue defaultTdsContext ti) v
    it "PLP values are sent as one chunk" $ do
      let ti = TIBigVarBinary maxLength
          v = Just (B.replicate 20000 0xAB)
          bytes = Put.runPut (putValue defaultTdsContext ti v)
      LB.length bytes `shouldBe` 8 + 4 + 20000 + 4
      Get.runGet (getValue defaultTdsContext ti) bytes `shouldBe` v
    it "reads unknown-length PLP" $ do
      let bytes = Put.runPut $ do
            Put.putWord64le 0xFFFFFFFFFFFFFFFE
            Put.putWord32le 3 >> Put.putByteString "abc"
            Put.putWord32le 2 >> Put.putByteString "de"
            Put.putWord32le 0
      Get.runGet (getValue defaultTdsContext (TINVarChar maxLength (Collation 0 0))) bytes `shouldBe` Just "abcde"

  describe "PRELOGIN" $
    it "round-trips" $ hedgehog $ do
      opts <- forAll $ Gen.list (Range.linear 1 6) $ Gen.choice
        [ PLVersion <$> w8 <*> w8 <*> w16 <*> w16
        , PLEncryption <$> Gen.word8 (Range.linear 0 4)
        , PLInstance . B.filter (/= 0) <$> Gen.bytes (Range.linear 0 20)
        , PLThreadId <$> Gen.maybe w32
        , PLMars <$> Gen.word8 (Range.linear 0 1)
        , PLTraceId <$> Gen.bytes (Range.singleton 16) <*> Gen.bytes (Range.singleton 16) <*> w32
        , PLFedAuthRequired <$> Gen.word8 (Range.linear 0 1)
        , PLNonce <$> Gen.bytes (Range.singleton 32)
        ]
      roundTrip putPrelogin getPrelogin (Prelogin opts)

  describe "LOGIN7" $ do
    it "obfuscates the password as the spec describes" $
      B.unpack (obfuscatePassword (B.pack [0x61, 0x00])) `shouldBe` [0xB3, 0xA5]
    it "declares its own length and places the FeatureExt offset" $ hedgehog $ do
      user <- forAll genText
      db <- forAll genText
      let l7 = defaultLogin7 { l7UserName = user, l7Database = db, l7Password = "secret" }
          bytes = Put.runPut (putLogin7 l7)
          declared = Get.runGet Get.getWord32le bytes
      fromIntegral declared === LB.length bytes
      LB.last bytes === 0xFF
      -- offset/length pair for the extension slot sits after 5 string slots
      let extSlotOffset = Get.runGet (Get.skip (36 + 5 * 4) >> Get.getWord16le) bytes
          featureOffset = Get.runGet (Get.skip (fromIntegral extSlotOffset) >> Get.getWord32le) bytes
          featureBlock = LB.drop (fromIntegral featureOffset) bytes
      LB.head featureBlock === 0x0A
      LB.length featureBlock === 1 + 4 + 1 + 1

  describe "tokens" $ do
    it "parses DONE" $ do
      let bytes = Put.runPut $ Put.putWord8 0xFD >> Put.putWord16le 0x11 >> Put.putWord16le 0 >> Put.putWord64le 12345
      case Get.runGet (getToken defaultTdsContext Nothing) bytes of
        TDone d -> do
          doneRowCount d `shouldBe` 12345
          doneMore d `shouldBe` True
          doneHasCount d `shouldBe` True
        t -> expectationFailure (show t)
    it "parses an NBCROW null bitmap" $ do
      let cols = [ ColumnInfo (T.pack [c]) (TIIntN 4) 1 0 Nothing | c <- "abcdefghij" ]
          bytes = Put.runPut $ do
            Put.putWord8 0xD2
            Put.putWord8 0x09   -- columns 0 and 3 null
            Put.putWord8 0x02   -- column 9 null
            mapM_ (\i -> Put.putWord8 4 >> Put.putInt32le i) [1, 2, 4, 5, 6, 7, 8]
      case Get.runGet (getToken defaultTdsContext (Just cols)) bytes of
        TRow row -> map (fmap B.head) (rowValues row) `shouldBe`
          [Nothing, Just 1, Just 2, Nothing, Just 4, Just 5, Just 6, Just 7, Just 8, Nothing]
        t -> expectationFailure (show t)
    it "rejects ROW before COLMETADATA" $ do
      let bytes = Put.runPut (Put.putWord8 0xD1)
      case Get.runGetOrFail (getToken defaultTdsContext Nothing) bytes of
        Left (_, _, err) -> err `shouldContain` "COLMETADATA"
        Right (_, _, t) -> expectationFailure (show t)
    it "parses ENVCHANGE begin transaction" $ do
      let bytes = Put.putWord8 0xE3 >> Put.putWord16le 11 >> Put.putWord8 8 >> Put.putWord8 8 >> Put.putWord64le 0xABCD >> Put.putWord8 0
      Get.runGet (getToken defaultTdsContext Nothing) (Put.runPut bytes)
        `shouldBe` TEnvChange (ECBeginTransaction (TransactionDescriptor 0xABCD))
    it "parses ENVCHANGE packet size" $ do
      let bytes = Put.runPut $ do
            Put.putWord8 0xE3
            Put.putWord16le (1 + 1 + 8 + 1 + 8)
            Put.putWord8 4
            putBVarChar "8192"
            putBVarChar "4096"
      Get.runGet (getToken defaultTdsContext Nothing) bytes `shouldBe` TEnvChange (ECPacketSize 4096 8192)
    it "parses ERROR" $ do
      let body = Put.runPut $ do
            Put.putInt32le 50000
            Put.putWord8 1
            Put.putWord8 16
            putUsVarChar "boom"
            putBVarChar "srv"
            putBVarChar ""
            Put.putInt32le 3
          bytes = Put.runPut (Put.putWord8 0xAA >> Put.putWord16le (fromIntegral (LB.length body)) >> Put.putLazyByteString body)
      Get.runGet (getToken defaultTdsContext Nothing) bytes
        `shouldBe` TError (ServerMessage 50000 1 16 "boom" "srv" "" 3)
    it "parses COLMETADATA with a text column's table name" $ do
      let bytes = Put.runPut $ do
            Put.putWord8 0x81
            Put.putWord16le 2
            Put.putWord32le 0 >> Put.putWord16le 0x09 >> putTypeInfo defaultTdsContext (TIIntN 4) >> putBVarChar "id"
            Put.putWord32le 0 >> Put.putWord16le 0x01 >> putTypeInfo defaultTdsContext (TIText 100 (Collation 0 0))
            Put.putWord8 2 >> putUsVarChar "dbo" >> putUsVarChar "notes"
            putBVarChar "body"
      case Get.runGet (getToken defaultTdsContext Nothing) bytes of
        TColMetaData [a, b] -> do
          columnName a `shouldBe` "id"
          columnIsNullable a `shouldBe` True
          columnTableName b `shouldBe` Just ["dbo", "notes"]
        t -> expectationFailure (show t)
  where
    w8 = Gen.word8 Range.linearBounded
    w16 = Gen.word16 Range.linearBounded
    w32 = Gen.word32 Range.linearBounded

chunksOf :: Int -> B.ByteString -> [B.ByteString]
chunksOf n b
  | B.null b = []
  | otherwise = let (x, y) = B.splitAt n b in x : chunksOf n y

groupsOf :: Int -> [a] -> [[a]]
groupsOf _ [] = []
groupsOf n xs = let (x, y) = splitAt n xs in x : groupsOf n y
