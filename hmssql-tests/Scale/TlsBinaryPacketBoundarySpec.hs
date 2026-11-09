-- | @varbinary(max)@ round trips across TDS packet boundaries at several
-- negotiated packet sizes, under strict TLS encryption ('EncryptStrict':
-- TDS 8.0, TLS wraps every byte from the start of the connection).
--
-- "Types.NVarCharSpec" already runs this exact boundary matrix for
-- @nvarchar(max)@ (see its \"PLP across different negotiated packet sizes\"
-- section); this is the same matrix for binary data, which is untested at
-- any packet size elsewhere. Since every packet here is TLS-wrapped, a value
-- that straddles a TDS packet boundary also straddles a TLS record boundary,
-- exercising the buffering that must track TDS packet boundaries inside the
-- decrypted TLS stream.
module Scale.TlsBinaryPacketBoundarySpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Word (Word32)
import Test.Hspec

import Hmssql
import TestDb

withPacketSize :: Word32 -> (Connection -> IO a) -> IO a
withPacketSize sz act = do
  ci <- testConnectInfo EncryptStrict
  withConnection ci { connectPacketSize = sz } act

spec :: Spec
spec = describe "PLP across different negotiated packet sizes" $ do
  let packetSizes = [512, 4096, 32767] :: [Word32]
  forM_ packetSizes $ \sz ->
    it ("round trips a varbinary(max) parameter across boundaries at packet size " ++ show sz) $
      withPacketSize sz $ \conn -> do
        let so = fromIntegral sz :: Int
            lens = [max 0 (so - 1), so, so + 1, max 0 (2 * so - 1), 2 * so, 2 * so + 1]
        forM_ lens $ \len -> do
          let b = B.replicate len 0x5A
          Only b' <- query1 conn ("SELECT " <> param b)
          b' `shouldBe` b
          Only dlen <- query1 conn ("SELECT DATALENGTH(" <> param b <> ")") :: IO (Only Int)
          dlen `shouldBe` len
