-- | SMP framing and flow control against a real server (docs/dev/mars-research.md, A7,
-- A8, A9, A12): requests of many packets, in every encryption mode; a
-- stream nobody reads holds at most the window's packets on the client,
-- whatever the window, while other sessions keep flowing; a request far
-- longer than the server's own window of 4 packets completes; and the
-- client's memory stays flat while several streams are traversed and
-- bounded while one is stalled.
module Mars.FlowControlSpec (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_, when)
import qualified Data.ByteString as B
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word8)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (expectUsable)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Mars.Harness
import Resources.Helpers (heapLiveBytes)
import TestDb

modes :: [Encryption]
modes = [EncryptStrict, EncryptOn, EncryptOff, EncryptNotSup]

plaintextIfAllowed :: Encryption -> SpecWith a -> SpecWith a
plaintextIfAllowed enc = if enc == EncryptNotSup then skipIfEncryptionRequired else id

-- | @n@ bytes that a shifted or dropped packet would show.
pattern :: Int -> B.ByteString
pattern n = B.pack [fromIntegral ((i * 7 + i `div` 251) `mod` 256) :: Word8 | i <- [0 .. n - 1]]

-- | @n@ characters, some of them beyond the BMP.
mixedText :: Int -> Text
mixedText n = T.take n (T.replicate (n `div` 8 + 1) "aé€𝄞z0 \n")

-- | Rows of a number and 1000 bytes, as 'wideRows' gives.
-- | A MARS connection with the window, and packets of at least 4 KiB: the
-- window tests count packets and read 60 MB per stream, which at
-- 512-byte packets would take thousands of round trips per window.
withWindow :: Int -> (Connection -> IO a) -> IO a
withWindow window = withMarsConnWith (\ci -> ci { connectMarsWindow = window, connectPacketSize = max 4096 (connectPacketSize ci) })

wideStream :: Connection -> Int -> IO (Stream (Of (Int64, Text)) IO ())
wideStream conn n = queryS conn (rawSql (wideRows n))

-- | Check that every row is the next number with its padding, and count them.
checkWide :: Stream (Of (Int64, Text)) IO () -> IO Int
checkWide = go 1 0
  where
    go !next !count s = S.next s >>= \case
      Left () -> pure count
      Right ((n, pad), rest) -> do
        when (n /= next) $ expectationFailure ("row " ++ show n ++ " where " ++ show next ++ " was due")
        when (T.length pad /= 1000) $ expectationFailure ("padding of " ++ show (T.length pad) ++ " characters")
        go (next + 1) (count + 1) rest

