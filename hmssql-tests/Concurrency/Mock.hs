{-# LANGUAGE DerivingStrategies #-}

-- | A scripted mock TDS server for the concurrency tests: the script sees the
-- client's messages on a channel (so it can wait with a timeout, count
-- Attentions, or pause mid-response) and sends whole messages or single
-- packets (with or without END_OF_MESSAGE, even splitting a token).
module Concurrency.Mock
  ( MockIO (..)
  , ClientMessage
  , scripted
  , withScripted
    -- * Requests
  , batchText
  , tmBeginLevel
  , selectedNumber
  , serveSelects
  , expectBatch
  , expectTmBegin
  , expectAttention
  , collectFor
    -- * Tokens
  , colMetaBigint
  , rowBigint
  , doneFinal
  , doneMore
  , doneAttn
  , infoMsg
  , answerSelect
  , tokenBytes
  ) where

import Control.Concurrent
import Control.Exception
import Control.Monad (forever)
import qualified Data.Binary.Put as Put
import Data.Binary.Put (Put)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word8)
import System.IO.Error (isResourceVanishedError)
import Compat (timeoutInSlices)
import Text.Read (readMaybe)

import Hmssql
import Hmssql.Types
import Hmssql.Tds.Packet
import MockServer

type ClientMessage = (PacketType, B.ByteString)

data MockIO = MockIO
  { mRecv :: Int -> IO (Maybe ClientMessage)
    -- ^ The client's next message, waiting at most that many microseconds.
    -- Throws 'MockClientClosed' if the client closed the connection.
  , mSendPacket :: Bool -> B.ByteString -> IO ()
    -- ^ One tabular-result packet with the given body; the flag is
    -- END_OF_MESSAGE.
  , mSendMessage :: [Put] -> IO ()
    -- ^ A whole tabular-result message.
  }

-- | Log in, then run the script.
scripted :: (MockIO -> IO r) -> MockConn -> IO r
scripted script mc = do
  _ <- serveLogin defaultLoginResponse mc
  chan <- newChan
  let reader = forever $ (recvMessageMaybe mc `catch` reset) >>= \case
        Nothing -> writeChan chan Nothing >> throwIO MockClientClosed
        Just m -> writeChan chan (Just m)
      -- A client that closes the connection with data it has not read (an
      -- acknowledgement that a broken connection never reads, say) resets
      -- it instead: that is the client closing too.  Otherwise the reader
      -- would stop without a word, and the script would wait for a message
      -- that never comes.
      reset e
        | isResourceVanishedError e = pure Nothing
        | otherwise = throwIO e
      mRecv micros = timeoutInSlices micros (readChan chan) >>= \case
        Nothing -> pure Nothing
        Just Nothing -> writeChan chan Nothing >> throwIO MockClientClosed
        Just (Just m) -> pure (Just m)
      mSendPacket eom body = sendRaw mc $ LB.toStrict $ Put.runPut $ do
        putHeader Header
          { headerType = PTTabularResult
          , headerStatus = if eom then statusEndOfMessage else PacketStatus 0
          , headerPacketLength = fromIntegral (B.length body + headerLength)
          , headerSpid = 0
          , headerPacketId = 1
          , headerWindow = 0
          }
        Put.putByteString body
      mSendMessage = sendTokens mc
  bracket (forkIO (reader `catch` \(_ :: SomeException) -> pure ())) killThread $ \_ -> script MockIO{..}

-- | Run a scripted server; the client action gets settings that reach it,
-- and the script's outcome is returned alongside the client's.
withScripted :: (MockIO -> IO r) -> (ConnectInfo -> IO a) -> IO (a, Either SomeException r)
withScripted script client = withMockServer (scripted script) $ \srv -> do
  a <- client (mockConnectInfo srv)
  r <- nextResult srv
  pure (a, r)

-- | The SQL text of a SQL batch message (after ALL_HEADERS).
batchText :: B.ByteString -> Text
batchText body = T.decodeUtf16LE (afterAllHeaders body)

