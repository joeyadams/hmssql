{-# LANGUAGE TupleSections #-}

-- | Statements opened, read part-way, cancelled, interrupted and abandoned
-- against a model of the server, on a plain connection ("MockServer") and
-- over SMP ("Mars.MockSmp"): a hedgehog property, after the C port's
-- @fuzz_cancel@.
--
-- The model server answers each statement with its own rows (each row
-- names its statement and its place), in packets of arbitrary sizes,
-- including tiny ones.  When an Attention comes it cuts the response at
-- the next row's end, or runs it whole (as SQL Server 2025 does with an
-- Attention that comes before the statement is under way), and
-- acknowledges it in the response's last DONE or in a message of its own;
-- an Attention after the response has gone is acknowledged on its own.
-- Over SMP it may raise its windows late (a poller instead of SQL
-- Server's ACK as the data arrives), and the client's window is 4, 8 or
-- 64.  It may close or reset the connection after any packet.
--
-- The owner opens statements, reads a step of one, reads one under a
-- timeout of a few milliseconds, cancels one, or settles the connection.
-- Invariants:
--
-- * a row a reader returns is its own statement's, the next one, and a
--   reader that ends has had every row, except that each read interrupted
--   without abandoning its response may have lost one batch: the rows of
--   a packet, and a row cut by its start ("Interruption and cancellation"
--   in docs/dev/design.md; the step's result was committed as consumed
--   when the interruption landed, in the library's return or in
--   'timeout''s own, and nothing can hand it to the caller);
-- * a reader read after it was cancelled, interrupted or (on a plain
--   connection) superseded throws 'ResultAbandoned';
-- * nothing fails with the connection unless the server closed it, and
--   then only with 'ConnectionClosed' or 'ConnectionBroken';
-- * no step hangs (10 s each);
-- * at the end, unless the server closed the connection, a settle
--   succeeds and the next statement reads exactly its rows, and the SMP
--   mock saw no violation.
module Concurrency.CancelModelSpec (spec) where

import Hmssql.Tds.Reader (RowRead (..))
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, forever, unless, void, when)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Unsafe as BU
import Data.Bits (shiftL, (.|.))
import Data.Int (Int32, Int64)
import Data.IORef
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import qualified Data.Text as T
import Data.Word (Word16)
import Data.String (fromString)
import Hedgehog (Gen, annotate, classify, evalIO, failure, forAll, success)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import System.Timeout (timeout)
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)
import Test.Hspec.QuickCheck (modifyMaxShrinks)
import Text.Read (readMaybe)
import qualified Network.Socket as Socket

import Compat (onWindows, timeoutInSlices)
import Concurrency.Mock (batchText, doneAttn)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Connection.Internal (ResponseStep (..), RowBatch (..))
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Value (rowValues)
import Hmssql.Types
import Mars.MockSmp
import MockServer
import Protocol.MockTokens (colMetaData, packet)
import TestDb (withCases)

------------------------------------------------------------------------------
-- The case

-- | How the server answers one statement.
data Plan = Plan
  { planRows :: !Int
  , planBlob :: !Int
    -- ^ The bytes of a varbinary(max) in each row; 0 for no such column.
  , planIgnore :: !Bool
    -- ^ Run the response whole when an Attention comes.
  , planAckOwn :: !Bool
    -- ^ Acknowledge the Attention in a message of its own, not in the
    -- last DONE.
  , planPace :: !Int
    -- ^ Microseconds between the response's packets: a statement that
    -- takes its time, so that a read waits.
  }
  deriving (Show)

data Command
  = Open !Plan
  | Step !Int
    -- ^ One step of the reader in this slot, counted from the newest
    -- (modulo the slots).
  | Interrupted !Int !Int
    -- ^ One step under a timeout of this many microseconds.
  | Cancel !Int
  | Settle
  deriving (Show)

