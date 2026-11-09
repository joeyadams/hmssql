{-# LANGUAGE DerivingStrategies #-}

-- | Shared helpers for the MARS tests (@hmssql-tests/Mars/*Spec.hs@): connections
-- that are MARS connections whether or not @HMSSQL_TEST_MARS@ is set, a look
-- at the client's SMP sessions (which are open, which busy, which the server
-- still knows, how many packets a session holds), and the queries the tests
-- stream.
module Mars.Harness
  ( -- * Connections
    marsInfo
  , withMarsConn
  , withMarsConnWith
  , withMarsConnFor
  , plainInfo
  , withPlainConn
    -- * The client's sessions
  , openSids
  , busySids
  , idleSids
  , registrySids
  , closingSids
  , marsOf
  , sessionOf
  , heldPackets
  , receivedPackets
  , waitHeldStable
  , waitHeldFull
  , connWindow
  , expectClean
  , startNumbers
  , startRowReader
  , attentionSent
  , waitFullyArrived
  , observerSees
  , awaitLockWait
  , waitingForLock
  , attentionTakenIn
  , withObserver
  , withScanTable
  , waitUntil
  , pollFor
    -- * Queries
  , numbers
  , wideRows
  , numStream
  , withNums
  , spidOf
  , tsql
    -- * Reading streams
  , expectAbandoned
  , expectAbandonedS
  , readAll
  , firstRow
  , takeRows
  , roundRobin
    -- * Azure's kill of an early Attention
  , EarlyAttentionKill (..)
  , cancelling
  , survivingEarlyAttentionKill
    -- * Timing
  , seconds
    -- * Diagnosing a hang
  , describeMars
  , Steps
  , newSteps
  , markStep
  , withinTraced
  , withinTracedOn
  , withinMoving
  ) where

import UnusableCause (brokenCause)
import qualified RecipeState
import Control.Concurrent (forkIO, killThread, myThreadId, threadDelay)
import Data.Functor ((<&>))
import Data.Char (toUpper)
import Numeric (readHex, showHex)
import qualified Network.Socket as Socket
import Control.Concurrent.STM
import Control.Exception
import Data.IORef
import Control.Monad (forM, when)
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import System.IO (hPutStrLn, stderr)
import System.Mem.Weak (deRefWeak)
import GHC.Conc (listThreads, threadStatus)
import Control.Concurrent.MVar (isEmptyMVar, tryReadMVar)
import Hmssql.Connection.Locking (mutexOwner)
import GHC.Clock (getMonotonicTime)
import Data.Unique (Unique, newUnique)
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Streaming (Of (..), Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Compat (connSocketMaybe)
import Concurrency.Harness (expectUsable, within)
import Hmssql
import Hmssql.Connection.Internal
import Hmssql.Errors
import Hmssql.Query (drainResponse, queryRequest, startResponse)
import Hmssql.Query.Internal (compilerFor, streamFirstResultSet)
import Hmssql.Query.Types (ResponseReader (..))
import TestDb

------------------------------------------------------------------------------
-- Connections

-- | The default test settings, as a MARS connection whatever
-- @HMSSQL_TEST_MARS@ says.
marsInfo :: IO ConnectInfo
marsInfo = do
  ci <- defaultTestConnectInfo
  pure ci { connectMars = True }

-- | The default test settings without MARS, whatever @HMSSQL_TEST_MARS@ says.
plainInfo :: IO ConnectInfo
plainInfo = do
  ci <- defaultTestConnectInfo
  pure ci { connectMars = False }

-- | A MARS connection to the test database (the configured encryption,
-- packet size and session setup).
withMarsConn :: (Connection -> IO a) -> IO a
withMarsConn = withMarsConnWith id

-- | 'withMarsConn' with some settings changed.
withMarsConnWith :: (ConnectInfo -> ConnectInfo) -> (Connection -> IO a) -> IO a
withMarsConnWith f act = do
  ci <- marsInfo
  withConnection (f ci) act

-- | A MARS connection with the given encryption.
withMarsConnFor :: Encryption -> (ConnectInfo -> ConnectInfo) -> (Connection -> IO a) -> IO a
withMarsConnFor enc f act = do
  ci <- testConnectInfo enc
  withConnection (f ci { connectMars = True }) act

-- | A connection without MARS.
withPlainConn :: (Connection -> IO a) -> IO a
withPlainConn act = do
  ci <- plainInfo
  withConnection ci act

------------------------------------------------------------------------------
-- The client's sessions

marsOf :: Connection -> Mars
marsOf conn = case connMars conn of
  Just m -> m
  Nothing -> error "Mars.Harness: not a MARS connection"

-- | The identifiers of the open sessions, lowest first.
openSids :: Connection -> IO [Int]
openSids conn = IntMap.keys <$> readIORef (marsOpen (marsOf conn))

-- | The open sessions with a response (busy: its end is unread, or its
-- cancel undrained).
busySids :: Connection -> IO [Int]
busySids conn = do
  open <- readIORef (marsOpen (marsOf conn))
  fmap concat $ mapM (\(sid, sess) -> do
    r <- readIORef (sessResponse sess)
    pure [sid | isJust r]) (IntMap.toList open)

-- | The open sessions with no response.
idleSids :: Connection -> IO [Int]
idleSids conn = do
  open <- openSids conn
  busy <- busySids conn
  pure [s | s <- open, s `notElem` busy]

-- | The identifiers the server knows: open, or closing (a FIN sent, the
-- server's not yet arrived).
registrySids :: Connection -> IO [Int]
registrySids conn = IntMap.keys <$> readTVarIO (marsRegistry (marsOf conn))

-- | The registered identifiers that are not open: closing.
closingSids :: Connection -> IO [Int]
closingSids conn = do
  reg <- registrySids conn
  open <- openSids conn
  pure [s | s <- reg, s `notElem` open]

sessionOf :: Connection -> Int -> IO Session
sessionOf conn sid = do
  open <- readIORef (marsOpen (marsOf conn))
  case IntMap.lookup sid open of
    Just s -> pure s
    Nothing -> throwIO (userError ("no open session " ++ show sid))

linkOf :: Connection -> Int -> IO SmpLink
linkOf conn sid = do
  reg <- readTVarIO (marsRegistry (marsOf conn))
  case IntMap.lookup sid reg of
    Just l -> pure l
    Nothing -> throwIO (userError ("no session " ++ show sid ++ " in the registry"))

-- | The TDS packets a session has received and not yet consumed: what its
-- queue holds.  (Read without losing any: flushed and put back in one
-- transaction.)
heldPackets :: Connection -> Int -> IO Int
heldPackets conn sid = do
  link <- linkOf conn sid
  atomically $ do
    xs <- flushTQueue (linkIncoming link)
    mapM_ (writeTQueue (linkIncoming link)) xs
    pure (length xs)

-- | How many DATA packets a session has received in all (its sequence
-- number for receiving).
receivedPackets :: Connection -> Int -> IO Word32
receivedPackets conn sid = do
  link <- linkOf conn sid
  readTVarIO (linkRecvSeq link)

-- | The connection answers, no session has a response, and no transaction is
-- open.
expectClean :: Connection -> IO ()
expectClean conn = do
  busySids conn `shouldReturn` []
  expectUsable conn

-- | A table of @n@ rows (@id@, and 100 bytes of padding), created and dropped
-- through a connection of its own, so that cleanup can't wait on the
-- connection under test.  The action gets its name.
withScanTable :: Int -> (Text -> IO a) -> IO a
withScanTable n act = do
  name <- uniqueName "hmssql_mars_scan"
  let table = "dbo." <> name
  withTestDb $ \admin -> do
    _ <- execute admin $ rawSql $
      "CREATE TABLE " <> table <> " (id int NOT NULL PRIMARY KEY, pad char(100) NOT NULL DEFAULT 'x'); \
      \INSERT INTO " <> table <> " (id) SELECT TOP " <> T.pack (show n)
      <> " ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns a CROSS JOIN sys.all_columns b"
    act table `finally` execute admin (rawSql ("SET LOCK_TIMEOUT -1; DROP TABLE IF EXISTS " <> table))

-- | Send a query and give its response's reader with a stream of the rows
-- of its first result set: the same as 'queryS', but with the handle that
-- 'Hmssql.Query.cancelResponse' takes.
startRowReader :: FromSqlRow r => Connection -> Query -> IO (ResponseReader, Stream (Of r) IO ())
startRowReader conn q = do
  req <- queryRequest conn q
  resp <- startResponse conn req
  pure (resp, streamFirstResultSet (compilerFor rowDecoder) resp (drainResponse resp))

-- | 'startRowReader' of a query of numbers ('numbers').
startNumbers :: Connection -> Int -> IO (ResponseReader, Stream (Of Int64) IO ())
startNumbers conn n = do
  (resp, s) <- startRowReader conn (rawSql (numbers n))
  pure (resp, S.map fromOnly s)

-- | Whether an Attention was sent for the response.
attentionSent :: ResponseReader -> IO Bool
attentionSent resp = RecipeState.attentionSent (respActive resp)

-- | Wait until the response's last packet has arrived on the client (its
-- session's end-of-message count is past what it was when the request left).
waitFullyArrived :: ResponseReader -> IO ()
waitFullyArrived resp = do
  let ar = respActive resp
  case sessSmp (arSession ar) of
    Nothing -> expectationFailure "not a MARS session"
    Just smp -> do
      ok <- waitUntil 30 ((> arEomBase ar) <$> readTVarIO (linkEoms (smpLink smp)))
      ok `shouldBe` True

-- | A second connection that can see other sessions' requests; pending
-- without VIEW SERVER STATE.
withObserver :: (Connection -> IO ()) -> IO ()
withObserver act = withTestDb $ \obs -> do
  Only perm <- query1 obs "SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE')"
  if perm == Just (1 :: Int)
    then act obs
    else pendingWith "needs VIEW SERVER STATE to see another session's requests"

-- | The requests the server has for a session (its statuses), as the
-- observer sees them.
observerSees :: Connection -> Int -> IO [Text]
observerSees obs spid =
  map fromOnly <$> query obs (mkQuery "SELECT status FROM sys.dm_exec_requests WHERE session_id = @p1" (Only spid))

-- | Wait (up to 30 s) until the observer sees a request of the session
-- waiting for a lock: a test that needs a statement held up by another
-- connection's locks waits for that, not for a fixed time, which a
-- loaded server overran (the statement hadn't reached the lock yet).
awaitLockWait :: Connection -> Int -> IO ()
awaitLockWait obs spid = go (1500 :: Int)
  where
    go n = do
      waiting <- waitingForLock obs spid
      if waiting
        then pure ()
        else if n <= 0
          then expectationFailure "the statement never showed as waiting for a lock"
          else threadDelay 20_000 >> go (n - 1)

-- | Whether the observer sees a request of the session waiting for a lock.
waitingForLock :: Connection -> Int -> IO Bool
waitingForLock obs spid = do
  Only waiting <- query1 obs $ mkQuery
    "SELECT CAST(COUNT(*) AS int) FROM sys.dm_exec_requests WHERE session_id = @p1 AND wait_type LIKE N'LCK[_]M[_]%'"
    (Only spid)
  pure ((waiting :: Int) > 0)

-- | Whether the server's SMP layer has taken in every DATA packet sent on
-- the session, the last (an Attention, say) included: SQL Server keeps its
-- window 4 packets ahead of what it has consumed (A9), so a window 4 past
-- the last packet sent means that one was consumed too.  An Attention is
-- ACKed so at once, even while the statement it cancels waits for a lock
-- (seen in captures, 2026-10-15).
attentionTakenIn :: Connection -> Int -> IO Bool
attentionTakenIn conn sid = do
  sess <- sessionOf conn sid
  case sessSmp sess of
    Nothing -> pure False
    Just smp -> do
      sent <- readIORef (smpSendSeq smp)
      window <- readTVarIO (linkSendHighWater (smpLink smp))
      pure (window - sent >= 4)

-- | Wait until the session's held packets stay the same for 300 ms (the
-- server has sent what it may), and return that count.
waitHeldStable :: Connection -> Int -> IO Int
waitHeldStable conn sid = go 0 (-1) (0 :: Int)
  where
    go stable prev n = do
      h <- heldPackets conn sid
      let stable' = if h == prev then stable + 1 else 0 :: Int
      if stable' >= 6 || n > 400
        then pure h
        else threadDelay 50_000 >> go stable' h (n + 1)

-- | Wait until the session holds at least @target@ packets (the server has
-- sent that many), then until its count stays the same for 300 ms; that count.
-- A stream of more packets than the window parks at the window, so the
-- target is the window.
waitHeldFull :: Connection -> Int -> Int -> IO Int
waitHeldFull conn sid target = do
  ok <- waitUntil 20 ((>= target) <$> heldPackets conn sid)
  when (not ok) $ do
    h <- heldPackets conn sid
    expectationFailure ("session " ++ show sid ++ " held " ++ show h ++ " packets, never the " ++ show target ++ " expected")
  waitHeldStable conn sid

-- | The window of the connection's SMP sessions ('connectMarsWindow', which
-- @HMSSQL_TEST_MARS_WINDOW@ sets for test connections); 0 without MARS.
connWindow :: Connection -> Int
connWindow conn = maybe 0 (fromIntegral . marsWindow) (connMars conn)

-- | Poll every 20 ms until the condition holds or @secs@ pass; whether it
-- held.
waitUntil :: Double -> IO Bool -> IO Bool
waitUntil secs cond = do
  t0 <- getMonotonicTime
  let go = cond >>= \case
        True -> pure True
        False -> do
          now <- getMonotonicTime
          if now - t0 > secs then pure False else threadDelay 20_000 >> go
  go

-- | Run the action every 20 ms until its result satisfies the predicate or
-- the deadline (in seconds) passes; returns the last result.
pollFor :: Double -> (a -> Bool) -> IO a -> IO a
pollFor secs ok act = do
  t0 <- getMonotonicTime
  let go = do
        a <- act
        now <- getMonotonicTime
        if ok a || now - t0 > secs then pure a else threadDelay 20_000 >> go
  go

------------------------------------------------------------------------------
-- Queries

-- | @n@ rows of one bigint column, 1 .. n.
numbers :: Int -> Text
numbers n = "SELECT TOP " <> T.pack (show n)
  <> " CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint) FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | @n@ rows, a bigint and 1000 bytes each: about eight rows a packet, so
-- a result that fills a window of packets quickly.
wideRows :: Int -> Text
wideRows n = "SELECT TOP " <> T.pack (show n)
  <> " CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint), REPLICATE(CAST('x' AS varchar(1000)), 1000) \
     \FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | 'queryS' of 'numbers', as a stream of the numbers.
numStream :: Connection -> Int -> IO (Stream (Of Int64) IO ())
numStream conn n = S.map fromOnly <$> queryS conn (rawSql (numbers n))

-- | 'withQueryS' of 'numbers'.
withNums :: Connection -> Int -> (Stream (Of Int64) IO () -> IO a) -> IO a
withNums conn n act = withQueryS conn (rawSql (numbers n)) (act . S.map fromOnly)

spidOf :: Connection -> IO Int
spidOf conn = fromOnly <$> query1 conn "SELECT CAST(@@SPID AS int)"

-- | A SQL text from a pack of lines.
tsql :: [Text] -> Query
tsql = rawSql . T.unwords

------------------------------------------------------------------------------
-- Reading streams

-- | Reading the stream on throws 'ResultAbandoned'.
expectAbandoned :: Show a => IO a -> Expectation
expectAbandoned act = within 30 (try act) >>= \case
  Left ResultAbandoned -> pure ()
  Right a -> expectationFailure ("expected ResultAbandoned, got " ++ show a)

expectAbandonedS :: Stream (Of a) IO () -> Expectation
expectAbandonedS s = expectAbandoned (S.length_ s)

-- | The rows of a stream.
readAll :: Stream (Of (Only Int64)) IO () -> IO [Int64]
readAll s = S.toList_ (S.map fromOnly s)

-- | The first row of a stream, and the rest of it.
firstRow :: Stream (Of a) IO () -> IO (a, Stream (Of a) IO ())
firstRow s = S.next s >>= \case
  Right r -> pure r
  Left () -> throwIO (userError "the stream has no row")

-- | The first @n@ rows of a stream, and the rest of it.
takeRows :: Int -> Stream (Of a) IO () -> IO ([a], Stream (Of a) IO ())
takeRows n s = do
  xs :> rest <- S.toList (S.splitAt n s)
  pure (xs, rest)

-- | Pull one row at a time from each stream in turn until all have ended.
-- Each row goes to the callback with its stream's index and its own index
-- in the stream (from 0).  Returns how many rows each stream gave.
roundRobin :: [Stream (Of a) IO ()] -> (Int -> Int -> a -> IO ()) -> IO [Int]
roundRobin streams onRow = go (zip3 [0 ..] (repeat 0) streams) []
  where
    go [] done = pure (map snd (sortOn fst done))
    go live done = do
      steps <- forM live $ \(i, n, s) -> S.next s >>= \case
        Left () -> pure (Left (i, n))
        Right (a, s') -> do
          onRow i n a
          let !n' = n + 1
          pure (Right (i, n', s'))
      -- Strict, or the lists would hold every row through the steps.
      let !finished = [x | Left x <- steps]
          !live' = [x | Right x <- steps]
          !done' = finished ++ done
      go live' done'

------------------------------------------------------------------------------
-- Timing

-- | A duration in seconds, for a message.
seconds :: Double -> String
seconds x = show (fromIntegral (round (x * 1000) :: Int) / 1000 :: Double) ++ " s"

------------------------------------------------------------------------------
-- Azure's kill of an early Attention

-- | Azure SQL Database, loaded, sometimes reads a request together with the
-- Attention that cancels it, and then ends the whole MARS connection: a
-- DONE flagged DONE_ERROR and DONE_SRVERROR on that session, a FIN, and
-- the close (docs/dev/protocol-notes.md, "Azure SQL Database";
-- docs/dev/limitations.md, "MARS").  SQL Server never does.
data EarlyAttentionKill = EarlyAttentionKill
  deriving (Show)

instance Exception EarlyAttentionKill

-- | Run a cancel ('cancelResponse', 'cancelActiveStatement',
-- 'rollback' with busy responses).  On Azure SQL Database the
-- server's close out of it is 'EarlyAttentionKill'; anything else, and
-- anything anywhere else, is rethrown as it is.
cancelling :: IO a -> IO a
cancelling act = do
  azure <- testServerIsAzure
  try act >>= \case
    Left e | azure, Just (ConnectionClosedBy ClosedByServer) <- fromException e -> throwIO EarlyAttentionKill
    Left e -> throwIO (e :: SomeException)
    Right a -> pure a

-- | Run a test's body, whose cancels go through 'cancelling'.  If one meets
-- Azure's kill, the body ends there: the connection must be broken, and
-- the test passes with a note on stderr.
survivingEarlyAttentionKill :: String -> Connection -> IO () -> IO ()
survivingEarlyAttentionKill label conn body = try body >>= \case
  Right () -> pure ()
  Left EarlyAttentionKill -> do
    r <- try (query1 conn "SELECT 1" :: IO (Only Int))
    case r of
      Left (_ :: SomeException) -> pure ()
      Right _ -> expectationFailure "the connection answered after the server had closed it"
    hPutStrLn stderr ("    [" ++ label ++ "] Azure SQL ended the connection at an early Attention")

------------------------------------------------------------------------------
-- Diagnosing a hang

-- | The client's view of a MARS connection, for a failure message: whether
-- it ended or broke, and each open session's response (its Attention, the
-- acknowledgement, the final DONE) and SMP counters (packets queued,
-- sequence numbers and windows).
describeMars :: Connection -> IO String
describeMars conn = do
  ended <- readTVarIO (connEnded conn)
  broken <- brokenCause conn
  let m = marsOf conn
  open <- readIORef (marsOpen m)
  registered <- IntMap.keys <$> readTVarIO (marsRegistry m)
  resetInFlight <- isJust <$> readIORef (marsResetInFlight m)
  sessions <- forM (IntMap.toList open) $ \(sid, sess) -> do
    response <- readIORef (sessResponse sess) >>= \case
      Nothing -> pure "idle"
      Just ar -> do
        -- The link the drain reads ('readSessionPacket' reads the
        -- response's own session's) against the one the reader thread
        -- fills (the registry's, by identifier).
        registry <- readTVarIO (marsRegistry m)
        let own = smpLink <$> sessSmp (arSession ar)
            filled = IntMap.lookup sid registry
            sameLink = case (own, filled) of
              (Just a, Just b) -> if linkRecvSeq a == linkRecvSeq b then "the reader's" else "NOT the reader's"
              _ -> "unknown"
        ownQueue <- case own of
          Just l -> atomically (isEmptyTQueue (linkIncoming l)) <&> \e -> if e then "empty" else "non-empty"
          Nothing -> pure "none"
        attn <- RecipeState.attentionSent ar
        ack <- RecipeState.acknowledged ar
        final <- readIORef (arSawFinalDone ar)
        abandoned <- RecipeState.abandoned ar
        pure $ concat
          [ "response ", show (fmap (T.take 60) (arStatement ar))
          , ", attention ", show attn, ", ack ", show ack, ", final DONE ", show final
          , ", abandoned ", show abandoned, ", EOM base ", show (arEomBase ar)
          , ", its link ", sameLink, " (queue ", ownQueue, ")" ]
    smp <- case sessSmp sess of
      Nothing -> pure ""
      Just ss -> do
        let l = smpLink ss
        sent <- readIORef (smpSendSeq ss)
        advertised <- readIORef (smpAdvertised ss)
        (empty, sendHw, recvSeq, recvHw, eoms, closing) <- atomically $
          (,,,,,) <$> isEmptyTQueue (linkIncoming l) <*> readTVar (linkSendHighWater l)
            <*> readTVar (linkRecvSeq l) <*> readTVar (linkRecvHighWater l)
            <*> readTVar (linkEoms l) <*> readTVar (linkClosing l)
        pure $ concat
          [ "; queue ", if empty then "empty" else "non-empty", ", sent ", show sent
          , " of ", show sendHw, ", received ", show recvSeq, " of ", show recvHw
          , " (advertised ", show advertised, "), EOMs ", show eoms
          , if closing then ", closing" else "" ]
    pure ("session " ++ show sid ++ ": " ++ response ++ smp)
  reader <- readIORef (connReader conn) >>= \case
    Nothing -> pure "not started"
    Just weak -> deRefWeak weak >>= maybe (pure "collected") (fmap show . threadStatus)
  owner <- mutexOwner (connMutex conn) >>= \case
    Nothing -> pure "free"
    Just n -> do
      threads <- listThreads
      status <- case [t | t <- threads, show t == "ThreadId " ++ show n] of
        t : _ -> show <$> threadStatus t
        [] -> pure "not found"
      pure ("held by thread " ++ show n ++ ", " ++ status)
  sendLockHeld <- isEmptyMVar (connSendLock conn)
  -- TLS records gathered but not yet written, and the kernel's queues for
  -- the socket (bytes not yet sent, and received but not yet read).
  let SendGather gv = connSendGather conn
  gathered <- tryReadMVar gv <&> \case
    Nothing -> "busy"
    Just NotGathering -> "none"
    Just (Gathering pending size) -> show (length pending) ++ " records, " ++ show size ++ " bytes"
  queues <- maybe (pure "not a socket: no queues to read") socketQueues (connSocketMaybe conn)
  pure $ concat
    [ "mutex ", owner, ", send lock ", if sendLockHeld then "held" else "free"
    , ", gathered ", gathered, ", socket ", queues
    , ", reader ", reader, ", ended ", maybe "no" show ended, ", broken ", maybe "no" show broken
    , ", reset in flight ", show resetInFlight, ", registered ", show registered
    , "; ", if null sessions then "no open session" else foldr1 (\a b -> a ++ " | " ++ b) sessions ]

-- | Where a traced test is ('withinTraced'): its current step, when it
-- began (by the monotonic clock, and by the wall clock to compare with the
-- server's times), and its longest step so far.
data Steps = Steps !String !Double !UTCTime !(String, Double)

-- | A new trace, at the step.
newSteps :: String -> IO (IORef Steps)
newSteps what = do
  t <- getMonotonicTime
  wall <- getCurrentTime
  newIORef (Steps what t wall ("none", 0))

-- | Begin a step, ending the one before.
markStep :: IORef Steps -> String -> IO ()
markStep ref what = do
  t <- getMonotonicTime
  wall <- getCurrentTime
  modifyIORef' ref $ \(Steps prev start _ longest) ->
    let took = t - start
     in Steps what t wall (if took > snd longest then (prev, took) else longest)

-- | 'within' for a test of a MARS connection, as a hang detector: it fails
-- when the connection has made no progress for @secs@ seconds (no DATA
-- packet sent or received on any session, and no window raised), or when
-- the test has run ten times @secs@ in all.  A loaded server can serve a
-- connection slowly for minutes (docs/dev/protocol-notes.md, "The server
-- under load"), and a test of what flow control does, not of how fast,
-- then rides it out, saying on stderr that it ran past @secs@ while the
-- connection kept moving.
--
-- The failure says which step the test was at and for how long, its
-- longest step before that, the client's view of the connection
-- ('describeMars'), and the server's view of its session
-- ('describeSession').  The two looks are 2 s apart, so the packet counts
-- in them tell a stream that stopped from one that moves slowly; and the
-- server's look says how long it took to connect and answer, so a server
-- that stopped answering everyone shows as such.
withinTraced :: Int -> Connection -> SessionIdentity -> IORef Steps -> IO a -> IO a
withinTraced secs conn victim = watched secs conn (Just victim)

-- | 'withinTraced' for a test that marks no steps and whose session the
-- server's look doesn't name, since asking costs a request on the
-- connection, which a test of how requests take sessions would see: the
-- same limit on time without progress, the client's view, and the whole
-- server's.
withinMoving :: Int -> Connection -> IO a -> IO a
withinMoving secs conn act = do
  steps <- newSteps "the test"
  watched secs conn Nothing steps act

watched :: Int -> Connection -> Maybe SessionIdentity -> IORef Steps -> IO a -> IO a
watched secs conn victim steps act = do
  me <- myThreadId
  early <- newIORef "none"
  t0 <- getMonotonicTime
  token <- newUnique
  let limit = fromIntegral secs :: Double
      cap = 10 * limit
      lookAtServer = do
        t1 <- getMonotonicTime
        server <- either (\e -> "not known: " ++ show (e :: SomeException)) id <$> try (maybe describeServer describeSession victim)
        t2 <- getMonotonicTime
        pure ("(a new connection's look took " ++ seconds (t2 - t1) ++ ") " ++ server)
      -- A look 2 s before the limit, while the thread is still where it is
      -- stuck: what it is blocked on, and the connection as it holds it.
      -- The client's part first: a server that doesn't answer may take the
      -- look past the limit.
      earlyLook = do
        status <- threadStatus me
        client <- describeMars conn
        writeIORef early (show status ++ "; " ++ client ++ "\n    the server then: (no answer by the limit)")
        server <- lookAtServer
        writeIORef early (show status ++ "; " ++ client ++ "\n    the server then " ++ server)
      watch lastProgress lastMoved looked = do
        threadDelay 250_000
        now <- getMonotonicTime
        progress <- connectionProgress conn
        let moved = if progress /= lastProgress then now else lastMoved
            still = now - moved
            due = still >= limit - 2 || now - t0 >= cap - 2
        -- One look while it is due; another only after the connection has
        -- moved and stalled again.  (The look itself can take up to 10 s,
        -- which the limit can then overrun.)
        looked' <- if due && not looked then earlyLook >> pure True else pure (looked && due)
        if still >= limit || now - t0 >= cap
          then throwTo me (Stalled token still)
          else watch progress moved looked'
  p0 <- connectionProgress conn
  r <- try (bracket (forkIO (watch p0 t0 False)) killThread (\_ -> act))
  t <- getMonotonicTime
  case r of
   Right a -> do
    when (t - t0 > limit) $ do
      Steps at _ _ (slowest, took) <- readIORef steps
      hPutStrLn stderr $ "    [ran " ++ seconds (t - t0) ++ ", past its " ++ show secs
        ++ " s, while the connection kept moving: a slow server (its longest step: " ++ slowest
        ++ ", " ++ seconds took ++ "; its last: " ++ at ++ ")]"
    pure a
   Left (Stalled tok still) | tok /= token -> throwIO (Stalled tok still)
   Left (Stalled _ still) -> do
    Steps at start wall (slowest, took) <- readIORef steps
    before <- readIORef early
    client <- describeMars conn
    server <- lookAtServer
    throwIO $ userError $ concat
      [ if still >= limit
          then "no progress on the connection for " ++ seconds still ++ " (deadlock or hang?)"
          else "still running after " ++ seconds (t - t0) ++ ", ten times its " ++ show secs ++ " s, though the connection moves"
      , " at: ", at, ", for ", seconds (t - start)
      , " (from ", formatTime defaultTimeLocale "%H:%M:%S%3Q" wall, " UTC)"
      , " (the longest step before: ", slowest, ", ", seconds took, "; the test ran ", seconds (t - t0), ")"
      , "\n  2 s before, the test thread: ", before
      , "\n  client: ", client, "\n  server ", server ]

-- | What 'withinTraced' throws to the test's thread, as 'timeout' does.
data Stalled = Stalled Unique Double

instance Show Stalled where
  show (Stalled _ still) = "Stalled after " ++ seconds still

instance Exception Stalled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | A number that changes whenever the connection moves: the DATA packets
-- sent and received on its sessions, and the server's windows.  (Without
-- MARS, always 0.)
connectionProgress :: Connection -> IO Integer
connectionProgress conn = case connMars conn of
  Nothing -> pure 0
  Just m -> do
    sessions <- IntMap.elems <$> readIORef (marsOpen m)
    sent <- forM sessions $ \sess -> maybe (pure 0) (fmap toInteger . readIORef . smpSendSeq) (sessSmp sess)
    links <- IntMap.elems <$> readTVarIO (marsRegistry m)
    received <- forM links $ \l -> atomically $
      (\a b -> toInteger a + toInteger b) <$> readTVar (linkRecvSeq l) <*> readTVar (linkSendHighWater l)
    pure (sum sent + sum received + toInteger (length links))

-- | 'withinTraced' for a test of one connection: its identity is asked
-- for first (one request), and the body marks its steps with the function
-- it is given.
withinTracedOn :: Int -> Connection -> ((String -> IO ()) -> IO a) -> IO a
withinTracedOn secs conn body = do
  ident <- sessionIdentity conn
  steps <- newSteps "start"
  withinTraced secs conn ident steps (body (markStep steps))

-- | The kernel's send and receive queues of a TCP socket, from
-- @/proc/net/tcp@ and @/proc/net/tcp6@ (Linux), found by its local port.
socketQueues :: Socket.Socket -> IO String
socketQueues sock = do
  r <- try @SomeException $ do
    name <- Socket.getSocketName sock
    port <- case name of
      Socket.SockAddrInet p _ -> pure (fromIntegral p :: Int)
      Socket.SockAddrInet6 p _ _ _ -> pure (fromIntegral p)
      _ -> fail "not a TCP socket"
    tables <- mapM readFile ["/proc/net/tcp", "/proc/net/tcp6"]
    let hexPort = map toUpper (showHex port "")
        padded = replicate (4 - length hexPort) '0' ++ hexPort
        rows = [ws | t <- tables, l <- drop 1 (lines t), let ws = words l, length ws > 4
               , (':' : p) <- [dropWhile (/= ':') (ws !! 1)], p == padded]
    pure $ case rows of
      ws : _ -> case break (== ':') (ws !! 4) of
        (tx, ':' : rx) -> "send queue " ++ show (readHexInt tx) ++ " bytes, receive queue " ++ show (readHexInt rx) ++ " bytes"
        _ -> "queues unreadable"
      [] -> "no entry for port " ++ show port
  pure (either (\e -> "queues not known: " ++ show e) id r)
  where
    readHexInt h = case readHex h of
      [(n, "")] -> n :: Integer
      _ -> -1
