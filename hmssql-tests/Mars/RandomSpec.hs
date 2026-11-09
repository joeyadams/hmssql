{-# LANGUAGE MultiWayIf #-}

-- | Random interleavings of opening streams, reading some of their rows,
-- reading them to the end, cancelling them and making other requests on one
-- MARS connection: every row is the number it should be, the busy sessions
-- are exactly the responses the model has open, cancelled and ended streams
-- are abandoned, and the connection is clean at the end.
module Mars.RandomSpec (spec) where

import Control.Exception (try)
import Control.Monad (foldM, forM_, when)
import Data.Bits (shiftL, shiftR, xor, (.&.))
import Data.Int (Int64)
import Data.Word (Word64)
import Streaming (Of, Stream)
import qualified Streaming.Prelude as S
import Test.Hspec

import Concurrency.Harness (within)
import Hmssql
import Hmssql.Connection (cancelActiveStatement)
import Hmssql.Errors
import Hmssql.Query (ResponseReader, cancelResponse)
import Mars.Harness

-- | xorshift64*: a repeatable stream of choices from a seed.
next :: Word64 -> (Word64, Word64)
next x0 = (x3, x3 * 0x2545F4914F6CDD1D)
  where
    x1 = x0 `xor` (x0 `shiftR` 12)
    x2 = x1 `xor` (x1 `shiftL` 25)
    x3 = x2 `xor` (x2 `shiftR` 27)

-- | A number below @n@, and the new generator state.
below :: Int -> Word64 -> (Int, Word64)
below n g = let (g', r) = next g in (fromIntegral ((r `shiftR` 11) `mod` fromIntegral n), g')

-- | A stream of the model: its reader, what is left to read and how many
-- rows it has in all.
data Open = Open
  { oResp :: ResponseReader
  , oRest :: Stream (Of Int64) IO ()
  , oNext :: Int64
  , oTotal :: Int64
  }

data Model = Model
  { mOpen :: [Open]
  , mDead :: [Stream (Of Int64) IO ()]
  , mGen :: Word64
  }

-- | One random step.
step :: Connection -> Model -> IO Model
step conn m = do
  let (choice, g1) = below 100 (mGen m)
      m1 = m { mGen = g1 }
      nOpen = length (mOpen m1)
  if
    | choice < 22, nOpen < 8 -> openOne m1
    | choice < 22 -> readSome m1
    | choice < 60, nOpen > 0 -> readSome m1
    | choice < 72, nOpen > 0 -> readToEnd m1
    | choice < 82, nOpen > 0 -> cancelOne m1
    | choice < 92 -> request m1
    | choice < 96 -> failing m1
    | choice < 97 -> cancelAll m1
    | otherwise -> request m1
  where
    pick mm = let (i, g) = below (length (mOpen mm)) (mGen mm) in (i, mm { mGen = g })
    removeAt i xs = take i xs ++ drop (i + 1) xs

    openOne mm = do
      let (k, g) = below 5 (mGen mm)
          total = [1, 5, 100, 5000, 200_000] !! k
      (resp, s) <- startNumbers conn total
      pure mm { mGen = g, mOpen = mOpen mm ++ [Open resp s 1 (fromIntegral total)] }

    readSome mm
      | null (mOpen mm) = pure mm
      | otherwise = do
          let (i, mm1) = pick mm
              (k, g) = below 3 (mGen mm1)
              want = [1, 10, 1000] !! k
              o = mOpen mm1 !! i
          (rows, rest) <- takeRows want (oRest o)
          let expected = take want [oNext o .. oTotal o]
          rows `shouldBe` expected
          let o' = o { oRest = rest, oNext = oNext o + fromIntegral (length rows) }
          if length rows < want
            then pure mm1 { mGen = g, mOpen = removeAt i (mOpen mm1) }
            else pure mm1 { mGen = g, mOpen = take i (mOpen mm1) ++ [o'] ++ drop (i + 1) (mOpen mm1) }

    readToEnd mm = do
      let (i, mm1) = pick mm
          o = mOpen mm1 !! i
      rows <- S.toList_ (oRest o)
      rows `shouldBe` [oNext o .. oTotal o]
      pure mm1 { mOpen = removeAt i (mOpen mm1), mDead = oRest o : mDead mm1 }

    cancelOne mm = do
      let (i, mm1) = pick mm
          o = mOpen mm1 !! i
      cancelling (cancelResponse (oResp o))
      pure mm1 { mOpen = removeAt i (mOpen mm1), mDead = oRest o : mDead mm1 }

    request mm = do
      let (v, g) = below 1000 (mGen mm)
      query1 conn (mkQuery "SELECT @p1" (Only v)) `shouldReturn` Only v
      pure mm { mGen = g }

    failing mm = do
      r <- try (query conn (rawSql "SELECT 1 / 0") :: IO [Only Int])
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 8134
        Right rows -> expectationFailure ("no error: " ++ show rows)
      pure mm

    cancelAll mm = do
      cancelling (cancelActiveStatement conn)
      pure mm { mOpen = [], mDead = map oRest (mOpen mm) ++ mDead mm }

spec :: Spec
spec = describe "random interleavings on one MARS connection" $
  forM_ [1 .. 6 :: Word64] $ \seed ->
    it ("seed " ++ show seed ++ ": 400 steps keep every row exact and the busy sessions equal to the open responses") $
      withMarsConn $ \conn -> within 180 $ survivingEarlyAttentionKill ("seed " ++ show seed) conn $ do
        final <- foldM (\m i -> do
          m' <- step conn m
          busy <- busySids conn
          -- Every open response is busy; a stream read to its end is not.
          when (length busy /= length (mOpen m')) $
            expectationFailure ("step " ++ show (i :: Int) ++ ": " ++ show (length busy) ++ " sessions busy, the model has "
              ++ show (length (mOpen m')) ++ " open")
          pure m') (Model [] [] (seed * 0x9E3779B97F4A7C15 .&. 0xFFFFFFFFFFFFFFFF)) [1 .. 400]
        -- What is open is cancelled; every stream that is not open any more,
        -- ended or cancelled, refuses to read.
        cancelActiveStatement conn
        expectClean conn
        forM_ (mDead final ++ map oRest (mOpen final)) expectAbandonedS
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
