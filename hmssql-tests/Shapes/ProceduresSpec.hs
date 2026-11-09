-- | Shapes of stored-procedure calls: return status, output parameters
-- (including NULL), nested calls, errors, missing procedures/parameters, and
-- procedures whose result-set shape varies by call.
module Shapes.ProceduresSpec (spec) where

import Control.Exception (finally, try)
import Data.Int (Int32)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Token (ReturnValue (..))
import TestDb

-- | Short names for 'outParam' and 'inParam', so that a call's parameter
-- list reads as a table.
out :: ToSqlField a => Text -> a -> ProcParam
out = outParam

inp :: ToSqlField a => Text -> a -> ProcParam
inp = inParam

outValues :: ProcResult -> [Either DecodeError SqlValue]
outValues = map decodeReturnValue . procOutputValues

tshow :: Show a => a -> Text
tshow = T.pack . show

mkProc :: Connection -> Text -> Text -> IO ()
mkProc conn name body = () <$ execute conn (rawSql ("CREATE OR ALTER PROCEDURE dbo." <> name <> " " <> body))

dropProc :: Connection -> Text -> IO ()
dropProc conn name = () <$ execute conn (rawSql ("DROP PROCEDURE IF EXISTS dbo." <> name))

withProc :: Connection -> Text -> Text -> IO a -> IO a
withProc conn name body act = do
  mkProc conn name body
  act `finally` dropProc conn name

