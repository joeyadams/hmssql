-- | Invalid datetimeoffset values fail decoding without damaging framing.
module Protocol.DateTimeOffsetSpec (spec) where

import Wire.PrimitiveGet (getDateTimeOffset)
import Control.Monad (forM_)
import qualified Data.Binary.Get as Get
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Either (isLeft)
import Data.Int (Int16)
import Data.Time
import Test.Hspec

import Hmssql
import Hmssql.Query (callProcedure, decodeReturnValue, ProcResult (..))
import Hmssql.Connection.Internal (nextToken, startRequest)
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Primitives
import Hmssql.Tds.Token (Token (..), ReturnValue (..))
import Hmssql.Tds.Value (rowValues)
import Hmssql.Tds.TypeInfo (TypeInfo (..), putTypeInfo)
import Hmssql.Tds.Context (defaultTdsContext)
import MockServer (doneToken)
import Protocol.MockTokens

-- Encode only the UTC part through the checked encoder, then append an
-- unchecked offset so malformed values reach the decoder.
wire :: Scale -> UTCTime -> Int16 -> B.ByteString
wire scale (UTCTime day tod) mins =
  let utc = either error id (putDateTime2 scale (LocalTime day (timeToTimeOfDay tod)))
   in LB.toStrict (Put.runPut (utc >> Put.putInt16le mins))

spec :: Spec
spec = describe "datetimeoffset bounds" $ forM_ [0 .. 7] $ \scale -> describe ("scale " ++ show scale) $ do
  let lo = fromGregorian 1 1 1
      hi = fromGregorian 9999 12 31
      unit = picosecondsToDiffTime (10 ^ (12 - fromIntegral scale :: Int))
      middle = UTCTime (fromGregorian 2000 1 1) 0
      invalid =
        [ ("offset +841", middle, 841)
        , ("offset -841", middle, -841)
        , ("offset minBound", middle, minBound)
        , ("offset maxBound", middle, maxBound)
        , ("local date before year 1", UTCTime lo (840 * 60 - unit), -840)
        , ("local date after year 9999", UTCTime hi (86400 - 840 * 60), 840)
        , ("negative minute at the first UTC midnight", UTCTime lo 0, -1)
        , ("positive minute at the last UTC instant", UTCTime hi (86400 - unit), 1)
        ]
      valid =
        [ DateTimeOffset (UTCTime lo (840 * 60)) (-840)
        , DateTimeOffset (UTCTime hi (86400 - 840 * 60 - unit)) 840
        , DateTimeOffset (UTCTime lo 0) 840
        , DateTimeOffset (UTCTime hi (86400 - unit)) (-840)
        ]
      ti = TIDateTimeOffsetN scale
      good = wire scale middle 0
      response bad = [colMetaData [("v", ti)], row [(ti, Just bad)], row [(ti, Just good)], doneToken 0x10 2]

  forM_ invalid $ \(label, utc, mins) -> it ("rejects " ++ label ++ " in both primitive readers") $ do
    let bs = wire scale utc mins
    readDateTimeOffset scale (B.take (B.length bs) (B.drop 6 ("prefix" <> bs <> "suffix"))) `shouldSatisfy` isLeft
    Get.runGetOrFail (getDateTimeOffset scale) (LB.fromStrict bs) `shouldSatisfy` isLeft

  it "round-trips valid UTC and local date boundaries with offsets of +/-840" $
    forM_ valid $ \dto -> do
      Right encoded <- pure (putDateTimeOffset scale dto)
      let bs = LB.toStrict (Put.runPut encoded)
      readDateTimeOffset scale bs `shouldBe` Right dto
      Get.runGet (getDateTimeOffset scale) (LB.fromStrict bs) `shouldBe` dto

  it "rejects malformed rows but keeps the connection usable" $
    forM_ invalid $ \(_, utc, mins) ->
      withScriptedTokens (response (wire scale utc mins)) $ \conn -> do
        within (trySync (query conn "SELECT v" :: IO [Only DateTimeOffset])) >>= expectDecodeError
        expectUsable conn

  it "keeps raw invalid values and the following row readable" $
    forM_ invalid $ \(_, utc, mins) -> do
      let bad = wire scale utc mins
      withScriptedTokens (response bad) $ \conn -> do
        ar <- startRequest conn PTSqlBatch (const mempty)
        Just (TColMetaData _) <- nextToken conn ar
        Just (TRow first) <- nextToken conn ar
        rowValues first `shouldBe` [Just bad]
        Just (TRow second) <- nextToken conn ar
        rowValues second `shouldBe` [Just good]
        Just (TDone _) <- nextToken conn ar
        nextToken conn ar `shouldReturn` Nothing
        expectUsable conn

  it "rejects malformed output parameters while retaining their raw values" $
    forM_ invalid $ \(_, utc, mins) -> do
      let bad = wire scale utc mins
          rv = do
            Put.putWord8 0xAC >> Put.putWord16le 1 >> putBVarChar "@out"
            Put.putWord8 1 >> Put.putWord32le 0 >> Put.putWord16le 0
            putTypeInfo defaultTdsContext ti
            Put.putWord8 (fromIntegral (B.length bad)) >> Put.putByteString bad
      withScriptedTokens [rv, doneToken 0 0] $ \conn -> do
        result <- callProcedure conn "p" []
        case procOutputValues result of
          [out] -> do
            decodeReturnValue @DateTimeOffset out `shouldSatisfy` isLeft
            rvValue out `shouldBe` Just bad
          other -> expectationFailure ("expected one output value, got " ++ show other)
        expectUsable conn
