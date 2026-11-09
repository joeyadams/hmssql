-- | Algorithmic complexity of shapes a real SQL Server won't produce on
-- demand, crafted with "MockServer" instead: very long error messages, deep
-- NBCROW null bitmaps, and an unknown-length PLP made of many tiny chunks
-- (as e.g. @FOR XML@ streaming can produce).  For the live-server
-- dimensions, see "Resources.ComplexitySpec".
--
-- All 'slow' (the larger sizes still take a moment to build and ship over a
-- socket): run with @HMSSQL_TEST_SLOW=1@.
module Resources.ComplexityMockSpec (spec) where

import Control.Exception
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word64)
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import MockServer
import Protocol.MockTokens
import Resources.Helpers (subQuadraticAlloc)
import TestDb (slow)

msg :: Text -> ServerMessage
msg t = ServerMessage 50000 1 16 t "mock" "" 1

-- | An unknown-length PLP value made of @chunks@ 1-byte chunks (0x61 each).
-- [MS-TDS] 2.2.5.2.3: 0xFFFFFFFFFFFFFFFE marks the length as unknown ahead of
-- time (0xFFFFFFFFFFFFFFFF, one more, is the PLP NULL marker instead).
plpValue :: Int -> Put.Put
plpValue chunks = do
  Put.putWord64le (0xFFFFFFFFFFFFFFFE :: Word64) -- unknown total length
  mapM_ (const (Put.putWord32le 1 >> Put.putWord8 0x61)) [1 .. chunks]
  Put.putWord32le 0 -- terminating zero-length chunk

vbin :: TypeInfo
vbin = TIBigVarBinary 0xFFFF

-- | An NBCROW token (0xD2) for @cnt@ columns, all NULL: a bitmap of all-1
-- bits (built directly with 'B.replicate', not via "Protocol.MockTokens"'s
-- @nbcRow@, whose bitmap construction is O(n^2) in the column count -- fine
-- at the small scale it's normally used at, but it would swamp this test's
-- own measurement of the *client's* decode cost at a few thousand columns).
allNullNbcRow :: Int -> Put.Put
allNullNbcRow cnt = Put.putWord8 0xD2 >> Put.putByteString (B.replicate ((cnt + 7) `div` 8) 0xFF)

spec :: Spec
spec = slow $ describe "algorithmic complexity (mock server)" $ do
  describe "length of a server error message (4x: 8,000 vs 32,000 characters)" $
    it "SqlServerError carries it without excess allocation" $ do
      let run :: Int -> IO (Maybe Word64)
          run n = do
            (alloc, ()) <- allocatedDuring $
              withScriptedTokens [errorToken (msg (T.replicate n "e")), doneToken 0x02 0] $ \conn -> do
                r <- try (goodQuery conn) :: IO (Either SomeException [Only Int32])
                case r of
                  Left e -> case fromException e of
                    Just se -> T.length (sqlErrorMessage se) `shouldBe` n
                    Nothing -> expectationFailure ("expected SqlServerError, got " ++ describeException e)
                  Right v -> expectationFailure ("expected an error, got " ++ show v)
            pure alloc
      small <- run 8000
      large <- run 32000
      subQuadraticAlloc "error message length" 4 small large

  describe "deep NBCROW null bitmaps (4x: 1,024 vs 4,096 all-NULL columns)" $
    it "decodes every column without excess allocation" $ do
      let run :: Int -> IO (Maybe Word64)
          run cnt = do
            let cols = [(tshow i, TIIntN 4) | i <- [1 .. cnt :: Int]]
            (alloc, r) <- allocatedDuring $
              withScriptedTokens [colMetaData cols, allNullNbcRow cnt, doneToken 0x10 1] firstQuery
            case r of
              Right [ResultSet _ [row]] -> do
                length (sqlRowValues row) `shouldBe` cnt
                sqlRowValues row `shouldBe` replicate cnt SqlNull
              other -> expectationFailure ("unexpected result: " ++ take 200 (show other))
            pure alloc
      small <- run 1024
      large <- run 4096
      subQuadraticAlloc "NBCROW column count" 4 small large

  describe "unknown-length PLP made of many tiny chunks (4x: 50,000 vs 200,000 chunks)" $
    it "reassembles it without excess allocation" $ do
      let run :: Int -> IO (Maybe Word64)
          run chunks = do
            (alloc, ()) <- allocatedDuring $
              withScriptedTokens
                [ colMetaData [("v", vbin)]
                , Put.putWord8 0xD1 >> plpValue chunks
                , doneToken 0x10 1
                ]
                $ \conn -> do
                  r <- try (query conn "SELECT v") :: IO (Either SomeException [Only B.ByteString])
                  case r of
                    Right [Only bs] -> B.length bs `shouldBe` chunks
                    other -> expectationFailure ("unexpected result: " ++ describeOutcome other)
            pure alloc
      small <- run 50000
      large <- run 200000
      subQuadraticAlloc "PLP chunk count" 4 small large
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

    describeOutcome :: Show a => Either SomeException a -> String
    describeOutcome = either describeException show