spec :: Spec
spec = around withTestDb $ do
  describe "return status" $ do
    it "reports a return status with no result sets" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_ret"
      withProc conn name "AS RETURN 42" $ do
        res <- callProcedure conn ("dbo." <> name) []
        procReturnStatus res `shouldBe` Just 42
        procResultSets res `shouldBe` []

    it "reports a return status alongside result sets" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_ret2"
      withProc conn name "AS BEGIN SELECT 1 AS a; SELECT 2 AS b, 3 AS c; RETURN 5 END" $ do
        res <- callProcedure conn ("dbo." <> name) []
        procReturnStatus res `shouldBe` Just 5
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]], [[SqlInt32 2, SqlInt32 3]]]

  describe "output parameters" $ do
    it "decodes output parameters of several types, including one left NULL (looked up by name)" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out"
      withProc conn name
        "@n int OUTPUT, @t nvarchar(50) OUTPUT, @unset int OUTPUT \
        \AS BEGIN SET @n = 99; SET @t = N'hello'; END" $ do
        let pn = outParam "@n" (0 :: Int32)
        let pt = outParam "@t" ("" :: Text)
        let pu = outParam "@unset" (Nothing :: Maybe Int32)
        res <- callProcedure conn ("dbo." <> name) [pn, pt, pu]
        -- look up by name
        let byName n = [rv | rv <- procOutputValues res, rvName rv == n]
        case byName "@n" of
          [rn] -> decodeReturnValue rn `shouldBe` Right (99 :: Int32)
          other -> expectationFailure ("@n: " ++ show other)
        case byName "@t" of
          [rt] -> decodeReturnValue rt `shouldBe` Right ("hello" :: Text)
          other -> expectationFailure ("@t: " ++ show other)
        case byName "@unset" of
          [ru] -> decodeReturnValue ru `shouldBe` Right (Nothing :: Maybe Int32)
          other -> expectationFailure ("@unset: " ++ show other)

    it "returns output parameters in the caller's parameter order" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_order"
      withProc conn name
        "@n int OUTPUT, @t nvarchar(50) OUTPUT, @unset int OUTPUT \
        \AS BEGIN SET @n = 99; SET @t = N'hello'; END" $ do
        let pn = outParam "@n" (0 :: Int32)
        let pt = outParam "@t" ("" :: Text)
        let pu = outParam "@unset" (Nothing :: Maybe Int32)
        res <- callProcedure conn ("dbo." <> name) [pn, pt, pu]
        -- The server sends @t (nvarchar(max) after widening) last
        map rvName (procOutputValues res) `shouldBe` ["@n", "@t", "@unset"]
        outValues res `shouldBe` [Right (SqlInt32 99), Right (SqlText "hello"), Right SqlNull]

    it "keeps caller order with input parameters interleaved, by name and by position" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_mixed"
      withProc conn name
        "@a int, @x nvarchar(20) OUTPUT, @b int = 5, @y int OUTPUT, @c int = 7, @z nvarchar(20) OUTPUT \
        \AS BEGIN SET @x = CONCAT(N'x', @a); SET @y = @b; SET @z = CONCAT(N'z', @c); END" $ do
        -- all by name
        r1 <- callProcedure conn ("dbo." <> name)
          [inp "@a" (1 :: Int32), out "@x" ("" :: Text), inp "@b" (2 :: Int32), out "@y" (0 :: Int32), inp "@c" (3 :: Int32), out "@z" ("" :: Text)]
        outValues r1 `shouldBe` [Right (SqlText "x1"), Right (SqlInt32 2), Right (SqlText "z3")]
        -- all by position
        r2 <- callProcedure conn ("dbo." <> name)
          [inp "" (1 :: Int32), out "" ("" :: Text), inp "" (2 :: Int32), out "" (0 :: Int32), inp "" (3 :: Int32), out "" ("" :: Text)]
        outValues r2 `shouldBe` [Right (SqlText "x1"), Right (SqlInt32 2), Right (SqlText "z3")]
        -- by name, in a different order than declared, relying on defaults
        r3 <- callProcedure conn ("dbo." <> name)
          [out "@z" ("" :: Text), inp "@a" (1 :: Int32), out "@y" (0 :: Int32), out "@x" ("" :: Text)]
        map rvName (procOutputValues r3) `shouldBe` ["@z", "@y", "@x"]
        outValues r3 `shouldBe` [Right (SqlText "z7"), Right (SqlInt32 5), Right (SqlText "x1")]
        -- positional, then by name
        r4 <- callProcedure conn ("dbo." <> name)
          [inp "" (4 :: Int32), out "" ("" :: Text), out "@z" ("" :: Text), inp "@b" (6 :: Int32), out "@y" (0 :: Int32)]
        outValues r4 `shouldBe` [Right (SqlText "x4"), Right (SqlText "z7"), Right (SqlInt32 6)]

    it "keeps caller order for many output parameters of the same types, which the server reorders" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_many"
      let n = 12 :: Int
          decls = [ "@i" <> tshow k <> " int OUTPUT, @s" <> tshow k <> " nvarchar(20) OUTPUT" | k <- [1 .. n] ]
          sets = [ "SET @i" <> tshow k <> " = " <> tshow (k * 10) <> "; SET @s" <> tshow k <> " = N's" <> tshow k <> "';" | k <- [1 .. n] ]
      withProc conn name (T.intercalate ", " decls <> " AS BEGIN " <> T.unwords sets <> " END") $ do
        -- a shuffled order, by name
        let order = [7, 2, 11, 1, 12, 5, 9, 3, 10, 4, 8, 6] :: [Int]
            params = concat [ [out ("@s" <> tshow k) ("" :: Text), out ("@i" <> tshow k) (0 :: Int32)] | k <- order ]
            expected = concat [ [Right (SqlText ("s" <> tshow k)), Right (SqlInt32 (fromIntegral (k * 10)))] | k <- order ]
        res <- callProcedure conn ("dbo." <> name) params
        outValues res `shouldBe` expected
        -- Decoding each by the type the caller expects at that position works
        [ decodeReturnValue @Text rv | (k, rv) <- zip [0 :: Int ..] (procOutputValues res), even k ]
          `shouldBe` [ Right ("s" <> tshow k) | k <- order ]

    it "keeps caller order when some outputs are NULL" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_nulls"
      withProc conn name
        "@a nvarchar(20) OUTPUT, @b int OUTPUT, @c varbinary(20) OUTPUT, @d int OUTPUT, @e nvarchar(20) OUTPUT \
        \AS BEGIN SET @a = NULL; SET @b = 2; SET @c = NULL; SET @d = NULL; SET @e = N'e'; END" $ do
        res <- callProcedure conn ("dbo." <> name)
          [out "@a" ("init" :: Text), out "@b" (Nothing :: Maybe Int32), out "@c" (Just ("\1" :: ByteString)), out "@d" (Just (4 :: Int32)), out "@e" (Nothing :: Maybe Text)]
        outValues res `shouldBe` [Right SqlNull, Right (SqlInt32 2), Right SqlNull, Right SqlNull, Right (SqlText "e")]

    it "throws when the procedure errors after setting some outputs, and the connection stays usable" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_err"
      withProc conn name
        "@x int OUTPUT, @s nvarchar(20) OUTPUT, @y int OUTPUT \
        \AS BEGIN SET @x = 1; SET @s = N's'; RAISERROR('boom', 16, 1); SET @y = 2; END" $ do
        r <- try (callProcedure conn ("dbo." <> name) [out "@x" (0 :: Int32), out "@s" ("" :: Text), out "@y" (0 :: Int32)])
        case r of
          Left e -> sqlErrorMessage e `shouldBe` "boom"
          Right res -> expectationFailure ("succeeded: " ++ show res)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "keeps caller order when the procedure catches an error after setting some outputs" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_caught"
      withProc conn name
        "@x int OUTPUT, @s nvarchar(20) OUTPUT, @y int OUTPUT \
        \AS BEGIN BEGIN TRY SET @s = N's'; SET @x = 1 / 0; SET @y = 2; END TRY \
        \BEGIN CATCH SET @x = ERROR_NUMBER(); END CATCH END" $ do
        res <- callProcedure conn ("dbo." <> name) [out "@y" (0 :: Int32), out "@s" ("" :: Text), out "@x" (0 :: Int32)]
        outValues res `shouldBe` [Right (SqlInt32 0), Right (SqlText "s"), Right (SqlInt32 8134)]

    it "keeps caller order for output parameters of sp_executesql" $ \conn -> do
      res <- callProcedure conn "sp_executesql"
        [ inp "" ("SET @q = CONCAT(N'q', @in); SET @r = @in + 1; SET @s = N's';" :: Text)
        , inp "" ("@s nvarchar(20) OUTPUT, @in int, @q nvarchar(20) OUTPUT, @r int OUTPUT" :: Text)
        , out "@q" ("" :: Text), inp "@in" (9 :: Int32), out "@r" (0 :: Int32), out "@s" ("" :: Text) ]
      map rvName (procOutputValues res) `shouldBe` ["@q", "@r", "@s"]
      outValues res `shouldBe` [Right (SqlText "q9"), Right (SqlInt32 10), Right (SqlText "s")]

    it "returns a scalar function's return value as the only output value" $ \conn -> do
      name <- uniqueName "hmssql_shapes_fn_ret"
      execute conn (rawSql ("CREATE OR ALTER FUNCTION dbo." <> name <> " (@a int, @b int) RETURNS int AS BEGIN RETURN @a * 10 + @b END")) `shouldReturn` 0
      flip finally (execute conn (rawSql ("DROP FUNCTION IF EXISTS dbo." <> name))) $ do
        res <- callProcedure conn ("dbo." <> name) [inp "@b" (2 :: Int32), inp "@a" (4 :: Int32)]
        outValues res `shouldBe` [Right (SqlInt32 42)]
        map rvStatus (procOutputValues res) `shouldBe` [0x02]

    it "reports a NULL output parameter that started non-NULL" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_out_null"
      withProc conn name "@n int OUTPUT AS BEGIN SET @n = NULL; END" $ do
        let pn = outParam "@n" (7 :: Int32)
        res <- callProcedure conn ("dbo." <> name) [pn]
        case procOutputValues res of
          [rn] -> decodeReturnValue rn `shouldBe` Right (Nothing :: Maybe Int32)
          other -> expectationFailure ("outputs: " ++ show other)

  describe "errors" $ do
    it "throws when a RAISERROR fires inside the procedure body" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_err"
      withProc conn name "AS BEGIN SELECT 1; RAISERROR('boom', 16, 1); END" $ do
        r <- try (callProcedure conn ("dbo." <> name) [])
        case r of
          Left e -> sqlErrorMessage e `shouldBe` "boom"
          Right res -> expectationFailure ("succeeded: " ++ show res)
        query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "reports a clean error for a procedure that doesn't exist" $ \conn -> do
      r <- try (callProcedure conn "dbo.hmssql_shapes_no_such_proc" [])
      case r of
        Left e -> sqlErrorNumber e `shouldBe` 2812
        Right res -> expectationFailure ("succeeded: " ++ show res)

    it "reports a clean error for too many parameters" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_wrongcount"
      withProc conn name "@a int AS SELECT @a" $ do
        let pa = inParam "@a" (1 :: Int32)
        let pb = inParam "@b" (2 :: Int32)
        r <- try (callProcedure conn ("dbo." <> name) [pa, pb])
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 8144
          Right res -> expectationFailure ("succeeded: " ++ show res)

    it "reports a clean error when a required parameter is missing" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_missing"
      withProc conn name "@a int, @b int AS SELECT @a + @b" $ do
        let pa = inParam "@a" (1 :: Int32)
        r <- try (callProcedure conn ("dbo." <> name) [pa])
        case r of
          Left e -> sqlErrorNumber e `shouldBe` 201
          Right res -> expectationFailure ("succeeded: " ++ show res)

  describe "nesting and system procedures" $ do
    it "captures result sets from a nested procedure call, and the outer return status" $ \conn -> do
      inner <- uniqueName "hmssql_shapes_proc_inner"
      outer <- uniqueName "hmssql_shapes_proc_outer"
      mkProc conn inner "AS BEGIN SELECT N'from inner' AS x; RETURN 99 END"
      let cleanup = dropProc conn outer >> dropProc conn inner
      flip finally cleanup $ do
        mkProc conn outer
          ( "AS BEGIN DECLARE @r int; EXEC @r = dbo." <> inner <> "; \
            \SELECT N'from outer' AS y; RETURN 7 END" )
        res <- callProcedure conn ("dbo." <> outer) []
        procReturnStatus res `shouldBe` Just 7
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe`
          [[[SqlText "from inner"]], [[SqlText "from outer"]]]

    it "calls a system procedure (sp_who) and gets a dynamic result set" $ \conn -> do
      res <- callProcedure conn "sp_who" []
      case procResultSets res of
        [ResultSet cols rows] -> do
          ("spid" `elem` map columnName cols) `shouldBe` True
          length rows `shouldSatisfy` (> 0)
        other -> expectationFailure ("result sets: " ++ show other)

  describe "varying shape" $
    it "returns result sets of different shapes on different calls" $ \conn -> do
      name <- uniqueName "hmssql_shapes_proc_varying"
      withProc conn name
        "@wide bit AS BEGIN \
        \IF @wide = 1 SELECT 1 AS a, 2 AS b, 3 AS c \
        \ELSE SELECT 1 AS a END" $ do
        let pNarrow = inParam "@wide" False
        let pWide = inParam "@wide" True
        narrow <- callProcedure conn ("dbo." <> name) [pNarrow]
        wide <- callProcedure conn ("dbo." <> name) [pWide]
        map (length . resultColumns) (procResultSets narrow) `shouldBe` [1]
        map (length . resultColumns) (procResultSets wide) `shouldBe` [3]
