-- | Negotiating MARS (docs/dev/mars-research.md, A1-A3): the PRELOGIN option, SMP
-- starting after the login response (the session setup then runs on
-- session 0), in every encryption mode, with and without a session setup,
-- at every packet size, and a connection without MARS unaffected;
-- 'connectionMars' reports which a connection is.
module Mars.NegotiationSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (expectUsable)
import Hmssql
import Hmssql.Connection (connectionMars, reset)
import Hmssql.Connection.Internal (Connection (..))
import Mars.Harness
import TestDb

modes :: [Encryption]
modes = [EncryptStrict, EncryptOn, EncryptOff, EncryptNotSup]

-- | The plaintext variants are pending on a server that requires encryption.
plaintextIfAllowed :: Encryption -> SpecWith a -> SpecWith a
plaintextIfAllowed enc = if enc == EncryptNotSup then skipIfEncryptionRequired else id

-- | The rows of @sys.dm_exec_connections@ for this session, transport and
-- whether it is the physical connection: one per SMP session (the same
-- @session_id@ for all), then the physical connection's own, last.  Its
-- transport is whatever the suite's connections travel on
-- ('testNetTransport'): TCP, or on Windows a pipe.
connectionRows :: Connection -> IO [(Text, Bool)]
connectionRows conn = query conn
  "SELECT net_transport, CAST(CASE WHEN parent_connection_id IS NULL THEN 1 ELSE 0 END AS bit) \
  \FROM sys.dm_exec_connections WHERE session_id = @@SPID \
  \ORDER BY CASE WHEN parent_connection_id IS NULL THEN 1 ELSE 0 END, net_transport"

-- | @net_packet_size@ of the physical connection.
netPacketSize :: Connection -> IO Int
netPacketSize conn = fromOnly <$> query1 conn
  "SELECT CAST(net_packet_size AS int) FROM sys.dm_exec_connections WHERE session_id = @@SPID AND parent_connection_id IS NULL"

arithabort :: Connection -> IO Int
arithabort conn = fromOnly <$> query1 conn "SELECT CAST(SESSIONPROPERTY('ARITHABORT') AS int)"

