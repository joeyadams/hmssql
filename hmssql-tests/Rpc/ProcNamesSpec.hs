-- | RPC procedure-name resolution: schemas, quoting, multi-part names, temp
-- and system procedures, synonyms, and identifier-length edge cases.
module Rpc.ProcNamesSpec (spec) where

import Control.Exception (SomeException, finally, try)
import Data.Either (isLeft)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Errors
import Rpc.Common
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "schema-qualified names" $ do
    it "calls a procedure in a non-dbo schema" $ \conn -> do
      schema <- uniqueName "hmssql_rpc_schema"
      name <- uniqueName "hmssql_rpc_proc"
      execute conn (rawSql ("CREATE SCHEMA " <> quoteName schema)) `shouldReturn` 0
      let cleanup = execute conn (rawSql ("DROP SCHEMA " <> quoteName schema))
      flip finally cleanup $ do
        execute conn (rawSql ("CREATE OR ALTER PROCEDURE " <> quoteName schema <> "." <> quoteName name <> " AS SELECT 42 AS a"))
          `shouldReturn` 0
        let cleanupProc = execute conn (rawSql ("DROP PROCEDURE " <> quoteName schema <> "." <> quoteName name))
        flip finally cleanupProc $ do
          res <- callProcedure conn (quoteName schema <> "." <> quoteName name) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 42]]]

  describe "quoted / unusual identifiers" $ do
    it "calls a procedure whose name contains spaces" $ \conn -> do
      raw <- uniqueName "hmssql rpc proc with spaces"
      callNamedProc conn raw

    it "calls a procedure whose name contains unicode characters" $ \conn -> do
      base <- uniqueName "hmssql_rpc_unicode"
      callNamedProc conn (base <> "_héllo_wörld_日本語")

    it "calls a procedure whose name contains a closing bracket" $ \conn -> do
      base <- uniqueName "hmssql_rpc_bracket"
      callNamedProc conn (base <> "_]_end")

  describe "multi-part names" $ do
    skipOnAzure "no three-part names into another database (error 40515)" $
      it "calls a procedure via a three-part database.schema.name reference" $ \conn -> do
      -- In the companion database.
      name <- uniqueName "hmssql_rpc_threepart"
      cci <- companionConnectInfo
      withConnection cci $ \other ->
        execute other (rawSql ("CREATE OR ALTER PROCEDURE dbo." <> name <> " AS SELECT 7 AS a")) `shouldReturn` 0
      let dbName = connectDatabase cci
          dropProc = withConnection cci $ \other -> execute other (rawSql ("DROP PROCEDURE IF EXISTS dbo." <> name))
      flip finally dropProc $ do
        res <- callProcedure conn (quoteName dbName <> ".dbo." <> name) []
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 7]]]

  describe "temporary procedures" $ do
    it "calls a session-scoped temp procedure (#p)" $ \conn -> do
      name <- uniqueName "hmssql_rpc_temp"
      let full = "#" <> name
      execute conn (rawSql ("CREATE PROCEDURE " <> full <> " AS SELECT 11 AS a")) `shouldReturn` 0
      res <- callProcedure conn full []
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 11]]]

    it "calls a global temp procedure (##p)" $ \conn -> do
      name <- uniqueName "hmssql_rpc_gtemp"
      let full = "##" <> name
      execute conn (rawSql ("CREATE PROCEDURE " <> full <> " AS SELECT 13 AS a")) `shouldReturn` 0
      res <- callProcedure conn full [] `finally` execute conn (rawSql ("DROP PROCEDURE IF EXISTS " <> full))
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 13]]]

  describe "system and extended procedures" $ do
    it "calls sp_help on a table and gets several result sets" $ \conn -> do
      -- sp_help resolves its @objname by looking the name up in the
      -- database's catalog; a session-scoped #temp table's mangled catalog
      -- name isn't found by its ordinary #-prefixed name, so use a real table.
      name <- uniqueName "hmssql_rpc_sphelp"
      execute conn (rawSql ("CREATE TABLE dbo." <> name <> " (a int, b nvarchar(10))")) `shouldReturn` 0
      res <- callProcedure conn "sp_help" [inp "" ("dbo." <> name)]
        `finally` execute conn (rawSql ("DROP TABLE dbo." <> name))
      length (procResultSets res) `shouldSatisfy` (> 1)

    it "calls sp_helptext on a procedure's definition" $ \conn -> do
      name <- uniqueName "hmssql_rpc_helptext"
      withProc conn name "AS SELECT 1" $ do
        res <- callProcedure conn "sp_helptext" [inp "" ("dbo." <> name)]
        case procResultSets res of
          [rs] -> length (resultRows rs) `shouldSatisfy` (> 0)
          other -> expectationFailure ("result sets: " ++ show (map (length . resultRows) other))

    it "calls sp_who2 and gets a dynamic result set" $ \conn -> do
      res <- callProcedure conn "sp_who2" []
      case procResultSets res of
        [rs] -> length (resultRows rs) `shouldSatisfy` (> 0)
        other -> expectationFailure ("result sets: " ++ show (map (length . resultRows) other))

    it "sp_executesql by name (RPC) agrees with query/execute (by RpcProcId)" $ \conn -> do
      -- query/execute always dispatch sp_executesql by its well-known RpcProcId
      -- (Hmssql.Query.executeSqlRequest); calling it explicitly by name here
      -- should behave identically.
      rowsById <- query conn (mkQuery "SELECT @p1 + @p2" (1 :: Int32, 2 :: Int32))
      res <- callProcedure conn "sp_executesql"
        [ inp "" ("SELECT @p1 + @p2" :: Text)
        , inp "" ("@p1 int, @p2 int" :: Text)
        , inp "@p1" (1 :: Int32), inp "@p2" (2 :: Int32)
        ]
      case procResultSets res of
        [rs] -> map sqlRowValues (resultRows rs) `shouldBe` [[SqlInt32 3]]
        other -> expectationFailure ("result sets: " ++ show other)
      rowsById `shouldBe` [Only (3 :: Int32)]

    it "calls sp_prepexec (prepare and execute in one RPC)" $ \conn -> do
      res <- callProcedure conn "sp_prepexec"
        [ out "" (0 :: Int32)
        , inp "" ("@a int" :: Text)
        , inp "" ("SELECT @a * 2 AS a" :: Text)
        , inp "" (21 :: Int32)
        ]
      case procResultSets res of
        [rs] -> map sqlRowValues (resultRows rs) `shouldBe` [[SqlInt32 42]]
        other -> expectationFailure ("result sets: " ++ show other)
      case map decodeReturnValue (procOutputValues res) :: [Either DecodeError Int32] of
        [Right h] -> () <$ callProcedure conn "sp_unprepare" [inp "" h]
        other -> expectationFailure ("handle: " ++ show other)

    skipOnAzure "no extended procedures" $ it "calls an extended procedure (xp_msver)" $ \conn -> do
      res <- callProcedure conn "xp_msver" []
      case procResultSets res of
        [rs] -> length (resultRows rs) `shouldSatisfy` (> 0)
        other -> expectationFailure ("result sets: " ++ show (map (length . resultRows) other))

  describe "synonyms" $
    it "calls a procedure through a synonym" $ \conn -> do
      name <- uniqueName "hmssql_rpc_syn_target"
      syn <- uniqueName "hmssql_rpc_syn"
      withProc conn name "AS SELECT 21 AS a" $ do
        execute conn (rawSql ("CREATE SYNONYM dbo." <> syn <> " FOR dbo." <> name)) `shouldReturn` 0
        res <- callProcedure conn ("dbo." <> syn) [] `finally` execute conn (rawSql ("DROP SYNONYM dbo." <> syn))
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 21]]]

  describe "identifier length" $ do
    it "calls a procedure with a 128-character name (the maximum)" $ \conn -> do
      uid <- uniqueName "hmssql128"
      let name = T.take 128 (uid <> T.replicate 128 "x")
      T.length uid `shouldSatisfy` (< 128)
      withProc conn name "AS SELECT 1 AS a" $ do
        T.length name `shouldBe` 128
        res <- callProcedure conn ("dbo." <> name) []
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]

    it "reports a clean error for a name of 129 characters (too long to exist)" $ \conn -> do
      let name = T.replicate 129 "y"
      r <- try (callProcedure conn ("dbo." <> name) []) :: IO (Either SqlServerError ProcResult)
      case r of
        Left _ -> pure ()  -- a clean server error; the exact number isn't pinned down
        Right res -> expectationFailure ("succeeded: " ++ show res)

  describe "malformed names" $ do
    it "reports a clean error, and leaves the connection usable, for a proc name of '@x'" $ \conn -> do
      r <- try (callProcedure conn "@x" []) :: IO (Either SomeException ProcResult)
      isLeft r `shouldBe` True
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "reports a clean error, and leaves the connection usable, for an empty proc name" $ \conn -> do
      r <- try (callProcedure conn "" []) :: IO (Either SomeException ProcResult)
      isLeft r `shouldBe` True
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

-- | Create a procedure named @dbo.\<quoted raw>@ (bracket-quoted for the
-- literal-name variants above) returning a fixed row, call it, and clean up.
callNamedProc :: Connection -> Text -> IO ()
callNamedProc conn raw = do
  let full = "dbo." <> quoteName raw
  execute conn (rawSql ("CREATE OR ALTER PROCEDURE " <> full <> " AS SELECT 5 AS a")) `shouldReturn` 0
  res <- callProcedure conn full [] `finally` execute conn (rawSql ("DROP PROCEDURE " <> full))
  map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 5]]]
