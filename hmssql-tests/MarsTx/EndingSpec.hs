-- | How a transaction ends on a MARS connection while other sessions have
-- responses open (docs/dev/mars-research.md A30-A32).  'withTransaction''s cleanup
-- cancels every open response before its rollback, so a body that throws
-- with streams open leaves a usable connection with @XACT_ABORT@ off and
-- on, and neither 3998 nor 3989 surfaces.  Under @XACT_ABORT ON@ the
-- Attention on a statement still executing ends the connection's
-- transaction ('TransactionEndedEarly'); one that has finished doesn't,
-- nor does any Attention with it off.  An error that ends the transaction
-- is reported on its own session; a stream open on another session
-- delivers its rows and then ends with 3998.
module MarsTx.EndingSpec (spec) where

import Control.Exception
import Control.Monad (forM_)
import Data.Text (Text)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Transaction
import MarsTx.Harness

xactAbort :: Bool -> Text
xactAbort on = if on then "SET XACT_ABORT ON" else "SET XACT_ABORT OFF"

onOff :: Bool -> String
onOff on = if on then "ON" else "OFF"

spec :: Spec
spec = do
  describe "A30: a body that throws with two streams open" $
    forM_ [False, True] $ \on ->
      it ("XACT_ABORT " ++ onOff on ++ ": the cleanup rolls back, the body's exception propagates, no 3998 or 3989, and the next transaction works (20 times)") $ withIntTable "marstx_a30" $ \t -> withMarsConn $ \conn -> do
        _ <- execute conn (rawSql (xactAbort on))
        forM_ [1 .. 20] $ \i -> do
          r <- try $ withTransaction conn $ do
            insertKey conn t i
            -- One still executing (parked at its window), one small.
            (_, big) <- openWide conn 100_000
            S.effects (S.take 1 big)
            _ <- openWide conn 1
            length <$> busySids conn `shouldReturn` 2
            throwIO (userError "boom")
          case r of
            Left (e :: SomeException) -> case fromException e of
              Just (io :: IOException) -> show io `shouldContain` "boom"
              Nothing -> expectationFailure ("expected the body's exception, got " ++ show e)
            Right () -> expectationFailure "no exception"
          inTransaction conn `shouldReturn` False
          noResponseOpen conn
          tranCount conn `shouldReturn` 0
          canTakeKeys t [i]
          withTransaction conn (insertKey conn t (-i))
        keysIn t `shouldReturn` [-20 .. -1]

  describe "A31: cancelling a stream inside a transaction" $ do
    it "XACT_ABORT ON, the statement still executing: the transaction ends (inTransaction False), and withTransaction throws TransactionEndedEarly (20 times each: cancelResponse, withQueryS)" $ withIntTable "marstx_a31" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 20] $ \i -> forM_ [False, True] $ \bracketed -> do
        let key = i * 2 + fromEnum bracketed
        shouldEndEarly $ withTransaction conn $ do
          insertKey conn t key
          if bracketed
            then withQueryS conn (numbers 100_000) $ \(s :: Stream (Of WideRow) IO ()) -> S.effects (S.take 10 s)
            else do
              (r, s) <- openWide conn 100_000
              S.effects (S.take 10 s)
              cancelResponse r
          inTransaction conn `shouldReturn` False
          tranCount conn `shouldReturn` 0
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        canTakeKeys t [key]
        -- The next one works.
        withTransaction conn (insertKey conn t (-key))
      length <$> keysIn t `shouldReturn` 40

    it "XACT_ABORT ON, the statement finished (the response fully arrived): nothing is cancelled on the server, and it commits (20 times)" $ withIntTable "marstx_a31f" $ \t -> withMarsConnArriving $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 20] $ \i -> do
        withTransaction conn $ do
          insertKey conn t i
          (r, s) <- openWide conn 100
          S.effects (S.take 10 s)
          awaitArrived conn
          cancelResponse r
          inTransaction conn `shouldReturn` True
        inTransaction conn `shouldReturn` False
      keysIn t `shouldReturn` [1 .. 20]

    it "XACT_ABORT OFF, the statement still executing: the transaction survives, and commits (20 times each: cancelResponse, withQueryS)" $ withIntTable "marstx_a31off" $ \t -> withMarsConn $ \conn -> do
      forM_ [1 .. 20] $ \i -> forM_ [False, True] $ \bracketed -> do
        let key = i * 2 + fromEnum bracketed
        withTransaction conn $ do
          insertKey conn t key
          if bracketed
            then withQueryS conn (numbers 100_000) $ \(s :: Stream (Of WideRow) IO ()) -> S.effects (S.take 10 s)
            else do
              (r, s) <- openWide conn 100_000
              S.effects (S.take 10 s)
              cancelResponse r
          inTransaction conn `shouldReturn` True
          tranCount conn `shouldReturn` 1
      length <$> keysIn t `shouldReturn` 40

  describe "A32: an error that ends the transaction (a conversion error under XACT_ABORT ON)" $ do
    it "is reported on its own session; a stream still executing on another delivers every row, then ends with 3998" $ withIntTable "marstx_a32" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 10] $ \i -> do
        begin conn
        insertKey conn t i
        (_, s0) <- openWide conn 100_000
        Right (_, s) <- S.next s0
        conversionError conn
        inTransaction conn `shouldReturn` False
        readCounting s `shouldReturn` (99_999, 3998)
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        tranCount conn `shouldReturn` 0
        canTakeKeys t [i]

    it "a stream whose response had fully arrived before the error delivers its rows and ends without error" $ withIntTable "marstx_a32f" $ \t -> withMarsConnArriving $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 10] $ \i -> do
        begin conn
        insertKey conn t i
        (_, s) <- openWide conn 100
        awaitArrived conn
        conversionError conn
        inTransaction conn `shouldReturn` False
        readCounting s `shouldReturn` (100, 0)
        noResponseOpen conn
        tranCount conn `shouldReturn` 0
        canTakeKeys t [i]

    it "inside withTransaction: the body catches the error and reads the other stream to its end (3998): TransactionEndedEarly, and the next transaction works" $ withIntTable "marstx_a32w" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 10] $ \i -> do
        shouldEndEarly $ withTransaction conn $ do
          insertKey conn t i
          (_, s0) <- openWide conn 100_000
          Right (_, s) <- S.next s0
          conversionError conn
          readCounting s `shouldReturn` (99_999, 3998)
        canTakeKeys t [i]
        withTransaction conn (insertKey conn t (-i))
      keysIn t `shouldReturn` [-10 .. -1]

    it "inside withTransaction: the body catches the error and returns with the other stream unread: TransactionRequestsActive (the check comes first), and the connection is clean" $ withIntTable "marstx_a32u" $ \t -> withMarsConn $ \conn -> do
      _ <- execute conn "SET XACT_ABORT ON"
      forM_ [1 .. 10] $ \i -> do
        stmts <- requestsActive $ withTransaction conn $ do
          insertKey conn t i
          (_, s0) <- openWide conn 100_000
          Right (_, _) <- S.next s0
          conversionError conn
        stmts `shouldBe` [numbersSql 100_000]
        inTransaction conn `shouldReturn` False
        noResponseOpen conn
        tranCount conn `shouldReturn` 0
        canTakeKeys t [i]
        withTransaction conn (insertKey conn t (-i))
      keysIn t `shouldReturn` [-10 .. -1]
