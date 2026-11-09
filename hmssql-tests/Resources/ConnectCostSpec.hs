-- | What a connection costs to open.  Each connection used to load the
-- system certificate store (on macOS by running the @security@ tool): about
-- 20 ms and 38 MB of allocation per TLS connection, a third of the time of
-- a connection to a local server.  It is now loaded once per process.
module Resources.ConnectCostSpec (spec) where

import Control.Monad (forM_, replicateM_)
import GHC.Stats (allocated_bytes, getRTSStats, getRTSStatsEnabled)
import Test.Hspec

import Hmssql
import TestDb

spec :: Spec
spec = describe "opening a TLS connection that trusts the system store" $
  forM_ [EncryptStrict, EncryptOn] $ \enc ->
    it ("allocates less than 8 MB (" ++ show enc ++ ")") $ do
      enabled <- getRTSStatsEnabled
      enabled `shouldBe` True
      ci0 <- testConnectInfo enc
      let ci = ci0 { connectTls = (connectTls ci0) { tlsUseSystemCertificateStore = True } }
          open = withConnection ci $ \conn -> query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
          n = 10
      open
      before <- allocated_bytes <$> getRTSStats
      replicateM_ n open
      after <- allocated_bytes <$> getRTSStats
      ((after - before) `div` fromIntegral n) `shouldSatisfy` (< 8 * 1024 * 1024)
