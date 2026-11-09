-- | Server cursors and prepared statements, called through 'callProcedure'
-- exactly as a driver that dispatches by well-known RPC id would: @sp_cursoropen@\/
-- @sp_cursorfetch@\/@sp_cursorclose@ (a cursor handle comes back as an output
-- parameter, and fetched rows carry an extra ROWSTAT column), and
-- @sp_prepare@\/@sp_execute@\/@sp_unprepare@ and @sp_prepexec@ (a statement
-- handle as an output parameter, reused across executions).
module Session.CursorsSpec (spec) where

import Control.Exception (try)
import Data.Int (Int32)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import TestDb

int32 :: Int32 -> ProcParam
int32 = inParam ""

outInt32 :: ProcParam
outInt32 = outParam "" (0 :: Int32)

text :: T.Text -> ProcParam
text = inParam ""

-- | Decode the first output value (by position) as an 'Int32'.
firstOut :: ProcResult -> Int32
firstOut res = case procOutputValues res of
  (rv : _) -> either (error . show) id (decodeReturnValue rv)
  [] -> error "firstOut: no output values"

spec :: Spec
spec = around withTestDb $ do
  describe "sp_cursoropen / sp_cursorfetch / sp_cursorclose" $ do
    it "opens a cursor over a query, fetches rows (with a ROWSTAT column), and closes it" $ \conn -> do
      _ <- execute conn "CREATE TABLE #curstbl (i int, s nvarchar(10)); \
                         \INSERT INTO #curstbl VALUES (1,'a'),(2,'b'),(3,'c')"
      openRes <- callProcedure conn "sp_cursoropen"
        [ outInt32 -- @cursor OUTPUT
        , text "SELECT i, s FROM #curstbl ORDER BY i" -- @stmt
        , int32 1 -- @scrollopt (keyset-driven)
        , int32 1 -- @ccopt (read-only)
        , outInt32 -- @rowcount OUTPUT
        ]
      let handle = firstOut openRes
      handle `shouldSatisfy` (/= 0)
      fetchRes <- callProcedure conn "sp_cursorfetch"
        [ int32 handle
        , int32 2 -- FETCH_NEXT
        , int32 0
        , int32 2 -- number of rows
        ]
      case procResultSets fetchRes of
        [ResultSet cols rows] -> do
          map columnName cols `shouldBe` ["i", "s", "ROWSTAT"]
          map sqlRowValues rows `shouldBe`
            [ [SqlInt32 1, SqlText "a", SqlInt32 1]
            , [SqlInt32 2, SqlText "b", SqlInt32 1]
            ]
        other -> expectationFailure ("result sets: " ++ show other)
      _ <- callProcedure conn "sp_cursorclose" [int32 handle]
      -- the connection is still usable afterwards
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "reports a clean error when fetching from an already-closed cursor" $ \conn -> do
      _ <- execute conn "CREATE TABLE #curstbl2 (i int); INSERT INTO #curstbl2 VALUES (1)"
      openRes <- callProcedure conn "sp_cursoropen"
        [outInt32, text "SELECT i FROM #curstbl2", int32 1, int32 1, outInt32]
      let handle = firstOut openRes
      _ <- callProcedure conn "sp_cursorclose" [int32 handle]
      r <- try (callProcedure conn "sp_cursorfetch" [int32 handle, int32 2, int32 0, int32 1])
        :: IO (Either SqlServerError ProcResult)
      case r of
        Left _ -> pure () -- a clean SQL error, not a hang or garbled decode
        Right res -> expectationFailure ("succeeded: " ++ show res)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "sp_prepare / sp_execute / sp_unprepare" $ do
    it "prepares a parameterized statement and reuses the handle across executions" $ \conn -> do
      prepRes <- callProcedure conn "sp_prepare"
        [outInt32, text "@x int", text "SELECT @x + 1 AS r"]
      let handle = firstOut prepRes
      handle `shouldSatisfy` (/= 0)
      r1 <- callProcedure conn "sp_execute" [int32 handle, int32 41]
      map (map sqlRowValues . resultRows) (procResultSets r1) `shouldBe` [[[SqlInt32 42]]]
      r2 <- callProcedure conn "sp_execute" [int32 handle, int32 100]
      map (map sqlRowValues . resultRows) (procResultSets r2) `shouldBe` [[[SqlInt32 101]]]
      _ <- callProcedure conn "sp_unprepare" [int32 handle]
      -- using it after sp_unprepare is a clean error, not a hang
      r3 <- try (callProcedure conn "sp_execute" [int32 handle, int32 1]) :: IO (Either SqlServerError ProcResult)
      case r3 of
        Left _ -> pure ()
        Right res -> expectationFailure ("succeeded after sp_unprepare: " ++ show res)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "sp_prepexec" $
    it "prepares and executes in one call, returning both the handle and the result" $ \conn -> do
      res <- callProcedure conn "sp_prepexec"
        [outInt32, text "@x int", text "SELECT @x * 2 AS r", int32 21]
      firstOut res `shouldSatisfy` (/= 0)
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 42]]]