data Case = Case
  { caseMars :: !Bool
  , caseWindow :: !Int
  , caseLateWindows :: !Bool
  , caseSizes :: ![Int]
    -- ^ The payload sizes of the server's packets, cycled.
  , caseHangUp :: !(Maybe (Int, Bool))
    -- ^ After how many packets the server closes the connection, and
    -- whether with a reset.
  , caseCommands :: ![Command]
  }
  deriving (Show)

-- | A response stays short enough to send in about a second even in the
-- smallest packets: a value longer than 64 KiB in at most two rows, and
-- no pause between the packets of one with values.
genPlan :: Gen Plan
genPlan = do
  blob <- Gen.frequency [(6, pure 0), (3, Gen.int (Range.linear 1 400)), (1, Gen.int (Range.linear 65_000 80_000))]
  rows <- Gen.int (Range.constant 0 (if blob > 400 then 2 else 40))
  ignore <- Gen.bool
  ackOwn <- Gen.bool
  pace <- if blob > 0 then pure 0 else Gen.frequency [(1, pure 0), (2, Gen.int (Range.constant 500 5000))]
  pure (Plan rows blob ignore ackOwn pace)

genCase :: Bool -> Gen Case
genCase mars = do
  window <- if mars then Gen.element [4, 8, 64] else pure 64
  late <- if mars then Gen.bool else pure False
  sizes <- Gen.list (Range.linear 1 6) $
    Gen.frequency [(1, Gen.int (Range.constant 64 200)), (4, Gen.int (Range.constant 200 4088))]
  hangUp <- Gen.frequency [(2, pure Nothing), (1, Just <$> ((,) <$> Gen.int (Range.constant 1 15) <*> Gen.bool))]
  commands <- Gen.list (Range.linear 3 30) $ Gen.frequency
    [ (3, Open <$> genPlan)
    , (5, Step <$> slot)
    , (4, Interrupted <$> slot <*> Gen.frequency [(1, pure 0), (1, Gen.int (Range.constant 1 20)), (4, Gen.int (Range.constant 20 1500))])
    , (2, Cancel <$> slot)
    , (1, pure Settle) ]
  pure (Case mars window late sizes hangUp commands)
  where
    -- Counted from the newest: without MARS only the newest is live.
    slot = Gen.frequency [(3, pure 0), (2, Gen.int (Range.constant 1 7))]

------------------------------------------------------------------------------
-- The model server

-- | What a session's worker is told.
data Event = Request !Int | Attention | OtherRequest

-- | How the model server's packets leave: on a session, and how it hangs
-- up.
data Wire = Wire
  { wireSend :: Word16 -> B.ByteString -> IO ()
  , wireHangUp :: Bool -> IO ()
  }

data Server = Server
  { srvWire :: !Wire
  , srvPlans :: !(IORef (IntMap.IntMap Plan))
  , srvSizes :: !(IORef [Int])
  , srvPackets :: !(IORef Int)
  , srvHangUp :: !(Maybe (Int, Bool))
  , srvHungUp :: !(IORef Bool)
  , srvQueues :: !(MVar [(Word16, TQueue Event)])
  , srvThreads :: !(IORef [ThreadId])
  }

-- | The statement a request names: @STMT n@.
statementOf :: B.ByteString -> Maybe Int
statementOf body = case T.words (batchText body) of
  ["STMT", n] -> readMaybe (T.unpack n)
  _ -> Nothing

newServer :: Wire -> Case -> IORef (IntMap.IntMap Plan) -> IORef Bool -> IO Server
newServer wire c plans hungUp =
  Server wire plans <$> newIORef (cycle (caseSizes c)) <*> newIORef 0
    <*> pure (caseHangUp c) <*> pure hungUp <*> newMVar [] <*> newIORef []

