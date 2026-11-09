-- | Pure round-trip properties for every token in the tabular-result stream
-- ("Hmssql.Tds.Token"), including tokens the client never has to *build*
-- (LOGINACK, RETURNVALUE, ...): each has a test-side @Put@ mirroring the
-- wire layout described by [MS-TDS] 2.2.7, checked against 'getToken'.
--
-- Also: a mixed stream of many tokens, parsed incrementally from arbitrary
-- chunk boundaries (byte-by-byte, and random splits), must give the same
-- result as parsing the whole buffer at once.
module Wire.TokensSpec (spec) where

import Wire.RecipeGet (getToken)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Exception (evaluate, try)
import Streaming (inspect)
import qualified Hmssql.Tds.Parser as P
import System.Timeout (timeout)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import Data.Bits (setBit)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.List as List
import Data.Maybe (isNothing)
import qualified Data.Text as T
import Data.Word (Word32, Word64, Word8)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog
import TestDb (withCases, withCasesSlow)

import Hmssql.Tds.Context
import Hmssql.Tds.Primitives
import Hmssql.Tds.Value (rowFromValues, rowValues)
import Hmssql.Tds.Token
import Hmssql.Tds.TypeInfo

import Wire.TypeInfoSpec (genTypeInfo, genValueFor, genText)
import Wire.Util

ctx :: TdsContext
ctx = defaultTdsContext

------------------------------------------------------------------------------
-- Generic byte-level builders

tokenU16 :: Word8 -> B.ByteString -> Put.Put
tokenU16 ty body = Put.putWord8 ty >> Put.putWord16le (fromIntegral (B.length body)) >> Put.putByteString body

tokenU32 :: Word8 -> B.ByteString -> Put.Put
tokenU32 ty body = Put.putWord8 ty >> Put.putWord32le (fromIntegral (B.length body)) >> Put.putByteString body

putBVarByte :: B.ByteString -> Put.Put
putBVarByte bs = Put.putWord8 (fromIntegral (B.length bs)) >> Put.putByteString bs

strict :: Put.Put -> B.ByteString
strict = LB.toStrict . Put.runPut

toLazy :: Put.Put -> LB.ByteString
toLazy = LB.fromStrict . strict

tshow :: Show a => a -> T.Text
tshow = T.pack . show

genColumnName :: Gen T.Text
genColumnName = Gen.text (Range.linear 0 20) Gen.unicode

-- | Types 'getRowValue' reads specially (text pointer + timestamp); excluded
-- from ROW\/NBCROW generators here to keep the builder simple ("Hmssql.Tds.TypeInfo"'s
-- own 'putValue'\/'getValue' pair, used by RETURNVALUE, is unaffected).
genRowTypeInfo :: Gen TypeInfo
genRowTypeInfo = Gen.filter (not . isLob) genTypeInfo
  where
    isLob = \case
      TIText{} -> True
      TINText{} -> True
      TIImage{} -> True
      _ -> False

-- | A ROW's value as 'getRowValue' reads it: with a text pointer and
-- timestamp before @text@, @ntext@ and @image@ values ('putValue' writes
-- the RETURNVALUE form, without them).
rowValueP :: TypeInfo -> RawBytes -> Put.Put
rowValueP ti v = case ti of
  TIText{} -> lob
  TINText{} -> lob
  TIImage{} -> lob
  _ -> putValue ctx ti v
  where
    lob = case v of
      Nothing -> Put.putWord8 0
      Just bs -> do
        Put.putWord8 16
        Put.putByteString (B.replicate 16 0xAB)  -- text pointer
        Put.putByteString (B.replicate 8 0xCD)   -- timestamp
        Put.putWord32le (fromIntegral (B.length bs))
        Put.putByteString bs

------------------------------------------------------------------------------
-- COLMETADATA

needsTableName :: TypeInfo -> Bool
needsTableName = \case
  TIText{} -> True
  TINText{} -> True
  TIImage{} -> True
  _ -> False

genColumnInfo :: Gen ColumnInfo
genColumnInfo = do
  columnType <- genTypeInfo
  columnName <- genColumnName
  columnFlags <- Gen.word16 Range.linearBounded
  columnUserType <- Gen.word32 Range.linearBounded
  columnTableName <-
    if needsTableName columnType
      then Just <$> Gen.list (Range.linear 0 3) genColumnName
      else pure Nothing
  pure ColumnInfo{..}

colMetaDataP :: [ColumnInfo] -> Put.Put
colMetaDataP cols = do
  Put.putWord8 0x81
  Put.putWord16le (fromIntegral (length cols))
  mapM_ putCol cols
  where
    putCol ColumnInfo{..} = do
      Put.putWord32le columnUserType
      Put.putWord16le columnFlags
      putTypeInfo ctx columnType
      case columnTableName of
        Just parts -> Put.putWord8 (fromIntegral (length parts)) >> mapM_ putUsVarChar parts
        Nothing -> pure ()
      putBVarChar columnName

------------------------------------------------------------------------------
-- ROW / NBCROW

rowTokenP :: [(TypeInfo, RawBytes)] -> Put.Put
rowTokenP vals = Put.putWord8 0xD1 >> mapM_ (\(ti, v) -> putValue ctx ti v) vals

