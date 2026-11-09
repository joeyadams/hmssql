-- | The exact-size RPC body writer ('rpcRequestBodyUnchecked') and the SQL batch
-- body ('sqlBatchBody') against the writers they replaced, kept here as
-- the reference: binary's 'Put' and a bytestring 'BB.Builder', a field at
-- a time.
module Wire.RpcBodySpec (spec) where

import Hmssql.Encoding (ParamValue (..))
import RecipeParameters
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as LB
import Data.List (intersperse)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog
import TestDb (withCases)

import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives (Collation (..), putUsVarChar)
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Utf16 as Utf16

import Wire.RequestsSpec (genRpcRequest)
import Wire.TypeInfoSpec (genText, genValueFor)

spec :: Spec
spec = describe "RPC body" $ do
  withCases 2000 $
    it "rpcRequestBodyUnchecked writes the bytes the Builder writer wrote" $ hedgehog $ do
      ctx <- forAll genContext
      reqs <- forAll $ Gen.list (Range.linear 1 4) genRequest
      rpcRequestBodyUnchecked ctx reqs === referenceRpcBody ctx reqs

  it "refers to values of 8 KiB or more rather than copying them" $ do
    let big = B.replicate 100_000 0x61
        req = RpcRequest procSpExecuteSql 0
          [ byteParam "" 0 (TINVarChar maxLength (Collation 0 0)) (Just big)
          , byteParam "@p1" 0 (TIBigVarBinary 8000) (Just (B.replicate 8000 0x62))
          ]
        body = rpcRequestBody defaultTdsContext [req]
    body `shouldBe` referenceRpcBody defaultTdsContext [req]
    -- The buffer before the value, the value itself, the buffer after it.
    map B.length (LB.toChunks body) `shouldSatisfy` elem 100_000

  withCases 500 $
    it "sqlBatchBody writes ALL_HEADERS and the text as before" $ hedgehog $ do
      ctx <- forAll genContext
      sql <- forAll $ Gen.choice [genText, Gen.text (Range.linear 0 3000) Gen.unicode]
      sqlBatchBody ctx sql === Put.runPut (putAllHeaders ctx >> Put.putByteString (Utf16.encodeUtf16LE sql))

genContext :: Gen TdsContext
genContext = do
  td <- Gen.maybe (TransactionDescriptor <$> Gen.word64 Range.linearBounded)
  pure defaultTdsContext { tdsTransaction = td }

-- | 'genRpcRequest', and requests with names outside ASCII, large values
-- and UDT types (which 'Wire.TypeInfoSpec.genTypeInfo' leaves out).
genRequest :: Gen RpcRequest
genRequest = Gen.choice
  [ genRpcRequest
  , do
      rpcProc <- Gen.choice
        [ pure procSpExecuteSql
        , RpcProcName <$> Gen.text (Range.linear 0 40) Gen.unicode
        ]
      rpcOptions <- Gen.word16 Range.linearBounded
      rpcParams <- Gen.list (Range.linear 0 8) genParam
      pure RpcRequest{..}
  ]
  where
    genParam = do
      rpcParamName <- Gen.choice [pure "", ("@" <>) <$> Gen.text (Range.linear 1 60) Gen.unicode]
      rpcParamStatus <- Gen.word8 Range.linearBounded
      (rpcParamType, rawValue) <- Gen.choice
        [ do
            ti <- Gen.element [TINVarChar maxLength (Collation 0 0), TIBigVarBinary maxLength, TIXml Nothing]
            v <- Gen.frequency
              [ (1, pure Nothing)
              , (4, Just <$> Gen.bytes (Range.exponential 0 70_000))
              , (1, Just <$> Gen.bytes (Range.linear 8180 8200))
              ]
            pure (ti, v)
        , do
            ti <- TIUdt <$> (UdtInfo <$> Gen.word16 Range.linearBounded <*> genText <*> genText <*> genText <*> genText)
            (,) ti <$> genValueFor ti
        , do
            ti <- Gen.element [TIText 0x7FFFFFFF (Collation 0 0), TINText 0x7FFFFFFF (Collation 0 0), TIImage 0x7FFFFFFF]
            (,) ti <$> Gen.maybe (Gen.bytes (Range.exponential 0 30_000))
        ]
      let rpcParamValue = ParamBytes rawValue
      pure RpcParam{..}

------------------------------------------------------------------------------
-- The reference: the Builder-based writer that the exact-size one
-- ('rpcRequestBody') replaced, kept here as it was.

referenceRpcBody :: TdsContext -> [RpcRequest] -> LB.ByteString
referenceRpcBody ctx reqs = Put.runPut $ do
  putAllHeaders ctx
  sequence_ $ intersperse (Put.putWord8 0xFF) (map putOne reqs)
  where
    putOne RpcRequest{..} = do
      case rpcProc of
        RpcProcId pid -> Put.putWord16le 0xFFFF >> Put.putWord16le pid
        RpcProcName name -> putUsVarChar name
      Put.putWord16le rpcOptions
      Put.putBuilder (foldMap (paramBuilder ctx) rpcParams)

paramBuilder :: TdsContext -> RpcParam -> BB.Builder
paramBuilder ctx RpcParam{..} =
  BB.word8 (fromIntegral (Utf16.utf16Length rpcParamName))
    <> Utf16.utf16LEBuilder rpcParamName
    <> BB.word8 rpcParamStatus
    <> Put.execPut (putTypeInfo ctx rpcParamType)
    <> Put.execPut (putValueUnchecked rpcParamType (parameterBytes rpcParamValue))
