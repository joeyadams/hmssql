-- | Connection-option edge cases that aren't about the LOGIN7 wire encoding
-- itself (that's "Protocol.LoginSpec"): packet-size boundaries, session
-- setup, language, read-only intent, and the info-message callback.
module Connection.OptionsSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Connection (TdsContext (..), connectionContext)
import TestConfig

-- | Session-property columns the login (fODBC) and a @SET ARITHABORT ON@
-- session setup are expected to affect, read back from the session's own
-- row.
sessionPropsQuery :: Text
sessionPropsQuery =
  "SELECT quoted_identifier, arithabort, ansi_null_dflt_on, ansi_warnings, ansi_padding, ansi_nulls, concat_null_yields_null \
  \FROM sys.dm_exec_sessions WHERE session_id = @@SPID"

type SessionProps = (Bool, Bool, Bool, Bool, Bool, Bool, Bool)

spec :: Spec
spec = describe "connection options" $ do
  describe "connectPacketSize" $ do
    let connectsAt :: Word32 -> IO Word32
        connectsAt sz = do
          ci <- defaultTestConnectInfo
          withConnection ci { connectPacketSize = sz } $ \conn -> do
            _ <- query1 conn "SELECT 1" :: IO (Only Int)
            tdsPacketSize <$> connectionContext conn

    mapM_
      (\sz -> it ("connects with a " ++ show sz ++ "-byte packet size") $
        connectsAt sz `shouldReturn` sz)
      [512, 4096, 8000]

    -- The server may negotiate down from what's asked (its own configured
    -- "network packet size" caps this); either way the connection is usable
    -- and the client's context reflects whatever the server chose, via the
    -- ENVCHANGE the server always sends.
    mapM_
      (\sz -> it ("connects with a " ++ show sz ++ "-byte requested packet size (server may adjust it)") $ do
        got <- connectsAt sz
        got `shouldSatisfy` (\g -> g >= 512 && g <= sz))
      [16384, 32767]

    it "a below-minimum packet size (below the 512 [MS-TDS] minimum) is bumped up by the server, not rejected" $
      connectsAt 256 `shouldReturn` 512

    -- hmssql clamps the request to 512 .. 32767 itself, so a size the
    -- header can't even frame doesn't reach the wire.
    mapM_
      (\sz -> it ("a " ++ show sz ++ "-byte packet size (at or below the 8-byte header) is bumped up to 512") $ do
        r <- timeout 15_000_000 (try (connectsAt sz) :: IO (Either SomeException Word32))
        case r of
          Nothing -> expectationFailure "connect hung"
          Just (Left e) -> expectationFailure ("connect failed: " ++ show e)
          Just (Right got) -> got `shouldBe` 512)
      [0, 1, 8]

    it "a packet size above the 32767 maximum is capped, and a request over 64 KiB is framed correctly" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectPacketSize = 0xFFFFFFFF } $ \conn -> do
        got <- tdsPacketSize <$> connectionContext conn
        got `shouldSatisfy` (\g -> g >= 512 && g <= 32767)
        let sql = "SELECT LEN(N'" <> T.replicate 40000 "x" <> "')"
        query1 conn (rawSql sql) `shouldReturn` Only (40000 :: Int)

  describe "read-only intent" $
    it "connects without error" $ do
      -- There's no DMV on a standalone (non-Availability-Group) instance
      -- that surfaces whether a session asked for read-only routing, so
      -- this only confirms the option doesn't break the connection; see
      -- docs/dev/limitations.md.
      ci <- defaultTestConnectInfo
      withConnection ci { connectReadOnlyIntent = True } $ \conn ->
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "session setup" $ do
    it "a SET ARITHABORT ON session setup is in effect, alongside the login's ANSI options" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectSessionSetup = ["SET ARITHABORT ON"] } $ \conn ->
        query1 conn (rawSql sessionPropsQuery) `shouldReturn` (True, True, True, True, True, True, True :: Bool)

    it "an empty session setup skips it (leaving ARITHABORT off)" $ do
      ci <- defaultTestConnectInfo
      withConnection ci { connectSessionSetup = [] } $ \conn -> do
        (_, arithabort, _, _, _, _, _) <- query1 conn (rawSql sessionPropsQuery) :: IO SessionProps
        arithabort `shouldBe` False

    it "a failing statement in a custom session setup fails the connect cleanly, as a SqlServerError" $ do
      ci <- defaultTestConnectInfo
      r <- try (withConnection ci { connectSessionSetup = ["SELECT 1/0"] } (\_ -> pure ())) :: IO (Either SomeException ())
      case r of
        Left e -> case fromException e :: Maybe SqlServerError of
          Just se -> sqlErrorNumber se `shouldBe` 8134 -- divide by zero
          Nothing -> expectationFailure ("wrong exception type: " ++ show e)
        Right () -> expectationFailure "connected despite the failing setup statement"
      -- the failure didn't wedge anything global; a normal connect still works
      withConnection ci $ \conn -> query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "language" $
    mapM_
      (\(lang, month1Name) ->
        it ("SET LANGUAGE " ++ show lang ++ " affects DATENAME and error message language") $ do
          ci <- defaultTestConnectInfo
          withConnection ci { connectLanguage = lang } $ \conn -> do
            query1 conn "SELECT @@LANGUAGE" `shouldReturn` Only lang
            query1 conn "SELECT DATENAME(month, '2024-01-01')" `shouldReturn` Only month1Name)
      ([ ("us_english", "January")
       , ("Deutsch", "Januar")
       , ("Français", "janvier")
       ] :: [(Text, Text)])

  describe "info-message callback" $ do
    it "a callback that throws during login fails the connect cleanly with that exception" $ do
      ci <- defaultTestConnectInfo
      r <- try (withConnection ci { connectOnInfoMessage = \_ -> ioError (userError "callback boom") } (\_ -> pure ()))
        :: IO (Either IOError ())
      case r of
        Left e -> show e `shouldContain` "callback boom"
        Right () -> expectationFailure "connected despite the throwing callback"

    it "a callback that throws during a later request fails that request, and the connection stays usable" $ do
      -- The INFO token is consumed before the callback runs, so the byte
      -- stream is intact; the rest of the response is drained by the next
      -- request (1c77379).
      ci <- defaultTestConnectInfo
      active <- newIORef False
      withConnection ci
        { connectOnInfoMessage = \_ -> readIORef active >>= \a -> if a then ioError (userError "callback boom") else pure () }
        $ \conn -> do
          writeIORef active True
          r1 <- try (execute conn "PRINT 'hi'; SELECT 1") :: IO (Either IOError Int64)
          case r1 of
            Left e -> show e `shouldContain` "callback boom"
            Right n -> expectationFailure ("succeeded with " ++ show n)
          -- In step: each request gets its own result.
          query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
          query1 conn ("SELECT " <> param (4242 :: Int)) `shouldReturn` Only (4242 :: Int)
          writeIORef active False
          execute conn "PRINT 'again'; SELECT 2" `shouldReturn` 1
