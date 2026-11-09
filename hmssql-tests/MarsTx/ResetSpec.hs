-- | 'reset' and 'release' on a MARS connection (docs/dev/mars-research.md "Reset",
-- A35, A38, A39).  A reset resets the whole SQL session, whichever
-- session the state was made on, and the sessions stay open.  Streams
-- open when it goes out are settled first (they end with
-- 'ResultAbandoned'), since the server refuses a reset beside an
-- unfinished request, with a bare failed DONE; so the next request always
-- succeeds and the state really is reset, with and without a session
-- setup.  The isolation level survives the bit on SQL Server.  'release'
-- with a transaction and streams open rolls the transaction back at once;
-- a reset-carrying request cancelled at once still resets the session.
module MarsTx.ResetSpec (spec) where

import Control.Monad (forM, forM_, unless)
import Data.IORef
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Connection.Internal (Connection (..))
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Transaction
import MarsTx.Harness
import TestDb

-- | Session state a reset takes away: a @#temp@ table, @LOCK_TIMEOUT@
-- and @ARITHABORT@ (which a session setup may set again).  The streams a
-- test opens before the reset run under that @LOCK_TIMEOUT@, and they read
-- @sys.all_columns@, whose metadata locks other tests' DDL can hold for
-- seconds on a busy server: a timeout of 1.2 s failed one with 1222 on
-- Azure SQL Database (S3, under the whole suite), so it is two minutes.
messUp :: Text
messUp = "CREATE TABLE #marstx_reset (i int); SET LOCK_TIMEOUT 123456; SET ARITHABORT OFF"

-- | @(\@\@LOCK_TIMEOUT, whether #marstx_reset exists, the ARITHABORT bit
-- of \@\@OPTIONS)@, as one request sees them.
stateSql :: Text
stateSql =
  "SELECT @@LOCK_TIMEOUT, CASE WHEN OBJECT_ID(N'tempdb..#marstx_reset') IS NULL THEN 0 ELSE 1 END, @@OPTIONS & 64"

type State = (Int, Int, Int)

-- | The state as three requests open at once, on three sessions, see it.
stateOnSessions :: Connection -> IO [State]
stateOnSessions conn =
  withQueryS conn (rawSql stateSql) $ \s0 ->
    withQueryS conn (rawSql stateSql) $ \s1 ->
      withQueryS conn (rawSql stateSql) $ \s2 -> do
        length <$> busySids conn `shouldReturn` 3
        concat <$> mapM S.toList_ [s0, s1, s2]

setups :: [(String, [Text])]
setups = [("without a session setup", []), ("with a session setup (SET ARITHABORT ON)", ["SET ARITHABORT ON"])]

-- | The ARITHABORT bit a reset leaves: the setup's, or the login's.
arithAfterReset :: [Text] -> Int -> Int
arithAfterReset setup atLogin = if null setup then atLogin else 64

