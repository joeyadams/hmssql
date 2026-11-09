-- | Tests found by mutation testing of "Hmssql.Tds.Primitives",
-- "Hmssql.Tds.Client" and "Hmssql.Tds.TypeInfo": the lengths and quoting of
-- names on the wire.
module Mutation.WireNamesSpec (spec) where

import RecipeParameters
import Data.Maybe (isJust)
import qualified Data.Text as T
import Test.Hspec

import Hmssql.Types
import Hmssql.Tds.Client (RpcParam (..), RpcProc (..), RpcRequest (..), rpcParamProblem, rpcRequestProblem)
import Hmssql.Tds.Primitives (ucs2Length)
import Hmssql.Tds.TypeInfo (UdtInfo (..), typeInfoSqlName)

intParam :: T.Text -> RpcParam
intParam name = byteParam name 0 (TIIntN 4) (Just "\1\0\0\0")

spec :: Spec
spec = do
  describe "ucs2Length" $
    it "counts a character outside the BMP as two UTF-16 code units" $
      ucs2Length ("a" <> T.replicate 3 "\x1F600") `shouldBe` 7

  describe "rpcParamProblem" $ do
    it "allows a 255-unit parameter name, the most a B_VARCHAR holds, and no more" $ do
      rpcParamProblem (intParam ("@" <> T.replicate 254 "x")) `shouldBe` Nothing
      rpcParamProblem (intParam ("@" <> T.replicate 255 "x")) `shouldSatisfy` isJust

    it "measures a parameter name in UTF-16 code units, not characters" $ do
      -- 130 characters, but 1 + 2 * 129 = 259 code units: too long for a B_VARCHAR.
      let name = "@" <> T.replicate 129 "\x1F600"
      rpcParamProblem (intParam name) `shouldSatisfy` isJust

  describe "rpcRequestProblem" $
    it "allows a procedure name of 65534 code units; 65535 would read as a procedure ID" $ do
      let named n = RpcRequest (RpcProcName (T.replicate n "p")) 0 []
      rpcRequestProblem (named 65534) `shouldBe` Nothing
      rpcRequestProblem (named 65535) `shouldSatisfy` isJust

  describe "typeInfoSqlName of a user CLR type" $
    it "escapes ] in the schema and type names" $
      typeInfoSqlName (TIUdt (UdtInfo 0xFFFF "db" "odd]schema" "T]" "T, asm"))
        `shouldBe` "[odd]]schema].[T]]]"
