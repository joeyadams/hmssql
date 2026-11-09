{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | Security review: the password never appears in what hmssql shows or
-- throws, and a connection doesn't keep it.
module Security.SecretsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Data.Maybe (isNothing)
import qualified Data.ByteString.Char8 as BC
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Array as TA
import qualified Data.Text.Encoding as T
import Data.Text.Internal (Text (..))
import GHC.Exts (mkWeakNoFinalizer#)
import GHC.IO (IO (..))
import GHC.Weak (Weak (..), deRefWeak)
import System.Mem (performMajorGC)
import Data.Time.Clock (getCurrentTime)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Client (Login7 (..), defaultLogin7, featureFedAuthToken, login7Problem, obfuscatePassword)
import MockServer
import TestConfig

secret :: T.Text
secret = "Pa55-w0rd-that-must-not-leak"

-- | Neither the password nor its obfuscated LOGIN7 form (as 'show' of a
-- ByteString would print it) is in the text.
shouldNotLeak :: String -> Expectation
shouldNotLeak s = do
  s `shouldNotContain` T.unpack secret
  s `shouldNotContain` BC.unpack (obfuscatePassword (T.encodeUtf16LE secret))
  s `shouldNotContain` show (obfuscatePassword (T.encodeUtf16LE secret))

-- | A weak pointer to the array holding a Text's characters: it dies once
-- no Text refers to that array, however often the Text itself is unboxed
-- and reboxed.
weakChars :: Text -> IO (Weak ())
weakChars (Text (TA.ByteArray ba) _ _) = IO $ \s -> case mkWeakNoFinalizer# ba () s of
  (# s', w #) -> (# s', Weak w #)

-- | Run major GCs until the condition holds, or give up after a few seconds.
gcUntil :: IO Bool -> IO Bool
gcUntil cond = go (30 :: Int)
  where
    go 0 = cond
    go n = do
      performMajorGC
      ok <- cond
      if ok then pure True else threadDelay 100_000 >> go (n - 1)

-- | Both renderings of an exception.
renderings :: SomeException -> [String]
renderings e = [show e, displayException e]

spec :: Spec
spec = describe "the password" $ do
  it "is not in the Show of a Login7" $ do
    shouldNotLeak (show defaultLogin7 { l7Password = secret })

  it "nor are its length or characters in the message for LOGIN7 strings that are too long" $ do
    let l7 = defaultLogin7 { l7Password = secret, l7AppName = T.replicate 40000 "a" }
    case login7Problem l7 of
      Nothing -> expectationFailure "no problem reported"
      Just msg -> do
        shouldNotLeak msg
        msg `shouldNotContain` ("password " ++ show (T.length secret))

  it "is not in the EncodeError connect throws for LOGIN7 strings that are too long" $
    withMockServer (\mc -> respondPrelogin (preloginReply 2) mc >> awaitLogin7 mc) $ \srv -> do
      r <- try (withConnection (mockConnectInfo srv) { connectPassword = secret, connectApplicationName = T.replicate 40000 "a" } (\_ -> pure ()))
      case r of
        Left (e :: EncodeError) -> mapM_ shouldNotLeak (renderings (toException e))
        Right () -> expectationFailure "connected"

  it "is not in the ProtocolError for a malformed login response (mock)" $
    withMockServer (\mc -> do
        _ <- respondPrelogin (preloginReply 2) mc
        _ <- expectLogin7 mc
        sendRaw mc "\x04\x01\x00\x0a\x00\x00\x01\x00\x99\x99") $ \srv -> do
      r <- timeout 10_000_000 $ try (withConnection (mockConnectInfo srv) { connectPassword = secret } (\_ -> pure ()))
      case r of
        Just (Left (e :: SomeException)) -> do
          e `shouldSatisfy` (\ex -> case fromException ex of Just (ProtocolError _) -> True; Nothing -> False)
          mapM_ shouldNotLeak (renderings e)
        other -> expectationFailure ("expected a ProtocolError, got " ++ show other)

  it "is not kept reachable by an open connection (mock)" $
    withMockServer (cannedLoginServer defaultLoginResponse) $ \srv -> do
      -- Built at run time, so it is not a static closure.
      now <- getCurrentTime
      password <- evaluate (T.pack ("password-" ++ show now))
      w <- weakChars password
      conn <- connect (mockConnectInfo srv) { connectPassword = password }
      gone <- gcUntil (isNothing <$> deRefWeak w)
      _ <- execute conn "SELECT 1"  -- the connection is still in use
      close conn
      gone `shouldBe` True

  describe "the access token" $ do
    let token = T.pack "eyJ-access-token-that-must-not-leak"
        shouldNotLeakToken s = do
          s `shouldNotContain` T.unpack token
          s `shouldNotContain` show (T.encodeUtf16LE token)

    it "is not in the Show of a Login7 (the FEDAUTH feature is redacted)" $
      shouldNotLeakToken (show defaultLogin7 { l7Features = [featureFedAuthToken True token Nothing] })

    it "is not in the ProtocolError for a malformed login response (mock)" $
      withMockServer (\mc -> do
          _ <- respondPrelogin (preloginReply 2) mc
          _ <- expectLogin7 mc
          sendRaw mc "\x04\x01\x00\x0a\x00\x00\x01\x00\x99\x99") $ \srv -> do
        r <- timeout 10_000_000 $ try (withConnection (mockConnectInfo srv)
          { connectUser = "", connectPassword = "", connectAccessToken = Just token } (\_ -> pure ()))
        case r of
          Just (Left (e :: SomeException)) -> mapM_ shouldNotLeakToken (renderings e)
          other -> expectationFailure ("expected an exception, got " ++ show other)

  it "is not in the LoginError for a rejected login (live)" $ do
    ci <- defaultTestConnectInfo
    r <- try (withConnection ci { connectPassword = secret } (\_ -> pure ()))
    case r of
      Left (e :: LoginError) -> do
        mapM_ shouldNotLeak (renderings (toException e))
        show e `shouldSatisfy` ("Login failed" `isInfixOf`)
      Right () -> expectationFailure "logged in with a wrong password"