spec :: Spec
spec = do
  describe "A35: a reset with every session idle" $
    it "resets the whole SQL session: state made on another session is gone for every session, and the sessions stay open" $ withMarsConn $ \conn -> do
      (_, atLogin, arithAtLogin) <- query1 conn (rawSql stateSql) :: IO State
      atLogin `shouldBe` 0
      -- The state is made on session 1, beside a response on session 0.
      (_, s) <- openWide conn 3
      busySids conn `shouldReturn` [0]
      _ <- execute conn (rawSql messUp)
      S.effects s
      stateOnSessions conn `shouldReturn` replicate 3 (123456, 1, 0)
      sids <- openSids conn
      length sids `shouldSatisfy` (>= 3)
      reset conn
      stateOnSessions conn `shouldReturn` replicate 3 (-1, 0, arithAtLogin)
      openSids conn `shouldReturn` sids

  describe "reset with streams open" $
    forM_ setups $ \(label, setup) ->
      it (label ++ ": the streams end with ResultAbandoned at their next read; the next request succeeds, and the session is reset (20 times)") $ withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn -> do
        (_, _, arithAtLogin) <- query1 conn (rawSql stateSql) :: IO State
        forM_ [1 .. 20 :: Int] $ \_ -> do
          _ <- execute conn (rawSql messUp)
          (_, big0) <- openWide conn 100_000
          Right (_, big) <- S.next big0
          (_, small) <- openWide conn 1
          (_, unread) <- openWide conn 100
          reset conn
          query1 conn (rawSql stateSql) `shouldReturn` ((-1, 0, arithAfterReset setup arithAtLogin) :: State)
          shouldBeAbandoned (S.effects big)
          shouldBeAbandoned (S.effects small)
          shouldBeAbandoned (S.effects unread)
          noResponseOpen conn

  describe "A38: the refused reset is prevented" $
    forM_ setups $ \(label, setup) ->
      it (label ++ ": a reset with a stream parked at its window, then requests of each kind: never refused, and the state was reset (100 times)") $ withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn -> do
        (_, _, arithAtLogin) <- query1 conn (rawSql stateSql) :: IO State
        let after = (-1, 0, arithAfterReset setup arithAtLogin) :: State
            nextRequests :: [Connection -> IO ()]
            nextRequests =
              [ \c -> query1 c (rawSql stateSql) `shouldReturn` after
              , \c -> query1 c (rawSql stateSql <> " WHERE " <> param (1 :: Int) <> " = 1") `shouldReturn` after
              , \c -> do
                  (_, s) <- openS c stateSql
                  S.toList_ s `shouldReturn` [after]
              , \c -> do
                  _ <- execute c "SELECT 1"
                  query1 c (rawSql stateSql) `shouldReturn` after
              ]
        forM_ (zip [0 :: Int ..] (take 100 (cycle nextRequests))) $ \(_, next) -> do
          _ <- execute conn (rawSql messUp)
          (_, s0) <- openWide conn 100_000
          Right (_, s) <- S.next s0
          reset conn
          next conn
          shouldBeAbandoned (S.effects s)
          noResponseOpen conn

  describe "A39: the isolation level across the RESETCONNECTION bit" $
    forM_ setups $ \(label, setup) ->
      it (label ++ ": SQL Server keeps it (Azure SQL Database puts READ COMMITTED back), on every session") $ withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn -> do
        azure <- testServerIsAzure
        forM_ [ReadUncommitted, RepeatableRead, Serializable] $ \l -> do
          _ <- execute conn (rawSql ("SET TRANSACTION ISOLATION LEVEL " <> levelSql l))
          reset conn
          let expected = if azure then ReadCommitted else l
          sessionLevel conn `shouldReturn` expected
          withQueryS conn "SELECT 1" $ \(_ :: Stream (Of (Only Int)) IO ()) ->
            sessionLevel conn `shouldReturn` expected

  describe "release on a MARS connection" $
    forM_ setups $ \(label, setup) ->
      it (label ++ ": with a transaction and streams open, returns True; the transaction is rolled back at once; the sessions stay open; the renewed handle works; the old streams throw ConnectionReleased (10 times)") $ withIntTable "marstx_release" $ \t -> withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn0 -> do
        handle <- newIORef conn0
        forM_ [1 .. 10] $ \i -> do
          conn <- readIORef handle
          begin conn
          insertKey conn t i
          (_, big0) <- openWide conn 100_000
          Right (_, big) <- S.next big0
          (_, small) <- openWide conn 1
          sids <- openSids conn
          release conn `shouldReturn` True
          -- Nothing is held: another connection takes the key at once.
          canTakeKeys t [i]
          conn' <- renew conn
          writeIORef handle conn'
          -- The sessions survive (G35): release sent no FIN.
          openSids conn' `shouldReturn` sids
          -- Carried out by release itself, the transaction being open.
          readIORef (connResetPending conn') `shouldReturn` False
          inTransaction conn' `shouldReturn` False
          tranCount conn' `shouldReturn` 0
          noResponseOpen conn'
          stale (S.effects big)
          stale (S.effects small)
        keysIn t `shouldReturn` []

  -- SQL Server 2025 applies and acknowledges the reset of a request
  -- cancelled at once, every time (finishSession).  Azure SQL Database
  -- doesn't always: the Attention can overtake the request, and the
  -- response ends without the acknowledgement.  hmssql then asks for the
  -- reset again, so the next request finds the session reset either way.
  describe "a reset-carrying request cancelled at once (reset, startResponse, cancelResponse)" $
    forM_ [("a batch", False), ("an RPC", True)] $ \(label, rpc) ->
      it (label ++ ": the session is reset afterwards, acknowledged or asked for again (100 times)") $ withMarsConn $ \conn -> do
        azure <- testServerIsAzure
        pendings <- forM [1 .. 100 :: Int] $ \_ -> do
          _ <- execute conn (rawSql messUp)
          reset conn
          req <- queryRequest conn $
            if rpc
              then "SELECT n.i, n.pad FROM " <> rawSql (numbersTable 100_000) <> " WHERE n.i > " <> param (0 :: Int) <> " ORDER BY n.i"
              else numbers 100_000
          resp <- startResponse conn req
          cancelResponse resp
          pending <- readIORef (connResetPending conn)
          (lt, exists, _) <- query1 conn (rawSql stateSql) :: IO State
          (lt, exists) `shouldBe` (-1, 0)
          readIORef (connResetPending conn) `shouldReturn` False
          pure pending
        let again = length (filter id pendings)
        hPutStrLn stderr ("    [cancelled reset, " ++ label ++ "] not acknowledged, so asked for again, in " ++ show again ++ " of 100")
        unless azure $ again `shouldBe` 0

  -- R2 with the gate: the read of the reset-carrying stream is interrupted
  -- before its first packet, which sends the Attention and leaves the
  -- response for the next request to drain.  That request drains it
  -- before the gate would read it ('prepareForRequest'), finds the reset
  -- acknowledged, and so asks for no second reset.
  describe "the read of a reset-carrying stream interrupted before its first packet (a timeout: the Attention sent, the response left to drain)" $
    forM_ setups $ \(label, setup) ->
      it (label ++ ": the next request, on another session, drains it; the session is reset, no reset is left pending, and the stream is abandoned (20 times)") $ withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn -> do
        (_, _, arithAtLogin) <- query1 conn (rawSql stateSql) :: IO State
        forM_ [1 .. 20 :: Int] $ \_ -> do
          _ <- execute conn (rawSql messUp)
          reset conn
          (_, s) <- openS conn ("WAITFOR DELAY '00:00:01'; " <> numbersSql 10)
          r <- timeout 100_000 (S.next (s :: Stream (Of WideRow) IO ()))
          case r of
            Nothing -> pure ()
            Just _ -> expectationFailure "the stream answered within 0.1 s"
          query1 conn (rawSql stateSql) `shouldReturn` ((-1, 0, arithAfterReset setup arithAtLogin) :: State)
          readIORef (connResetPending conn) `shouldReturn` False
          shouldBeAbandoned (S.effects s)
          noResponseOpen conn
  where
    stale act = act `shouldThrow` \ConnectionReleased -> True
