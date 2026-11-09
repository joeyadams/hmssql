{-# LANGUAGE ExistentialQuantification #-}
-- | RPC parameter passing: named vs. positional order, the byRef status flag,
-- the DEFAULT status flag, parameter-count limits, implicit conversion of
-- input parameters, NULLs, and table-valued parameters (unsupported).
module Rpc.ProcParamsSpec (spec) where

import RecipeParameters
import Control.Exception (finally, try)
import Data.ByteString (ByteString)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.SqlValue
import Hmssql.Errors
import Hmssql.Query
import Hmssql.Tds.Context (defaultTdsContext)
import Hmssql.Tds.Client (RpcParam (..), paramByRef, paramDefault)
import Hmssql.Tds.Token (Token (..))
import Rpc.Common
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "named vs. positional order" $ do
    it "allows a positional parameter after a named one (error 119 is an EXEC-statement parser rule, not an RPC one)" $ \conn -> do
      -- Directly resolving @b by its ordinal position among the not-yet-bound
      -- parameters, as if @a had never been named.
      name <- uniqueName "hmssql_rpcparam_posafter"
      withProc conn name "@a int, @b int AS SELECT @a, @b" $ do
        res <- callProcedure conn ("dbo." <> name) [inp "@a" (1 :: Int32), inp "" (2 :: Int32)]
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1, SqlInt32 2]]]

    it "accepts parameters entirely by position, and entirely by name" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_order"
      withProc conn name "@a int, @b int AS SELECT @a, @b" $ do
        r1 <- callProcedure conn ("dbo." <> name) [inp "" (1 :: Int32), inp "" (2 :: Int32)]
        r2 <- callProcedure conn ("dbo." <> name) [inp "@b" (2 :: Int32), inp "@a" (1 :: Int32)]
        map (map sqlRowValues . resultRows) (procResultSets r1) `shouldBe` [[[SqlInt32 1, SqlInt32 2]]]
        map (map sqlRowValues . resultRows) (procResultSets r2) `shouldBe` [[[SqlInt32 1, SqlInt32 2]]]

  describe "the byRef status flag" $ do
    it "an OUTPUT parameter passed without byRef runs normally but yields no output value" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_outnobyref"
      withProc conn name "@x int OUTPUT AS SET @x = 99" $ do
        res <- callProcedure conn ("dbo." <> name) [inp "@x" (0 :: Int32)]
        procOutputValues res `shouldBe` []

    it "byRef on a parameter not declared OUTPUT is a clean error (8162)" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_badbyref"
      withProc conn name "@a int AS SELECT @a" $ do
        let p0 = inParam "@a" (1 :: Int32)
        let p = p0 { procParamOutput = True }
        r <- try (callProcedure conn ("dbo." <> name) [p])
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 8162
          Right res -> expectationFailure ("succeeded: " ++ show res)

  describe "the DEFAULT status flag (low level; not exposed by ProcParam/outParam/inParam)" $
    it "a parameter sent with the DEFAULT flag uses the procedure's declared default, ignoring the wire value" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_default"
      withProc conn name "@x int = 111 OUTPUT AS SET @x = @x + 1" $ do
        let wrong = inParam "" (999 :: Int32)
        (ti, v) <- either (fail . ("the wrong value: " ++)) pure
          (procParamEncode wrong defaultTdsContext)
        let rp = RpcParam "@x" (paramDefault + paramByRef) ti v
        toks <- rpcRequest ("dbo." <> name) [rp] >>= responseS conn
        allToks <- S.toList_ toks
        let outs = [rv | TReturnValue rv <- allToks]
        case outs of
          [rv] -> decodeReturnValue rv `shouldBe` Right (112 :: Int32)
          other -> expectationFailure ("output values: " ++ show other)

  describe "parameter count limits" $ do
    it "calls a procedure with 2100 parameters (the maximum a procedure may declare)" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_2100"
      let n = 2100 :: Int
          decls = T.intercalate ", " ["@p" <> tshow k <> " int" | k <- [1 .. n]]
          body = "AS SELECT @p1, @p1050, @p" <> tshow n
      withProc conn name (decls <> " " <> body) $ do
        let params = [inp "" (fromIntegral k :: Int32) | k <- [1 .. n]]
        res <- callProcedure conn ("dbo." <> name) params
        map (map sqlRowValues . resultRows) (procResultSets res)
          `shouldBe` [[[SqlInt32 1, SqlInt32 1050, SqlInt32 (fromIntegral n)]]]

        -- A 2101st parameter value hits the RPC request's own parameter-count
        -- ceiling (error 8003, "the incoming request has too many
        -- parameters"), which is distinct from -- and reached before --
        -- 8144 ("too many arguments" for a specific procedure's signature;
        -- see the smaller-scale case in Shapes.ProceduresSpec).
        r <- try (callProcedure conn ("dbo." <> name) (params ++ [inp "" (0 :: Int32)]))
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 8003
          Right res' -> expectationFailure ("succeeded: " ++ show res')

  describe "implicit conversion of input parameters" $ do
    let convCases :: [InCase]
        convCases =
          [ InCase "nvarchar (Text) into varchar(20)" "varchar(20)" ("hello" :: Text) (SqlText "hello")
          , InCase "in-range Int64 into int" "int" (12345 :: Int64) (SqlInt32 12345)
          , InCase "Int32 into float (widening)" "float" (7 :: Int32) (SqlDouble 7.0)
          , InCase "Bool into bit" "bit" True (SqlBool True)
          ]
    mapM_ (runInCase) convCases

    it "an out-of-range Int64 into int is a clean overflow error (8114)" $ \conn -> do
      name <- uniqueName "hmssql_rpcparam_overflow"
      withProc conn name "@x int AS SELECT @x" $ do
        r <- try (callProcedure conn ("dbo." <> name) [inp "@x" (maxBound :: Int64)])
        case r of
          Left (e :: SqlServerError) -> sqlErrorNumber e `shouldBe` 8114
          Right res -> expectationFailure ("succeeded: " ++ show res)

  describe "NULL input parameters" $
    it "passes NULL for several parameter types" $ \conn -> do
      let go :: ToSqlField a => Text -> Text -> a -> Connection -> IO ()
          go label declType nullValue conn' = do
            name <- uniqueName ("hmssql_rpcparam_null_" <> label)
            withProc conn' name ("@x " <> declType <> " AS SELECT CASE WHEN @x IS NULL THEN 1 ELSE 0 END") $ do
              res <- callProcedure conn' ("dbo." <> name) [inp "@x" nullValue]
              map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]
      go "int" "int" (Nothing :: Maybe Int32) conn
      go "text" "nvarchar(20)" (Nothing :: Maybe Text) conn
      go "bin" "varbinary(20)" (Nothing :: Maybe ByteString) conn
      go "bool" "bit" (Nothing :: Maybe Bool) conn
      go "double" "float" (Nothing :: Maybe Double) conn

  describe "table-valued parameters (unsupported by hmssql: no encoding for TVPs)" $
    it "omitting a required TVP parameter uses SQL Server's implicit empty-table default" $ \conn -> do
      typeName <- uniqueName "hmssql_rpcparam_tvptype"
      name <- uniqueName "hmssql_rpcparam_tvpproc"
      execute conn (rawSql ("CREATE TYPE dbo." <> typeName <> " AS TABLE (v int)")) `shouldReturn` 0
      let cleanupType = execute conn (rawSql ("DROP TYPE dbo." <> typeName))
      flip finally cleanupType $
        withProc conn name ("@t dbo." <> typeName <> " READONLY AS SELECT COUNT(*) FROM @t") $ do
          -- hmssql has no ToSqlField instance (or TypeInfo constructor) for a
          -- TVP, so a caller cannot supply one; omitting it relies on SQL
          -- Server's own default-to-empty-table behaviour for TVPs, not on
          -- anything hmssql-specific.
          res <- callProcedure conn ("dbo." <> name) []
          map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 0]]]

-- | One implicit-conversion case: a Haskell value of type @a@, sent as the
-- input for a procedure parameter declared as 'icDeclType', should read back
-- (via a plain @SELECT \@x@) as 'icExpected'.
data InCase = forall a. ToSqlField a => InCase
  { icLabel :: String
  , icDeclType :: Text
  , icValue :: a
  , icExpected :: SqlValue
  }

runInCase :: InCase -> SpecWith Connection
runInCase InCase{..} =
  it (icLabel ++ " round-trips through a " ++ T.unpack icDeclType ++ " parameter") $ \conn -> do
    name <- uniqueName "hmssql_rpcparam_conv"
    withProc conn name ("@x " <> icDeclType <> " AS SELECT @x") $ do
      res <- callProcedure conn ("dbo." <> name) [inp "@x" icValue]
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[icExpected]]]