-- | A request message's body after its ALL_HEADERS (whose first four bytes
-- are its total length).
afterAllHeaders :: B.ByteString -> B.ByteString
afterAllHeaders body =
  let total = fromIntegral (B.foldr' (\w acc -> acc * 256 + fromIntegral w) (0 :: Integer) (B.take 4 body))
   in B.drop total body

-- | The isolation-level byte of a Transaction Manager request that begins a
-- transaction (TM_BEGIN_XACT, request type 5, with an empty name); Nothing
-- for any other body.
tmBeginLevel :: B.ByteString -> Maybe Word8
tmBeginLevel body = case B.unpack (afterAllHeaders body) of
  [5, 0, level, 0] -> Just level
  _ -> Nothing

-- | The client's next message must be a Transaction Manager request that
-- begins a transaction; returns its isolation-level byte.
expectTmBegin :: MockIO -> IO Word8
expectTmBegin io = mRecv io 10_000_000 >>= \case
  Just (PTTransactionManager, body) | Just level <- tmBeginLevel body -> pure level
  other -> throwIO (MockUnexpected ("expected TM_BEGIN_XACT, got " ++ show (fmap fst other)))

-- | @n@ for a batch @SELECT n@.
selectedNumber :: Text -> Maybe Int64
selectedNumber sql = case T.words sql of
  ["SELECT", n] -> readMaybe (T.unpack n)
  _ -> Nothing

-- | The client's next message must be a SQL batch; returns its text.
expectBatch :: MockIO -> IO Text
expectBatch io = mRecv io 10_000_000 >>= \case
  Just (PTSqlBatch, body) -> pure (batchText body)
  other -> throwIO (MockUnexpected ("expected a SQL batch, got " ++ show (fmap fst other)))

expectAttention :: MockIO -> IO ()
expectAttention io = mRecv io 10_000_000 >>= \case
  Just (PTAttention, _) -> pure ()
  other -> throwIO (MockUnexpected ("expected an Attention, got " ++ show (fmap fst other)))

-- | Every message the client sends in the next @micros@ microseconds.
collectFor :: MockIO -> Int -> IO [ClientMessage]
collectFor io micros = go micros
  where
    go left
      | left <= 0 = pure []
      | otherwise = do
          let step = min left 20_000
          mRecv io step >>= \case
            Nothing -> go (left - step)
            Just m -> (m :) <$> go (left - step)

-- | Answer @SELECT n@ batches with @n@ (a bigint column) and acknowledge
-- Attentions, until the client closes the connection.  Returns the SQL of
-- every batch.
serveSelects :: MockIO -> IO [Text]
serveSelects io = go []
  where
    go acc = do
      r <- try (mRecv io 30_000_000)
      case r of
        Left MockClientClosed -> pure (reverse acc)
        Left e -> throwIO e
        Right Nothing -> throwIO (MockUnexpected "client idle for 30 s")
        Right (Just (PTAttention, _)) -> mSendMessage io [doneAttn] >> go acc
        Right (Just (PTSqlBatch, body)) -> do
          let sql = batchText body
          case selectedNumber sql of
            Just n -> mSendMessage io (answerSelect n)
            Nothing -> mSendMessage io [doneFinal 0]
          go (sql : acc)
        Right (Just (ptype, _)) -> throwIO (MockUnexpected ("unexpected " ++ show ptype))

------------------------------------------------------------------------------
-- Tokens

-- | COLMETADATA for one nullable bigint column.
colMetaBigint :: Text -> Put
colMetaBigint name = do
  Put.putWord8 0x81
  Put.putWord16le 1
  Put.putWord32le 0          -- UserType
  Put.putWord16le 0x0001     -- Flags: nullable
  Put.putWord8 0x26 >> Put.putWord8 8  -- INTN(8)
  let bs = T.encodeUtf16LE name
  Put.putWord8 (fromIntegral (B.length bs `div` 2))
  Put.putByteString bs

-- | ROW for 'colMetaBigint'.
rowBigint :: Int64 -> Put
rowBigint n = Put.putWord8 0xD1 >> Put.putWord8 8 >> Put.putInt64le n

-- | A final DONE (with a row count).
doneFinal :: Int -> Put
doneFinal rows = doneToken 0x0010 (fromIntegral rows)

-- | A DONE with the MORE bit (another statement follows).
doneMore :: Int -> Put
doneMore rows = doneToken 0x0011 (fromIntegral rows)

-- | The Attention acknowledgement: a DONE with the ATTN bit.
doneAttn :: Put
doneAttn = doneToken 0x0020 0

infoMsg :: Text -> Put
infoMsg t = infoToken ServerMessage
  { msgNumber = 0, msgState = 1, msgClass = 0, msgText = t, msgServer = "mock", msgProcedure = "", msgLine = 1 }

answerSelect :: Int64 -> [Put]
answerSelect n = [colMetaBigint "", rowBigint n, doneFinal 1]

tokenBytes :: [Put] -> B.ByteString
tokenBytes = LB.toStrict . Put.runPut . sequence_
