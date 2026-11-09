-- | What a closed 'Connection' that is still referenced (by a pool entry, a
-- stream, a thread that hasn't finished) keeps alive.  A closed TLS
-- connection used to keep its TLS context, and through it the certificate
-- store it validated the server against: about 3.3 MB each.  Every closed
-- connection also kept its finished reader thread's stack (32 KiB), through
-- the thread's 'ThreadId', and a plaintext one the 32 KiB buffer its login
-- response was received into.  Now it keeps about 6 KB with TLS and 3 KB
-- without (GHC 9.12.4 on Linux).
module Resources.ClosedConnectionSpec (spec) where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.Word (Word64)
import Test.Hspec

import Hmssql
import Resources.Helpers (keptAliveByEach)
import TestDb

-- | Closed connections kept.
count :: Int
count = 50

-- | The most a closed connection may keep alive: less than a reader
-- thread's stack.
bound :: Word64
bound = 16 * 1024

-- | How many connections are opened at once.  Opening all 'count' at once
-- (while other test runs connect too) can overflow the server's accept
-- queue, and now and then Docker's port forwarding then gives up on one and
-- closes it, which fails the connect with 'ClosedByServer'; see
-- "Scale.TlsConcurrencySpec".
connectingAtOnce :: Int
connectingAtOnce = 8

spec :: Spec
spec = describe "a closed connection that is still referenced" $
  forM_ [EncryptStrict, EncryptOn, EncryptNotSup] $ \enc ->
    (if enc == EncryptNotSup then skipIfEncryptionRequired else id) $
    it ("keeps little alive (" ++ show enc ++ ")") $ do
      ci <- testConnectInfo enc
      sem <- newQSem connectingAtOnce
      -- Closed again after the first reading, which is what keeps them
      -- referenced during it (close is idempotent).
      per <- keptAliveByEach close $
        forConcurrently [1 .. count] $ \_ -> bracket_ (waitQSem sem) (signalQSem sem) $ do
          conn <- connect ci
          _ <- query1 conn "SELECT 1" :: IO (Only Int)
          close conn
          pure conn
      -- One more connection, so that what connecting loads once in a
      -- process (the system certificate store, above all) is still referred
      -- to by code to come at both readings, and alive at both.
      withConnection ci $ \conn -> query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
      per `shouldSatisfy` (< bound)
