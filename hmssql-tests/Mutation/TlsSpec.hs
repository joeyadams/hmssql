-- | Tests found by mutation testing of "Hmssql.Connection.Tls": where the
-- trusted certificates come from.
module Mutation.TlsSpec (spec) where

import Control.Exception (bracket)
import Data.Int (Int32)
import Data.X509.CertificateStore (listCertificates)
import Data.X509.File (readSignedObject)
import qualified Data.ByteString as B
import System.Directory (getModificationTime, getTemporaryDirectory, removeFile, setModificationTime)
import System.IO (hClose, openTempFile)
import Test.Hspec

import Hmssql
import Hmssql.Connection.Tls (buildCertificateStore)
import TestConfig

-- | Strict-encryption settings trusting only what @tls@ says (no system store).
connectTrusting :: (TlsSettings -> TlsSettings) -> IO [Only Int32]
connectTrusting adjust = do
  ci <- testConnectInfo EncryptStrict
  let tls = adjust (connectTls ci)
        { tlsUseSystemCertificateStore = False
        , tlsCaCertificateFiles = []
        , tlsExtraCertificates = []
        }
  withConnection ci { connectTls = tls } $ \conn -> query conn "SELECT 1"

requireCert :: IO FilePath
requireCert = testCertFile >>= maybe (pendingWith "HMSSQL_TEST_CERT is not set" >> fail "unreachable") pure

withEmptyFile :: (FilePath -> IO a) -> IO a
withEmptyFile act = do
  dir <- getTemporaryDirectory
  bracket (openTempFile dir "hmssql-empty.pem") (\(path, _) -> removeFile path) $ \(path, h) -> do
    hClose h
    act path

spec :: Spec
spec = describe "trusted certificates (live server)" $ do
  it "trusts certificates given in memory (tlsExtraCertificates)" $ do
    certs <- requireCert >>= readSignedObject
    connectTrusting (\t -> t { tlsExtraCertificates = certs }) `shouldReturn` [Only 1]

  it "reads every file in tlsCaCertificateFiles, not just the first" $ do
    cert <- requireCert
    withEmptyFile $ \empty ->
      connectTrusting (\t -> t { tlsCaCertificateFiles = [empty, cert] }) `shouldReturn` [Only 1]

  it "buildCertificateStore includes the system store only when asked to" $ do
    let none = defaultTlsSettings { tlsUseSystemCertificateStore = False }
    withSystem <- listCertificates <$> buildCertificateStore defaultTlsSettings
    without <- listCertificates <$> buildCertificateStore none
    (null withSystem, length without) `shouldBe` (False, 0)

  it "buildCertificateStore adds the files and the in-memory certificates" $ do
    cert <- requireCert
    certs <- readSignedObject cert
    let base = defaultTlsSettings { tlsUseSystemCertificateStore = False }
    fromFile <- listCertificates <$> buildCertificateStore base { tlsCaCertificateFiles = [cert] }
    fromMemory <- listCertificates <$> buildCertificateStore base { tlsExtraCertificates = certs }
    (length fromFile, length fromMemory) `shouldBe` (length certs, length certs)

  -- No cache by path and modification time: one would keep trusting a
  -- file replaced with its modification time preserved, or the file of
  -- another working directory under the same relative path.
  it "buildCertificateStore reads a file every time, even one replaced with its modification time kept" $ do
    cert <- requireCert
    pem <- B.readFile cert
    certs <- tlsExtraCertificates . (\c -> defaultTlsSettings { tlsExtraCertificates = c }) <$> readSignedObject cert
    let from path = length . listCertificates <$> buildCertificateStore
          defaultTlsSettings { tlsUseSystemCertificateStore = False, tlsCaCertificateFiles = [path] }
    withEmptyFile $ \path -> do
      t0 <- getModificationTime path
      from path `shouldReturn` 0
      B.writeFile path pem
      setModificationTime path t0
      from path `shouldReturn` length certs
      B.writeFile path B.empty
      setModificationTime path t0
      from path `shouldReturn` 0