nbcRowTokenP :: [(TypeInfo, RawBytes)] -> Put.Put
nbcRowTokenP vals = do
  Put.putWord8 0xD2
  mapM_ Put.putWord8 bitmap
  mapM_ (\(ti, v) -> maybe (pure ()) (const (putValue ctx ti v)) v) vals
  where
    n = length vals
    nulls = map (isNothing . snd) vals
    bitmap :: [Word8]
    bitmap =
      [ List.foldl' (\acc bit -> let i = byteIx * 8 + bit in if i < n && nulls !! i then setBit acc bit else acc) 0 [0 .. 7]
      | byteIx <- [0 .. (n + 7) `div` 8 - 1]
      ]

------------------------------------------------------------------------------
-- DONE / DONEPROC / DONEINPROC

doneTokenP :: Word8 -> Done -> Put.Put
doneTokenP code (Done st cc rc) = Put.putWord8 code >> Put.putWord16le st >> Put.putWord16le cc >> Put.putWord64le rc

------------------------------------------------------------------------------
-- ERROR / INFO

genServerMessage :: Gen ServerMessage
genServerMessage =
  ServerMessage
    <$> Gen.int32 Range.linearBounded
    <*> Gen.word8 Range.linearBounded
    <*> Gen.word8 Range.linearBounded
    <*> Gen.text (Range.linear 0 60) Gen.unicode
    <*> Gen.text (Range.linear 0 30) Gen.unicode
    <*> Gen.text (Range.linear 0 30) Gen.unicode
    <*> Gen.int32 Range.linearBounded

serverMessageTokenP :: Word8 -> ServerMessage -> Put.Put
serverMessageTokenP code ServerMessage{..} = tokenU16 code $ strict $ do
  Put.putInt32le msgNumber
  Put.putWord8 msgState
  Put.putWord8 msgClass
  putUsVarChar msgText
  putBVarChar msgServer
  putBVarChar msgProcedure
  Put.putInt32le msgLine

------------------------------------------------------------------------------
-- ENVCHANGE

simpleTextEnvChange :: Word8 -> T.Text -> T.Text -> Put.Put
simpleTextEnvChange ty new old = tokenU16 0xE3 $ B.cons ty $ strict (putBVarChar new >> putBVarChar old)

newOnlyTextEnvChange :: Word8 -> T.Text -> Put.Put
newOnlyTextEnvChange ty new = tokenU16 0xE3 $ B.cons ty $ strict (putBVarChar new >> putBVarChar T.empty)

packetSizeEnvChange :: Word32 -> Word32 -> Put.Put
packetSizeEnvChange new old = tokenU16 0xE3 $ B.cons 4 $ strict (putBVarChar (tshow new) >> putBVarChar (tshow old))

collationBytesEnvChange :: B.ByteString -> B.ByteString -> Put.Put
collationBytesEnvChange new old = tokenU16 0xE3 $ B.cons 7 $ strict (putBVarByte new >> putBVarByte old)

txnEnvChange :: Word8 -> Word64 -> Put.Put
txnEnvChange ty td = tokenU16 0xE3 $ B.cons ty $ strict (Put.putWord8 8 >> Put.putWord64le td >> Put.putWord8 0)

promoteTransactionEnvChange :: B.ByteString -> Put.Put
promoteTransactionEnvChange dtc = do
  Put.putWord8 0xE3
  Put.putWord16le 1 -- the server's own reported length is bogus for this type
  Put.putWord8 15
  Put.putWord32le (fromIntegral (B.length dtc))
  Put.putByteString dtc
  Put.putWord8 0 -- "OldValue": the type's generic decoder still expects an empty trailer

tmAddressEnvChange :: B.ByteString -> Put.Put
tmAddressEnvChange bs = tokenU16 0xE3 $ B.cons 16 $ strict (putBVarByte bs >> Put.putWord8 0)

resetAckEnvChange :: Put.Put
resetAckEnvChange = tokenU16 0xE3 (B.pack [18, 0, 0])

routingEnvChangeP :: RoutingInfo -> Put.Put
routingEnvChangeP (RoutingInfo proto port server) = tokenU16 0xE3 $ B.cons 20 $ strict $ do
  let inner = strict (Put.putWord8 proto >> Put.putWord16le port >> putUsVarChar server)
  Put.putWord16le (fromIntegral (B.length inner))
  Put.putByteString inner
  Put.putWord16le 0

unknownEnvChange :: Word8 -> B.ByteString -> Put.Put
unknownEnvChange ty payload = tokenU16 0xE3 (B.cons ty payload)

