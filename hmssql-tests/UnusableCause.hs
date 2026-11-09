-- | The exception inside an 'UnusableReason', for the tests of what broke a
-- connection: most care which exception it was, not which reason recorded it.
-- "Connection.UnusableReasonSpec" tests the reasons themselves.
module UnusableCause (reasonCause, brokenCause) where

import Control.Exception (SomeException, toException)
import Data.IORef (readIORef)

import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors

reasonCause :: UnusableReason -> SomeException
reasonCause = \case
  Closed r -> toException (ConnectionClosedBy r)
  ServerProtocolViolation m -> toException (ProtocolError m)
  FatalServerError msg -> toException (SqlServerError msg Nothing)
  ServerFailedConnection d -> toException (SevereError d Nothing)
  SendFailed e -> e
  ReadFailed e -> e
  DrainFailed e -> e
  ResetRefused (Just msg) -> toException (SqlServerError msg Nothing)
  ResetRefused Nothing -> toException (userError "the reset was refused by a failed DONE")
  ResetFailed e -> e
  RollbackFailed e -> e
  ReaderThreadDied e -> e

-- | The cause the connection recorded, if it is broken.
brokenCause :: Connection -> IO (Maybe SomeException)
brokenCause conn = fmap reasonCause <$> readIORef (connBroken conn)
