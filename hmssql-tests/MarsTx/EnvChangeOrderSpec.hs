-- | The order in which transaction ENVCHANGEs are applied on a MARS
-- connection (docs/dev/design.md "MARS: several responses on one connection"):
-- a transaction ended by an error while a second stream is open leaves a
-- second rollback ENVCHANGE in that stream's response.  A begin is refused
-- ('TransactionRequestsActive') until the stream has been read or
-- cancelled, so that ENVCHANGE is applied before the new transaction's,
-- and the new transaction survives it.  Likewise after a reset, which
-- rolls a transaction back.
module MarsTx.EnvChangeOrderSpec (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.Transaction
import MarsTx.Harness

-- | Ways to finish the second stream.
finishes :: [(String, ResponseReader -> Stream (Of WideRow) IO () -> IO ())]
finishes =
  [ ("read to its end (3998)", \_ s -> sqlErrorOf (S.effects s) `shouldReturn` 3998)
  , ("cancelled", \r _ -> cancelResponse r)
  ]

-- | A new transaction that survives: open, and committed by
-- 'commit'.
beginAgainAndCommit :: Connection -> Text -> Int -> IO ()
beginAgainAndCommit conn t key = do
  begin conn
  inTransaction conn `shouldReturn` True
  insertKey conn t key
  tranCount conn `shouldReturn` 1
  inTransaction conn `shouldReturn` True
  commit conn
  inTransaction conn `shouldReturn` False

spec :: Spec
spec = do
  describe "a transaction ended by an error while a second stream is open" $
    forM_ finishes $ \(label, finish) ->
      it ("refuses a new begin until the second is " ++ label ++ "; then the new transaction survives, and commits (10 times)") $ withIntTable "marstx_order" $ \t -> withMarsConn $ \conn -> do
        _ <- execute conn "SET XACT_ABORT ON"
        forM_ [1 .. 10] $ \i -> do
          begin conn
          insertKey conn t i
          (r2, s20) <- openWide conn 100_000
          Right (_, s2) <- S.next s20
          -- The first stream's error ends the transaction.
          (_, s1) <- openS conn "SELECT CAST('x' AS int)"
          sqlErrorOf (S.effects (s1 :: Stream (Of (Only Int)) IO ())) `shouldReturn` 245
          inTransaction conn `shouldReturn` False
          requestsActive (begin conn) `shouldReturn` [numbersSql 100_000]
          requestsActive (withTransaction conn (pure ())) `shouldReturn` [numbersSql 100_000]
          finish r2 s2
          noResponseOpen conn
          beginAgainAndCommit conn t (-i)
          canTakeKeys t [i]
        keysIn t `shouldReturn` [-10 .. -1]

  -- G47: the rollback ENVCHANGE is in the unread response, so the
  -- connection still has the ended transaction's descriptor, and the
  -- server refuses every request carrying it.  That is a plain
  -- SqlServerError (no type of its own), nothing is done, and reading the
  -- response puts the descriptor right: nothing keeps the old one.
  describe "an error that ended the transaction, unread in another stream" $
    it "makes a request meanwhile fail with SqlServerError 3971, having done nothing; once the stream is read, the transaction is over and requests work (10 times)" $ withIntTable "marstx_stale" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 10] $ \i -> do
        begin conn
        insertKey conn t i
        (_, s) <- openS conn "SELECT CAST('x' AS int)"
        -- The statement has run: its error, and the rollback, are queued.
        awaitArrived conn
        inTransaction conn `shouldReturn` True
        insertKey conn t (-i) `failsWithSql` 3971
        inTransaction conn `shouldReturn` True
        sqlErrorOf (S.effects (s :: Stream (Of (Only Int)) IO ())) `shouldReturn` 245
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        tranCount conn `shouldReturn` 0
        canTakeKeys t [i, -i]
      keysIn t `shouldReturn` []

  describe "a transaction ended by a reset while a stream is open" $ do
    it "the next request settles the stream and carries the reset; a new transaction then survives (10 times)" $ withIntTable "marstx_order_reset" $ \t -> withMarsConn $ \conn ->
      forM_ [1 .. 10] $ \i -> do
        begin conn
        insertKey conn t i
        (_, s0) <- openWide conn 100_000
        Right (_, s) <- S.next s0
        reset conn
        tranCount conn `shouldReturn` 0
        inTransaction conn `shouldReturn` False
        shouldBeAbandoned (S.effects s)
        noResponseOpen conn
        beginAgainAndCommit conn t (-i)
        canTakeKeys t [i]

    it "a begin with the reset pending and the stream open is refused; once the stream is cancelled the begin carries the reset, and the new transaction survives (10 times)" $ withIntTable "marstx_order_reset2" $ \t -> withMarsConn $ \conn ->
      forM_ [1 .. 10] $ \i -> do
        begin conn
        insertKey conn t i
        (r, s0) <- openWide conn 100_000
        Right (_, _) <- S.next s0
        reset conn
        requestsActive (begin conn) `shouldReturn` [numbersSql 100_000]
        cancelResponse r
        beginAgainAndCommit conn t (-i)
        canTakeKeys t [i]

    it "an error ends the transaction with a second stream open, then a reset: the next request settles the stream, and a new transaction survives (10 times)" $ withIntTable "marstx_order_both" $ \t -> withMarsConn $ \conn ->
      forM_ [1 .. 10] $ \i -> do
        _ <- execute conn "SET XACT_ABORT ON"
        begin conn
        insertKey conn t i
        (_, s0) <- openWide conn 100_000
        Right (_, s) <- S.next s0
        conversionError conn
        inTransaction conn `shouldReturn` False
        reset conn
        -- The reset put XACT_ABORT back OFF.
        fromOnly <$> query1 conn "SELECT CAST(@@OPTIONS & 16384 AS int)" `shouldReturn` (0 :: Int)
        shouldBeAbandoned (S.effects s)
        noResponseOpen conn
        beginAgainAndCommit conn t (-i)
        canTakeKeys t [i]