spec :: Spec
spec = do
  describe "A1: the server accepts MARS" $ do
    it "a MARS connection works, with session 0 open and no response" $ withMarsConn $ \conn -> do
      query1 conn "SELECT 42" `shouldReturn` Only (42 :: Int)
      openSids conn `shouldReturn` [0]
      busySids conn `shouldReturn` []
      registrySids conn `shouldReturn` [0]

    it "the server shows the physical connection and one 'Session' row per SMP session" $ withMarsConn $ \conn -> do
      transport <- testNetTransport
      -- Session 0 only: the physical connection, and its session.
      connectionRows conn `shouldReturn` [("Session", False), (transport, True)]
      withNums conn 10 $ \s -> do
        (_, _) <- firstRow s
        -- The stream holds session 0; the query that asks is on session 1.
        connectionRows conn `shouldReturn` [("Session", False), ("Session", False), (transport, True)]
        openSids conn `shouldReturn` [0, 1]
      -- Sessions stay open, idle, after their responses end.
      openSids conn `shouldReturn` [0, 1]
      connectionRows conn `shouldReturn` [("Session", False), ("Session", False), (transport, True)]

    it "every session is one SQL session: the same @@SPID whichever SMP session asks" $ withMarsConn $ \conn -> do
      spid <- spidOf conn
      withNums conn 100 $ \s -> do
        _ <- firstRow s
        spidOf conn `shouldReturn` spid

  describe "a connection without MARS is unaffected" $ do
    it "has no MARS state, one connection row and one session" $ withPlainConn $ \conn -> do
      case connMars conn of
        Nothing -> pure ()
        Just _ -> expectationFailure "connMars is set on a connection without connectMars"
      transport <- testNetTransport
      connectionRows conn `shouldReturn` [(transport, True)]
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "a new request still abandons an open stream" $ withPlainConn $ \conn -> do
      s <- numStream conn 100_000
      _ <- firstRow s
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
      expectAbandonedS s
      expectUsable conn

    -- withQueryS's Haddock: without MARS it works too, with queryS's rule.
    it "withQueryS: read to its end, or left early (the rest cancelled), and the connection is usable" $ withPlainConn $ \conn -> do
      withNums conn 1000 S.length_ `shouldReturn` 1000
      withNums conn 100_000 (fmap fst . firstRow) `shouldReturn` 1
      query1 conn "SELECT 3" `shouldReturn` Only (3 :: Int)
      expectUsable conn

    it "withQueryS: a request made in the scope abandons its stream, and the scope's end leaves that request's response alone" $ withPlainConn $ \conn -> do
      inner <- withNums conn 100_000 $ \s -> do
        _ <- firstRow s
        query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
        expectAbandonedS s
        -- Left open: the scope's cancellation is for its own stream only.
        numStream conn 10
      S.toList_ inner `shouldReturn` [1 .. 10]
      expectUsable conn

  -- Both, whatever HMSSQL_TEST_MARS says: the harness asks for each.
  describe "connectionMars" $
    forM_ [(False, withPlainConn), (True, withMarsConn)] $ \(mars, withConn) ->
      it ("is " ++ show mars ++ " with connectMars = " ++ show mars ++ ": on the handle, a renewed one, and after release") $
        withConn $ \conn -> do
          connectionMars conn `shouldBe` mars
          conn' <- renew conn
          connectionMars conn' `shouldBe` mars
          release conn' `shouldReturn` True
          -- A released (or stale) handle still answers: it asks nothing of the server.
          connectionMars conn' `shouldBe` mars
          connectionMars conn `shouldBe` mars
          conn'' <- renew conn'
          connectionMars conn'' `shouldBe` mars
          query1 conn'' "SELECT 1" `shouldReturn` Only (1 :: Int)

  forM_ modes $ \enc -> plaintextIfAllowed enc $ describe ("under " ++ show enc) $ do
    forM_ [(False, []), (True, ["SET ARITHABORT ON"])] $ \(withSetup, setup) ->
      it (if withSetup then "a session setup runs on the MARS connection (on session 0), and holds on every session" else "a MARS connection without a session setup works, with the default options") $
        withMarsConnFor enc (\ci -> ci { connectSessionSetup = setup }) $ \conn -> do
          let expected = if withSetup then 1 else 0
          arithabort conn `shouldReturn` expected
          -- A second session sees the same connection state.
          withNums conn 1000 $ \s -> do
            (_, rest) <- firstRow s
            arithabort conn `shouldReturn` expected
            openSids conn `shouldReturn` [0, 1]
            S.length_ rest `shouldReturn` 999
          -- And it survives a reset, which runs the setup again.
          reset conn
          arithabort conn `shouldReturn` expected

    forM_ [512, 4096, 8000, 16368, 32767] $ \size ->
      it ("packet size " ++ show size ++ " asked for: requests and responses spanning many packets round-trip") $
        withMarsConnFor enc (\ci -> ci { connectPacketSize = size }) $ \conn -> withinTracedOn 60 conn $ \at -> do
          -- A parameter longer than several packets, and a result likewise.
          -- At 512-byte packets a million bytes is about 2,100 SMP packets
          -- and 525 waits for the server's window of 4, which once ran
          -- past the time limit beside a busy server; 200,000 bytes is
          -- still about 400 packets.
          let big = T.replicate (if size < 4096 then 10_000 else 50_000) "0123456789"
          at "a long parameter"
          query1 conn (mkQuery "SELECT @p1" (Only big)) `shouldReturn` Only big
          at "a long value"
          query1 conn (rawSql "SELECT REPLICATE(CAST('y' AS varchar(max)), 300000)")
            `shouldReturn` Only (T.replicate 300_000 "y")
          at "a stream"
          (numStream conn 20_000 >>= S.length_) `shouldReturn` 20_000
          -- Next to an open stream.
          at "a long parameter beside a stream"
          withNums conn 20_000 $ \s -> do
            (_, rest) <- firstRow s
            query1 conn (mkQuery "SELECT @p1" (Only big)) `shouldReturn` Only big
            at "the rest of the stream"
            S.length_ rest `shouldReturn` 19_999

    -- The packet size the server settles on, as it reports it.  Encrypted, a
    -- MARS connection asks for at most 16368 (a bigger packet and its SMP
    -- header overflow a TLS record, and the server can't answer); so asking
    -- for more gives the same connection.
    if enc `elem` [EncryptStrict, EncryptOn]
      then it "the packet size asked for is capped at 16368: asking for 32767 gives the same connection as 16368" $ do
        atCap <- withMarsConnFor enc (\ci -> ci { connectPacketSize = 16368 }) netPacketSize
        above <- withMarsConnFor enc (\ci -> ci { connectPacketSize = 32767 }) netPacketSize
        above `shouldBe` atCap
        small <- withMarsConnFor enc (\ci -> ci { connectPacketSize = 4096 }) netPacketSize
        small `shouldSatisfy` (< atCap)
      else it "asking for a larger packet size gives a larger connection, up to what the server grants" $ do
        small <- withMarsConnFor enc (\ci -> ci { connectPacketSize = 512 }) netPacketSize
        large <- withMarsConnFor enc (\ci -> ci { connectPacketSize = 16368 }) netPacketSize
        small `shouldSatisfy` (< large)
