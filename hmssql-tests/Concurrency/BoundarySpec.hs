-- | An interruption at every packet boundary of a response: of rows cut
-- by the boundaries (each walked from a copy once it has arrived), of a
-- row longer than 64 KiB (read by a 'Hmssql.Tds.Token.RowReader' and
-- resumed packet by packet), of PLP values whose chunks the boundaries
-- cut, and of a RETURNVALUE (read by a
-- 'Hmssql.Tds.Token.ReturnValueReader').  The mock sends the response up
-- to the boundary and holds; the reader is interrupted there; the mock
-- answers its Attention with the rest of the response and the
-- acknowledgement, in a message of its own or in the response's last
-- DONE.  What was read before the interruption is the start of the
-- response, in order, and the next query gets exactly its own result.  On
-- a plain connection ("MockServer") and over SMP ("Mars.MockSmp").
module Concurrency.BoundarySpec (spec) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (forM, unless, void)
import Data.Binary.Put (Put)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32, Int64)
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word16, Word8)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Mock (answerSelect, batchText, doneAttn, doneFinal, selectedNumber)
import Hmssql
import Hmssql.Query
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Packet (PacketType (..))
import Hmssql.Tds.Primitives (putBVarChar)
import Hmssql.Tds.TypeInfo (putTypeInfo)
import Hmssql.Types
import Mars.MockSmp
import MockServer
import Protocol.MockTokens (colMetaData, latin1, packet, withinSecs)

-- | A response, the sizes of the packets it is cut into, and how the
-- client asks for it and reads it.
data Shape = Shape
  { shName :: String
  , shTokens :: Bool -> [Put]
    -- ^ The response; with 'True', its last DONE acknowledges an Attention
    -- too.
  , shSizes :: [Int]
    -- ^ Packet payload sizes, cycled.
  , shExpected :: [String]
    -- ^ What the reader records, in order, of the whole response.
  , shItemTokens :: [Int]
    -- ^ For each record the reader makes as the response arrives, the
    -- index in 'shTokens' of the token that completes it.
  , shRead :: Connection -> (String -> IO ()) -> IO ()
  }

-- | The payloads of the response's packets.
payloads :: Shape -> Bool -> [B.ByteString]
payloads sh ack = cut (cycle (shSizes sh)) (LB.toStrict (Put.runPut (sequence_ (shTokens sh ack))))
  where
    cut (n : ns) bs
      | B.length bs <= n = [bs]
      | otherwise = let (a, b) = B.splitAt n bs in a : cut ns b
    cut [] bs = [bs]

-- | A DONE (0xFD) or DONEPROC (0xFE) ending the response, with the ATTN
-- bit if it acknowledges.
lastDone :: Word8 -> Word16 -> Int -> Bool -> Put
lastDone code status rows ack = do
  Put.putWord8 code
  Put.putWord16le (if ack then status + 0x20 else status)
  Put.putWord16le 0
  Put.putWord64le (fromIntegral rows)

-- | A PLP value in chunks of the given size.
plp :: Int -> B.ByteString -> Put
plp size bs = do
  Put.putWord64le (fromIntegral (B.length bs))
  let go b = unless (B.null b) $ do
        let (c, rest) = B.splitAt size b
        Put.putWord32le (fromIntegral (B.length c))
        Put.putByteString c
        go rest
  go bs
  Put.putWord32le 0

utf16 :: Text -> B.ByteString
utf16 = T.encodeUtf16LE

int4 :: Int32 -> Put
int4 n = Put.putWord8 4 >> Put.putInt32le n