-- | Hand a client message to its session's worker.
deliver :: Server -> Word16 -> PacketType -> B.ByteString -> IO ()
deliver srv sid ptype body = do
  q <- modifyMVar (srvQueues srv) $ \qs -> case lookup sid qs of
    Just q -> pure (qs, q)
    Nothing -> do
      q <- newTQueueIO
      t <- forkIO (void (try @SomeException (worker srv sid q)))
      atomicModifyIORef' (srvThreads srv) (\ts -> (t : ts, ()))
      pure ((sid, q) : qs, q)
  atomically $ writeTQueue q $ case ptype of
    PTAttention -> Attention
    PTSqlBatch | Just n <- statementOf body -> Request n
    _ -> OtherRequest

stopServer :: Server -> IO ()
stopServer srv = readIORef (srvThreads srv) >>= mapM_ killThread

-- | The tokens of a statement's response but its last DONE, each a place
-- where an Attention may cut it.
responseTokens :: Int -> Plan -> [Put]
responseTokens stmt Plan{..} =
  colMetaData (cols ++ [("b", TIBigVarBinary 0xFFFF) | planBlob > 0])
    : [ Put.putWord8 0xD1 >> int8 (fromIntegral stmt) >> int8 (fromIntegral i) >> blob i | i <- [0 .. planRows - 1] ]
  where
    cols = [("s", TIIntN 8), ("i", TIIntN 8)]
    int8 n = Put.putWord8 8 >> Put.putInt64le n
    blob i = when (planBlob > 0) $ do
      let bs = blobOf stmt i planBlob
      Put.putWord64le (fromIntegral (B.length bs))
      Put.putWord32le (fromIntegral (B.length bs))
      Put.putByteString bs
      Put.putWord32le 0

blobOf :: Int -> Int -> Int -> B.ByteString
blobOf stmt i n = B.replicate n (fromIntegral (stmt * 7 + i))

done :: Word16 -> Int -> Put
done status rows = do
  Put.putWord8 0xFD
  Put.putWord16le status
  Put.putWord16le 0
  Put.putWord64le (fromIntegral rows)

-- | One session of the model server: answer each request whole, cut by
-- an Attention at a row's end unless the plan ignores it.
worker :: Server -> Word16 -> TQueue Event -> IO ()
worker srv sid q = newIORef 0 >>= workerPaced srv sid q

-- | 'worker', with the pause between the packets of the response being
-- sent.
workerPaced :: Server -> Word16 -> TQueue Event -> IORef Int -> IO ()
workerPaced srv sid q pace = forever $ atomically (readTQueue q) >>= \case
  Attention -> message [doneAttn]
  OtherRequest -> message [done 0 0]
  Request stmt -> do
    plan <- fromMaybe (Plan 0 0 False False 0) . IntMap.lookup stmt <$> readIORef (srvPlans srv)
    out <- newIORef B.empty
    writeIORef pace (planPace plan)
    let go [] attn = finish attn
        go (t : ts) attn = do
          attn' <- if attn then pure True else isAttention
          if attn' && not (planIgnore plan)
            then finish True
            else emit out False (LB.toStrict (Put.runPut t)) >> go ts attn'
        finish attn
          | attn && planAckOwn plan = do
              emit out True (LB.toStrict (Put.runPut (done 0 0)))
              message [doneAttn]
          | attn = emit out True (LB.toStrict (Put.runPut (done 0x20 0)))
          | otherwise = emit out True (LB.toStrict (Put.runPut (done 0x10 (planRows plan))))
    go (responseTokens stmt plan) False
    writeIORef pace 0
  where
    isAttention = atomically $ tryPeekTQueue q >>= \case
      Just Attention -> True <$ readTQueue q
      _ -> pure False
    message toks = do
      out <- newIORef B.empty
      emit out True (LB.toStrict (Put.runPut (sequence_ toks)))
    -- Add the bytes to the message being sent, and send each packet as it
    -- fills: its payload a size from the case's list.  With @eom@ the
    -- message ends.
    emit out eom bytes = do
      pending <- (<> bytes) <$> readIORef out
      let loop buf = do
            size <- atomicModifyIORef' (srvSizes srv) $ \case
              x : rest -> (rest, x)
              [] -> ([], 4088)
            if B.length buf > size
              then sendPacket False (B.take size buf) >> loop (B.drop size buf)
              else if eom
                then sendPacket True buf >> writeIORef out B.empty
                else do
                  -- Hold back what doesn't fill a packet, putting the size back.
                  atomicModifyIORef' (srvSizes srv) (\ss -> (size : ss, ()))
                  writeIORef out buf
      loop pending
    sendPacket eom payload = do
      micros <- readIORef pace
      when (micros > 0) $ threadDelay micros
      wireSend (srvWire srv) sid (packet eom payload)
      n <- atomicModifyIORef' (srvPackets srv) (\k -> (k + 1, k + 1))
      forM_ (srvHangUp srv) $ \(at, reset) -> when (n == at) $ do
        writeIORef (srvHungUp srv) True
        wireHangUp (srvWire srv) reset
        throwIO ThreadKilled