spec :: Spec
spec = do
  forM_ modes $ \enc -> plaintextIfAllowed enc $ describe ("A7: multi-packet requests under " ++ show enc) $ do
    it "a 1 MB binary parameter round-trips" $
      withMarsConnFor enc id $ \conn -> withinTracedOn 60 conn $ \at -> do
        let bytes = pattern 1_048_576
        at "the round trip"
        query1 conn (mkQuery "SELECT @p1" (Only bytes)) `shouldReturn` Only bytes
        at "a query after it"
        expectUsable conn

    it "a 1 M character text parameter round-trips" $
      withMarsConnFor enc id $ \conn -> withinTracedOn 60 conn $ \at -> do
        let txt = mixedText 1_048_576
        at "the round trip"
        query1 conn (mkQuery "SELECT @p1" (Only txt)) `shouldReturn` Only txt
        at "a query after it"
        expectUsable conn

    it "a 1 MB parameter round-trips at the smallest packet size, beside an open stream" $
      withMarsConnFor enc (\ci -> ci { connectPacketSize = 512 }) $ \conn -> withinTracedOn 120 conn $ \at -> do
        let bytes = pattern 1_048_576
        at "the stream's first row"
        withNums conn 50_000 $ \s -> do
          (_, rest) <- firstRow s
          at "the round trip"
          query1 conn (mkQuery "SELECT @p1" (Only bytes)) `shouldReturn` Only bytes
          at "the rest of the stream"
          S.length_ rest `shouldReturn` 49_999

  describe "A9: a request much longer than the server's window of 4 packets" $
    forM_ [EncryptStrict, EncryptNotSup] $ \enc -> plaintextIfAllowed enc $
      it ("a 4 MB parameter at packet size 512 (8192 packets) completes and comes back intact, under " ++ show enc) $
        withMarsConnFor enc (\ci -> ci { connectPacketSize = 512 }) $ \conn -> withinTracedOn 180 conn $ \at -> do
          let bytes = pattern 4_194_304
          at "the round trip"
          query1 conn (mkQuery "SELECT @p1" (Only bytes)) `shouldReturn` Only bytes
          -- And on a second session, a request the server takes while the
          -- first session's response is open and unread.
          at "the stream's first row"
          s <- numStream conn 100_000
          (_, rest) <- firstRow s
          at "the request beside the stream"
          Only n <- query1 conn (mkQuery "SELECT DATALENGTH(@p1)" (Only bytes))
          (n :: Int) `shouldBe` 4_194_304
          at "the rest of the stream"
          S.length_ rest `shouldReturn` 99_999

  describe "A8, A12: a stream that is not being read holds at most the window on the client" $ do
    forM_ [4, 16, 64, 256] $ \window ->
      describe ("window " ++ show window) $ do
        it "holds exactly the window's packets, however long it waits, and other sessions keep flowing" $
          withWindow window $ \conn -> withinTracedOn 60 conn $ \at -> do
            -- What session 0 received before (a session setup's response).
            before <- receivedPackets conn 0
            at "the parked stream's request"
            parked <- wideStream conn 30_000
            -- The request has been sent and nothing is read: session 0 has
            -- the response.
            busySids conn `shouldReturn` [0]
            at "waiting for the window's packets"
            held <- waitHeldFull conn 0 window
            held `shouldBe` window
            receivedPackets conn 0 `shouldReturn` before + fromIntegral window
            -- Other sessions go on meanwhile: a query, a whole stream.
            at "a query beside it"
            query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int)
            at "a stream beside it"
            numStream conn 50_000 >>= S.length_ >>= (`shouldBe` 50_000)
            busySids conn `shouldReturn` [0]
            -- The parked one has taken no more.
            heldPackets conn 0 `shouldReturn` window
            -- Read on: every row, the server never sends beyond the window.
            at "reading the parked stream"
            highest <- newIORef 0
            rows <- checkWideWatching conn highest parked
            rows `shouldBe` 30_000
            readIORef highest >>= (`shouldSatisfy` (<= window))
            busySids conn `shouldReturn` []

        it "a stream asked for beside a parked one is parked at the same window, on its own session" $
          withWindow window $ \conn -> withinTracedOn 60 conn $ \at -> do
            at "the three requests"
            a <- wideStream conn 30_000
            b <- wideStream conn 30_000
            c <- wideStream conn 30_000
            busySids conn `shouldReturn` [0, 1, 2]
            at "waiting for the windows' packets"
            forM_ [0, 1, 2] $ \sid -> waitHeldFull conn sid window `shouldReturn` window
            -- Reading one does not disturb the others' counts.
            at "reading the first stream"
            checkWide a `shouldReturn` 30_000
            forM_ [1, 2] $ \sid -> heldPackets conn sid `shouldReturn` window
            at "reading the second stream"
            checkWide b `shouldReturn` 30_000
            at "reading the third stream"
            checkWide c `shouldReturn` 30_000

    it "the default window is 64" $ do
      connectMarsWindow defaultConnectInfo `shouldBe` 64
      -- Whatever HMSSQL_TEST_MARS_WINDOW says.
      withMarsConnWith (\ci -> ci { connectMarsWindow = connectMarsWindow defaultConnectInfo }) $ \conn -> withinTracedOn 60 conn $ \at -> do
        at "the request"
        parked <- wideStream conn 30_000
        at "waiting for the window's packets"
        waitHeldFull conn 0 64 `shouldReturn` 64
        at "reading the stream"
        checkWide parked `shouldReturn` 30_000

    forM_ [3, 2, 1, 0, -7] $ \window ->
      it ("a window of " ++ show window ++ " is raised to 4") $
        withWindow window $ \conn -> withinTracedOn 60 conn $ \at -> do
          at "the request"
          parked <- wideStream conn 30_000
          at "waiting for the window's packets"
          waitHeldFull conn 0 4 `shouldReturn` 4
          at "reading the stream"
          checkWide parked `shouldReturn` 30_000
          at "a query after it"
          expectUsable conn

  describe "the client's memory" $ do
    -- The live heap after a major GC is process-wide, so these run alone.
    serial $ it "stays flat while four 200,000-row streams are traversed round-robin" $
      withMarsConn $ \conn -> withinTracedOn 300 conn $ \at -> do
        at "the four requests"
        Just before <- heapLiveBytes
        streams <- mapM (\_ -> queryS conn (rawSql (padded 200_000))) [1 .. 4 :: Int]
        busySids conn `shouldReturn` [0, 1, 2, 3]
        at "reading the streams round-robin"
        peak <- newIORef before
        rows <- roundRobin streams $ \i n (v :: Int64, pad :: Text) -> do
          when (fromIntegral v /= n + 1) $ expectationFailure ("stream " ++ show i ++ " row " ++ show n ++ " is " ++ show v)
          _ <- evaluate (T.length pad)
          when (n `mod` 40_000 == 0 && i == 0) $ do
            Just now <- heapLiveBytes
            modifyIORef' peak (max now)
        rows `shouldBe` [200_000, 200_000, 200_000, 200_000]
        p <- readIORef peak
        let growth = fromIntegral p - fromIntegral before :: Int
        -- Four windows of packets (64 * 8000 bytes each) and the row in hand:
        -- a few MB.  Holding the rows would take 100 MB and more.
        growth `shouldSatisfy` (< 24 * 1024 * 1024)
        busySids conn `shouldReturn` []

    serial $ it "is bounded for a stalled stream: a result of 200 MB parked at its window costs a window's packets" $
      withMarsConn $ \conn -> withinTracedOn 120 conn $ \at -> do
        at "the stalled stream's request"
        Just before <- heapLiveBytes
        stalled <- wideStream conn 200_000
        at "waiting for the window's packets"
        _ <- waitHeldFull conn 0 (connWindow conn)
        -- Long enough for an unbounded reader to have taken far more.
        Just during <- heapLiveBytes
        let growth = fromIntegral during - fromIntegral before :: Int
        growth `shouldSatisfy` (< 8 * 1024 * 1024)
        -- Other traffic meanwhile does not add to it.
        at "a stream beside it"
        numStream conn 100_000 >>= S.length_ >>= (`shouldBe` 100_000)
        Just after <- heapLiveBytes
        (fromIntegral after - fromIntegral before :: Int) `shouldSatisfy` (< 8 * 1024 * 1024)
        at "ten rows of the stalled stream"
        rest <- S.length_ (S.take 10 stalled)
        rest `shouldBe` 10
        at "cancelActiveStatement"
        cancelActiveStatement conn
        busySids conn `shouldReturn` []
  where
    padded :: Int -> Text
    padded n = "SELECT TOP " <> T.pack (show n)
      <> " CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS bigint), REPLICATE(CAST('x' AS varchar(100)), 100) \
         \FROM sys.all_columns a CROSS JOIN sys.all_columns b"

-- | 'checkWide', sampling how many packets session 0 holds every 100 rows.
checkWideWatching :: Connection -> IORef Int -> Stream (Of (Int64, Text)) IO () -> IO Int
checkWideWatching conn highest = go 1 0
  where
    go :: Int64 -> Int -> Stream (Of (Int64, Text)) IO () -> IO Int
    go !next !count s = S.next s >>= \case
      Left () -> pure count
      Right ((n, pad), rest) -> do
        when (n /= next) $ expectationFailure ("row " ++ show n ++ " where " ++ show next ++ " was due")
        when (T.length pad /= 1000) $ expectationFailure "padding of the wrong length"
        when (count `mod` 100 == 0) $ do
          h <- heldPackets conn 0
          modifyIORef' highest (max h)
        go (next + 1) (count + 1) rest
