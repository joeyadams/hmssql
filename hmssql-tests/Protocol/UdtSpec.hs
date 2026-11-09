-- | A result with CLR user-defined type columns, served by the mock: hmssql
-- doesn't decode UDT values, so decoding one is a 'DecodeError' that says
-- so, but the response is well-formed, so the connection stays usable
-- (unlike a malformed stream, which breaks it).  'RawValue' still gets the
-- serialized bytes.
module Protocol.UdtSpec (spec) where

import Control.Exception (SomeException, fromException)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import Data.List (isInfixOf)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Decoding
import Hmssql.Errors
import Hmssql.Tds.Primitives (putBVarChar)
import Hmssql.Tds.Token (columnName)
import MockServer (doneToken)
import Protocol.MockTokens
import Wire.UdtSpec (geographyInfo, hierarchyIdInfo, plpNull, plpValue, udtColumn)

point :: B.ByteString
point = B.pack [0xE6, 0x10, 0, 0, 1, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F]

-- | Columns (id int, h hierarchyid, g geography); two rows, the second with
-- NULL UDTs.
udtResponse :: [Put.Put]
udtResponse =
  [ do
      Put.putWord8 0x81 >> Put.putWord16le 3
      Put.putWord32le 0 >> Put.putWord16le 0 >> Put.putWord8 0x38 >> putBVarChar "id"
      udtColumn hierarchyIdInfo "h"
      udtColumn geographyInfo "g"
  , Put.putWord8 0xD1 >> Put.putInt32le 1 >> plpValue (B.pack [0x5B, 0x40]) >> plpValue point
  , Put.putWord8 0xD1 >> Put.putInt32le 2 >> plpNull >> plpNull
  , doneToken 0x10 2
  ]

expectUdtDecodeError :: Show a => Either SomeException a -> Expectation
expectUdtDecodeError = \case
  Left e | Just (DecodeError col why) <- fromException e -> do
    col `shouldBe` Just "h"
    why `shouldSatisfy` ("user-defined type" `isInfixOf`)
    why `shouldSatisfy` ("hierarchyid" `isInfixOf`)
  other -> expectationFailure ("expected a DecodeError for column h, got " ++ either describeException (take 300 . show) other)

spec :: Spec
spec = do
  it "decoding a UDT column as Text is a DecodeError naming the type; the connection stays usable" $
    withScriptedTokens udtResponse $ \conn -> do
      r <- within (trySync (query conn "SELECT id, h, g" >>= forceShow :: IO [(Int, Text, Text)]))
      expectUdtDecodeError r
      expectUsable conn

  it "is rejected up front, even when every value is NULL" $
    withScriptedTokens udtResponse $ \conn -> do
      r <- within (trySync (query conn "SELECT id, h, g" >>= forceShow :: IO [(Int, Maybe Text, Maybe Text)]))
      expectUdtDecodeError r
      expectUsable conn

  it "SqlValue (queryMulti) rejects it too" $
    withScriptedTokens udtResponse $ \conn -> do
      r <- within (trySync (queryMulti conn "SELECT id, h, g" >>= forceShow))
      expectUdtDecodeError r
      expectUsable conn

  it "SqlRow keeps metadata for an empty result set without forcing its deferred error" $
    withScriptedTokens (take 1 udtResponse ++ [doneToken 0x10 0]) $ \conn -> do
      [ResultSet cols rows] <- within (queryMulti conn "SELECT id, h, g WHERE 1 = 0")
      map columnName cols `shouldBe` ["id", "h", "g"]
      rows `shouldBe` []
      expectUsable conn

  it "RawValue gets the serialized bytes" $
    withScriptedTokens udtResponse $ \conn -> do
      r <- within (query conn "SELECT id, h, g")
      r `shouldBe` [(1 :: Int, Just (RawValue (B.pack [0x5B, 0x40])), Just (RawValue point)), (2, Nothing, Nothing)]
      expectUsable conn

  it "streaming past the UDT columns without decoding them (execute) works" $
    withScriptedTokens udtResponse $ \conn -> do
      within (execute conn "SELECT id, h, g") `shouldReturn` 2
      expectUsable conn