------------------------------------------------------------------------------
-- The owner

-- | Whether a reader may still be read.
data Standing
  = Live
  | MaybeAbandoned
    -- ^ A read under a timeout was interrupted: if the interruption landed
    -- in the read, the response is abandoned; if before it, nothing
    -- happened; if after the read had its result, that result is lost
    -- and the response stays readable ('slotMayLose').  Or it was
    -- cancelled after the server ended the connection, when a cancel does
    -- nothing.  The next read says which.
  | Abandoned
    -- ^ Cancelled, settled or (without MARS) superseded.
  | Ended
  deriving (Eq, Show)

data Slot = Slot
  { slotReader :: !ResponseReader
  , slotStmt :: !Int
  , slotPlan :: !Plan
  , slotNext :: !Int
  , slotStanding :: !Standing
  , slotMayLose :: !Int
    -- ^ How many rows the interrupted reads since the last step returned
    -- may have lost: for each, a batch ('lossBound').
  }

-- | The most rows one step returns: the rows of the largest packet, and a
-- row cut by the packet boundary before them.  (A row longer than 64 KiB
-- comes in a batch of its own.)
lossBound :: [Int] -> Plan -> Int
lossBound sizes Plan{planBlob} = maximum (1 : sizes) `div` rowBytes + 1
  where
    -- The ROW token's byte, the two bigints and the varbinary(max): its
    -- length, one chunk's length and the terminator.
    rowBytes = 1 + 9 + 9 + (if planBlob > 0 then 16 + planBlob else 0)

-- | A violation of an invariant.
newtype Violation = Violation String
  deriving (Show)

instance Exception Violation

violation :: String -> IO a
violation = throwIO . Violation

le64 :: B.ByteString -> Int64
le64 bs = foldr (\i acc -> (acc `shiftL` 8) .|. fromIntegral (BU.unsafeIndex bs i)) 0 [0 .. 7]

-- | Check a batch of a reader's rows: each its statement's, the next one
-- (the first may skip the rows 'slotMayLose' allows).
checkRows :: Slot -> [[Maybe B.ByteString]] -> IO Slot
checkRows sl0 = go sl0
  where
    go sl [] = pure sl
    go sl (r : rest) = case r of
      Just a : Just b : blob
        | B.length a == 8, B.length b == 8
        , fromIntegral (le64 a) == slotStmt sl
        , i <- fromIntegral (le64 b), i >= slotNext sl, i <= slotNext sl + slotMayLose sl
        , blobOk blob i -> go sl { slotNext = i + 1, slotMayLose = 0 } rest
      _ -> violation ("statement " ++ show (slotStmt sl) ++ " expected its row " ++ show (slotNext sl)
                        ++ lost sl ++ ", got " ++ show (map (fmap describe) r))
    lost sl
      | slotMayLose sl > 0 = " (or up to " ++ show (slotMayLose sl) ++ " rows later, after an interruption)"
      | otherwise = ""
    blobOk blob i = case (planBlob (slotPlan sl0), blob) of
      (0, []) -> True
      (n, [Just v]) -> v == blobOf (slotStmt sl0) i n
      _ -> False
    describe v = if B.length v == 8 then show (le64 v) else show (B.length v) ++ " bytes"

