-- | Pure round-trip properties for client-to-server messages
-- ("Hmssql.Tds.Client") and packet framing ("Hmssql.Tds.Packet"). No server
-- needed.
module Wire.RequestsSpec (spec, genRpcRequest) where

import Wire.PrimitiveGet (getUcs2)
import Hmssql.Encoding (ParamValue (..))
import RecipeParameters
import Wire.RecipeGet (getTypeInfo, getValue)
import Control.Monad (void)
import Data.Bits (complement, (.&.), (.|.))
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog
import TestDb (withCases, withCasesSlow)

import Hmssql (Only (..), Query, mkQuery, queryText, rawSql)
import Hmssql.Query (executeStatementsRequestsFor, queryRequestFor)
import Hmssql.Query.Types (Request (..))
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Primitives
import Hmssql.Tds.TypeInfo
import Hmssql.Tds.Utf16 (encodeUtf16LE)
import Wire.Login7Parser (getLogin7)

import Wire.TypeInfoSpec (genTypeInfo, genValueFor, genText)
import Wire.Util

------------------------------------------------------------------------------
-- SQLBatch / ALL_HEADERS

spec :: Spec
spec = do
  describe "ALL_HEADERS / SQLBatch" $
    it "declares the transaction descriptor and outstanding request count, then the UTF-16 text" $ hedgehog $ do
      mtd <- forAll $ Gen.maybe (Gen.word64 Range.linearBounded)
      sql <- forAll genText
      let context = defaultTdsContext { tdsTransaction = TransactionDescriptor <$> mtd }
          bytes = Put.runPut (putSqlBatch context sql)
          totalHeaderLen = Get.runGet Get.getWord32le bytes
          thisHeaderLen = Get.runGet (Get.skip 4 >> Get.getWord32le) bytes
          headerTy = Get.runGet (Get.skip 8 >> Get.getWord16le) bytes
          td = Get.runGet (Get.skip 10 >> Get.getWord64le) bytes
          outstanding = Get.runGet (Get.skip 18 >> Get.getWord32le) bytes
          rest = LB.drop 22 bytes
      totalHeaderLen === 22
      thisHeaderLen === 18
      headerTy === 0x0002
      td === maybe 0 id mtd
      outstanding === 1
      rest === Put.runPut (putUcs2 sql)

  describe "RPC" $
    withCasesSlow 200 1000 $
      it "round-trips a batch of RPCs with random params of every type and status flags" $ hedgehog $ do
        reqs <- forAll $ Gen.list (Range.linear 1 4) genRpcRequest
        let bytes = Put.runPut (putRpcRequest defaultTdsContext reqs)
            parsed = Get.runGet (Get.skip 22 >> getRpcRequestsBody defaultTdsContext) bytes
        map rpcView parsed === map rpcView reqs

  describe "executeStatements" $ do
    withCases 20 $
      it "sends each statement as its own sp_executesql RPC, 0xFF-separated, in messages of about 1 MiB" $ hedgehog $ do
        qs <- forAll $ Gen.list (Range.constant 0 400) genStatement
        void (checkMessages qs)
    it "splits 3000 statements of 2 KB into messages of about 1 MiB" $ hedgehog $ do
      let qs = [mkQuery ("SELECT @p1, '" <> T.replicate 1000 "x" <> "'") (Only i) | i <- [1 .. 3000 :: Int32]]
      n <- checkMessages qs
      assert (n >= 6)  -- 6 MB

  describe "LOGIN7" $
    withCases 1000 $
      it "round-trips every field" $ hedgehog $ do
        l7 <- forAll genLogin7
        Get.runGet getLogin7 (Put.runPut (putLogin7 l7)) === l7

  describe "PRELOGIN" $ do
    it "round-trips an empty option list" $ hedgehog $
      roundTrip putPrelogin getPrelogin (Prelogin [])

    it "round-trips PLUnknown options alongside known ones" $ hedgehog $ do
      opts <- forAll $ Gen.list (Range.linear 1 6) $ Gen.choice
        [ PLUnknown <$> Gen.filter (`notElem` [0, 1, 2, 3, 4, 5, 6, 7, 0xFF]) (Gen.word8 Range.linearBounded)
                    <*> Gen.bytes (Range.linear 0 20)
        , PLVersion <$> Gen.word8 Range.linearBounded <*> Gen.word8 Range.linearBounded
                    <*> Gen.word16 Range.linearBounded <*> Gen.word16 Range.linearBounded
        , PLNonce <$> Gen.bytes (Range.singleton 32)
        ]
      roundTrip putPrelogin getPrelogin (Prelogin opts)

  describe "packet framing" $ do
    it "sets RESETCONNECTION on the first packet only" $ hedgehog $ do
      size <- forAll $ Gen.word32 (Range.linear 20 300)
      body <- forAll $ Gen.bytes (Range.linear 0 2000)
      let context = defaultTdsContext { tdsPacketSize = size }
          packets = splitIntoPackets context PTSqlBatch statusResetConnection (LB.fromStrict body)
          headers = map (Get.runGet getHeader . LB.fromStrict) packets
          resetBit h = headerStatus h .&. statusResetConnection
      assert (not (null headers))
      map resetBit headers === (statusResetConnection : replicate (length headers - 1) (PacketStatus 0))

    it "frames a message across the full negotiable packet-size range (512..32767)" $ hedgehog $ do
      size <- forAll $ Gen.word32 (Range.linear minPacketSize maxPacketSize)
      body <- forAll $ genPayload 200000
      let context = defaultTdsContext { tdsPacketSize = size }
          packets = splitIntoPackets context PTSqlBatch (PacketStatus 0) (LB.fromStrict body)
          parsed = [(Get.runGet getHeader (LB.fromStrict p), B.drop headerLength p) | p <- packets]
          n = length parsed
      B.concat (map snd parsed) === body
      assert (all (\(h, b) -> fromIntegral (headerPacketLength h) == B.length b + headerLength) parsed)
      assert (all (\(h, _) -> headerPacketLength h <= 32767) parsed)
      [headerStatus h .&. statusEndOfMessage == statusEndOfMessage | (h, _) <- parsed]
        === (replicate (n - 1) False ++ [True])
      map (headerPacketId . fst) parsed === take n (cycle [0 .. 255])

