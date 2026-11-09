module Api.PureDecoderFailureSpec (spec) where
import Test.Hspec
import Hmssql
import Hmssql.Decoding
import Hmssql.Query
import MockServer
import Protocol.MockTokens (goodResponse, expectBroken)

spec :: Spec
spec = it "preserves connection failure for an exception from a pure conversion" $
  withMockServer (\mc -> serveLogin defaultLoginResponse mc >> serveRequests (\_ _ -> pure goodResponse) mc) $ \server ->
    withConnection (mockConnectInfo server) $ \conn -> do
      let decoder = singleField (fieldDecoderFor "bad" (const True) (\_ _ _ -> error "conversion failed"))
      (queryWith decoder conn "SELECT 42" :: IO [Int]) `shouldThrow` anyErrorCall
      expectBroken conn