isClosedOrBroken :: SomeException -> Bool
isClosedOrBroken e = case fromException e of
  Just (ConnectionClosedBy _) -> True
  Nothing -> case fromException e of
    Just (ConnectionBroken _) -> True
    Nothing -> False

isAbandoned :: SomeException -> Bool
isAbandoned e = case fromException e of
  Just ResultAbandoned{} -> True
  Nothing -> False

-- | Run a step of the owner under the bound on hanging.  The connection
-- failing is allowed once the server has hung up; any other exception
-- is the caller's to judge.  The 'try' is outside the 'timeout', so that
-- the timeout's own exception reaches it and not the 'try'.
guarded :: IORef Bool -> String -> IO a -> IO (Either SomeException a)
guarded hungUp what act = try (timeoutInSlices 10_000_000 act) >>= \case
  Right Nothing -> violation (what ++ ": hung for 10 s")
  Right (Just a) -> pure (Right a)
  Left e
    | Just (Violation _) <- fromException e -> throwIO e
    | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    | isClosedOrBroken e -> do
        hung <- readIORef hungUp
        unless hung $ violation (what ++ ": " ++ show e ++ ", but the server never hung up")
        pure (Left e)
    | otherwise -> pure (Left e)

-- | Run the commands; whether the connection failed.
runCommands :: Bool -> [Int] -> Connection -> IORef Bool -> IORef (IntMap.IntMap Plan) -> (String -> IO ()) -> [Command] -> IO Bool
runCommands mars sizes conn hungUp plans tally = go [] 1
  where
    go _ _ [] = pure False
    go slots next (c : cs) = tally (phase (show c)) >> step slots next c >>= \case
      Nothing -> pure True
      Just (slots', next') -> go slots' next' cs

    -- 'Nothing' once the connection has failed.
    step slots next = \case
      Open plan
        | length [s | s <- slots, slotStanding s `elem` [Live, MaybeAbandoned]] >= 6 -> pure (Just (slots, next))
        | otherwise -> do
            modifyIORef' plans (IntMap.insert next plan)
            guarded hungUp "open" (startResponse conn (batchRequest (T.pack ("STMT " ++ show next)))) >>= \case
              Left e -> failed "open" e
              Right reader -> do
                -- Without MARS the new request supersedes every other.
                let older = if mars then slots else map supersede slots
                pure (Just (older ++ [Slot reader next plan 0 Live 0], next + 1))
      Step i -> withSlot slots next i (readOne Nothing)
      Interrupted i micros -> withSlot slots next i (readOne (Just micros))
      Cancel i -> withSlot slots next i $ \s ->
        guarded hungUp "cancel" (cancelResponse (slotReader s)) >>= \case
          Left e -> failed "cancel" e
          Right () -> do
            -- On a connection the server has ended, a cancel does nothing,
            -- and the reader may go on to read what arrived before the end.
            hung <- readIORef hungUp
            pure (Just (if hung && slotStanding s /= Ended then s { slotStanding = MaybeAbandoned } else abandon s))
      Settle ->
        guarded hungUp "settle" (cancelActiveStatement conn) >>= \case
          Left e -> failed "settle" e
          Right () -> pure (Just (map abandon slots, next))

    supersede s = if slotStanding s == Ended then s else s { slotStanding = Abandoned }
    abandon = supersede

    withSlot slots next i k = case slots of
      [] -> pure (Just (slots, next))
      _ -> do
        let j = length slots - 1 - i `mod` length slots
        k (slots !! j) >>= \case
          Nothing -> pure Nothing
          Just s' -> pure (Just (take j slots ++ [s'] ++ drop (j + 1) slots, next))

    readOne limit s
      | slotStanding s == Ended = pure (Just s)
      | otherwise = do
          let -- Past the tokens before a batch of rows (COLMETADATA, say).
              readIt = readSteps (4 :: Int)
              readSteps n = readStep (slotReader s) (WholeRows rowValues) >>= \case
                StepToken _ | n > 1 -> readSteps (n - 1)
                stepped -> pure stepped
              who = "statement " ++ show (slotStmt s)
          r <- guarded hungUp "read" $ case limit of
            Nothing -> Just <$> readIt
            Just micros -> timeout micros readIt
          case r of
            Left e
              | isAbandoned e -> do
                  when (slotStanding s == Live) $ violation (who ++ ": ResultAbandoned, but it was neither cancelled nor superseded")
                  tally (if slotStanding s == MaybeAbandoned then "an interrupted read abandoned its response" else "a cancelled response was abandoned")
                  pure (Just s { slotStanding = Abandoned })
              | isClosedOrBroken e -> tally "the connection failed" >> pure Nothing
              | otherwise -> violation ("a read of " ++ who ++ ": " ++ show e)
            Right Nothing -> do
              tally "a read was interrupted"
              pure (Just s { slotStanding = MaybeAbandoned, slotMayLose = slotMayLose s + lossBound sizes (slotPlan s) })
            Right (Just stepped)
              | slotStanding s == Abandoned -> violation (who ++ " was read after it was cancelled or superseded")
              | otherwise -> case stepped of
                  StepRows (RowBatch rows failure) -> do
                    forM_ failure $ \e -> violation (who ++ ": a row failed to decode: " ++ show e)
                    s' <- checkRows s rows
                    when (slotNext s' - slotNext s > length rows) $ tally "an interruption lost rows"
                    unless (null rows) $ tally "rows were read"
                    when (slotStanding s == MaybeAbandoned) $ tally "a reader went on after an interruption or a cancel"
                    pure (Just s' { slotStanding = Live })
                  StepToken _ -> pure (Just s { slotStanding = Live })
                  StepEnd -> do
                    let missing = planRows (slotPlan s) - slotNext s
                    unless (missing >= 0 && missing <= slotMayLose s) $
                      violation (who ++ " ended after " ++ show (slotNext s) ++ " of its " ++ show (planRows (slotPlan s)) ++ " rows"
                        ++ (if slotMayLose s > 0 then " (up to " ++ show (slotMayLose s) ++ " lost to interruptions)" else ""))
                    when (missing > 0) $ tally "an interruption lost rows"
                    tally "a response was read to its end"
                    pure (Just s { slotStanding = Ended })

    failed what e
      | isClosedOrBroken e = pure Nothing
      | otherwise = violation (what ++ ": " ++ show e)

-- | The last statement, after a settle: exactly its rows.
finalStatement :: Connection -> IORef Bool -> IORef (IntMap.IntMap Plan) -> (String -> IO ()) -> IO ()
finalStatement conn hungUp plans tally = do
  let plan = Plan 5 0 False False 0
  modifyIORef' plans (IntMap.insert 0 plan)
  r <- guarded hungUp "the last statement" $ do
    cancelActiveStatement conn
    reader <- startResponse conn (batchRequest "STMT 0")
    let loop acc = readStep reader (WholeRows rowValues) >>= \case
          StepRows (RowBatch rows _) -> loop (acc ++ rows)
          StepToken _ -> loop acc
          StepEnd -> pure acc
    (,) reader <$> loop []
  case r of
    -- The server hung up after the commands ('guarded' checked that it did).
    Left e | isClosedOrBroken e -> tally "the connection failed"
    Left e -> violation ("the last statement: " ++ show e)
    Right (reader, rows) -> do
      s <- checkRows (Slot reader 0 plan 0 Live 0) rows
      unless (slotNext s == 5) $ violation ("the last statement had " ++ show (slotNext s) ++ " rows, not 5")

------------------------------------------------------------------------------
-- Running a case

-- | An event that says where the case is, for a case that hangs.
phase :: String -> String
phase = ("at: " ++)

stripPhase :: String -> Maybe String
stripPhase e = case splitAt 4 e of
  ("at: ", p) -> Just p
  _ -> Nothing

-- | A case's outcome, 'Nothing' or the violation, and what happened in
-- it (for the coverage).
runCase :: Case -> IO (Maybe String, [String])
runCase c = do
  plans <- newIORef IntMap.empty
  hungUp <- newIORef False
  events <- newIORef []
  let tally e = atomicModifyIORef' events (\es -> (e : es, ()))
  tally (phase "connecting")
  r <- timeoutInSlices 60_000_000 $ try @Violation $ if caseMars c then smp plans hungUp tally else plain plans hungUp tally
  happened <- readIORef events
  pure $ (, happened) $ case r of
    Nothing -> Just ("the case hung for 60 s, at " ++ fromMaybe "?" (listToMaybe (mapMaybe stripPhase happened)))
    Just (Left (Violation v)) -> Just v
    Just (Right ()) -> Nothing
  where
    owner conn plans hungUp tally = do
      tally (phase "connected")
      failedConn <- runCommands (caseMars c) (caseSizes c) conn hungUp plans tally (caseCommands c)
      hung <- readIORef hungUp
      when failedConn $ tally "the connection failed"
      when hung $ tally "the server hung up"
      unless (failedConn || hung) $ tally (phase "the last statement") >> finalStatement conn hungUp plans tally
      tally (phase "closing")

    plain plans hungUp tally = do
      let handler mc = do
            tally (phase "the mock accepted the connection")
            _ <- serveLogin defaultLoginResponse mc
            tally (phase "the mock served the login")
            let wire = Wire
                  { wireSend = \_ bytes -> sendRaw mc bytes
                  , wireHangUp = \reset -> if reset then resetUnderReader mc else shutdownSend mc }
            srv <- newServer wire c plans hungUp
            let loop = (recvMessageMaybe mc `catch` \(_ :: IOException) -> pure Nothing) >>= \case
                  Nothing -> pure ()
                  Just (ptype, body) -> deliver srv 0 ptype body >> loop
            loop `finally` stopServer srv
      withMockServer handler $ \ms ->
        withConnection (mockConnectInfo ms) $ \conn -> owner conn plans hungUp tally

    -- A reset sent from a worker while the handler's thread reads the
    -- socket.  Not 'resetConnection', which closes the socket under that
    -- read: a thread that starts to wait on a descriptor just after it was
    -- closed leaves a stale registration in GHC's IO manager (before
    -- 9.14), and the next socket given the number, in a later case or in
    -- the other property running beside this one, never wakes its reader,
    -- so that a login or a read there hung ('Mars.MockSmp.dropConnection'
    -- avoids the same).  The receiving side is shut down instead, which
    -- ends the handler's read, and the handler's own close ('closeMock',
    -- after the end of the stream) then sends the reset, SO_LINGER 0 being
    -- set already.  A pipe has no shutdown, and its close waits for a
    -- receive in progress.
    -- On Windows shutdown(SD_RECEIVE) does not cancel the overlapped
    -- ReadFile that the mock's backend has pending. Its close does:
    -- it cancels and waits for pending I/O before releasing the socket,
    -- so it is safe under the reader and actually sends the reset.
    resetUnderReader mc
      | onWindows = resetConnection mc
      | otherwise = case mcSocketMaybe mc of
          Just sock ->
            (Socket.setSockOpt sock Socket.Linger (Socket.StructLinger 1 0) >> Socket.shutdown sock Socket.ShutdownReceive)
              `catch` \(_ :: IOException) -> pure ()
          Nothing -> resetConnection mc

    smp plans hungUp tally = do
      mockVar <- newEmptyMVar
      srvVar <- newEmptyMVar
      let wire = Wire
            { wireSend = \sid bytes -> readMVar mockVar >>= \m -> sendTdsPacket m sid bytes
            , wireHangUp = \_ -> readMVar mockVar >>= dropConnection }
      srv <- newServer wire c plans hungUp
      putMVar srvVar srv
      let respond m msg = do
            void (tryPutMVar mockVar m)
            deliver srv (cmSid msg) (cmType msg) (cmBody msg)
          cfg = defaultSmpConfig { cfgRespond = Just respond, cfgAutoAck = not (caseLateWindows c), cfgHoldLimit = 20 }
      withSmpServer cfg $ \server -> do
        withConnection (smpConnectInfo server) { connectMarsWindow = caseWindow c } $ \conn -> do
          m <- nextMock server
          void (tryPutMVar mockVar m)
          poller <- if caseLateWindows c
            then do
              stopped <- newEmptyMVar
              t <- forkFinally (lateWindows m) (\_ -> putMVar stopped ())
              pure (Just (t, stopped))
            else pure Nothing
          owner conn plans hungUp tally `finally` mapM_ stopPoller poller
        out <- nextOutcome server
        stopServer srv
        hung <- readIORef hungUp
        unless (hung || null (outViolations out)) $
          violation ("the mock SMP server saw " ++ show (outViolations out))

    -- Raise a session's window only once the client has used all but one
    -- of it, a millisecond or so late.  A raise that fails (the session
    -- has closed, or the connection) is skipped, but the 'killThread'
    -- that stops the poller is not caught.  It can land in 'raiseWindow'
    -- (waiting for the send lock, or in the send), and a poller that
    -- swallowed it there went on polling the dead mock every millisecond
    -- for the rest of the process: about 3 MB of allocation a second
    -- each, which 'Resources.StalledServer' measured.
    lateWindows m = forever $ do
      ids <- mockSessionIds m
      forM_ ids $ \sid -> mockSession m sid >>= \case
        Just s | not (msClientFin s), (fromIntegral (msServerWindow s - msClientSeq s) :: Int32) <= 1 ->
          raiseWindow m sid (msClientSeq s + 4) `catch` \(e :: SomeException) ->
            case fromException e of
              Just (a :: SomeAsyncException) -> throwIO a
              Nothing -> pure ()
        _ -> pure ()
      threadDelay 1_000

    -- Stop the poller, and check that it stopped.
    stopPoller (t, stopped) = do
      killThread t
      timeoutInSlices 10_000_000 (readMVar stopped) >>= \case
        Just () -> pure ()
        Nothing -> violation "the window poller was still running 10 s after it was killed"

------------------------------------------------------------------------------

spec :: Spec
spec = describe "statements cancelled, interrupted and abandoned against a model server" $ do
  it "a reset during a large row wakes a request superseding that row" $ do
    (outcome, _) <- runCase Case
      { caseMars = False, caseWindow = 64, caseLateWindows = False
      , caseSizes = [2861, 166, 189], caseHangUp = Just (9, True)
      , caseCommands = [Open (Plan 1 70141 False False 0), Open (Plan 20 0 True True 3284)]
      }
    outcome `shouldBe` Nothing
  modifyMaxShrinks (const 20) $ withCases 500 $ do
    it "keep every row in its statement and in order, never hang, and leave the next statement exact" $
      hedgehog (property' False)
    it "over SMP: keep every row in its statement and in order, never hang, and leave the next statement exact" $
      hedgehog (property' True)
  where
    property' mars = do
      c <- forAll (genCase mars)
      (outcome, happened) <- evalIO (runCase c)
      forM_ coverage $ \e -> classify (fromString e) (e `elem` happened)
      case outcome of
        Nothing -> success
        Just v -> annotate v >> failure
    coverage =
      [ "rows were read", "a response was read to its end", "a read was interrupted"
      , "an interrupted read abandoned its response", "a reader went on after an interruption or a cancel"
      , "a cancelled response was abandoned", "an interruption lost rows", "the server hung up", "the connection failed" ]
