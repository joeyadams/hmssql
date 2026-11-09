-- | Transactions on a MARS connection the server has ended (its session
-- KILLed), found by the model tests ("Model.ConnectionSpec").  A request
-- whose read failed because the connection ended is not a response the
-- caller could read on or cancel ('cancelResponse' does nothing on an
-- ended connection), so it is not unfinished in the sense of
-- 'TransactionRequestsActive': 'begin', 'commit' and
-- 'withTransaction' report the ended connection, as any other use does
-- ('ConnectionClosed', or 'ConnectionBroken' wrapping it), and so they do
-- with a stream left unread from before the KILL: on an ended connection
-- the connection's error comes before 'TransactionRequestsActive'.
module Transaction.MarsEndedConnectionSpec (spec) where

import Control.Exception
import Control.Monad (forM_, replicateM, replicateM_, void, when)
import Data.Int (Int32)
import Streaming (Of, Stream)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Transaction
import TestDb

-- | A MARS connection whose session another connection KILLed (with a
-- stream open and unread from before, if asked), and whose next requests,
-- sent at once, failed.  (Sent before the server's reset has arrived, a
-- request's read fails; after, its send.)
withEndedMars :: Bool -> (Connection -> IO a) -> IO a
withEndedMars withStream act = do
  ci <- defaultTestConnectInfo
  withConnection ci { connectMars = True } $ \victim -> do
    victimId <- sessionIdentity victim
    when withStream $ void (queryS victim "SELECT 1 UNION ALL SELECT 2" :: IO (Stream (Of (Only Int32)) IO ()))
    withConnection ci $ \killer -> killSessionFrom killer victimId
    replicateM_ 3 $ do
      r <- try (query1 victim "SELECT 1" :: IO (Only Int32))
      case r of
        Left e | ended e || killed e -> pure ()
        _ -> expectationFailure ("a request after the KILL: " ++ show r)
    act victim

-- | Error 596: the session is being killed.
killed :: SomeException -> Bool
killed e = case fromException e of
  Just err -> sqlErrorNumber err == 596
  Nothing -> False

ended :: SomeException -> Bool
ended e
  | Just ConnectionClosed <- fromException e = True
  | Just (ConnectionBroken _) <- fromException e = True
  | otherwise = False

spec :: Spec
spec = describe "transactions on a MARS connection the server ended" $
  forM_ [False, True] $ \withStream ->
  forM_
    [ ("begin", begin)
    , ("commit", commit)
    , ("withTransaction", \conn -> withTransaction conn (pure ()))
    ] $ \(name, act) ->
      -- Whether the request after the KILL was sent (its read then fails)
      -- or its send failed depends on when the server's reset arrives, so
      -- several connections are tried.
      it (name ++ " throws the ended connection's error" ++ (if withStream then ", with a stream open" else "")) $ do
        rs <- replicateM 30 $ withEndedMars withStream $ \conn -> try (act conn)
        forM_ rs $ \case
          Left e
            | ended e -> pure ()
            | otherwise -> expectationFailure ("threw " ++ show e)
          Right () -> expectationFailure "succeeded on an ended connection"
