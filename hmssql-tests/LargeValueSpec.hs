{-# LANGUAGE DerivingStrategies #-}

-- | Reading and sending very large values: costs must be linear in the size
-- (docs/dev/bugs-found.md, the audit's first bug), and an interrupted read of one huge token
-- cancels the response (the stream is abandoned: pulling again throws
-- 'ResultAbandoned'), which the next request drains promptly.
module LargeValueSpec (spec) where

import RecipeParameters
import Control.Exception (evaluate, try)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import System.Mem (getAllocationCounter)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Encoding (encodeParam)
import Hmssql.Tds.Context
import Hmssql.Tds.Token (Token (..))
import Hmssql.Tds.TypeInfo (putValue, typeInfoSqlName)
import TestDb

mib :: Int
mib = 1024 * 1024

-- | Run an action, failing the test if it takes more than @limit@ seconds
-- (so a quadratic regression fails promptly instead of hanging the suite).
-- Returns the result and the elapsed time.
timed :: Double -> IO a -> IO (a, Double)
timed limit act = do
  t0 <- getMonotonicTime
  r <- timeout (round (limit * 1e6)) (act >>= evaluate)
  t1 <- getMonotonicTime
  case r of
    Nothing -> expectationFailure ("took more than " ++ show limit ++ " s") >> fail "timed out"
    Just a -> pure (a, t1 - t0)

-- | What an action cost: the bytes this thread allocated (an exact count,
-- unaffected by other threads or processes) and the wall-clock time.
data Cost = Cost { costBytes :: !Int64, costSeconds :: !Double }
  deriving stock (Show)

-- | Run an action @n@ times (each within @limit@ seconds, as 'timed'), and
-- return its cheapest run: the least allocation and the least time (not
-- necessarily of the same run).  The minimum is the run least disturbed by
-- whatever else the machine was doing.
cheapest :: Int -> Double -> IO a -> IO (a, Cost)
cheapest n limit act = do
  first <- once
  runs <- (first :) <$> mapM (const once) [2 .. n]
  pure (fst first, Cost (minimum (map (costBytes . snd) runs)) (minimum (map (costSeconds . snd) runs)))
  where
    once = do
      a0 <- getAllocationCounter
      (a, t) <- timed limit act
      a1 <- getAllocationCounter
      -- The counter counts down.
      pure (a, Cost (a0 - a1) t)

-- | A cost linear in the size: @large@ did 4x the work of @small@.  Linear
-- predicts 4x, quadratic 16x.  Allocation counts the copying that makes a
-- buffer quadratic, exactly; time (allowing for noise and a fixed cost)
-- catches anything else.
--
-- The allocation for a byte read is not one figure.  It depends on how the
-- packets fall across the chunks received: over a plaintext connection with
-- packets of 32767 bytes it is 2.35 bytes for most reads and as little as
-- 1.5 for some, and with TLS 1.4.  So a linear reader can show 4 x 2.4 /
-- 1.4, nearly 7x, between a lucky small read and an ordinary large one
-- (6.1x was seen, and failed a bound of 6x).
linearCost :: Cost -> Cost -> Expectation
linearCost small large = do
  (costBytes large, costBytes small) `shouldSatisfy` \(l, s) -> l < 8 * s
  (costSeconds large, costSeconds small) `shouldSatisfy` \(l, s) -> l < 8 * s + 1

-- | An @nvarchar(max)@ of @n@ bytes (@n / 2@ copies of @x@), built on the server.
nvarcharOf :: Int -> Text
nvarcharOf n = "SELECT REPLICATE(CONVERT(nvarchar(max), N'x'), " <> tshow (n `div` 2) <> ")"

-- | A @varbinary(max)@ of @n@ bytes (0x61 repeated), built on the server.
varbinaryOf :: Int -> Text
varbinaryOf n = "SELECT CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'a'), " <> tshow n <> "))"

tshow :: Show a => a -> Text
tshow = T.pack . show

readNvarchar :: Connection -> Int -> IO Int
readNvarchar conn n = do
  Only (t :: Text) <- query1 conn (rawSql (nvarcharOf n))
  T.length t `shouldBe` n `div` 2
  T.all (== 'x') t `shouldBe` True
  pure (T.length t)

-- | A @varbinary(max)@ output parameter of @n@ bytes (0x61 repeated),
-- set on the server by @sp_executesql@.
readVarbinaryOutput :: Connection -> Int -> IO Int
readVarbinaryOutput conn n = do
  let ps =
        [ inParam "" ("SET @out = CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'a'), " <> tshow n <> "))" :: Text)
        , inParam "" ("@out varbinary(max) OUTPUT" :: Text)
        , outParam "@out" B.empty ]
  res <- callProcedure conn "sp_executesql" ps
  case map (decodeReturnValue @B.ByteString) (procOutputValues res) of
    [Right b] -> do
      B.length b `shouldBe` n
      B.all (== 0x61) b `shouldBe` True
      pure (B.length b)
    r -> fail ("expected one output value, got " ++ show (map (fmap B.length) r))

readVarbinary :: Connection -> Int -> IO Int
readVarbinary conn n = do
  Only (b :: B.ByteString) <- query1 conn (rawSql (varbinaryOf n))
  B.length b `shouldBe` n
  B.all (== 0x61) b `shouldBe` True
  pure (B.length b)

spec :: Spec
spec = do
  describe "reading" $ around withTestDb $ do
    -- With the old quadratic buffer, 64 MB took minutes.
    it "reads a 64 MB nvarchar(max) promptly" $ \conn ->
      () <$ timed 60 (readNvarchar conn (64 * mib))

    it "reads a 64 MB varbinary(max) promptly" $ \conn ->
      () <$ timed 60 (readVarbinary conn (64 * mib))

    -- Timing ratios: alone (see TestDb.serial), as below.
    serial $ it "reading 4x the bytes takes well under 16x the time" $ \conn -> do
      _ <- readVarbinary conn mib -- warm up
      (_, small) <- cheapest 3 60 (readVarbinary conn (16 * mib))
      (_, large) <- cheapest 2 60 (readVarbinary conn (64 * mib))
      linearCost small large

    it "reads a 64 MB varbinary(max) output parameter promptly" $ \conn ->
      () <$ timed 60 (readVarbinaryOutput conn (64 * mib))

    it "reads large output parameters after large rows, and NULL and short ones" $ \conn -> do
      let ps =
            [ inParam "" ("SELECT CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'b'), 3000000)); \
                          \SET @a = REPLICATE(CONVERT(nvarchar(max), N'\233'), 3000000); SET @b = NULL; SET @c = 42; \
                          \SET @d = CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'd'), 5000000))" :: Text)
            , inParam "" ("@a nvarchar(max) OUTPUT, @b varbinary(max) OUTPUT, @c int OUTPUT, @d varbinary(max) OUTPUT" :: Text)
            , outParam "@a" T.empty, outParam "@b" B.empty, outParam "@c" (0 :: Int), outParam "@d" B.empty ]
      res <- callProcedure conn "sp_executesql" ps
      map (length . resultRows) (procResultSets res) `shouldBe` [1]
      case procOutputValues res of
        [a, b, c, d] -> do
          fmap (\t -> (T.length t, T.all (== '\233') t)) (decodeReturnValue @Text a) `shouldBe` Right (3000000, True)
          decodeReturnValue @(Maybe B.ByteString) b `shouldBe` Right Nothing
          decodeReturnValue @Int c `shouldBe` Right 42
          fmap (\x -> (B.length x, B.all (== 0x64) x)) (decodeReturnValue @B.ByteString d) `shouldBe` Right (5000000, True)
        vs -> expectationFailure ("expected four output values, got " ++ show (length vs))

    it "reads several large values in one row and one response" $ \conn -> do
      (a :: B.ByteString, b :: Text, c :: Int) <- query1 conn $
        "SELECT CONVERT(varbinary(max), REPLICATE(CONVERT(varchar(max), 'a'), 5000000)), \
        \REPLICATE(CONVERT(nvarchar(max), N'\233'), 3000000), 7"
      (B.length a, T.length b, T.all (== '\233') b, c) `shouldBe` (5000000, 3000000, True, 7)
      rs <- queryMulti conn (rawSql (varbinaryOf (3 * mib) <> "; " <> nvarcharOf (3 * mib) <> "; SELECT 1"))
      map (length . resultRows) rs `shouldBe` [1, 1, 1]

  describe "interrupted reads" $ around withTestDb $ do
    -- Resuming the read is no longer possible: the interruption sends an
    -- Attention at once, so the rest of the result would end early.
    it "an interrupted read of a huge token abandons the stream: pulling again throws ResultAbandoned, and the next request gets its own result" $ \conn -> do
      let n = 32 * mib
      toks <- responseS conn (batchRequest (varbinaryOf n))
      Right (TColMetaData _, rest) <- S.next toks
      -- 1 ms into a 32 MiB row: still reading it.
      timeout 1000 (S.next rest) >>= \case
        Just _ -> pendingWith "the 32 MiB row was read within 1 ms"
        Nothing -> do
          again <- try (S.next rest)
          case again of
            Left ResultAbandoned -> pure ()
            Right (Left ()) -> expectationFailure "the stream ended without an error"
            Right (Right (tok, _)) -> expectationFailure ("read on after the interruption: " ++ take 100 (show tok))
          query1 conn "SELECT 5" `shouldReturn` Only (5 :: Int)

    -- Once most of the row has probably arrived, the read is interrupted.
    -- The stream is abandoned (no retry re-decodes the value any more), and
    -- the next request drains what is left of the cancelled response: that
    -- must cost about as much as reading the value, not quadratically more.
    serial $ it "an interruption late in a large value abandons the stream, and the next request drains the cancelled rest promptly" $ \conn -> do
      let n = 64 * mib
      (_, full) <- timed 60 (readVarbinary conn n)
      let attempt [] = pendingWith "could not interrupt the read" >> pure Nothing
          attempt (frac : fracs) = do
            toks <- responseS conn (batchRequest (varbinaryOf n))
            Right (TColMetaData _, rest) <- S.next toks
            r <- timeout (round (frac * full * 1e6)) (S.next rest)
            case r of
              Nothing -> pure (Just rest)
              Just _ -> attempt fracs
      attempt [0.7, 0.5, 0.3, 0.15] >>= mapM_ (\rest -> do
        again <- try (S.next rest)
        case again of
          Left ResultAbandoned -> pure ()
          Right _ -> expectationFailure "read on after the interruption"
        (r, drain) <- timed 60 (query1 conn "SELECT 8")
        r `shouldBe` Only (8 :: Int)
        drain `shouldSatisfy` (< 3 * full + 1))

    it "recovers after a timeout in the middle of a large value" $ \conn -> do
      r <- timeout 50000 (query1 conn (rawSql (varbinaryOf (64 * mib))) :: IO (Only B.ByteString))
      case r of
        Nothing -> pure ()
        Just _ -> expectationFailure "finished before the timeout"
      query1 conn "SELECT 6" `shouldReturn` Only (6 :: Int)
      () <$ readNvarchar conn mib

    it "recovers after a timeout in the middle of a large output parameter" $ \conn -> do
      r <- timeout 50000 (readVarbinaryOutput conn (64 * mib))
      case r of
        Nothing -> pure ()
        Just _ -> expectationFailure "finished before the timeout"
      query1 conn "SELECT 7" `shouldReturn` Only (7 :: Int)
      () <$ readVarbinaryOutput conn mib

  describe "sending" $ around withTestDb $ do
    -- On a MARS connection the server takes four packets per round trip
    -- (its window), so with small packets a large parameter is slow by
    -- design (docs/dev/limitations.md); the bound is for packets of 4 KiB up.
    it "sends a 64 MB varbinary(max) parameter promptly" $ \_ ->
     withTestDbWith (\ci -> ci { connectPacketSize = max 4096 (connectPacketSize ci) }) $ \conn -> do
      let v = B.replicate (64 * mib) 0x62
      (Only len, _) <- timed 60 (query1 conn ("SELECT DATALENGTH(" <> param v <> ")"))
      len `shouldBe` (fromIntegral (64 * mib) :: Int64)

    -- A batch may have at most 65535 packets: 64 MB needs 1 KiB packets or more.
    it "sends a 32-million-character batch promptly" $ \_ ->
     withTestDbWith (\ci -> ci { connectPacketSize = max 4096 (connectPacketSize ci) }) $ \conn -> do
      let s = T.replicate (32 * 1000 * 1000) "B"
      (Only len, _) <- timed 60 (query1 conn (rawSql ("SELECT DATALENGTH(N'" <> s <> "')")))
      len `shouldBe` (64 * 1000 * 1000 :: Int64)

    serial $ it "sending 4x the bytes takes well under 16x the time" $ \conn -> do
      let send :: Int -> Int -> IO (Only Int64, Cost)
          send runs n = do
            let !v = B.replicate n 0x63
            cheapest runs 60 (query1 conn ("SELECT DATALENGTH(" <> param v <> ")"))
      _ <- send 1 mib
      (Only a, small) <- send 3 (16 * mib)
      (Only b, large) <- send 2 (64 * mib)
      (a, b) `shouldBe` (fromIntegral (16 * mib), fromIntegral (64 * mib))
      linearCost small large

  -- Ported from mssql's test suite.
  describe "mssql ports" $ do
    describe "parameters" $ around withTestDb $ do
      it "sends a million-character nvarchar(max) parameter" $ \conn -> do
        let v = T.replicate 1000000 "A"
        (len, back) <- query1 conn (mkQuery "SELECT DATALENGTH(@p1), @p1" (Only v))
        (len :: Int64) `shouldBe` 2000000
        back `shouldBe` v

      it "sends a small value declared as nvarchar(max)" $ \conn -> do
        let v = "Hello, World!" :: Text
        (len, back) <- query1 conn (mkQuery "DECLARE @v nvarchar(max) = @p1; SELECT DATALENGTH(@v), @v" (Only v))
        (len :: Int64, back) `shouldBe` (26, v)

      it "sends a NULL nvarchar(max) parameter (PLP NULL)" $ \conn -> do
        (len, back, isNull) <- query1 conn $ mkQuery
          "SELECT DATALENGTH(@p1), @p1, CASE WHEN @p1 IS NULL THEN 1 ELSE 0 END"
          (Only (Nothing :: Maybe Text))
        (len :: Maybe Int64, back :: Maybe Text, isNull :: Int) `shouldBe` (Nothing, Nothing, 1)

      it "encodes a NULL Text parameter as nvarchar(max) with the PLP NULL marker" $ \_ -> do
        case encodeParam fieldEncoder defaultTdsContext (Nothing :: Maybe Text) of
          Left err -> expectationFailure err
          Right (ti, v) -> do
            typeInfoSqlName ti `shouldBe` "nvarchar(max)"
            LB.toStrict (Put.runPut (putValue defaultTdsContext ti (parameterBytes v))) `shouldBe` B.replicate 8 0xFF

    -- (At least) 4096-byte packets, whatever HMSSQL_TEST_PACKET_SIZE says.
    -- Serial: each holds a few GB at its peak.
    slow $ serial $ describe "huge values" $ around (withTestDbWith (\ci -> ci { connectPacketSize = max 4096 (connectPacketSize ci) })) $ do
      -- The largest batch a 4096-byte packet size allows is 65535 packets
      -- (about 255.5 MiB); mssql's test stayed just under it.
      let hugeText = T.replicate 133900000 "A"

      it "sends a 134-million-character SQL batch" $ \conn -> do
        Only (len :: Int64) <- query1 conn (rawSql ("SELECT DATALENGTH(N'" <> hugeText <> "')"))
        len `shouldBe` 2 * 133900000

      it "reads the same string back as nvarchar(max)" $ \conn -> do
        Only (back :: Text) <- query1 conn (rawSql ("SELECT N'" <> hugeText <> "'"))
        T.length back `shouldBe` 133900000
        back `shouldBe` hugeText

      it "reads a 268 MB nvarchar(max) built on the server" $ \conn ->
        () <$ timed 300 (readNvarchar conn (256 * mib))