------------------------------------------------------------------------------
-- RPC: a test-side parser mirroring 'putRpcRequest', reusing 'RpcRequest'
-- and 'RpcParam' as the parsed representation.

genRpcParam :: Gen RpcParam
genRpcParam = do
  rpcParamName <- Gen.choice [pure "", ("@" <>) <$> Gen.text (Range.linear 1 20) Gen.alphaNum]
  rpcParamStatus <- Gen.element [0, paramByRef, paramDefault, paramByRef .|. paramDefault]
  rpcParamType <- genTypeInfo
  rpcParamValue <- ParamBytes <$> genValueFor rpcParamType
  pure RpcParam{..}

genRpcRequest :: Gen RpcRequest
genRpcRequest = do
  rpcProc <- Gen.choice
    [ RpcProcId <$> Gen.word16 Range.linearBounded
    , RpcProcName <$> Gen.text (Range.linear 1 30) Gen.alphaNum
    ]
  rpcOptions <- Gen.word16 Range.linearBounded
  rpcParams <- Gen.list (Range.linear 0 5) genRpcParam
  pure RpcRequest{..}

-- | The messages 'executeStatementsRequestsFor' makes of the statements are
-- the RPCs 'execute' would send for each, in order, in messages of about
-- 1 MiB.  How many messages.
checkMessages :: [Query] -> PropertyT IO Int
checkMessages qs = do
  reqs <- evalIO (executeStatementsRequestsFor defaultTdsContext qs)
  bodies <- evalIO (mapM (requestBytes defaultTdsContext) reqs)
  singles <- evalIO $ mapM (\q -> do
    r <- queryRequestFor defaultTdsContext q
    if requestPacketType r == PTRpc
      then Get.runGet (Get.skip 22 >> getRpcRequestsBody defaultTdsContext) <$> requestBytes defaultTdsContext r
      else pure [RpcRequest (RpcProcId 10) 0 [byteParam "" 0 (TINVarChar 0xFFFF (Collation 0 0)) (Just (encodeUtf16LE (queryText q)))]]) qs
  let parsed = map (Get.runGet (Get.skip 22 >> getRpcRequestsBody defaultTdsContext)) bodies
      largest = maximum (0 : map (LB.length . Put.runPut . putRpcRequest defaultTdsContext) singles)
  map rpcView (concat parsed) === map rpcView (concat singles)
  assert (all (not . null) parsed)
  assert (all (\b -> LB.length b <= 1048576 + largest + 10486) bodies)
  assert (all (\b -> LB.length b >= 1048576 - 10486) (drop 1 (reverse bodies)))
  pure (length bodies)