genEnvChangeCase :: Gen (EnvChange, Put.Put)
genEnvChangeCase = Gen.choice
  [ mk2 ECDatabase 1
  , mk2 ECLanguage 2
  , mk2 ECCharacterSet 3
  , do new <- Gen.word32 (Range.linear minPacketSize maxPacketSize)
       old <- Gen.word32 Range.linearBounded
       pure (ECPacketSize old new, packetSizeEnvChange new old)
  , mk1 ECUnicodeSortingLocale 5
  , mk1 ECUnicodeComparisonFlags 6
  , do new <- genBytes255
       old <- genBytes255
       pure (ECSqlCollation old new, collationBytesEnvChange new old)
  , txnCase ECBeginTransaction 8
  , txnCase ECCommitTransaction 9
  , txnCase ECRollbackTransaction 10
  , txnCase ECEnlistDtcTransaction 11
  , txnCase ECDefectTransaction 12
  , mk1 ECMirroringPartner 13
  , do dtc <- Gen.bytes (Range.linear 0 40)
       pure (ECPromoteTransaction dtc, promoteTransactionEnvChange dtc)
  , do bs <- genBytes255
       pure (ECTransactionManagerAddress bs, tmAddressEnvChange bs)
  , txnCase ECTransactionEnded 17
  , pure (ECResetConnectionAck, resetAckEnvChange)
  , mk1 ECUserInstance 19
  , do proto <- Gen.word8 Range.linearBounded
       port <- Gen.word16 Range.linearBounded
       server <- genText
       let info = RoutingInfo proto port server
       pure (ECRouting info, routingEnvChangeP info)
  , do ty <- Gen.word8 (Range.linear 21 254)
       payload <- Gen.bytes (Range.linear 0 30)
       pure (ECUnknown ty payload, unknownEnvChange ty payload)
  ]
  where
    genBytes255 = Gen.bytes (Range.linear 0 255)
    mk2 mkCtor ty = do
      new <- genText
      old <- genText
      pure (mkCtor old new, simpleTextEnvChange ty new old)
    mk1 mkCtor ty = do
      new <- genText
      pure (mkCtor new, newOnlyTextEnvChange ty new)
    txnCase mkCtor ty = do
      td <- Gen.word64 Range.linearBounded
      pure (mkCtor (TransactionDescriptor td), txnEnvChange ty td)

------------------------------------------------------------------------------
-- LOGINACK

