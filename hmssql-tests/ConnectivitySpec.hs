module ConnectivitySpec (spec) where

import Control.Exception (try)
import Network.TLS (TLSException)
import Test.Hspec

import Hmssql.Connection
import Hmssql.Errors
import Hmssql.Tds.Context
import Hmssql.Tds.Token (ServerMessage (..))
import TestConfig

spec :: Spec
spec = do
  describe "strict encryption (TDS 8.0)" $ do
    it "logs in" $ withTestConnection EncryptStrict $ \conn -> do
      ctx <- connectionContext conn
      tdsVersion ctx `shouldBe` Tds80

    it "rejects an untrusted certificate" $ do
      ci <- testConnectInfo EncryptStrict
      r <- try $ withConnection ci { connectTls = defaultTlsSettings { tlsUseSystemCertificateStore = False } } (\_ -> pure ())
      case r of
        Left (_ :: TLSException) -> pure ()
        Right () -> expectationFailure "connected with an untrusted certificate"

    it "can skip validation with trustServerCertificate" $ do
      ci <- testConnectInfo EncryptStrict
      withConnection ci { connectTls = defaultTlsSettings { tlsTrustServerCertificate = True } } $ \conn -> do
        ctx <- connectionContext conn
        tdsVersion ctx `shouldBe` Tds80

  describe "TDS-hosted TLS (ENCRYPT_ON)" $
    it "logs in" $ withTestConnection EncryptOn $ \conn -> do
      ctx <- connectionContext conn
      tdsVersion ctx `shouldBe` Tds74

  describe "login-only encryption (ENCRYPT_OFF)" $
    it "logs in" $ withTestConnection EncryptOff $ \conn -> do
      ctx <- connectionContext conn
      tdsVersion ctx `shouldBe` Tds74

  describe "login failures" $
    it "reports a bad password as LoginError" $ do
      ci <- defaultTestConnectInfo
      r <- try $ withConnection ci { connectPassword = "wrong" } (\_ -> pure ())
      case r of
        Left (LoginError msg) -> msgNumber msg `shouldBe` 18456
        Right () -> expectationFailure "logged in with a bad password"
