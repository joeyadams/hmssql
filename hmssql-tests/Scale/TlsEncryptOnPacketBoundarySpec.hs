-- | The same PLP packet-boundary matrix as "Types.NVarCharSpec" and
-- "Scale.TlsBinaryPacketBoundarySpec", but under 'EncryptOn': TDS 7.4, with
-- TLS negotiated inside PRELOGIN and the rest of the session ("Hmssql.Tds")
-- continuing over that TLS context ('hostedTlsHandshake'), a different code
-- path from 'EncryptStrict's TLS-from-byte-0 ('strictTlsHandshake'). Neither
-- existing spec exercises this path at scale.
--
-- @nvarchar(max)@ gets the full matrix (every packet size, every boundary
-- length); @varbinary(max)@ gets a representative subset, since the
-- underlying PLP chunking and TLS record framing are exercised identically
-- by both types and "Scale.TlsBinaryPacketBoundarySpec" already covers
-- binary thoroughly under 'EncryptStrict'.
module Scale.TlsEncryptOnPacketBoundarySpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import Test.Hspec

import Hmssql
import TestDb

withEncryptOnPacketSize :: Word32 -> (Connection -> IO a) -> IO a
withEncryptOnPacketSize sz act = do
  ci <- testConnectInfo EncryptOn
  withConnection ci { connectPacketSize = sz } act

boundaryLengths :: Word32 -> [Int]
boundaryLengths sz =
  let so = fromIntegral sz :: Int
  in [max 0 (so - 1), so, so + 1, max 0 (2 * so - 1), 2 * so, 2 * so + 1]

spec :: Spec
spec = describe "PLP across packet boundaries, TDS-hosted TLS (EncryptOn)" $ do
  let packetSizes = [512, 4096, 32767] :: [Word32]

  describe "nvarchar(max)" $
    forM_ packetSizes $ \sz ->
      it ("round trips an nvarchar(max) parameter across boundaries at packet size " ++ show sz) $
        withEncryptOnPacketSize sz $ \conn ->
          forM_ (boundaryLengths sz) $ \len -> do
            let t = T.replicate len "x" :: Text
            Only t' <- query1 conn ("SELECT " <> param t)
            t' `shouldBe` t
            Only dlen <- query1 conn ("SELECT DATALENGTH(" <> param t <> ")") :: IO (Only Int)
            dlen `shouldBe` len * 2

  describe "varbinary(max) (representative subset)" $
    forM_ packetSizes $ \sz ->
      it ("round trips a varbinary(max) parameter at packet-boundary lengths at packet size " ++ show sz) $
        withEncryptOnPacketSize sz $ \conn ->
          -- just the two lengths that straddle a single packet boundary,
          -- rather than the full six-length matrix
          forM_ [fromIntegral sz - 1, fromIntegral sz + 1] $ \len -> do
            let b = B.replicate len 0x5A
            Only b' <- query1 conn (mkQuery "SELECT @p1" (Only b))
            b' `shouldBe` b
