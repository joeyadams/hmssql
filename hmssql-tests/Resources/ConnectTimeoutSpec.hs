-- | 'connect' interrupted by a 'timeout' at any point of its run must
-- close the socket it opened then and there, not leave it for the garbage
-- collector (network's finalizer) to close some time later.
--
-- The one gap this guards against, an async exception arriving just after
-- the TCP connect returned the socket and before the cleanup for the rest
-- of 'connect' was installed, is a few instructions wide and has no hook to
-- stop a test inside it, so there is no deterministic test: this one sweeps
-- the timeout's delay across the whole of a connect to a mock server,
-- thousands of times.  After each attempt, the mock must see the client
-- close its connection within a moment.  A leaked socket would stay open
-- until the next garbage collection, which (with the suite's @-A64m@
-- nursery) is hundreds of connects away.  The same sweep runs over a
-- login redirected twice, through three mocks, where the timeout can also
-- land between the connections.  Serial (in "Resources."): the check
-- is a wall-clock bound, and the file descriptor count is checked too.
module Resources.ConnectTimeoutSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (forM_, replicateM, unless)
import Data.IORef
import Data.List (sort)
import Data.Maybe (isJust)
import GHC.Clock (getMonotonicTime)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Tds.Context (TdsVersion (..))
import Mars.MockSmp (preloginWithMars)
import MockServer
import Resources.Helpers (backendHandles, backendHandlesReturnTo, fdCount, fdSlack, settle)

-- | Connects to run.
attempts :: Int
attempts = 5000

spec :: Spec
spec = describe "connect interrupted by a timeout" $ do
  it "closes its socket at once wherever the timeout lands" $ do
    open <- newIORef (0 :: Int)
    withMockServer (counted open defaultLoginResponse) $ \srv ->
      sweep open (mockConnectInfo srv)

  it "closes every socket at once wherever the timeout lands in a login redirected twice" $ do
    open <- newIORef (0 :: Int)
    let redirect srv =
          [ loginAckToken Tds74 "Microsoft SQL Server"
          , routingEnvChange "127.0.0.1" (read (mockPort srv))
          , doneToken 0 0
          ]
    withTcpMockServer (counted open defaultLoginResponse) $ \target ->
      withTcpMockServer (counted open (redirect target)) $ \middle ->
        withMockServer (counted open (redirect middle)) $ \gateway ->
          sweep open (mockConnectInfo gateway)

  -- R9: a MARS connect sends the SYN for session 0 after the login, and
  -- starts the reader thread after that: the timeout can also land in the
  -- SYN's send, between it and the reader, or in the reader's start.
  it "closes its socket at once wherever the timeout lands in a MARS connect (its SYN included)" $ do
    open <- newIORef (0 :: Int)
    withMockServer (counted' open marsLogin) $ \srv ->
      sweep open (mockConnectInfo srv) { connectMars = True }
  where
    -- PRELOGIN granting MARS, LOGIN7 and the login response; then
    -- whatever the client sends (its SYN), until it closes.
    marsLogin mc = do
      _ <- respondPrelogin (preloginWithMars (Just 1)) mc
      awaitLogin7 mc >>= \case
        ClientSentLogin7 _ -> do
          sendTokens mc defaultLoginResponse
          let drain = recvBytes mc 1 >>= maybe (pure ()) (const drain)
          drain
        _ -> pure ()
    -- A mock that counts its open connections: a canned login server, or
    -- the handler given.
    counted open response = counted' open (cannedLoginServer response)
    counted' open handler mc = bracket_ (atomicModifyIORef' open (\k -> (k + 1, ())))
      (atomicModifyIORef' open (\k -> (k - 1, ())))
      (handler mc)

-- | Connect with timeouts swept across a whole connect, checking after each
-- that the mocks (whose open connections the counter counts) see every
-- connection closed within 200 ms.
sweep :: IORef Int -> ConnectInfo -> Expectation
sweep open ci = do
  -- The last clean failure of a connect, for the report when the sweep
  -- turns out not to have covered connect.
  lastFailure <- newIORef "none"
  let -- Wait up to 200 ms for the mock to have no open connection.
      idle n = readIORef open >>= \case
        0 -> pure True
        _ | n <= (0 :: Int) -> pure False
          | otherwise -> threadDelay 1_000 >> idle (n - 1)
      -- The caller's side stays masked except inside connect itself,
      -- so a connection that connect did return is always closed
      -- here: only connect's own cleanup is under test.
      --
      -- A connect can also fail cleanly with ConnectionClosed: on macOS
      -- a TCP connect started right after an interrupted one on the
      -- same descriptor number now and then returns as connected while
      -- it isn't (the first send fails with ENOTCONN), apparently a
      -- stale kqueue wake-up in GHC's IO manager.  That is a failed
      -- connect like any other here: its socket must be closed too.
      -- Anything else from connect or close is reported with where it
      -- came from.
      tryConnect delay = mask $ \restore -> do
        r <- try (timeout delay (restore (connect ci))) >>= \case
          Right v -> pure v
          Left (e :: SomeException)
            | Just (ConnectionClosedBy (TransportFailed cause)) <- fromException e ->
                Nothing <$ writeIORef lastFailure (show cause)
            | otherwise -> throwIO (userError ("connect (timeout " ++ show delay ++ " us) threw " ++ show e))
        forM_ r $ \c -> close c `catch` \(e :: SomeException) ->
          throwIO (userError ("close threw " ++ show e))
        pure (isJust r)
  -- How long a whole connect takes here, to sweep the delay across it.
  times <- replicateM 20 $ do
    -- The monotonic clock: the wall clock advances in ticks of up to
    -- 16 ms on Windows, and under GHC's native I/O manager every connect
    -- here measured 0 s by it.
    t0 <- getMonotonicTime
    _ <- tryConnect 10_000_000
    t1 <- getMonotonicTime
    pure (t1 - t0)
  let median = sort times !! 10
      span_ = max 200 (ceiling (median * 1.5e6)) :: Int
  settle
  before <- fdCount
  handlesBefore <- backendHandles
  -- Stops at the first leak (each costs the 200 ms wait).
  let go i interrupted
        | i >= attempts = pure (Nothing, interrupted)
        | otherwise = do
            let delay = (i * 7919) `mod` span_
            connected <- tryConnect delay
            idle 200 >>= \case
              False -> pure (Just (i, delay, connected), interrupted)
              True -> go (i + 1) (if connected then interrupted else interrupted + 1)
  (leak, interrupted) <- go 0 (0 :: Int)
  after <- fdCount
  case leak of
    Just (i, delay, connected) -> expectationFailure $
      "attempt " ++ show i ++ " (timeout " ++ show delay ++ " us, "
        ++ (if connected then "connected" else "interrupted")
        ++ "): the client's socket was still open 200 ms later"
    Nothing -> pure ()
  -- The sweep did cover connect: some attempts finished, some didn't.
  failure <- readIORef lastFailure
  unless (interrupted > 0 && interrupted < attempts) $ expectationFailure $
    "the sweep did not cover connect: " ++ show interrupted ++ " of " ++ show attempts
      ++ " attempts were interrupted, with timeouts up to " ++ show span_
      ++ " us (a whole connect took " ++ show median ++ " s; the last connect to fail by itself: " ++ failure ++ ")"
  -- On Windows, exactly: every handle a connect opened was closed.
  backendHandlesReturnTo handlesBefore
  case (before, after) of
    (Just f0, Just f1) -> (f1 - f0) `shouldSatisfy` (<= 2 + fdSlack)
    _ -> pendingWith "/dev/fd is not listable here"
