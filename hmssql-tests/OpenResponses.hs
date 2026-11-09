-- | What is open on a connection, for tests that look inside it, in both
-- modes: without MARS a connection has one session, which has at most one
-- response; under MARS ('testMars') each SMP session may have one, and
-- 'connPrimary' is only the first of them.  "A response is pending on the
-- connection" means on any of its sessions.
module OpenResponses
  ( isMarsConnection
  , connectionBroken
  , responsePending
  , openResponses
  , theOpenResponse
  , openStatements
  , whenMars
  , unlessMars
  ) where

import Control.Monad (unless, when)
import Data.IORef (readIORef)
import Data.Maybe (catMaybes, isJust)
import Data.Text (Text)

import Hmssql.Connection.Internal (ActiveResponse, Connection (..), Session (..), allSessions, busyStatements, withConnectionLock)
import TestConfig (testMars)

-- | Whether the connection runs over SMP sessions (MARS).
isMarsConnection :: Connection -> Bool
isMarsConnection = isJust . connMars

-- | Whether the connection is marked broken ('Hmssql.Errors.ConnectionBroken').
connectionBroken :: Connection -> IO Bool
connectionBroken conn = isJust <$> readIORef (connBroken conn)

-- | Whether any session of the connection has a response that has not
-- been read to its end or drained.
responsePending :: Connection -> IO Bool
responsePending conn = not . null <$> openResponses conn

-- | The responses on the connection's sessions, in the order of the
-- sessions.
openResponses :: Connection -> IO [ActiveResponse]
openResponses conn = allSessions conn >>= fmap catMaybes . mapM (readIORef . sessResponse)

-- | The one response open on the connection; fails if there is none, or
-- more than one.
theOpenResponse :: Connection -> IO ActiveResponse
theOpenResponse conn = openResponses conn >>= \case
  [ar] -> pure ar
  ars -> fail ("expected one open response, found " ++ show (length ars))

-- | The SQL text of each response open on the connection (the library's
-- 'busyStatements', with the lock taken).
openStatements :: Connection -> IO [Text]
openStatements conn = withConnectionLock conn (busyStatements conn)

-- | Run only on a MARS test connection ('testMars').
whenMars :: IO () -> IO ()
whenMars act = testMars >>= \m -> when m act

-- | Run only without MARS.
unlessMars :: IO () -> IO ()
unlessMars act = testMars >>= \m -> unless m act
