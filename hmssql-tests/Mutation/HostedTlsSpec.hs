-- | Tests found by mutation testing of "Hmssql.Connection.Tls": how the
-- TDS-hosted TLS transport (ENCRYPT_ON) reports the server going away.
module Mutation.HostedTlsSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Data.Int (Int32)
import System.IO.Error (isResourceVanishedError)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import TestConfig

-- | How the connection ended: in an orderly way, by the other end
-- aborting it (a TCP reset, or a pipe disconnected), or otherwise.
data Ending = Orderly | Aborted String | Other String
  deriving (Eq, Show)

endingOf :: SomeException -> Ending
endingOf e = case fromException e of
  Just (ConnectionClosedBy ClosedByServer) -> Orderly
  Just (ConnectionClosedBy (TransportFailed cause))
    | Just io <- fromException cause, isResourceVanishedError io -> Aborted (show (io :: IOException))
  Just (ConnectionClosedBy r) -> Other ("ConnectionClosedBy (" ++ show r ++ ")")
  Nothing -> Other (show e)

spec :: Spec
spec = describe "ENCRYPT_ON (TLS in PRELOGIN packets) when the server kills the session" $
  it "the next request reports the end of the stream as ClosedByServer (or as the connection aborted, by Azure's gateway or by SQL Server on Windows)" $
    withTestConnection EncryptOn $ \conn -> do
      victim <- sessionIdentity conn
      withTestConnection EncryptStrict $ \killer -> killSessionFrom killer victim
      threadDelay 500_000
      r <- timeout 10_000_000 (try (query1 conn "SELECT 1" :: IO (Only Int32)))
      -- SQL Server on Linux closes the socket (a TCP EOF, which TLS reports
      -- as the end of the stream).  Azure SQL Database's gateway resets it,
      -- and so does SQL Server on Windows, which over Shared Memory or
      -- Named Pipes disconnects the pipe: what was unread is lost, and the
      -- client's read fails.
      abortive <- (||) <$> testServerIsAzure <*> testServerOnWindows
      case r of
        Nothing -> expectationFailure "hung"
        Just (Right v) -> expectationFailure ("succeeded: " ++ show v)
        Just (Left e) -> case endingOf e of
          Orderly -> pure ()
          Aborted _ | abortive -> pure ()
          other -> expectationFailure ("expected ClosedByServer" ++ (if abortive then " or an aborted connection" else "") ++ ", got " ++ show other)
