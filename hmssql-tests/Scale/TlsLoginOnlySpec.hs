-- | Large values sent and received *after* login under 'EncryptOff'
-- (login-only encryption): only the LOGIN7 packet itself is TLS-wrapped
-- ([\[MS-TDS\] 2.2.6.5]); every packet after that, including these large
-- values, travels in plaintext over the raw socket
-- ('Hmssql.Connection.Internal.TransportPlain'). "Protocol.EncryptionSpec" and
-- "ConnectivitySpec" already confirm the login itself succeeds and that
-- @encrypt_option@ reports @FALSE@; this checks that the framing/buffering
-- logic correctly stops expecting TLS records once the handshake's
-- single encrypted packet ends, for values large and oddly-sized enough to
-- span several plaintext TDS packets.
module Scale.TlsLoginOnlySpec (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import Test.Hspec

import Hmssql
import TestDb

mib :: Int
mib = 1024 * 1024

withLoginOnlyPacketSize :: Word32 -> (Connection -> IO a) -> IO a
withLoginOnlyPacketSize sz act = do
  ci <- testConnectInfo EncryptOff
  withConnection ci { connectPacketSize = sz } act

spec :: Spec
spec = describe "large values after login-only encryption drops away (EncryptOff)" $ do
  around (withTestConnection EncryptOff) $ do
    describe "several-MB values over the post-login plaintext channel" $ do
      it "round trips a several-MB varbinary(max) parameter" $ \conn -> do
        let v = B.replicate (4 * mib) 0x7A
        Only v' <- query1 conn ("SELECT " <> param v)
        v' `shouldBe` v

      it "round trips a several-MB nvarchar(max) parameter" $ \conn -> do
        let t = T.replicate (2 * mib) "q" :: Text
        Only t' <- query1 conn ("SELECT " <> param t)
        t' `shouldBe` t
        Only dlen <- query1 conn ("SELECT DATALENGTH(" <> param t <> ")") :: IO (Only Int)
        dlen `shouldBe` (2 * mib) * 2

  describe "PLP across plaintext packet boundaries" $ do
    -- the default packet size, and a non-default one, both over the
    -- plaintext-after-login channel
    let packetSizes = [4096, 32767] :: [Word32]
    forM_ packetSizes $ \sz ->
      it ("round trips values straddling a packet boundary at packet size " ++ show sz) $
        withLoginOnlyPacketSize sz $ \conn -> do
          let so = fromIntegral sz :: Int
              lens = [so - 1, so, so + 1, 2 * so - 1, 2 * so, 2 * so + 1]
          forM_ lens $ \len -> do
            let b = B.replicate len 0x5A
            Only b' <- query1 conn (mkQuery "SELECT @p1" (Only b))
            b' `shouldBe` b

            let t = T.replicate len "x" :: Text
            Only t' <- query1 conn (mkQuery "SELECT @p1" (Only t))
            t' `shouldBe` t

  slow $ describe "a genuinely large value over the plaintext channel (slow)" $
    it "round trips a 32 MB varbinary(max) parameter" $
      withTestConnection EncryptOff $ \conn -> do
        let v = B.replicate (32 * mib) 0x42
        Only v' <- query1 conn (mkQuery "SELECT @p1" (Only v))
        v' `shouldBe` v