-- | Rows of an int and an nvarchar(200) of 150 characters, about 300
-- bytes each, in packets of uneven sizes.
cutRows :: Shape
cutRows = Shape
  { shName = "rows cut by the boundaries"
  , shTokens = \ack ->
      colMetaData [("n", TIIntN 4), ("s", TINVarChar 400 latin1)]
        : [ Put.putWord8 0xD1 >> putRowValue' i | i <- [1 .. count] ]
        ++ [lastDone 0xFD 0x10 (fromIntegral count) ack]
  , shSizes = [512, 37, 1000, 200]
  , shExpected = [show i ++ ":" ++ T.unpack (text i) | i <- [1 .. count]]
  , shItemTokens = [1 .. fromIntegral count]
  , shRead = \conn record -> withQueryS conn "SHAPE" $
      S.mapM_ (\(n :: Int32, s :: Text) -> record (show n ++ ":" ++ T.unpack s))
  }
  where
    count = 30 :: Int32
    text i = T.replicate 150 (T.pack (show (i `mod` 10)))
    putRowValue' i = do
      int4 i
      let bs = utf16 (text i)
      Put.putWord16le (fromIntegral (B.length bs))
      Put.putByteString bs

-- | A row with a varbinary(max) of 100,000 bytes, longer than the row walk
-- copies, and a short row after it, in packets of 4088 bytes.
longRow :: Shape
longRow = Shape
  { shName = "a row longer than 64 KiB"
  , shTokens = \ack ->
      [ colMetaData [("n", TIIntN 4), ("b", TIBigVarBinary 0xFFFF)]
      , Put.putWord8 0xD1 >> int4 1 >> plp 8000 big
      , Put.putWord8 0xD1 >> int4 2 >> plp 8000 small
      , lastDone 0xFD 0x10 2 ack ]
  , shSizes = [4088]
  , shExpected = [describe 1 big, describe 2 small]
  , shItemTokens = [1, 2]
  , shRead = \conn record -> withQueryS conn "SHAPE" $
      S.mapM_ (\(n :: Int32, b :: B.ByteString) -> record (describe n b))
  }
  where
    big = B.pack (take 100_000 (cycle [0 .. 250]))
    small = "0123456789"
    describe :: Int32 -> B.ByteString -> String
    describe n b = show n ++ ":" ++ show (B.length b) ++ ":" ++ show (B.foldl' (\h w -> h * 31 + fromIntegral w) (7 :: Int) b)

-- | Rows of an int and an nvarchar(max) of 3000 bytes in PLP chunks of
-- 98 bytes, in packets of uneven sizes: the boundaries fall in chunk
-- lengths and in chunks.
cutChunks :: Shape
cutChunks = Shape
  { shName = "PLP values whose chunks the boundaries cut"
  , shTokens = \ack ->
      colMetaData [("n", TIIntN 4), ("s", TINVarChar 0xFFFF latin1)]
        : [ Put.putWord8 0xD1 >> int4 i >> plp 98 (utf16 (text i)) | i <- [1 .. 3] ]
        ++ [lastDone 0xFD 0x10 3 ack]
  , shSizes = [512, 61, 300]
  , shExpected = [show i ++ ":" ++ T.unpack (text i) | i <- [1 .. 3]]
  , shItemTokens = [1 .. 3]
  , shRead = \conn record -> withQueryS conn "SHAPE" $
      S.mapM_ (\(n :: Int32, s :: Text) -> record (show n ++ ":" ++ T.unpack s))
  }
  where
    text i = T.pack (take 1500 (cycle (show (i :: Int32) ++ "abcdefghij")))

-- | A procedure's output parameter, a varbinary(max) of 100,000 bytes,
-- in packets of 4088 bytes.
returnValue :: Shape
returnValue = Shape
  { shName = "a RETURNVALUE"
  , shTokens = \ack ->
      [ do
          Put.putWord8 0xAC
          Put.putWord16le 1
          putBVarChar "@out"
          Put.putWord8 1 >> Put.putWord32le 0 >> Put.putWord16le 0
          putTypeInfo defaultTdsContext (TIBigVarBinary 0xFFFF)
          plp 8000 big
      , lastDone 0xFE 0 0 ack ]
  , shSizes = [4088]
  , shExpected = ["called"]
    -- Recorded once the call has returned.
  , shItemTokens = []
  , shRead = \conn record -> do
      r <- callProcedure conn "p" [outParam "@out" B.empty]
      void (evaluate (length (show (map (decodeReturnValue @B.ByteString) (procOutputValues r)))))
      record "called"
  }
  where
    big = B.pack (take 100_000 (cycle [3 .. 200]))

shapes :: [Shape]
shapes = [cutRows, longRow, cutChunks, returnValue]

data Interrupt = Interrupt
  deriving (Show)

-- | Asynchronous, as 'System.Timeout.timeout''s and 'killThread''s are.
instance Exception Interrupt where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | How many records the reader can make from the first @k@ packets of
-- the response: those whose tokens end in them.
readyAfter :: Shape -> Int -> Int
readyAfter sh k = length [i | i <- shItemTokens sh, ends !! i <= sent]
  where
    ends = scanl1 (+) (map (fromIntegral . LB.length . Put.runPut) (shTokens sh False))
    sent = sum (map B.length (take k (payloads sh False)))

-- | Run the reader in a thread of its own, interrupt it once the mock has
-- sent its packets up to the boundary and the reader has recorded what
-- they hold (and has had a moment to take the rest of them), and return
-- what it recorded.
interruptedAt :: MVar () -> Int -> ((String -> IO ()) -> IO ()) -> IO [String]
interruptedAt sent ready act = do
  recorded <- newTVarIO []
  finished <- newEmptyMVar
  t <- forkIO $ try @SomeException (act (\x -> atomically (modifyTVar' recorded (x :)))) >>= putMVar finished
  withinSecs 10 (readMVar sent)
  -- The rows the packets sent hold are read before the interruption, so
  -- that the count at the last boundary checks where it lands, whatever
  -- the load (with a fixed pause instead, a loaded machine read 4 of 28).
  withinSecs 10 $ atomically $ readTVar recorded >>= check . (>= ready) . length
  -- Where else in the packets the interruption lands (in a row cut by the
  -- boundary, say) doesn't matter to what is checked; after the reader
  -- has taken them is where it is meant to land.
  threadDelay 10_000
  throwTo t Interrupt
  withinSecs 10 (takeMVar finished) >>= \case
    Left e | Just Interrupt <- fromException e -> pure ()
    Left e -> throwIO (userError ("the reader failed: " ++ show e))
    Right () -> throwIO (userError "the reader read the response to its end")
  reverse <$> readTVarIO recorded

-- | Every boundary, with the acknowledgement in a message of its own and
-- in the last DONE: the failures, by boundary.  At the last boundary,
-- every row but the last was read before the interruption (all of them
-- are in the packets sent), which shows that the interruptions land
-- where they are meant to.
everyBoundary :: Shape -> (Int -> Bool -> IO Int) -> IO [(Int, Bool, String)]
everyBoundary sh run = do
  let n = length (payloads sh False)
  outcomes <- forM [(k, ack) | k <- [1 .. n - 1], ack <- [False, True]] $ \(k, ack) ->
    try @SomeException (run k ack) >>= \case
      Right count -> pure (k, ack, Right count)
      Left e -> pure (k, ack, Left (show e))
  let failures = [(k, ack, e) | (k, ack, Left e) <- outcomes]
      atLast = [count | (k, _, Right count) <- outcomes, k == n - 1]
      wanted = max 0 (length (shExpected sh) - 2)
  pure $ failures ++
    [ (n - 1, False, "read " ++ show count ++ " rows at the last boundary, fewer than " ++ show wanted)
    | count <- atLast, count < wanted ]

checkRead :: Shape -> [String] -> IO Int
checkRead sh got
  | got `isPrefixOf` shExpected sh = pure (length got)
  | otherwise = throwIO (userError ("read " ++ show (map (take 40) got)))

-- | The answer to the next query, @SELECT n@.
answer :: B.ByteString -> [Put]
answer body = maybe [doneFinal 0] answerSelect (selectedNumber (batchText body))

-- | A plain connection: the mock sends the first @k@ packets, waits for
-- the Attention, then sends the rest and the acknowledgement.
plainAt :: Shape -> Int -> Bool -> IO Int
plainAt sh k ack = do
  sent <- newEmptyMVar
  let mock mc = do
        _ <- serveLogin defaultLoginResponse mc
        _ <- recvMessage mc
        mapM_ (sendRaw mc . packet False) (take k (payloads sh False))
        putMVar sent ()
        (ptype, _) <- recvMessage mc
        unless (ptype == PTAttention) $ throwIO (MockUnexpected ("expected an Attention, got " ++ show ptype))
        let rest = drop k (payloads sh ack)
        mapM_ (sendRaw mc) (zipWith packet (map (== length rest) [1 ..]) rest)
        unless ack $ sendTokens mc [doneAttn]
        serveRequests (\_ body -> pure (answer body)) mc
  withMockServer mock $ \srv -> withConnection (mockConnectInfo srv) $ \conn -> do
    count <- interruptedAt sent (readyAfter sh k) (shRead sh conn) >>= checkRead sh
    r <- withinSecs 10 (query1 conn "SELECT 42")
    unless (r == Only (42 :: Int64)) $ throwIO (userError ("the next query got " ++ show r))
    pure count

-- | The same over SMP, on the response's session.
smpAt :: Shape -> Int -> Bool -> IO Int
smpAt sh k ack = do
  sent <- newEmptyMVar
  let respond m msg@ClientMsg{cmSid = sid} = case cmType msg of
        PTAttention -> void $ forkIO $ void $ try @SomeException $ do
          readMVar sent
          let rest = drop k (payloads sh ack)
          mapM_ (sendTdsPacket m sid) (zipWith tdsPacket (map (== length rest) [1 ..]) rest)
          unless ack $ sendTdsPacket m sid (tdsPacket True (LB.toStrict (Put.runPut doneAttn)))
        PTSqlBatch | Just _ <- selectedNumber (batchText (cmBody msg)) -> answerRequests m msg
        _ -> void $ forkIO $ void $ try @SomeException $ do
          mapM_ (sendTdsPacket m sid . tdsPacket False) (take k (payloads sh False))
          putMVar sent ()
  withSmpServer defaultSmpConfig { cfgRespond = Just respond } $ \srv -> do
    count <- withConnection (smpConnectInfo srv) $ \conn -> do
      count <- interruptedAt sent (readyAfter sh k) (shRead sh conn) >>= checkRead sh
      r <- withinSecs 10 (query1 conn "SELECT 42")
      unless (r == Only (42 :: Int64)) $ throwIO (userError ("the next query got " ++ show r))
      pure count
    out <- nextOutcome srv
    unless (null (outViolations out) && null (outErrors out)) $
      throwIO (userError ("the mock saw " ++ show (outViolations out ++ outErrors out)))
    pure count

spec :: Spec
spec = describe "an interruption at every packet boundary of a response" $
  forM_' shapes $ \sh -> do
    it ("of " ++ shName sh ++ ": the rows read are the response's first, and the next query is exact") $
      everyBoundary sh (plainAt sh) `shouldReturn` []
    it ("of " ++ shName sh ++ ", over SMP: the rows read are the response's first, and the next query is exact") $
      everyBoundary sh (smpAt sh) `shouldReturn` []
  where
    forM_' xs f = mapM_ f xs
