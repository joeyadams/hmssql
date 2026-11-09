{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE MultiWayIf #-}

-- | The mock TDS server ("MockServer") speaking SMP, the session multiplex
-- of a MARS connection (MC-SMP): it answers PRELOGIN with the MARS option
-- it is given, completes the login in plain TDS, and from then on reads
-- and writes SMP packets only.
--
-- Everything the client sends is recorded and checked, per session,
-- against what MC-SMP and SQL Server require of a client (see 'receive'):
-- a SYN only for a closed identifier at most one above the largest in use,
-- with SEQNUM 0; DATA SEQNUMs one more than the last, from 1, never beyond
-- the window the mock advertised (4 until it says otherwise); ACK and FIN
-- carrying the last DATA SEQNUM; WNDW never smaller than before; one whole
-- TDS packet in each DATA payload.  A breach is recorded as a violation,
-- not thrown, so a test sees them all in the outcome ('outViolations').
--
-- The mock's own DATA packets keep to the client's window: a response
-- longer than it waits for the client's ACKs.  By default the mock raises
-- its window as SQL Server does, as it receives (an ACK every second
-- packet, 4 ahead), and answers a client's FIN with its own; both can be
-- turned off, and a test can send anything at all ('sendSmpRaw').
--
-- > withSmpServer defaultSmpConfig $ \srv -> do
-- >   withConnection (smpConnectInfo srv) $ \conn -> query1 conn "SELECT 7"
-- >   out <- nextOutcome srv
-- >   outViolations out `shouldBe` []
module Mars.MockSmp
  ( -- * Running
    SmpConfig (..)
  , defaultSmpConfig
  , SmpServer (..)
  , withSmpServer
  , SmpOutcome (..)
  , preloginWithMars

    -- * The mock of one connection
  , SmpMock
  , mockConn
  , hangUp
  , dropConnection

    -- * What the client sent
  , SmpIn (..)
  , flagSyn
  , flagAck
  , flagFin
  , flagData
  , isData
  , isAck
  , isSyn
  , isFin
  , ClientMsg (..)
  , nextMessage
  , expectMessage
  , receivedSoFar
  , messagesSoFar
  , violationsSoFar
  , awaitReceived
  , awaitClientClose

    -- * Sending
  , answerRequests
  , respondOn
  , respondPackets
  , sendTdsPacket
  , tdsPackets
  , tdsPacket
  , raiseWindow
  , sendFin
  , stampData
  , sendSmpRaw
  , smpPacket
  , smpPacketWithLength

    -- * The mock's view of a session
  , MockSession (..)
  , mockSession
  , mockSessionIds
  , shiftSession
  , setAutoAck
  , setAutoFin

    -- * The client's view
  , openSessionIds
  , registrySize
  , registered
  , shiftClientSession
  , endedBy

    -- * Responses
  , longRows
  , partialSelects
  ) where

import UnusableCause (reasonCause)
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM_, forever, unless, when)
import qualified Data.Binary.Get as Get
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import Data.Bits ((.&.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Foldable (toList)
import Data.Int (Int32)
import Data.IORef
import Data.List (sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Word (Word16, Word32, Word8)
import qualified Network.Socket as Socket
import System.Timeout (timeout)
import Compat (timeoutInSlices)

import Concurrency.Mock (answerSelect, batchText, colMetaBigint, doneAttn, doneFinal, rowBigint, selectedNumber)
import Hmssql
import Hmssql.Connection.Internal (Connection (..), Mars (..), Session (..), SmpLink (..), SmpSession (..), withConnectionLock)
import Hmssql.Errors
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import MockServer

------------------------------------------------------------------------------
-- Running

data SmpConfig = SmpConfig
  { cfgMars :: !(Maybe Word8)
    -- ^ The MARS option in the PRELOGIN answer; 'Nothing' leaves it out.
    -- Anything but 1 means no SMP: a client that logs in all the same gets
    -- the login response and nothing more.  A client that doesn't log in
    -- (it refused the answer) is waited for to close.
  , cfgLoginResponse :: ![Put]
  , cfgAutoAck :: !Bool
    -- ^ Raise the mock's window as the client's DATA arrives, as SQL
    -- Server does: once it is at most 2 ahead, to 4 ahead, with an ACK.
  , cfgAutoFin :: !Bool
    -- ^ Answer a client's FIN with a FIN at once.
  , cfgRespond :: !(Maybe (SmpMock -> ClientMsg -> IO ()))
    -- ^ Called for each message the client sends, in order, by the
    -- handler's thread (which must not block: 'respondOn' queues).  With
    -- 'Nothing', nothing is answered, and the test reads the messages
    -- itself ('nextMessage').
  , cfgHoldLimit :: !Int
    -- ^ How long, in seconds, the handler waits for the client to close
    -- the connection before it records an error and closes it itself.
  }

-- | MARS granted, the default login response, the window raised and FINs
-- answered as SQL Server does, requests answered by 'answerRequests'.
defaultSmpConfig :: SmpConfig
defaultSmpConfig = SmpConfig
  { cfgMars = Just 1
  , cfgLoginResponse = defaultLoginResponse
  , cfgAutoAck = True
  , cfgAutoFin = True
  , cfgRespond = Just answerRequests
  , cfgHoldLimit = 60
  }

data SmpServer = SmpServer
  { smpConnectInfo :: !ConnectInfo
    -- ^ Settings that reach the server, with 'connectMars'.
  , nextMock :: IO SmpMock
    -- ^ The mock of the next connection to reach SMP, once it has taken
    -- the client's first packet (waits up to 10 s).
  , nextOutcome :: IO SmpOutcome
    -- ^ What the next connection's handler saw, once the client has
    -- closed the connection or 'hangUp' was called (waits up to 10 s).
  }

-- | What the mock saw of one connection.
data SmpOutcome = SmpOutcome
  { outPrelogin :: !Prelogin
    -- ^ The client's PRELOGIN.
  , outLoggedIn :: !Bool
    -- ^ The client sent LOGIN7.
  , outReceived :: ![SmpIn]
    -- ^ Every SMP packet the client sent, in order.
  , outMessages :: ![ClientMsg]
    -- ^ Every whole TDS message they carried, in order.
  , outViolations :: ![String]
    -- ^ What the client did wrong ('receive'), in order.
  , outErrors :: ![String]
    -- ^ Failures of the mock itself (a response the client's window never
    -- let through, a responder that threw).
  , outClientClosed :: !Bool
    -- ^ The client closed the connection.
  }

-- | Run a server whose every connection is handled as the configuration
-- says.
withSmpServer :: SmpConfig -> (SmpServer -> IO a) -> IO a
withSmpServer cfg act = do
  mocks <- newChan
  withMockServer (smpHandler cfg mocks) $ \srv -> act SmpServer
    { smpConnectInfo = (mockConnectInfo srv) { connectMars = True }
    , nextMock = timeout 10_000_000 (readChan mocks)
        >>= maybe (throwIO (MockUnexpected "no connection reached SMP in 10 s")) pure
    , nextOutcome = nextResult srv >>= either throwIO pure
    }

-- | 'preloginReply' for a client without encryption, with the given MARS
-- option, or none.
preloginWithMars :: Maybe Word8 -> Prelogin
preloginWithMars mars = Prelogin $
  [ PLVersion 17 0 1000 0
  , PLEncryption (encryptionWord EncryptNotSup)
  , PLInstance ""
  , PLThreadId Nothing
  ] ++ [PLMars m | Just m <- [mars]]

smpHandler :: SmpConfig -> Chan SmpMock -> MockConn -> IO SmpOutcome
smpHandler cfg mocks mc = do
  clientPrelogin <- respondPrelogin (preloginWithMars (cfgMars cfg)) mc
  step <- awaitLogin7 mc
  let loggedIn = case step of
        ClientSentLogin7 _ -> True
        _ -> False
  if not loggedIn || cfgMars cfg /= Just 1
    then do
      -- Whatever the client does next, until it closes.
      closed <- if loggedIn
        then do
          sendTokens mc (cfgLoginResponse cfg)
          isJust <$> timeout 30_000_000 (drainUntilClosed mc)
        else pure (step == ClientClosed)
      pure SmpOutcome
        { outPrelogin = clientPrelogin, outLoggedIn = loggedIn, outReceived = [], outMessages = []
        , outViolations = [], outErrors = [], outClientClosed = closed }
    else do
      sendTokens mc (cfgLoginResponse cfg)
      m <- newSmpMock cfg mc
      reader <- forkIO (readerLoop m `catch` \(e :: SomeException) -> case fromException e of
        Just ThreadKilled -> pure ()
        _ -> recordError m ("mock reader: " ++ show e) >> atomically (writeTVar (smEof m) True))
      -- Handed over once the client's first packet (its SYN) has been
      -- taken, so that the test finds session 0 open on the mock.
      _ <- timeout 10_000_000 $ atomically $
        (readTVar (smReceived m) >>= check . not . null) `orElse` (readTVar (smEof m) >>= check)
      writeChan mocks m
      let ended =(readTVar (smEof m) >>= check) `orElse` (readTVar (smHungUp m) >>= check)
          serve respond = do
            next <- atomically $ (Just <$> readTQueue (smInbox m)) `orElse` (Nothing <$ ended)
            forM_ next $ \msg -> do
              respond m msg `catch` \(e :: SomeException) -> recordError m ("responder: " ++ show e)
              serve respond
      finished <- timeout (cfgHoldLimit cfg * 1_000_000) $ case cfgRespond cfg of
        Just respond -> serve respond
        Nothing -> atomically ended
      when (isNothing finished) $ recordError m ("the client kept the connection open for " ++ show (cfgHoldLimit cfg) ++ " s")
      killThread reader
      readIORef (smThreads m) >>= mapM_ killThread
      atomically $ do
        received <- reverse <$> readTVar (smReceived m)
        messages <- reverse <$> readTVar (smMessages m)
        violations <- reverse <$> readTVar (smViolations m)
        errors <- reverse <$> readTVar (smErrors m)
        closed <- readTVar (smEof m)
        pure SmpOutcome
          { outPrelogin = clientPrelogin, outLoggedIn = True, outReceived = received, outMessages = messages
          , outViolations = violations, outErrors = errors, outClientClosed = closed }
  where
    drainUntilClosed c = recvBytes c 1 >>= maybe (pure ()) (\_ -> drainUntilClosed c)

------------------------------------------------------------------------------
-- The mock of one connection

data SmpMock = SmpMock
  { smConn :: !MockConn
  , smSessions :: !(TVar [(Word16, MockSession)])
    -- ^ The sessions open or closing, by identifier.
  , smReceived :: !(TVar [SmpIn])
    -- ^ Newest first.
  , smMessages :: !(TVar [ClientMsg])
    -- ^ Newest first.
  , smInbox :: !(TQueue ClientMsg)
    -- ^ The messages not yet taken by the responder or 'nextMessage'.
  , smViolations :: !(TVar [String])
  , smErrors :: !(TVar [String])
  , smEof :: !(TVar Bool)
  , smHungUp :: !(TVar Bool)
  , smAutoAck :: !(TVar Bool)
  , smAutoFin :: !(TVar Bool)
  , smSendLock :: !(MVar ())
    -- ^ Held for each write to the socket, with the state it stamps.
  , smOutboxes :: !(MVar [(Word16, TQueue [B.ByteString])])
    -- ^ Each session's queue of responses, sent in order by a thread of
    -- its own ('respondPackets').
  , smThreads :: !(IORef [ThreadId])
  }

-- | The socket, for 'shutdownSend' (and 'sendRaw', though 'sendSmpRaw'
-- keeps to the mock's send lock).
mockConn :: SmpMock -> MockConn
mockConn = smConn

newSmpMock :: SmpConfig -> MockConn -> IO SmpMock
newSmpMock cfg smConn = do
  smSessions <- newTVarIO []
  smReceived <- newTVarIO []
  smMessages <- newTVarIO []
  smInbox <- newTQueueIO
  smViolations <- newTVarIO []
  smErrors <- newTVarIO []
  smEof <- newTVarIO False
  smHungUp <- newTVarIO False
  smAutoAck <- newTVarIO (cfgAutoAck cfg)
  smAutoFin <- newTVarIO (cfgAutoFin cfg)
  smSendLock <- newMVar ()
  smOutboxes <- newMVar []
  smThreads <- newIORef []
  pure SmpMock{..}

-- | End the handler (the socket is then closed), whatever the client does.
hangUp :: SmpMock -> IO ()
hangUp m = atomically $ writeTVar (smHungUp m) True

-- | Shut the connection down both ways, at once: the client's reads see
-- the end of the stream, and its sends fail.  The socket itself is closed
-- (with a reset) when the handler ends, once the mock's reader thread has
-- stopped.  Not 'resetConnection', which closes the socket under the
-- reader: a thread that starts to wait on a descriptor just after it was
-- closed leaves a stale registration in GHC's IO manager (before 9.14),
-- and the next socket given that number (the mock's next connection)
-- then never wakes its reader (see 'Hmssql.Connection.Internal.closeSocket').
dropConnection :: SmpMock -> IO ()
dropConnection m = case mcSocketMaybe (smConn m) of
  Just sock -> Socket.shutdown sock Socket.ShutdownBoth `catch` \(_ :: IOException) -> pure ()
  -- A pipe has no shutdown.  It is disconnected and closed at once, which
  -- is safe under the mock's reader there: the close waits for a receive
  -- in progress to end.
  Nothing -> resetConnection (smConn m)

recordError :: SmpMock -> String -> IO ()
recordError m e = atomically $ modifyTVar' (smErrors m) (e :)

setAutoAck, setAutoFin :: SmpMock -> Bool -> IO ()
setAutoAck m = atomically . writeTVar (smAutoAck m)
setAutoFin m = atomically . writeTVar (smAutoFin m)

------------------------------------------------------------------------------
-- What the client sent

-- | One SMP packet, as received.
data SmpIn = SmpIn
  { inFlags :: !Word8
  , inSid :: !Word16
  , inLength :: !Word32
  , inSeq :: !Word32
  , inWindow :: !Word32
  , inPayload :: !B.ByteString
  }
  deriving stock (Eq, Show)

flagSyn, flagAck, flagFin, flagData :: Word8
flagSyn = 0x01
flagAck = 0x02
flagFin = 0x04
flagData = 0x08

isData, isAck, isSyn, isFin :: SmpIn -> Bool
isData = (== flagData) . inFlags
isAck = (== flagAck) . inFlags
isSyn = (== flagSyn) . inFlags
isFin = (== flagFin) . inFlags

-- | A whole TDS message the client sent on a session.
data ClientMsg = ClientMsg
  { cmSid :: !Word16
  , cmType :: !PacketType
  , cmReset :: !Bool
    -- ^ The first packet carries RESETCONNECTION.
  , cmBody :: !B.ByteString
  }
  deriving stock (Eq, Show)

-- | The next message the client sends (on any session), waiting at most
-- that many microseconds.  Throws 'MockClientClosed' once the client has
-- closed the connection and every message was taken.  Only with no
-- responder ('cfgRespond').
nextMessage :: SmpMock -> Int -> IO (Maybe ClientMsg)
nextMessage m micros = timeoutInSlices micros (atomically next) >>= \case
  Nothing -> pure Nothing
  Just Nothing -> throwIO MockClientClosed
  Just (Just msg) -> pure (Just msg)
  where
    next = (Just <$> readTQueue (smInbox m)) `orElse` (Nothing <$ (readTVar (smEof m) >>= check))

-- | 'nextMessage', waiting up to 10 s, and throwing if none came.
expectMessage :: SmpMock -> IO ClientMsg
expectMessage m = nextMessage m 10_000_000 >>= maybe (throwIO (MockUnexpected "no message from the client in 10 s")) pure

receivedSoFar :: SmpMock -> IO [SmpIn]
receivedSoFar m = reverse <$> readTVarIO (smReceived m)

messagesSoFar :: SmpMock -> IO [ClientMsg]
messagesSoFar m = reverse <$> readTVarIO (smMessages m)

violationsSoFar :: SmpMock -> IO [String]
violationsSoFar m = reverse <$> readTVarIO (smViolations m)

-- | Wait until what the client has sent satisfies the predicate, at most
-- that many microseconds; whether it did.
awaitReceived :: SmpMock -> Int -> ([SmpIn] -> Bool) -> IO Bool
awaitReceived m micros p = isJust <$> timeout micros (atomically (readTVar (smReceived m) >>= check . p . reverse))

-- | Wait until the client has closed the connection, at most that many
-- microseconds; whether it did.
awaitClientClose :: SmpMock -> Int -> IO Bool
awaitClientClose m micros = isJust <$> timeout micros (atomically (readTVar (smEof m) >>= check))

-- | Read, record and check SMP packets until the client closes the
-- connection.  A packet that can't be framed (not SMP, too short) ends the
-- checking: the rest is read and dropped.
readerLoop :: SmpMock -> IO ()
readerLoop m = loop
  where
    mc = smConn m
    loop = recvBytes mc 16 >>= \case
      Nothing -> eof
      Just hdr -> do
        let (smid, flags, sid, len, sq, wnd) = Get.runGet getSmpHeader (LB.fromStrict hdr)
        if
          | smid /= 0x53 -> do
              violation ("a packet that is not SMP (its first byte is " ++ show smid ++ ")")
              discard
          | len < 16 -> do
              violation ("an SMP packet of length " ++ show len)
              discard
          | otherwise -> recvBytes mc (fromIntegral len - 16) >>= \case
              Nothing -> violation "the client closed the connection in the middle of an SMP packet" >> eof
              Just payload -> do
                handle (SmpIn flags sid len sq wnd payload)
                loop
    eof = atomically $ writeTVar (smEof m) True
    discard = recvBytes mc 1 >>= maybe eof (const discard)
    violation v = atomically $ modifyTVar' (smViolations m) (v :)

    handle p = do
      (accepted, finned) <- atomically $ do
        modifyTVar' (smReceived m) (p :)
        sessions <- readTVar (smSessions m)
        let (errs, sessions', msg) = receive sessions p
        writeTVar (smSessions m) sessions'
        modifyTVar' (smViolations m) (reverse errs ++)
        forM_ msg $ \x -> modifyTVar' (smMessages m) (x :) >> writeTQueue (smInbox m) x
        autoAck <- readTVar (smAutoAck m)
        autoFin <- readTVar (smAutoFin m)
        let now = lookup (inSid p) sessions'
            ackTo = case now of
              Just s | autoAck, isData p, null errs, diff (msServerWindow s) (msClientSeq s) <= 2 -> Just (msClientSeq s + 4)
              _ -> Nothing
        pure (ackTo, autoFin && isFin p && null errs)
      forM_ accepted $ raiseWindow m (inSid p)
      when finned $ sendFin m (inSid p)

-- | SMID, flags, SID, length, SEQNUM, WNDW.
getSmpHeader :: Get.Get (Word8, Word8, Word16, Word32, Word32, Word32)
getSmpHeader =
  (,,,,,) <$> Get.getWord8 <*> Get.getWord8 <*> Get.getWord16le <*> Get.getWord32le <*> Get.getWord32le <*> Get.getWord32le

-- | @a - b@ as a signed difference: sequence numbers and windows are
-- compared modulo 2^32.
diff :: Word32 -> Word32 -> Int32
diff a b = fromIntegral (a - b)

------------------------------------------------------------------------------
-- The mock's view of a session

data MockSession = MockSession
  { msClientSeq :: !Word32
    -- ^ The SEQNUM of the client's last DATA packet.
  , msClientWindow :: !Word32
    -- ^ The client's WNDW: the highest SEQNUM the mock may send.
  , msServerSeq :: !Word32
    -- ^ The SEQNUM of the mock's last DATA packet.
  , msServerWindow :: !Word32
    -- ^ The window the mock advertised: the highest SEQNUM the client may
    -- send.
  , msClientFin :: !Bool
    -- ^ The client sent a FIN, which the mock hasn't answered.
  , msPartial :: ![B.ByteString]
    -- ^ The packets of the message being received, newest first.
  }
  deriving stock (Show)

-- | A client's packet: the violations it commits, the sessions after it,
-- and the message it completes.  The checks are MC-SMP's and SQL
-- Server's.
receive :: [(Word16, MockSession)] -> SmpIn -> ([String], [(Word16, MockSession)], Maybe ClientMsg)
receive sessions SmpIn{..}
  | inFlags == flagSyn = syn
  | inFlags == flagAck = withOpen "ACK" $ \s -> (control "ACK" s, s, Nothing)
  | inFlags == flagFin = withOpen "FIN" $ \s -> (control "FIN" s, s { msClientFin = True }, Nothing)
  | inFlags == flagData = withOpen "DATA" dataPacket
  | otherwise = (["session " ++ show inSid ++ ": a packet with flags " ++ show inFlags], sessions, Nothing)
  where
    at = "session " ++ show inSid ++ ": "
    existing = lookup inSid sessions
    largest = maximum ((-1) : map (fromIntegral . fst) sessions) :: Int

    syn =
      let errs =
            [ at ++ "a SYN for a session that is open" | Just s <- [existing], not (msClientFin s) ]
              ++ [ at ++ "a SYN before the server's FIN answered the client's" | Just s <- [existing], msClientFin s ]
              ++ [ at ++ "a SYN more than one above the largest session in use, " ++ show largest
                 | fromIntegral inSid > largest + 1 ]
              ++ [ at ++ "a SYN with SEQNUM " ++ show inSeq | inSeq /= 0 ]
              ++ [ at ++ "a SYN of length " ++ show inLength | inLength /= 16 ]
          -- Before its peer says otherwise, a session's window is 4
          -- (MC-SMP 3.1.3).
          new = MockSession { msClientSeq = 0, msClientWindow = inWindow, msServerSeq = 0, msServerWindow = 4
                            , msClientFin = False, msPartial = [] }
       in (errs, if isJust existing then sessions else sortOn fst ((inSid, new) : sessions), Nothing)

    withOpen what k = case existing of
      Nothing -> ([at ++ "a " ++ what ++ " for a session that is not open"], sessions, Nothing)
      Just s
        | msClientFin s -> ([at ++ "a " ++ what ++ " after the client's FIN"], sessions, Nothing)
        | otherwise ->
            let shrank = diff inWindow (msClientWindow s) < 0
                windowErrs = [ at ++ "a " ++ what ++ " with WNDW " ++ show inWindow ++ ", less than the "
                                 ++ show (msClientWindow s) ++ " before" | shrank ]
                s1 = if shrank then s else s { msClientWindow = inWindow }
                (errs, s2, msg) = k s1
             in (windowErrs ++ errs, map (\(i, x) -> if i == inSid then (i, s2) else (i, x)) sessions, msg)

    control what s =
      [ at ++ "a " ++ what ++ " with SEQNUM " ++ show inSeq ++ ", not the last DATA's " ++ show (msClientSeq s)
      | inSeq /= msClientSeq s ]
        ++ [ at ++ "a " ++ what ++ " of length " ++ show inLength | inLength /= 16 ]

    dataPacket s =
      let seqErrs =
            [ at ++ "DATA with SEQNUM " ++ show inSeq ++ " after " ++ show (msClientSeq s) | inSeq /= msClientSeq s + 1 ]
              ++ [ at ++ "DATA with SEQNUM " ++ show inSeq ++ ", beyond the window " ++ show (msServerWindow s)
                 | diff (msServerWindow s) inSeq < 0 ]
          tdsLen = if B.length inPayload >= 8 then Just (fromIntegral (B.index inPayload 2) * 256 + fromIntegral (B.index inPayload 3)) else Nothing
          tdsErrs = case tdsLen of
            Just n | n == B.length inPayload -> []
            _ -> [ at ++ "a DATA payload of " ++ show (B.length inPayload) ++ " bytes that is not one TDS packet (its length field says "
                     ++ maybe "nothing" show tdsLen ++ ")" ]
          s' = s { msClientSeq = inSeq }
       in if not (null tdsErrs)
            then (seqErrs ++ tdsErrs, s', Nothing)
            else
              let hdr = readHeader inPayload
                  partial = inPayload : msPartial s
                  PacketStatus st = headerStatus hdr
               in if st .&. 0x01 /= 0
                    then
                      let packets = reverse partial
                          first = readHeader (last partial)
                          PacketStatus st0 = headerStatus first
                          msg = ClientMsg
                            { cmSid = inSid, cmType = headerType first, cmReset = st0 .&. 0x08 /= 0
                            , cmBody = B.concat (map (B.drop headerLength) packets) }
                       in (seqErrs, s' { msPartial = [] }, Just msg)
                    else (seqErrs, s' { msPartial = partial }, Nothing)

-- | The mock's state of the session, if it is open or closing.
mockSession :: SmpMock -> Word16 -> IO (Maybe MockSession)
mockSession m sid = lookup sid <$> readTVarIO (smSessions m)

-- | The sessions open (or closing, if the client sent a FIN) on the mock.
mockSessionIds :: SmpMock -> IO [Word16]
mockSessionIds m = map fst <$> readTVarIO (smSessions m)

-- | Add the offset to every sequence number and window of the session, as
-- if that many packets had gone each way: to test the arithmetic modulo
-- 2^32.  The client's state must be shifted alike, with nothing in flight.
shiftSession :: SmpMock -> Word16 -> Word32 -> IO ()
shiftSession m sid k = atomically $ modifyTVar' (smSessions m) $ map $ \(i, s) ->
  if i /= sid then (i, s) else
    (i, s { msClientSeq = msClientSeq s + k, msClientWindow = msClientWindow s + k
          , msServerSeq = msServerSeq s + k, msServerWindow = msServerWindow s + k })

------------------------------------------------------------------------------
-- Sending

-- | Answer as a simple server does, on the message's session: @SELECT n@
-- with @n@ (a bigint column), an Attention with its acknowledgement, and
-- anything else with a final DONE.
answerRequests :: SmpMock -> ClientMsg -> IO ()
answerRequests m ClientMsg{..} = respondOn m cmSid $ case cmType of
  PTAttention -> [doneAttn]
  PTSqlBatch | Just n <- selectedNumber (batchText cmBody) -> answerSelect n
  _ -> [doneFinal 0]

-- | As 'answerRequests', but a @SELECT n@ is answered with the first
-- packet of its response only (the column, the row, no END_OF_MESSAGE):
-- a statement still running, whose reader waits.
partialSelects :: SmpMock -> ClientMsg -> IO ()
partialSelects m msg@ClientMsg{..} = case cmType of
  PTSqlBatch | Just n <- selectedNumber (batchText cmBody) ->
    respondPackets m cmSid [tdsPacket False (LB.toStrict (Put.runPut (colMetaBigint "" >> rowBigint n)))]
  _ -> answerRequests m msg

-- | A result of @n@ rows, 1 to @n@, in a bigint column.
longRows :: Int -> [Put]
longRows n = colMetaBigint "" : map (rowBigint . fromIntegral) [1 .. n] ++ [doneFinal n]

-- | Queue a tabular-result message, in packets of 4096 bytes, on the
-- session ('respondPackets').
respondOn :: SmpMock -> Word16 -> [Put] -> IO ()
respondOn m sid = respondPackets m sid . tdsPackets 4096

-- | Queue TDS packets to be sent as DATA on the session, after those
-- queued before, by the session's own thread, each as soon as the
-- client's window lets it ('sendTdsPacket').  Returns at once.
respondPackets :: SmpMock -> Word16 -> [B.ByteString] -> IO ()
respondPackets m sid packets = do
  q <- modifyMVar (smOutboxes m) $ \boxes -> case lookup sid boxes of
    Just q -> pure (boxes, q)
    Nothing -> do
      q <- newTQueueIO
      let worker = forever (atomically (readTQueue q) >>= mapM_ (sendTdsPacket m sid))
      t <- forkIO $ worker `catch` \(e :: SomeException) -> case fromException e of
        Just ThreadKilled -> pure ()
        _ -> recordError m ("session " ++ show sid ++ ": " ++ show e)
      atomicModifyIORef' (smThreads m) (\ts -> (t : ts, ()))
      pure ((sid, q) : boxes, q)
  atomically $ writeTQueue q packets

-- | The body as a tabular-result message, in packets of the given size.
tdsPackets :: Int -> [Put] -> [B.ByteString]
tdsPackets size toks =
  splitIntoPackets defaultTdsContext { tdsPacketSize = fromIntegral size } PTTabularResult (PacketStatus 0)
    (Put.runPut (sequence_ toks))

-- | One tabular-result packet with the given body, END_OF_MESSAGE if asked.
tdsPacket :: Bool -> B.ByteString -> B.ByteString
tdsPacket eom body = LB.toStrict $ Put.runPut $ do
  putHeader Header
    { headerType = PTTabularResult
    , headerStatus = if eom then statusEndOfMessage else PacketStatus 0
    , headerPacketLength = fromIntegral (B.length body + headerLength)
    , headerSpid = 0
    , headerPacketId = 1
    , headerWindow = 0
    }
  Put.putByteString body

-- | Send a TDS packet as the session's next DATA packet, with the mock's
-- window, once the client's window has room for it (waiting up to 20 s).
sendTdsPacket :: SmpMock -> Word16 -> B.ByteString -> IO ()
sendTdsPacket m sid packet = timeoutInSlices 20_000_000 go >>= \case
  Just () -> pure ()
  Nothing -> throwIO (MockUnexpected ("session " ++ show sid ++ ": the client's window stayed shut for 20 s"))
  where
    room s = diff (msClientWindow s) (msServerSeq s) > 0
    go = do
      atomically $ readTVar (smSessions m) >>= \sessions -> case lookup sid sessions of
        Nothing -> throwSTM (MockUnexpected ("session " ++ show sid ++ " is not open"))
        Just s -> check (room s)
      sent <- withMVar (smSendLock m) $ \() -> do
        stamped <- atomically $ readTVar (smSessions m) >>= \sessions -> case lookup sid sessions of
          Just s | room s -> do
            let n = msServerSeq s + 1
            writeTVar (smSessions m) (update sid s { msServerSeq = n } sessions)
            pure (Just (smpPacket flagData sid n (msServerWindow s) packet))
          _ -> pure Nothing
        mapM_ (sendRaw (smConn m)) stamped
        pure (isJust stamped)
      unless sent go

-- | The session's next DATA packet carrying the TDS packet, as bytes to
-- send ('sendSmpRaw'): its SEQNUM is taken now, whatever the client's
-- window.  For a test that sends packets its own way (split, say).
stampData :: SmpMock -> Word16 -> B.ByteString -> IO B.ByteString
stampData m sid packet = atomically $ readTVar (smSessions m) >>= \sessions -> case lookup sid sessions of
  Nothing -> throwSTM (MockUnexpected ("session " ++ show sid ++ " is not open"))
  Just s -> do
    let n = msServerSeq s + 1
    writeTVar (smSessions m) (update sid s { msServerSeq = n } sessions)
    pure (smpPacket flagData sid n (msServerWindow s) packet)

-- | Raise the mock's window on the session to the given SEQNUM, with an
-- ACK (which carries it whatever it is: to send a smaller one, which
-- breaks the protocol, use 'sendSmpRaw').
raiseWindow :: SmpMock -> Word16 -> Word32 -> IO ()
raiseWindow m sid w = withMVar (smSendLock m) $ \() -> do
  sq <- atomically $ readTVar (smSessions m) >>= \sessions -> case lookup sid sessions of
    Nothing -> throwSTM (MockUnexpected ("session " ++ show sid ++ " is not open"))
    Just s -> do
      writeTVar (smSessions m) (update sid s { msServerWindow = w } sessions)
      pure (msServerSeq s)
  sendRaw (smConn m) (smpPacket flagAck sid sq w B.empty)

-- | Close the session with a FIN: the answer to the client's, or, for a
-- session the client didn't close, the end of the connection.
sendFin :: SmpMock -> Word16 -> IO ()
sendFin m sid = withMVar (smSendLock m) $ \() -> do
  (sq, w) <- atomically $ readTVar (smSessions m) >>= \sessions -> case lookup sid sessions of
    Nothing -> throwSTM (MockUnexpected ("session " ++ show sid ++ " is not open"))
    Just s -> do
      writeTVar (smSessions m) (filter ((/= sid) . fst) sessions)
      pure (msServerSeq s, msServerWindow s)
  sendRaw (smConn m) (smpPacket flagFin sid sq w B.empty)

-- | Send bytes as they are, between the mock's own packets.
sendSmpRaw :: SmpMock -> B.ByteString -> IO ()
sendSmpRaw m bs = withMVar (smSendLock m) $ \() -> sendRaw (smConn m) bs

-- | An SMP packet: flags, SID, SEQNUM, WNDW and payload.
smpPacket :: Word8 -> Word16 -> Word32 -> Word32 -> B.ByteString -> B.ByteString
smpPacket flags sid sq w payload = smpPacketWithLength flags sid (fromIntegral (16 + B.length payload)) sq w payload

-- | 'smpPacket' with the given length field, whatever the payload's.
smpPacketWithLength :: Word8 -> Word16 -> Word32 -> Word32 -> Word32 -> B.ByteString -> B.ByteString
smpPacketWithLength flags sid len sq w payload = LB.toStrict $ Put.runPut $ do
  Put.putWord8 0x53
  Put.putWord8 flags
  Put.putWord16le sid
  Put.putWord32le len
  Put.putWord32le sq
  Put.putWord32le w
  Put.putByteString payload

update :: Word16 -> MockSession -> [(Word16, MockSession)] -> [(Word16, MockSession)]
update sid s = map (\(i, x) -> if i == sid then (i, s) else (i, x))

------------------------------------------------------------------------------
-- The client's view

-- | The identifiers of the connection's open SMP sessions, lowest first.
openSessionIds :: Connection -> IO [Word16]
openSessionIds conn = case connMars conn of
  Nothing -> pure []
  Just mars -> do
    sessions <- toList <$> readIORef (marsOpen mars)
    pure [smpSid smp | Just smp <- map sessSmp sessions]

-- | How many sessions the connection's registry holds: open, and closing
-- (a FIN sent and not yet answered).
registrySize :: Connection -> IO Int
registrySize conn = case connMars conn of
  Nothing -> pure 0
  Just mars -> length <$> readTVarIO (marsRegistry mars)

-- | Whether the open session with this identifier is in the registry
-- (shared with the reader thread), so that the client knows the server
-- has it.
registered :: Connection -> Word16 -> IO Bool
registered conn sid = case connMars conn of
  Nothing -> pure False
  Just mars -> do
    sessions <- toList <$> readIORef (marsOpen mars)
    links <- toList <$> readTVarIO (marsRegistry mars)
    pure $ or [ linkSendHighWater (smpLink smp) == linkSendHighWater l
              | Just smp <- map sessSmp sessions, smpSid smp == sid, l <- links ]

-- | Add the offset to every sequence number and window of the client's
-- session, as 'shiftSession' does to the mock's.  Nothing may be in
-- flight on it.
shiftClientSession :: Connection -> Word16 -> Word32 -> IO ()
shiftClientSession conn sid k = withConnectionLock conn $ forM_ (connMars conn) $ \mars -> do
  sessions <- toList <$> readIORef (marsOpen mars)
  forM_ [smp | Just smp <- map sessSmp sessions, smpSid smp == sid] $ \smp -> do
    modifyIORef' (smpSendSeq smp) (+ k)
    modifyIORef' (smpAdvertised smp) (+ k)
    let link = smpLink smp
    atomically $ do
      modifyTVar' (linkSendHighWater link) (+ k)
      modifyTVar' (linkRecvSeq link) (+ k)
      modifyTVar' (linkRecvHighWater link) (+ k)

-- | The exception is the expected one, directly or as the cause of a
-- 'ConnectionBroken' (what a use after the first failure throws).
endedBy :: (SomeException -> Bool) -> SomeException -> Bool
endedBy expected e = expected e || case fromException e of
  Just (ConnectionBroken (reasonCause -> cause)) -> expected cause
  Nothing -> False
