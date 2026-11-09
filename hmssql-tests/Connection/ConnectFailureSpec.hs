-- | 'connect' failing before there is a connection at all (the host name
-- doesn't resolve, or the TCP connect is refused) is a transport failure
-- like any other: @'ConnectionClosedBy' ('TransportFailed' e)@ with the
-- underlying 'IOException', not a bare 'IOException' from
-- "Network.Socket". An external 'timeout' still cancels a connect that
-- hangs, and is not turned into anything else.
--
-- A host with several addresses gives every address but the last
-- 'addressConnectTimeout' (4 s) to answer, so a silent first address (a
-- dropped SYN) doesn't cost the operating system's whole connect timeout
-- before the second is tried; the last address, and so a host with one
-- address, keeps the system's timeout.  A name that resolves to a silent
-- address and then a listening one can't be made without root, so these
-- tests give 'connectAddresses' the list themselves.
module Connection.ConnectFailureSpec (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar
import Control.Exception (SomeException, bracket, finally, fromException, handle, mask, try)
import Data.List (isInfixOf, isPrefixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Foreign.C.Error (Errno (..), eCONNREFUSED)
import GHC.Clock (getMonotonicTime)
import GHC.IO.Exception (IOException (..))
import qualified Network.Socket as Socket
import System.Timeout (timeout)
import Test.Hspec

import Compat (blockingCallStopsProcess, onWindows, windowsNetworkTcp)
import Hmssql

import Hmssql.Connection.Backend (addressConnectTimeout, closeSocket, connectAddresses)
import Hmssql.Errors
import MockServer (withRefusingPort)
-- | The 'IOException' inside @ConnectionClosedBy (TransportFailed _)@.
transportIOException :: Either SomeException () -> Either String IOException
transportIOException = \case
  Left e
    | Just (ConnectionClosedBy (TransportFailed cause)) <- fromException e
    , Just ioe <- fromException cause -> Right ioe
  other -> Left ("expected ConnectionClosedBy (TransportFailed IOException), got " ++ either show show other)

-- | Nothing here needs a server: every attempt fails before the login.
ci0 :: ConnectInfo
ci0 = defaultConnectInfo { connectUser = "sa", connectPassword = "unused" }

attempt :: ConnectInfo -> IO (Maybe (Either SomeException ()))
attempt ci = timeout 10_000_000 (try (withConnection ci (\_ -> pure ())))

spec :: Spec
spec = describe "connect failing before there is a connection" $ do
  it "a refused TCP connect: TransportFailed with the IOException (ECONNREFUSED)" $ withRefusingPort $ \port -> do
    r <- attempt ci0 { connectHost = "127.0.0.1", connectPort = port }
    case r of
      Nothing -> expectationFailure "connect to a closed port did not fail within 10s"
      Just o -> do
        let ioe = transportIOException o
        -- Which failure it was.  On Windows network's exception has no
        -- errno, and names the Winsock error in its description.
        if onWindows
          then fmap (("WSAECONNREFUSED" `isInfixOf`) . ioe_description) ioe `shouldBe` Right True
          else fmap ioe_errno ioe `shouldBe` Right (Just (let Errno c = eCONNREFUSED in c))
        fmap (("Network.Socket.connect" `isPrefixOf`) . ioe_location) ioe `shouldBe` Right True

  it "a refused TCP connect on every address a name resolves to: TransportFailed" $ withRefusingPort $ \port -> do
    -- "localhost" often resolves to both ::1 and 127.0.0.1; each is tried,
    -- and the last failure is reported, typed the same way.  (The port
    -- is held on 127.0.0.1; on ::1 nothing of the suite listens.)
    r <- attempt ci0 { connectHost = "localhost", connectPort = port }
    case r of
      Nothing -> expectationFailure "connect to a closed port did not fail within 10s"
      Just o -> fmap (const ()) (transportIOException o) `shouldBe` Right ()

  it "a host name that doesn't resolve: TransportFailed" $ do
    -- .invalid is reserved (RFC 2606): it never resolves.
    r <- attempt ci0 { connectHost = "no-such-host.invalid" }
    case r of
      Nothing -> expectationFailure "resolving a .invalid name did not fail within 10s"
      Just o -> fmap (const ()) (transportIOException o) `shouldBe` Right ()

  it "an external timeout still cancels a connect that hangs, as Nothing (not wrapped)" $ interruptibleConnect $ do
    -- A black-holed address: the TCP connect neither succeeds nor fails
    -- for a long time. No 'try' inside: 'timeout' must see its own exception.
    r <- timeout 300_000 (withConnection ci0 { connectHost = "10.255.255.1" } (\_ -> pure ()))
    r `shouldBe` Nothing

  describe "a host with several addresses" $ do
    it "gives up a silent first address after addressConnectTimeout and connects to the second" $
     if blockingCallStopsProcess
      then pendingWith "without -threaded the connect to the silent address stops every thread for Windows' 21 s, and the tests beside it with them (Compat.blockingCallStopsProcess)"
      else
      withListener $ \listener accepted -> do
        silent <- blackholed
        start <- getMonotonicTime
        r <- timeout 30_000_000 (mask $ \restore -> connectAddresses restore (silent :| [listener]))
        elapsed <- subtract start <$> getMonotonicTime
        case r of
          Nothing -> expectationFailure "the connect was not through within 30 s: the second address was never tried"
          Just sock -> do
            closeSocket sock
            -- The limit plus a margin; a regression waits the system's
            -- connect timeout, two minutes on Linux.  Where the address is
            -- unreachable rather than silent (no route), the first attempt
            -- fails at once and this is only faster.
            --
            -- On Windows with TCP through network's calls, the consequence of
            -- network's blocking connect: the limit's timeout lands only once
            -- the operating system gives the first address up, after about
            -- 21 s (measured), and only then is the second tried.  So only
            -- the outer limit is checked there: an unreachable address fails
            -- at once, and a silent one takes the 21 s.
            if windowsNetworkTcp
              then elapsed `shouldSatisfy` (< 30)
              else elapsed `shouldSatisfy` (< 8)
            -- The listener, not something else, took the connection.
            timeout 5_000_000 (takeMVar accepted) `shouldReturn` Just ()

    it "a caller's timeout shorter than the limit still wins, as Nothing" $ interruptibleConnect $
      withListener $ \listener accepted -> do
        silent <- blackholed
        r <- timeout 300_000 (mask $ \restore -> connectAddresses restore (silent :| [listener]))
        -- The listener never saw a connection: the second address was
        -- not reached.
        r `shouldSatisfy` (\case Nothing -> True; Just _ -> False)
        mapM_ closeSocket r
        timeout 500_000 (takeMVar accepted) `shouldReturn` Nothing

    it "a host with one silent address keeps the operating system's connect timeout" $ interruptibleConnect $ do
      -- Still running after 5 s, past the per-address limit: the test's
      -- own timeout ends it.
      silent <- blackholed
      r <- timeout 5_000_000 (mask $ \restore -> connectAddresses restore (silent :| []))
      r `shouldSatisfy` (\case Nothing -> True; Just _ -> False)
      mapM_ closeSocket r
  where
    numeric = Socket.defaultHints { Socket.addrSocketType = Socket.Stream, Socket.addrFlags = [Socket.AI_NUMERICHOST] }

    -- A test of a timeout that ends a connect to a silent address.  On
    -- Windows with TCP through network's calls the connect is a blocking
    -- foreign call that the timeout can't end: it would return Nothing only
    -- once the operating system gave up, after about 21 s.  "gives up a
    -- silent first address" states that consequence.
    interruptibleConnect :: Expectation -> Expectation
    interruptibleConnect test
      | windowsNetworkTcp = pendingWith "on Windows with TCP through network's calls a timeout can't end a connect (network's connect is a blocking call); \"gives up a silent first address\" states the consequence"
      | otherwise = test

    -- A black-holed address: the TCP connect neither succeeds nor fails
    -- for a long time.  Any port.
    blackholed = do
      addr : _ <- Socket.getAddrInfo (Just numeric) (Just "10.255.255.1") (Just "1433")
      pure addr

    -- A listening socket on 127.0.0.1, as an address to connect to, and a
    -- signal that it accepted a connection.  The acceptor is stopped as
    -- the mock servers are, by closing the listener before killing it:
    -- on Windows nothing interrupts a thread inside accept.
    withListener act = do
      addr : _ <- Socket.getAddrInfo (Just numeric) (Just "127.0.0.1") (Just "0")
      bracket (Socket.openSocket addr) Socket.close $ \lsock -> do
        Socket.bind lsock (Socket.addrAddress addr)
        Socket.listen lsock 1
        port <- Socket.socketPort lsock
        listener : _ <- Socket.getAddrInfo (Just numeric) (Just "127.0.0.1") (Just (show port))
        accepted <- newEmptyMVar
        tid <- forkIO $ handle (\(_ :: SomeException) -> pure ()) $
          bracket (Socket.accept lsock) (Socket.close . fst) (\_ -> putMVar accepted ())
        act listener accepted `finally` (Socket.close lsock >> killThread tid)