-- | A statement for 'executeStatements': text of up to a few KB, with no
-- parameters or a few.
genStatement :: Gen Query
genStatement = do
  text <- Gen.text (Range.exponential 0 4000) Gen.alphaNum
  Gen.choice
    [ pure (rawSql ("SELECT '" <> text <> "'"))
    , (\i -> mkQuery ("SELECT @p1, '" <> text <> "'") (Only i)) <$> Gen.int32 Range.linearBounded
    , (\i s -> mkQuery ("SELECT @p2, @p1 /* " <> text <> " */") (i, s)) <$> Gen.int64 Range.linearBounded <*> Gen.text (Range.linear 0 50) Gen.unicode
    ]

getRpcRequestsBody :: TdsContext -> Get.Get [RpcRequest]
getRpcRequestsBody ctx = goOne
  where
    goOne = do
      rpcProc <- getProc
      rpcOptions <- Get.getWord16le
      rpcParams <- getParams
      let req = RpcRequest{..}
      atEnd <- Get.isEmpty
      if atEnd
        then pure [req]
        else do
          sep <- Get.getWord8
          if sep == 0xFF
            then (req :) <$> goOne
            else fail "getRpcRequestsBody: expected 0xFF RPC batch separator"

    getProc = do
      w <- Get.getWord16le
      if w == 0xFFFF then RpcProcId <$> Get.getWord16le else RpcProcName <$> getUcs2 (fromIntegral w)

    getParams = do
      atEnd <- Get.isEmpty
      if atEnd
        then pure []
        else do
          nextByte <- Get.lookAhead Get.getWord8
          if nextByte == 0xFF
            then pure []
            else (:) <$> getOneParam <*> getParams

    getOneParam = do
      nameLen <- Get.getWord8
      rpcParamName <- getUcs2 (fromIntegral nameLen)
      rpcParamStatus <- Get.getWord8
      rpcParamType <- getTypeInfo ctx
      rpcParamValue <- ParamBytes <$> getValue ctx rpcParamType
      pure RpcParam{..}

------------------------------------------------------------------------------
-- LOGIN7

genLogin7 :: Gen Login7
genLogin7 = do
  l7Version <- Gen.element [Tds74, Tds80]
  l7PacketSize <- Gen.word32 Range.linearBounded
  l7ClientProgVer <- Gen.word32 Range.linearBounded
  l7ClientPid <- Gen.word32 Range.linearBounded
  l7ConnectionId <- Gen.word32 Range.linearBounded
  l7OptionFlags1 <- Gen.word8 Range.linearBounded
  l7OptionFlags2 <- Gen.word8 Range.linearBounded
  l7TypeFlags <- Gen.word8 Range.linearBounded
  -- Bit 0x10 (FeatureExt present) is decided by 'putLogin7' from 'l7Features'
  -- alone and always cleared again by 'getLogin7', so fix it here too.
  l7OptionFlags3 <- (.&. complement 0x10) <$> Gen.word8 Range.linearBounded
  l7TimeZone <- Gen.int32 Range.linearBounded
  l7Collation <- Gen.word32 Range.linearBounded
  l7HostName <- genLoginText
  l7UserName <- genLoginText
  l7Password <- genLoginText
  l7AppName <- genLoginText
  l7ServerName <- genLoginText
  l7LibraryName <- genLoginText
  l7Language <- genLoginText
  l7Database <- genLoginText
  l7ClientId <- Gen.bytes (Range.singleton 6)
  l7Features <- Gen.list (Range.linear 0 3) genFeature
  pure Login7{..}
  where
    genLoginText = Gen.text (Range.linear 0 20) Gen.unicode
    genFeature = Feature <$> Gen.filter (/= 0xFF) (Gen.word8 Range.linearBounded) <*> Gen.bytes (Range.linear 0 15)
