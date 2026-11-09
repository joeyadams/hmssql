-- | The reset gate of a MARS connection (docs/dev/design.md "Session setup and
-- reset"; docs/dev/mars-research.md A36, A37): a request sent on another session right
-- behind one that carries RESETCONNECTION could run first on the server
-- and be refused, so no request starts until the carrying request's
-- leading ENVCHANGEs (the rollback of an open transaction, the reset's
-- acknowledgement) have been read.  The gate reads them for the response's
-- consumer if need be, and gives them to it afterwards: the consumer sees
-- every token once, in order, whatever it had read when the gate ran, and
-- each ENVCHANGE is applied and reported once.  An interrupted gate wait
-- is harmless.
module MarsTx.ResetGateSpec (spec) where

import Control.Monad (forM_, replicateM)
import Data.IORef
import Data.Maybe (isNothing)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Connection.Internal (Connection (..), Mars (..))
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Tds.Token (EnvChange (..), Token (..))
import Hmssql.Transaction
import MarsTx.Harness

-- | A token's kind, and an ENVCHANGE's: what the tests compare (the rows
-- and descriptors differ between runs).
shape :: Token -> String
shape = \case
  TEnvChange ec -> "TEnvChange " ++ envShape ec
  tok -> takeWhile (/= ' ') (show tok)

envShape :: EnvChange -> String
envShape = takeWhile (/= ' ') . show

-- | The handle with an observer of the ENVCHANGEs it applies.
observed :: Connection -> IO (Connection, IO [EnvChange])
observed conn = do
  seen <- newIORef []
  pure (conn { connOnEnvChange = \ec -> modifyIORef' seen (ec :) }, reverse <$> readIORef seen)

-- | Up to @k@ tokens from the stream, and the rest of it.
takeTokens :: Int -> Stream (Of Token) IO () -> IO ([Token], Stream (Of Token) IO ())
takeTokens k s
  | k <= 0 = pure ([], s)
  | otherwise = S.next s >>= \case
      Left () -> pure ([], pure ())
      Right (tok, rest) -> do
        (toks, rest') <- takeTokens (k - 1) rest
        pure (tok : toks, rest')

-- | In a transaction, with a reset pending: the tokens of a request that
-- carries the reset, of which the consumer reads @k@ before a second
-- request starts (if @k@ is @Nothing@, none starts), then the rest; and
-- the ENVCHANGEs the connection applied and reported meanwhile.
replay :: Connection -> Maybe Int -> IO ([Token], [EnvChange])
replay conn0 k = do
  (conn, seen) <- observed conn0
  begin conn
  before <- length <$> seen
  reset conn
  toks <- responseS conn (batchRequest "SELECT 1 AS x")
  (first, rest) <- takeTokens (maybe 0 id k) toks
  case k of
    Nothing -> pure ()
    Just _ -> do
      -- On another session, behind the gate.
      busySids conn `shouldReturn` [0]
      query1 conn "SELECT 2" `shouldReturn` Only (2 :: Int)
      resetInFlight conn `shouldReturn` False
  others <- S.toList_ rest
  inTransaction conn `shouldReturn` False
  applied <- drop before <$> seen
  pure (first ++ others, applied)

-- | A MARS connection without a session setup, so that a reset rides on
-- the next request.  (With one, the reset is a batch of its own, read to
-- its end before the request: no gate.)
withGateConn :: (Connection -> IO a) -> IO a
withGateConn = withMarsConnWith (\ci -> ci { connectSessionSetup = [] })

-- | Whether a reset-carrying response is still holding requests back.
resetInFlight :: Connection -> IO Bool
resetInFlight conn = case connMars conn of
  Nothing -> pure False
  Just mars -> not . isNothing <$> readIORef (marsResetInFlight mars)

spec :: Spec
spec = do
  describe "A36/A37: requests right behind a reset" $ do
    it "release, renew, a first request left unread (3,000 rows), a second on another session, then the first read to its end: never refused, every row, the second after the reset (1000 times)" $ withGateConn $ \conn0 -> do
      handle <- newIORef conn0
      forM_ [1 .. 1000 :: Int] $ \_ -> do
        conn <- readIORef handle
        _ <- execute conn "SET LOCK_TIMEOUT 1234"
        release conn `shouldReturn` True
        conn' <- renew conn
        writeIORef handle conn'
        (_, s) <- openWide conn' 3000
        lockTimeout conn' `shouldReturn` (-1)
        map wideRow <$> S.toList_ s `shouldReturn` [1 .. 3000]

    it "the same with a session setup (the reset in a batch of its own, no gate): never refused, every row (300 times)" $ withMarsConnWith (\ci -> ci { connectSessionSetup = ["SET ARITHABORT ON"] }) $ \conn0 -> do
      handle <- newIORef conn0
      forM_ [1 .. 300 :: Int] $ \_ -> do
        conn <- readIORef handle
        _ <- execute conn "SET LOCK_TIMEOUT 1234"
        release conn `shouldReturn` True
        conn' <- renew conn
        writeIORef handle conn'
        (_, s) <- openWide conn' 3000
        lockTimeout conn' `shouldReturn` (-1)
        map wideRow <$> S.toList_ s `shouldReturn` [1 .. 3000]

    it "the same inside a transaction, which the reset rolls back: never refused, every row (300 times)" $ withIntTable "marstx_gate" $ \t -> withGateConn $ \conn ->
      forM_ [1 .. 300] $ \i -> do
        begin conn
        insertKey conn t i
        reset conn
        (_, s) <- openWide conn 3000
        tranCount conn `shouldReturn` 0
        inTransaction conn `shouldReturn` False
        map wideRow <$> S.toList_ s `shouldReturn` [1 .. 3000]
        noResponseOpen conn

    -- The request that carries the reset first closes the idle sessions
    -- beyond ten ('closeIdleSessions'), so its FINs, not yet answered, go
    -- out right in front of it: the server must not count a closing
    -- session as a request still active, and refuse the reset.
    forM_ [("without a session setup (the bit on the request)", []), ("with a session setup (the bit on the setup batch)", ["SET ARITHABORT ON"])] $ \(label, setup) ->
      it ("idle sessions beyond ten closed with a FIN just before the request that carries the reset, " ++ label ++ ": never refused, the state reset, ten sessions left open (200 times)") $ withMarsConnWith (\ci -> ci { connectSessionSetup = setup }) $ \conn ->
        forM_ [1 .. 200 :: Int] $ \_ -> do
          _ <- execute conn "SET LOCK_TIMEOUT 1234"
          streams <- replicateM 13 (snd <$> openWide conn 1)
          length <$> busySids conn `shouldReturn` 13
          mapM_ S.effects streams
          length <$> openSids conn `shouldReturn` 13
          reset conn
          lockTimeout conn `shouldReturn` (-1)
          length <$> openSids conn `shouldReturn` 10
          noResponseOpen conn

  describe "gate replay: the consumer of the reset-carrying response has read none, some or all of its leading tokens when a second request starts" $ do
    it "reference: with no second request, the response begins with the rollback and the reset acknowledgement" $ withGateConn $ \conn -> do
      (toks, applied) <- replay conn Nothing
      map shape toks `shouldBe`
        [ "TEnvChange ECRollbackTransaction", "TEnvChange ECResetConnectionAck"
        , "TColMetaData", "TRow", "TDone" ]
      applied `shouldBe` [ec | TEnvChange ec <- toks]

    forM_ [0 .. 4] $ \k ->
      it (show k ++ " token(s) read before the second request: every token seen once and in order, each ENVCHANGE applied and reported once, no transaction (50 times)") $ withGateConn $ \conn -> do
        (reference, _) <- replay conn Nothing
        results <- replicateM 50 (replay conn (Just k))
        forM_ results $ \(toks, applied) -> do
          map shape toks `shouldBe` map shape reference
          applied `shouldBe` [ec | TEnvChange ec <- toks]

    forM_ [0, 1, 2] $ \k ->
      it ("release with the response unread (" ++ show k ++ " token(s) read): True, each ENVCHANGE applied once, the transaction gone, the stream stale") $ withGateConn $ \conn0 -> do
        handle <- newIORef conn0
        forM_ [1 .. 20 :: Int] $ \_ -> do
          (conn, seen) <- observed =<< readIORef handle
          begin conn
          before <- length <$> seen
          reset conn
          toks <- responseS conn (batchRequest "SELECT 1 AS x")
          (_, rest) <- takeTokens k toks
          release conn `shouldReturn` True
          -- The drain read the leading ENVCHANGEs (after those replayed):
          -- nothing holds the next borrower's requests back.
          resetInFlight conn `shouldReturn` False
          map envShape . drop before <$> seen `shouldReturn` ["ECRollbackTransaction", "ECResetConnectionAck"]
          conn' <- renew conn
          writeIORef handle conn'
          inTransaction conn' `shouldReturn` False
          tranCount conn' `shouldReturn` 0
          S.effects rest `shouldThrow` \ConnectionReleased -> True

  describe "a gate wait interrupted by a timeout" $
    it "the timeout fires before the second request is sent; the connection is still usable, and the first stream delivers everything (5 times)" $
      forM_ [1 .. 5 :: Int] $ \_ -> withGateConn $ \conn -> do
        _ <- execute conn "SET LOCK_TIMEOUT 1234"
        reset conn
        -- The reset-carrying request sends nothing for a second.
        (_, s) <- openS conn ("WAITFOR DELAY '00:00:01'; " <> numbersSql 3000)
        timeout 200_000 (lockTimeout conn) `shouldReturn` Nothing
        -- Held at the gate: no session was taken for it.
        openSids conn `shouldReturn` [0]
        resetInFlight conn `shouldReturn` True
        lockTimeout conn `shouldReturn` (-1)
        map wideRow <$> S.toList_ s `shouldReturn` [1 .. 3000]
        noResponseOpen conn
