{-# LANGUAGE DerivingStrategies #-}

-- | 'withTransaction' interrupted at random points (during BEGIN, the body,
-- or COMMIT) by 'timeout', 'killThread' or 'throwTo'.  Afterwards: no open
-- transaction; the body's writes rolled back unless it finished (a commit
-- that was interrupted may or may not have happened); and no locks left
-- behind that would block another connection, checked from that connection
-- before the interrupted one is used again.
--
-- On a MARS connection a body that leaves its stream open and is not
-- interrupted isn't committed: 'TransactionRequestsActive', and its writes
-- rolled back like an interrupted body's.
module Concurrency.TransactionKillSpec (spec) where

import UnusableCause (brokenCause)
import Control.Exception hiding (assert)
import Control.Monad (void)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness
import Hmssql
import Hmssql.Errors
import Hmssql.Transaction (TransactionError (..))
import TestDb

-- | What the body does between its two inserts.
data Middle
  = Nothing'
  | Rows !Int
  | StreamSome !Int
  | Sleep !Int
  | BigParam !Int
  deriving stock (Show)

genMiddle :: Gen Middle
genMiddle = Gen.choice
  [ pure Nothing'
  , Rows <$> Gen.int (Range.exponential 1 20_000)
  , StreamSome <$> Gen.int (Range.linear 0 20)
  , Sleep <$> Gen.int (Range.linear 0 50)
  , BigParam <$> Gen.int (Range.exponential 1 200_000)
  ]

runMiddle :: Connection -> Middle -> IO ()
runMiddle conn = \case
  Nothing' -> pure ()
  Rows n -> void (query conn (mkQuery "SELECT TOP (@p1) 1 FROM sys.all_columns a CROSS JOIN sys.all_columns b" (Only n)) :: IO [Only Int])
  StreamSome k -> do
    s <- queryS conn "SELECT TOP 100000 1 FROM sys.all_columns a CROSS JOIN sys.all_columns b"
    void (S.length_ (S.take k (s :: S.Stream (S.Of (Only Int)) IO ())))
  Sleep ms -> void $ execute conn (rawSql ("WAITFOR DELAY '00:00:00." <> pad3 ms <> "'"))
  BigParam n -> void (query conn (mkQuery "SELECT LEN(@p1)" (Only (textOf n))) :: IO [Only Int])
  where
    pad3 ms = T.justifyRight 3 '0' (T.pack (show ms))
    textOf n = T.replicate n "z"

data Setting = Setting
  { table :: !Text
  , holder :: !ConnHolder
  , observer :: !Connection
  }

txnProperty :: Setting -> PropertyT IO ()
txnProperty Setting{..} = do
  middle <- forAll genMiddle
  method <- forAll genMethod
  delay <- forAll (genDelay 30_000)
  (outcome, bodyDone, visible, health) <- evalIO $ withHeldConnection holder $ \conn -> do
    v <- nextId
    doneRef <- newIORef False
    let insert = void $ execute conn (mkQuery ("INSERT INTO " <> table <> " (v) VALUES (@p1)") (Only v))
    r <- interruptWith method delay $ withTransaction conn $ do
      insert
      runMiddle conn middle
      insert
      writeIORef doneRef True
    bodyDone <- readIORef doneRef
    -- A broken connection may still have its transaction open on the
    -- server; closing it ends the session, which rolls it back.
    broken <- brokenCause conn
    case broken of
      Just _ -> closeHolder holder
      Nothing -> pure ()
    -- Before the interrupted connection is used again: its locks must be
    -- gone already (the rollback is not left for the next request).
    visible <- try $ query1 observer
      (mkQuery ("SET LOCK_TIMEOUT 5000; SELECT COUNT(*) FROM " <> table <> " WHERE v = @p1") (Only v))
    health <- case broken of
      Just cause -> pure (Broken cause)
      Nothing -> checkHealth conn
    pure (r, bodyDone, visible, health)
  annotateShow (fmap (const ()) outcome, bodyDone)
  case visible of
    Left (e :: SqlServerError) -> do
      annotate ("the other connection could not read (left-over locks?): " ++ show e)
      failure
    Right (Only (n :: Int)) -> case outcome of
      Right () -> n === 2
      Left e
        | leftStreamOpen middle e -> n === 0
        | bodyDone -> assert (n == 0 || n == 2)  -- interrupted during COMMIT
        | otherwise -> n === 0
  case outcome of
    Left e -> assert (isAsync e || show e == show (userError "<<timeout>>") || leftStreamOpen middle e)
    Right () -> pure ()
  case health of
    Broken cause -> annotateShow cause >> assert (isAsync cause)
    Usable -> pure ()

-- | The commit was refused for the stream the body left open (MARS only,
-- and only a body that opens a stream).
leftStreamOpen :: Middle -> SomeException -> Bool
leftStreamOpen middle e = case (middle, fromException e) of
  (StreamSome _, Just (TransactionRequestsActive _)) -> True
  _ -> False

runTxnProperty :: Int -> Spec
runTxnProperty n = it ("rolls back and releases locks when interrupted anywhere (" ++ show n ++ " runs)") $
  withTestDb $ \owner -> withTestDb $ \observer -> do
    table <- ("##" <>) <$> uniqueName "conc_txn"
    _ <- execute owner (rawSql ("CREATE TABLE " <> table <> " (v bigint NOT NULL)"))
    ci <- defaultTestConnectInfo
    holder <- newConnHolder ci (\_ -> pure ())
    cases <- scaledCases n
    ok <- check $ withTests (fromIntegral cases) $ withShrinks 0 $ property $ txnProperty Setting{..}
    closeHolder holder
    ok `shouldBe` True

spec :: Spec
spec = describe "withTransaction interrupted" $ do
  runTxnProperty 100
  slow $ runTxnProperty 2000
