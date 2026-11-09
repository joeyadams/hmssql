-- | LOGIN7 locates each string (host, user, password, application, server,
-- language, database) with a 16-bit offset and a 16-bit character count
-- ([MS-TDS] 2.2.6.4).  Strings too long for those used to be written modulo
-- 65536, so the server read garbled (and shifted) fields; hmssql must refuse
-- them before sending anything.  Lengths the wire can carry are sent, and
-- the server applies its own limits.
module Review.Login7FieldsSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client (Login7 (..), defaultLogin7, login7Problem)
import MockServer
import TestDb

isEncodeError :: Either SomeException a -> Bool
isEncodeError = \case
  Left e -> isJust (fromException e :: Maybe EncodeError)
  Right _ -> False

spec :: Spec
spec = do
  describe "login7Problem" $ do
    it "accepts ordinary logins" $ do
      login7Problem defaultLogin7 `shouldBe` Nothing
      login7Problem defaultLogin7 { l7UserName = T.replicate 128 "u", l7Password = T.replicate 128 "p" } `shouldBe` Nothing
    it "refuses a field longer than a 16-bit character count" $
      login7Problem defaultLogin7 { l7AppName = T.replicate 70000 "a" } `shouldSatisfy` isJust
    it "refuses fields whose offsets would pass 65535" $
      login7Problem defaultLogin7 { l7Database = T.replicate 20000 "d", l7AppName = T.replicate 20000 "a" } `shouldSatisfy` isJust

  describe "connect" $ do
    it "refuses an application name too long for LOGIN7 with an EncodeError, before sending it" $
      withMockServer (cannedLoginServer defaultLoginResponse) $ \srv -> do
        r <- try (connect (mockConnectInfo srv) { connectApplicationName = T.replicate 70000 "a" } >>= close)
        r `shouldSatisfy` isEncodeError

    it "refuses a database name that would push later offsets past 65535" $ do
      ci <- testConnectInfo EncryptStrict
      r <- try (connect ci { connectDatabase = T.replicate 40000 "d" } >>= close)
      r `shouldSatisfy` isEncodeError

    it "sends a long application name the wire can carry (the server applies its own limit)" $ do
      ci <- testConnectInfo EncryptStrict
      r <- try (withConnection ci { connectApplicationName = T.replicate 300 "a" } $ \conn ->
        query conn "SELECT 1")
      case r of
        Left (e :: SomeException) -> fromException e `shouldNotSatisfy` (isJust :: Maybe EncodeError -> Bool)
        Right rows -> rows `shouldBe` [Only (1 :: Int)]
