-- | The server killing the session mid-way through a large streamed result,
-- specifically under 'EncryptOn' (TDS 7.4 with TLS negotiated inside
-- PRELOGIN, the whole session then running over that TLS context).
--
-- "Shapes.ErrorsSpec" already has \"surfaces a clean error (not a hang) when
-- another connection KILLs the session\" and a severity-20 test, but both
-- run under 'EncryptStrict' with quick, single-value queries -- the KILL
-- always lands between requests or right at the start of one. Here the
-- victim is killed while tens of megabytes of a streamed result are still
-- in flight, so the TLS record the reader is mid-way through decrypting (and
-- the TDS packet framing inside it) is cut off along with the socket. A
-- correct client raises a clean exception promptly; a client whose TLS
-- record buffering doesn't correctly track TDS packet boundaries could
-- instead hang, or decode garbage from a truncated/incomplete buffer.
module Scale.TlsKillMidResultSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, try)
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import TestDb

-- | A hundred million rows of a 200-character nvarchar each (40 GB on the
-- wire): a result the client can't finish reading before the KILL.  With
-- 300,000 rows (120 MB) a client beside two other runs of the suite had
-- read them all by the time the server acted on the KILL.
rows :: Int
rows = 100_000_000

bigStreamQuery :: Text
bigStreamQuery =
  "SELECT TOP " <> T.pack (show rows) <> " REPLICATE(CONVERT(nvarchar(max), N'x'), 200) \
  \FROM sys.all_columns a CROSS JOIN sys.all_columns b CROSS JOIN sys.all_columns c"

spec :: Spec
spec = describe "KILL mid-result over TDS-hosted TLS (EncryptOn)" $
  it "surfaces a clean error (not a hang, not garbled data) when another connection KILLs the session mid-stream" $
    -- The killer connects first: connecting while the stream runs gave a
    -- fast client time to read the whole result before the KILL.
    withTestDb $ \killer -> withTestConnection EncryptOn $ \conn -> do
      victimId <- sessionIdentity conn
      progress <- newIORef (0 :: Int)
      done <- newEmptyMVar
      _ <- forkIO $ do
        r <- try $ do
          s <- queryS conn (rawSql bigStreamQuery)
          S.mapM_
            (\(Only (t :: Text)) -> do
                T.length t `shouldBe` 200
                modifyIORef' progress (+ 1))
            s
        putMVar done (r :: Either SomeException ())

      -- wait until we're well into the stream (not just past the first
      -- packet or two) before killing it
      let waitForRows = do
            n <- readIORef progress
            if n > 1000 then pure () else threadDelay 1000 >> waitForRows
      waited <- timeout 20000000 waitForRows
      case waited of
        Nothing -> expectationFailure "never got far enough into the stream to test a mid-stream KILL"
        Just () -> pure ()

      killResult <- timeout 10000000
        (try (killSessionFrom killer victimId) :: IO (Either SomeException ()))
      case killResult of
        Just _ -> pure ()
        Nothing -> expectationFailure "KILL timed out"

      victim <- timeout 20000000 (takeMVar done)
      case victim of
        Nothing -> expectationFailure "victim stream hung instead of erroring after being killed mid-stream"
        Just (Right ()) -> expectationFailure "victim stream completed instead of being killed"
        Just (Left _) -> pure ()

      n <- readIORef progress
      n `shouldSatisfy` (< rows)

      -- the connection is unusable afterwards, but that must be a clean
      -- error, not a hang
      after <- timeout 10000000 (try (execute conn "SELECT 1") :: IO (Either SomeException Int64))
      case after of
        Nothing -> expectationFailure "connection hung on reuse after being killed mid-stream"
        Just (Right n') -> expectationFailure ("succeeded with " ++ show n')
        Just (Left _) -> pure ()