genLoginAck :: Gen LoginAck
genLoginAck = do
  laInterface <- w8
  laTdsVersion <- Gen.word32 Range.linearBounded
  -- getLoginAck strips trailing NULs (SQL Server's own padding); avoid them
  -- entirely so the round trip is exact.
  laProgName <- T.filter (/= '\0') <$> genText
  laProgVersion <- (,,,) <$> w8 <*> w8 <*> w8 <*> w8
  pure LoginAck{..}
  where
    w8 = Gen.word8 Range.linearBounded

loginAckTokenP :: LoginAck -> Put.Put
loginAckTokenP LoginAck{..} = tokenU16 0xAD $ strict $ do
  Put.putWord8 laInterface
  Put.putWord32be laTdsVersion
  putBVarChar laProgName
  let (a, b, c, d) = laProgVersion
  mapM_ Put.putWord8 [a, b, c, d]

------------------------------------------------------------------------------
-- FEATUREEXTACK

genFeatureAck :: Gen FeatureAck
genFeatureAck = FeatureAck <$> Gen.filter (/= 0xFF) (Gen.word8 Range.linearBounded) <*> Gen.bytes (Range.linear 0 20)

featureExtAckTokenP :: [FeatureAck] -> Put.Put
featureExtAckTokenP feats = do
  Put.putWord8 0xAE
  mapM_ (\FeatureAck{..} -> Put.putWord8 featureId >> Put.putWord32le (fromIntegral (B.length featureData)) >> Put.putByteString featureData) feats
  Put.putWord8 0xFF

------------------------------------------------------------------------------
-- RETURNVALUE

genReturnValue :: Gen ReturnValue
genReturnValue = do
  rvOrdinal <- Gen.word16 Range.linearBounded
  rvName <- genColumnName
  rvStatus <- Gen.word8 Range.linearBounded
  rvUserType <- Gen.word32 Range.linearBounded
  rvFlags <- Gen.word16 Range.linearBounded
  rvType <- genTypeInfo
  rvValue <- genValueFor rvType
  pure ReturnValue{..}

returnValueTokenP :: ReturnValue -> Put.Put
returnValueTokenP rv = returnValueHeadP rv >> putValue ctx (rvType rv) (rvValue rv)

-- | A RETURNVALUE token up to its value.
returnValueHeadP :: ReturnValue -> Put.Put
returnValueHeadP ReturnValue{..} = do
  Put.putWord8 0xAC
  Put.putWord16le rvOrdinal
  putBVarChar rvName
  Put.putWord8 rvStatus
  Put.putWord32le rvUserType
  Put.putWord16le rvFlags
  putTypeInfo ctx rvType

------------------------------------------------------------------------------
-- A mixed token stream, parsed incrementally

getTokens :: TdsContext -> Get.Get [Token]
getTokens c = go Nothing
  where
    go cols = do
      done <- Get.isEmpty
      if done
        then pure []
        else do
          t <- getToken c cols
          let cols' = case t of
                TColMetaData cs -> Just cs
                _ -> cols
          (t :) <$> go cols'

buildStream :: Gen (B.ByteString, [Token])
buildStream = do
  cols <- Gen.list (Range.linear 1 5) genRowTypeInfo
  let colInfos = [ColumnInfo (T.pack ("c" ++ show i)) ti 1 0 Nothing | (i, ti) <- zip [1 :: Int ..] cols]
  rows <- Gen.list (Range.linear 0 4) (mapM genValueFor cols)
  msg <- genServerMessage
  (ec, ecPut) <- genEnvChangeCase
  rv <- genReturnValue
  ordCols <- Gen.list (Range.linear 0 4) (Gen.word16 Range.linearBounded)
  let done = Done 0x10 0 (fromIntegral (length rows))
      puts =
        [colMetaDataP colInfos, serverMessageTokenP 0xAB msg, ecPut, orderTokenP ordCols]
          ++ map (\vals -> rowTokenP (zip cols vals)) rows
          ++ [returnValueTokenP rv, doneTokenP 0xFD done]
      bytes = strict (sequence_ puts)
      expected =
        [TColMetaData colInfos, TInfo msg, TEnvChange ec, TOrder ordCols]
          ++ map (TRow . rowFromValues) rows
          ++ [TReturnValue rv, TDone done]
  pure (bytes, expected)
  where
    orderTokenP cs = Put.putWord8 0xA9 >> Put.putWord16le (fromIntegral (2 * length cs)) >> mapM_ Put.putWord16le cs

-- | A ROW or NBCROW token as the server sends it, text pointers included.
rowP, nbcRowP :: [(TypeInfo, RawBytes)] -> Put.Put
rowP vals = Put.putWord8 0xD1 >> mapM_ (uncurry rowValueP) vals
nbcRowP vals = do
  Put.putWord8 0xD2
  mapM_ Put.putWord8
    [ List.foldl' setBit (0 :: Word8) [i `mod` 8 | (i, (_, v)) <- zip [0 ..] vals, isNothing v, i `div` 8 == j]
    | j <- [0 .. (length vals + 7) `div` 8 - 1] ]
  mapM_ (\(ti, v) -> maybe (pure ()) (const (rowValueP ti v)) v) vals

-- | The bytes cut at up to eight random places (rows here run to
-- hundreds of KB, too many for 'genChunks'' subsequence of every offset).
genCuts :: B.ByteString -> Gen [B.ByteString]
genCuts bs
  | B.length bs < 2 = pure [bs]
  | otherwise = do
      cuts <- Gen.list (Range.linear 0 8) (Gen.int (Range.linear 1 (B.length bs - 1)))
      let points = List.nub (List.sort cuts)
      pure [B.take (b - a) (B.drop a bs) | (a, b) <- zip (0 : points) (points ++ [B.length bs])]

-- Drive the actual recipe with the supplied chunks, preserving the suffix.
readRecipeChunks :: P.Parser a -> [B.ByteString] -> IO (Either String (a, B.ByteString))
readRecipeChunks recipe = go (P.parse recipe B.empty)
  where
    go stream chunks = try (inspect stream) >>= \case
      Left (P.ProtocolError err) -> pure (Left err)
      Right (Left (P.Got a rest)) -> pure (Right (a, B.concat (rest : chunks)))
      Right (Right (P.NeedMore k)) -> case chunks of
        [] -> pure (Left "needs more")
        c : cs -> go (k (P.More c)) cs
      Right (Right P.RunConsumer{}) -> fail "consumer in a token recipe"

readChunks :: Int -> ResultSetInfo -> [B.ByteString] -> IO (Either String ([RawBytes], B.ByteString))
readChunks ahead rs chunks = fmap convert <$> readRecipeChunks recipe chunks
  where
    recipe = do
      tag <- P.peekWord8
      if tag == 0xD1 || tag == 0xD2 then readTokenWith ahead (Just rs) else fail "expected ROW or NBCROW"
    convert (TRow row, rest) = (rowValues row, rest)
    convert _ = error "expected a row"

-- | A column of a long row: its type and value, and the value as the row
-- carries it (a PLP value in chunks of its own, with a declared total).
data LongCell = LongCell TypeInfo RawBytes Put.Put

instance Show LongCell where
  show (LongCell ti v _) = "LongCell " ++ show ti ++ " " ++ maybe "NULL" (\bs -> show (B.length bs) ++ " bytes") v

-- | Columns of the random types of 'genTypeInfo', and large values (up to
-- 200 KB, over '65536'): PLP values in one or several chunks, of
-- a declared total, an unknown one, or a wrong one (which the parsers
-- ignore); @image@ and @text@ with their text pointers.
genLongCell :: Gen LongCell
genLongCell = genLongValue rowValueP

-- | 'genLongCell', with the value written by this function when it isn't a
-- PLP value in chunks of its own: 'rowValueP' for a row's, 'putValue' for
-- a RETURNVALUE's (no text pointers).
genLongValue :: (TypeInfo -> RawBytes -> Put.Put) -> Gen LongCell
genLongValue valueP = Gen.frequency
  [ (2, do ti <- genTypeInfo
           v <- genValueFor ti
           pure (LongCell ti v (valueP ti v)))
  , (3, do ti <- Gen.element [TIBigVarBinary maxLength, TINVarChar maxLength (Collation 0 0), TIBigVarChar maxLength (Collation 0 0)]
           v <- genBig
           case v of
             Nothing -> pure (LongCell ti Nothing (Put.putWord64le 0xFFFFFFFFFFFFFFFF))
             Just bs -> do
               cuts <- Gen.list (Range.linear 0 5) (Gen.int (Range.linear 0 (B.length bs)))
               let points = List.sort cuts
                   chunks = filter (not . B.null) [B.take (b - a) (B.drop a bs) | (a, b) <- zip (0 : points) (points ++ [B.length bs])]
               total <- Gen.frequency
                 [ (4, pure (fromIntegral (B.length bs)))
                 , (2, pure 0xFFFFFFFFFFFFFFFE)
                 , (1, Gen.word64 (Range.linear 0 400000)) ]
               pure $ LongCell ti v $ do
                 Put.putWord64le total
                 mapM_ (\c -> Put.putWord32le (fromIntegral (B.length c)) >> Put.putByteString c) chunks
                 Put.putWord32le 0)
  , (1, do ti <- Gen.element [TIImage maxBound, TIText maxBound (Collation 0 0), TINText maxBound (Collation 0 0)]
           v <- genBig
           pure (LongCell ti v (valueP ti v)))
  ]
  where
    -- Mostly long; its bytes a rotation of 0..255, cheap to build.
    genBig = Gen.frequency
      [ (1, pure Nothing)
      , (8, do len <- Gen.frequency [(3, Gen.int (Range.linear 65537 200000)), (1, Gen.int (Range.linear 0 70000))]
               start <- Gen.int (Range.linear 0 255)
               pure (Just (B.take len (B.drop start (B.concat (replicate (len `div` 256 + 2) (B.pack [0 .. 255]))))))) ]

-- | The RETURNVALUE 'feedReturnValue' reads from the chunks (a reader
-- started at the first, with this allocation-ahead bound), with what
-- follows it; or why not ("needs more": every chunk was consumed, the
-- token goes on).
readReturnValueChunks :: Int -> [B.ByteString] -> IO (Either String (ReturnValue, B.ByteString))
readReturnValueChunks ahead chunks = fmap convert <$> readRecipeChunks (readTokenWith ahead Nothing) chunks
  where
    convert (TReturnValue value, rest) = (value, rest)
    convert _ = error "expected RETURNVALUE"

spec :: Spec
spec = do
  describe "COLMETADATA" $ do
    withCases 1000 $
      it "round-trips 0..N columns with random flags, user types and names" $ hedgehog $ do
        cols <- forAll $ Gen.list (Range.linear 0 8) genColumnInfo
        Get.runGet (getToken ctx Nothing) (toLazy (colMetaDataP cols)) === TColMetaData cols

    it "a declared column count of 0xFFFF means no columns" $ do
      Get.runGet (getToken ctx Nothing) (toLazy (Put.putWord8 0x81 >> Put.putWord16le 0xFFFF))
        `shouldBe` TColMetaData []

  describe "ROW / NBCROW" $ do
    withCasesSlow 200 1000 $
      it "ROW round-trips arbitrary columns, including NULLs" $ hedgehog $ do
        tys <- forAll $ Gen.list (Range.linear 0 8) genRowTypeInfo
        vals <- forAll $ mapM genValueFor tys
        let cols = [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
        Get.runGet (getToken ctx (Just cols)) (toLazy (rowTokenP (zip tys vals))) === TRow (rowFromValues vals)

    withCasesSlow 200 1000 $
      it "NBCROW round-trips with a random null bitmap" $ hedgehog $ do
        tys <- forAll $ Gen.list (Range.linear 1 20) genRowTypeInfo
        vals <- forAll $ mapM genValueFor tys
        let cols = [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
        Get.runGet (getToken ctx (Just cols)) (toLazy (nbcRowTokenP (zip tys vals))) === TRow (rowFromValues vals)

  describe "row recipes against generated values" $ do
    withCasesSlow 300 2000 $
      it "reads ROW and NBCROW at every byte boundary with no re-walk" $ hedgehog $ do
        tys <- forAll $ Gen.list (Range.linear 0 8) genTypeInfo
        vals <- forAll $ map (fmap (B.take 64)) <$> mapM genValueFor tys
        nbc <- forAll Gen.bool
        let rs = compileResultSet [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
            bytes = strict ((if nbc then nbcRowP else rowP) (zip tys vals))
        -- Small rows check every two-packet cut; large rows also check random
        -- cuts and byte-by-byte input in the properties below.
        forM_ [0 .. B.length bytes] $ \cut -> do
          result <- evalIO (readChunks lobAllocAhead rs [B.take cut bytes, B.drop cut bytes])
          result === Right (vals, B.empty)

    it "leaves bytes after a row untouched and rejects truncated prefixes" $ hedgehog $ do
      tys <- forAll $ Gen.list (Range.linear 1 8) genTypeInfo
      vals <- forAll $ mapM genValueFor tys
      suffix <- forAll $ Gen.bytes (Range.linear 0 20)
      let rs = compileResultSet [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
          bytes = strict (rowP (zip tys vals))
      chunks <- forAll (genCuts (bytes <> suffix))
      result <- evalIO (readChunks lobAllocAhead rs chunks)
      result === Right (vals, suffix)
      cut <- forAll $ Gen.int (Range.linear 0 (B.length bytes - 1))
      truncated <- evalIO (readChunks lobAllocAhead rs [B.take cut bytes])
      truncated === Left "needs more"

  describe "long row recipes" $ do
    withCasesSlow 100 500 $
      it "reads long rows cut anywhere, against their generated values" $ hedgehog $ do
        cells <- forAll $ Gen.list (Range.linear 1 6) genLongCell
        nbc <- forAll Gen.bool
        let tys = [ti | LongCell ti _ _ <- cells]
            vals = [v | LongCell _ v _ <- cells]
            cols = [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
            rs = compileResultSet cols
            n = length cells
            bitmap = [ List.foldl' setBit (0 :: Word8) [i `mod` 8 | (i, v) <- zip [0 ..] vals, isNothing v, i `div` 8 == j]
                     | j <- [0 .. (n + 7) `div` 8 - 1] ]
            bytes = strict $
              if nbc
                then Put.putWord8 0xD2 >> mapM_ Put.putWord8 bitmap >> mapM_ (\(LongCell _ v p) -> maybe (pure ()) (const p) v) cells
                else Put.putWord8 0xD1 >> mapM_ (\(LongCell _ _ p) -> p) cells
        cover 30 "a value longer than 65536" (any (maybe False ((> 65536) . B.length)) vals)
        cover 5 "a row longer than 65536 in NBCROW" (nbc && B.length bytes > 65536)
        -- The reader, over the row and a few bytes after it, cut at up to
        -- eight places, with a bound on allocating ahead of the bytes
        -- from none to more than the row (so buffers are made at once,
        -- grown, and cut down).
        after <- forAll $ Gen.bytes (Range.linear 0 8)
        chunks <- forAll (genCuts (bytes <> after))
        ahead <- forAll $ Gen.frequency [(1, Gen.int (Range.linear 0 64)), (1, Gen.int (Range.linear 0 300000)), (1, pure lobAllocAhead)]
        r <- liftIO (readChunks ahead rs chunks)
        r === Right (vals, after)
        -- Cut short, it only ever asks for more.
        cut <- forAll $ Gen.int (Range.linear 0 (B.length bytes - 1))
        tchunks <- forAll (genCuts (B.take cut bytes))
        r' <- liftIO (readChunks ahead rs (filter (not . B.null) tchunks))
        r' === Left "needs more"

    -- The reader runs inside the masked read of a packet ('fetchPacket'),
    -- where no timeout can end it: on any bytes it must end, or ask for
    -- more.
    withCasesSlow 2000 100000 $
      it "reads long rows with corrupted bytes, cut anywhere, to an end" $ hedgehog $ do
        cells <- forAll $ Gen.list (Range.linear 1 6) genLongCell
        nbc <- forAll Gen.bool
        let tys = [ti | LongCell ti _ _ <- cells]
            vals = [v | LongCell _ v _ <- cells]
            cols = [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
            rs = compileResultSet cols
            n = length cells
            bitmap = [ List.foldl' setBit (0 :: Word8) [i `mod` 8 | (i, v) <- zip [0 ..] vals, isNothing v, i `div` 8 == j]
                     | j <- [0 .. (n + 7) `div` 8 - 1] ]
            bytes = strict $
              if nbc
                then Put.putWord8 0xD2 >> mapM_ Put.putWord8 bitmap >> mapM_ (\(LongCell _ v p) -> maybe (pure ()) (const p) v) cells
                else Put.putWord8 0xD1 >> mapM_ (\(LongCell _ _ p) -> p) cells
        -- Edits anywhere, and some in the first bytes, where the lengths
        -- and PLP totals of the first values are.
        edits <- forAll $ Gen.list (Range.linear 1 6) $
          (,) <$> Gen.frequency [(1, Gen.int (Range.linear 0 (B.length bytes - 1))), (1, Gen.int (Range.linear 0 (min 40 (B.length bytes - 1))))]
              <*> Gen.word8 Range.constantBounded
        let corrupt = foldl (\b (i, w) -> B.take i b <> B.singleton w <> B.drop (i + 1) b) bytes edits
        chunks <- forAll $ Gen.frequency
          [ (4, genCuts corrupt)
          , (1, pure [B.singleton w | w <- B.unpack (B.take 2000 corrupt)] ) ]
        ahead <- forAll $ Gen.frequency [(1, Gen.int (Range.linear 0 64)), (1, Gen.int (Range.linear 0 300000)), (1, pure lobAllocAhead)]
        r <- evalIO $ timeout 5_000_000 $ do
          out <- readChunks ahead rs chunks
          evaluate $ case out of
            Left why -> length why
            Right (vs, rest) -> length (show (map (fmap B.length) vs)) + B.length rest
        when (isNothing r) $ do
          annotate "the reader did not end within 5 s"
          failure

    it "reads the rows of the other properties, one byte at a time" $ hedgehog $ do
      tys <- forAll $ Gen.list (Range.linear 1 8) genTypeInfo
      vals <- forAll $ mapM genValueFor tys
      let rs = compileResultSet [ColumnInfo "c" ti 1 0 Nothing | ti <- tys]
          bytes = strict (rowP (zip tys vals))
      r <- liftIO (readChunks lobAllocAhead rs [B.singleton b | b <- B.unpack bytes])
      r === Right (vals, B.empty)

  describe "DONE / DONEPROC / DONEINPROC" $
    it "round-trip every status bit and a 64-bit row count" $ hedgehog $ do
      (code, wrap) <- forAllWith (show . fst) $ Gen.element [(0xFD, TDone), (0xFE, TDoneProc), (0xFF, TDoneInProc)]
      st <- forAll $ Gen.word16 Range.linearBounded
      cc <- forAll $ Gen.word16 Range.linearBounded
      rc <- forAll $ Gen.word64 Range.linearBounded
      let d = Done st cc rc
      Get.runGet (getToken ctx Nothing) (toLazy (doneTokenP code d)) === wrap d

  describe "fixed-size token recipes" $
    it "reads DONE and RETURNSTATUS cut at every byte" $ hedgehog $ do
      done <- forAll $ Done <$> Gen.word16 Range.linearBounded <*> Gen.word16 Range.linearBounded <*> Gen.word64 Range.linearBounded
      let bytes = strict (doneTokenP 0xFD done)
      forM_ [0 .. B.length bytes] $ \cut -> do
        result <- evalIO (readRecipeChunks (readToken Nothing) [B.take cut bytes, B.drop cut bytes])
        result === Right (TDone done, B.empty)

  describe "ERROR / INFO" $ do
    it "round-trip arbitrary fields" $ hedgehog $ do
      (code, wrap) <- forAllWith (show . fst) $ Gen.element [(0xAA, TError), (0xAB, TInfo)]
      msg <- forAll genServerMessage
      Get.runGet (getToken ctx Nothing) (toLazy (serverMessageTokenP code msg)) === wrap msg

    it "round-trips at the token's maximum length (a USHORT, 65535 bytes)" $ do
      let serverLen = 255 :: Int
          procLen = 255 :: Int
          server = T.replicate serverLen "a"
          procedure = T.replicate procLen "p"
          fixedBytes = 4 + 1 + 1 + 2 + (1 + 2 * serverLen) + (1 + 2 * procLen) + 4
          textChars = (65535 - fixedBytes) `div` 2
          msgText = T.replicate textChars "c"
          msg = ServerMessage 123456789 7 16 msgText server procedure (-1)
          bytes = toLazy (serverMessageTokenP 0xAA msg)
      LB.length bytes `shouldBe` fromIntegral (3 + fixedBytes + 2 * textChars)
      Get.runGet (getToken ctx Nothing) bytes `shouldBe` TError msg

  describe "ENVCHANGE" $
    withCases 1000 $
      it "round-trips every type" $ hedgehog $ do
        (ec, putter) <- forAllWith (show . fst) genEnvChangeCase
        Get.runGet (getToken ctx Nothing) (toLazy putter) === TEnvChange ec

  describe "LOGINACK" $
    it "round-trips" $ hedgehog $ do
      la <- forAll genLoginAck
      Get.runGet (getToken ctx Nothing) (toLazy (loginAckTokenP la)) === TLoginAck la

  describe "FEATUREEXTACK" $
    it "round-trips a list of feature acknowledgements" $ hedgehog $ do
      feats <- forAll $ Gen.list (Range.linear 0 5) genFeatureAck
      Get.runGet (getToken ctx Nothing) (toLazy (featureExtAckTokenP feats)) === TFeatureExtAck feats

  describe "RETURNVALUE" $
    withCasesSlow 300 1000 $
      it "round-trips every TYPE_INFO and value" $ hedgehog $ do
        rv <- forAll genReturnValue
        Get.runGet (getToken ctx Nothing) (toLazy (returnValueTokenP rv)) === TReturnValue rv

  describe "RETURNVALUE recipes across chunks" $ do
    withCasesSlow 100 500 $
      it "reads long values cut anywhere, as getToken reads them whole" $ hedgehog $ do
        LongCell ti v valueP <- forAll (genLongValue (putValue ctx))
        hd <- forAll genReturnValue
        let rv = hd { rvType = ti, rvValue = v }
            bytes = strict (returnValueHeadP rv >> valueP)
        cover 30 "a value longer than 65536" (maybe False ((> 65536) . B.length) v)
        Get.runGet (getToken ctx Nothing) (LB.fromStrict bytes) === TReturnValue rv
        -- The reader, over the token and a few bytes after it, cut at up
        -- to eight places (in the header too), with a bound on allocating
        -- ahead of the bytes from none to more than the value.
        after <- forAll $ Gen.bytes (Range.linear 0 8)
        chunks <- forAll (genCuts (bytes <> after))
        ahead <- forAll $ Gen.frequency [(1, Gen.int (Range.linear 0 64)), (1, Gen.int (Range.linear 0 300000)), (1, pure lobAllocAhead)]
        r <- liftIO (readReturnValueChunks ahead chunks)
        r === Right (rv, after)
        -- Cut short, it only ever asks for more.
        cut <- forAll $ Gen.int (Range.linear 0 (B.length bytes - 1))
        tchunks <- forAll (genCuts (B.take cut bytes))
        r' <- liftIO (readReturnValueChunks ahead tchunks)
        r' === Left "needs more"

    withCasesSlow 300 1000 $
      it "reads the tokens of the round-trip property, one byte at a time" $ hedgehog $ do
        rv <- forAll genReturnValue
        let bytes = strict (returnValueTokenP rv)
        r <- liftIO (readReturnValueChunks lobAllocAhead [B.singleton b | b <- B.unpack bytes])
        r === Right (rv, B.empty)

    withCasesSlow 300 1000 $
      it "fails where getToken fails, with its message, on arbitrary bytes after the token byte" $ hedgehog $ do
        -- A valid token with some of its bytes changed, the type's often.
        rv <- forAll genReturnValue
        let valid = strict (returnValueTokenP rv)
            typeAt = B.length (strict (returnValueHeadP rv)) - B.length (strict (putTypeInfo ctx (rvType rv)))
        flips <- forAll $ Gen.list (Range.linear 0 4) $ (,)
          <$> Gen.frequency [(1, pure typeAt), (1, Gen.int (Range.linear typeAt (typeAt + 8))), (2, Gen.int (Range.linear 1 (max 1 (B.length valid - 1))))]
          <*> Gen.word8 Range.linearBounded
        junk <- forAll $ Gen.bytes (Range.linear 0 40)
        let bytes = B.take 1 valid <> B.pack [maybe b id (lookup i flips) | (i, b) <- zip [1 ..] (B.unpack (B.drop 1 valid))] <> junk
            expected = case Get.pushChunk (Get.runGetIncremental (getToken ctx Nothing)) bytes of
              Get.Fail _ _ err -> Left err
              Get.Partial _ -> Left "needs more"
              Get.Done rest _ (TReturnValue rv') -> Right (rv', rest)
              Get.Done _ _ tok -> error ("not a RETURNVALUE: " ++ show tok)
        cover 10 "getToken fails" (either (/= "needs more") (const False) expected)
        cover 10 "getToken reads a token" (either (const False) (const True) expected)
        chunks <- forAll (genCuts bytes)
        r <- liftIO (readReturnValueChunks 64 chunks)
        r === expected

  describe "RETURNSTATUS" $
    it "round-trips" $ hedgehog $ do
      n <- forAll $ Gen.int32 Range.linearBounded
      Get.runGet (getToken ctx Nothing) (toLazy (Put.putWord8 0x79 >> Put.putInt32le n)) === TReturnStatus n

  describe "ORDER" $
    it "round-trips a list of column numbers" $ hedgehog $ do
      cs <- forAll $ Gen.list (Range.linear 0 30) (Gen.word16 Range.linearBounded)
      let body = strict (mapM_ Put.putWord16le cs)
      Get.runGet (getToken ctx Nothing) (toLazy (Put.putWord8 0xA9 >> Put.putWord16le (fromIntegral (B.length body)) >> Put.putByteString body))
        === TOrder cs

  describe "COLINFO / TABNAME" $
    it "round-trip as opaque bytes" $ hedgehog $ do
      (code, wrap) <- forAllWith (show . fst) $ Gen.element [(0xA5, TColInfo), (0xA4, TTabName)]
      bs <- forAll $ Gen.bytes (Range.linear 0 200)
      Get.runGet (getToken ctx Nothing) (toLazy (tokenU16 code bs)) === wrap bs

  describe "SESSIONSTATE / FEDAUTHINFO" $
    it "round-trip as opaque bytes with a 4-byte length" $ hedgehog $ do
      (code, wrap) <- forAllWith (show . fst) $ Gen.element [(0xE4, TSessionState), (0xEE, TFedAuthInfo)]
      bs <- forAll $ Gen.bytes (Range.linear 0 300)
      Get.runGet (getToken ctx Nothing) (toLazy (tokenU32 code bs)) === wrap bs

  describe "SSPI" $
    it "round-trips as opaque bytes" $ hedgehog $ do
      bs <- forAll $ Gen.bytes (Range.linear 0 200)
      Get.runGet (getToken ctx Nothing) (toLazy (tokenU16 0xED bs)) === TSspi bs

  describe "OFFSET" $
    it "round-trips" $ hedgehog $ do
      a <- forAll $ Gen.word16 Range.linearBounded
      b <- forAll $ Gen.word16 Range.linearBounded
      Get.runGet (getToken ctx Nothing) (toLazy (Put.putWord8 0x78 >> Put.putWord16le a >> Put.putWord16le b)) === TOffset a b

  describe "a mixed token stream" $
    withCasesSlow 100 500 $
      it "parses the same whether fed whole, byte-by-byte, or in random splits" $ hedgehog $ do
        (bytes, expected) <- forAll buildStream
        Get.runGet (getTokens ctx) (LB.fromStrict bytes) === expected
        runIncremental (getTokens ctx) (byteByByte bytes) === Right expected
        chunks <- forAll (genChunks bytes)
        runIncremental (getTokens ctx) chunks === Right expected
