-- | The SQLBatch size limit: SQL Server accepts at most 65535 packets in one
-- SQLBatch message, and drops the connection (without an error message) on
-- a longer one.  hmssql refuses such a batch before sending it.
module Connection.BatchSizeSpec (spec) where

import Control.Exception (try)
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Word (Word32)
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Errors
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import TestDb

-- | The longest @SELECT DATALENGTH(N'BBB...')@ that fits in 65535 packets of
-- this size: 22 bytes of ALL_HEADERS, then 2 bytes per character.
longestBatch :: Word32 -> Int
longestBatch size = (65535 * (fromIntegral size - 8) - 22) `div` 2 - length ("SELECT DATALENGTH(N'')" :: String)

batchOf :: Int -> T.Text
batchOf n = "SELECT DATALENGTH(N'" <> T.replicate n "B" <> "')"

spec :: Spec
spec = do
  describe "packetCount" $
    it "is the number of packets splitIntoPackets makes" $ hedgehog $ do
      size <- forAll (Gen.integral (Range.linear 9 600))
      len <- forAll (Gen.int (Range.linear 0 5000))
      let ctx = defaultTdsContext { tdsPacketSize = size }
          body = LB.replicate (fromIntegral len) 0x41
      packetCount ctx body === length (splitIntoPackets ctx PTSqlBatch (PacketStatus 0) body)

  describe "a SQL batch over 65535 packets" $ do
    let withSmallPackets act = do
          ci <- defaultTestConnectInfo
          withConnection ci { connectPacketSize = 512 } act

    it "is sent when it just fits" $ withSmallPackets $ \conn -> do
      let n = longestBatch 512
      query1 conn (rawSql (batchOf n)) `shouldReturn` Only (2 * fromIntegral n :: Int64)

    it "is refused with EncodeError before anything is sent, leaving the connection usable" $
      withSmallPackets $ \conn -> do
        r <- try (execute conn (rawSql (batchOf (longestBatch 512 + 1))))
        case r of
          Left (EncodeError msg) -> msg `shouldSatisfy` ("65535" `isInfixOf`)
          Right _ -> expectationFailure "sent a batch over 65535 packets"
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "leaves a pending reset pending (no session setup)" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectPacketSize = 512, connectSessionSetup = [] } $ \conn -> do
        _ <- execute conn "CREATE TABLE #hmssql_batch_size (i int)"
        reset conn
        r <- try (execute conn (rawSql (batchOf (longestBatch 512 + 1))))
        either (\(EncodeError _) -> pure ()) (\_ -> expectationFailure "sent") r
        -- This request carries the reset.
        query1 conn "SELECT OBJECT_ID('tempdb..#hmssql_batch_size')" `shouldReturn` Only (Nothing :: Maybe Int)

    it "counts packets of the negotiated size" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectPacketSize = 1024 } $ \conn -> do
        r <- try (execute conn (rawSql (batchOf (longestBatch 1024 + 1))))
        either (\(EncodeError _) -> pure ()) (\_ -> expectationFailure "sent") r
        let n = longestBatch 1024
        query1 conn (rawSql (batchOf n)) `shouldReturn` Only (2 * fromIntegral n :: Int64)
