-- | Named-parameter misuse not already covered by 'Shapes.ParametersSpec'
-- (which covers parameter counts up to the 2098/2099 boundary, NULLs of
-- every type, unicode\/keyword-like names, an unused declared parameter, and
-- a parameter referenced many times): a SQL name the caller never supplies a
-- value for, and misuse within a single 'NamedParams' list (duplicate names,
-- names colliding only case-insensitively or by the optional leading @\@@,
-- and an empty name).  Every case is asserted on 'sqlErrorNumber'\/
-- 'sqlErrorMessage' or the exact 'EncodeError' text, not just "it threw".
--
-- A query without parameters is sent as a plain batch, one with parameters
-- through sp_executesql.  Positional and named parameters can be mixed in
-- one query by composing with '<>' ('param', 'namedParam', 'mkQuery'); that,
-- a name used twice across '<>', a named parameter called @\@pN@ and a
-- placeholder with no parameter are covered by "QuerySpec" ("the Query type
-- against the server").
module Api.ParameterMisuseSpec (spec) where

import Control.Exception (try)
import Data.Char (toLower)
import Data.Int (Int64)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Errors
import TestDb

spec :: Spec
spec = around withTestDb $ do
  describe "a SQL name the caller never supplies a value for" $ do
    it "reports a clean server error when no parameters are supplied at all (a plain batch, where @missing is an undeclared variable)" $ \conn -> do
      r <- try (query1 conn "SELECT @missing") :: IO (Either SqlServerError (Only Int))
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 137
          sqlErrorMessage e `shouldSatisfy` T.isInfixOf "@missing"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "reports a clean server error when other named parameters are supplied but the referenced one is not (only @pN placeholders are checked before sending)" $ \conn -> do
      r <- try (query1 conn (mkQuery "SELECT @a, @b" (NamedParams [("a", SqlParam (1 :: Int))])))
             :: IO (Either SqlServerError (Int, Int))
      case r of
        Left e -> do
          sqlErrorNumber e `shouldBe` 137
          sqlErrorMessage e `shouldSatisfy` T.isInfixOf "@b"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "a NamedParams name that never appears anywhere in the SQL text" $
    it "is harmless: sp_executesql declares every supplied name regardless of whether the SQL text mentions it" $ \conn -> do
      -- executeSqlRequest builds the @params declaration string from every
      -- name the caller passes, not from what the SQL text references, so a
      -- name absent from the SQL text is indistinguishable on the wire from
      -- one that's merely unused (already covered by Shapes.ParametersSpec's
      -- "allows an unused declared parameter"). There is no way through
      -- NamedParams to send a name sp_executesql won't declare.
      --
      -- The result (1) is just the row count of the (unrelated) row-returning
      -- SELECT itself -- see Api.StatementShapeMisuseSpec -- not a signal
      -- about the parameter; the point of this test is that it succeeds at
      -- all instead of erroring.
      n <- execute conn (mkQuery "SELECT 1" (NamedParams [("neverMentioned", SqlParam (1 :: Int))]))
      n `shouldBe` 1

  describe "duplicate names within one NamedParams list" $ do
    it "rejects an exact duplicate with a clean EncodeError before any request is sent" $ \conn -> do
      r <- try (execute conn (mkQuery "SELECT 1" (NamedParams [("dup", SqlParam (1 :: Int)), ("dup", SqlParam (2 :: Int))])))
             :: IO (Either EncodeError Int64)
      case r of
        Left (EncodeError msg) -> msg `shouldBe` "duplicate parameter name @dup"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "rejects names colliding only case-insensitively, with or without the leading @" $ \conn -> do
      r <- try (execute conn (mkQuery "SELECT 1" (NamedParams [("@Foo", SqlParam (1 :: Int)), ("foo", SqlParam (2 :: Int))])))
             :: IO (Either EncodeError Int64)
      case r of
        Left (EncodeError msg) -> do
          msg `shouldContain` "duplicate parameter name"
          map toLower msg `shouldContain` "foo"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

  describe "an empty parameter name" $
    it "is rejected with a clean EncodeError before any request is sent" $ \conn -> do
      r <- try (execute conn (mkQuery "SELECT 1" (NamedParams [("", SqlParam (1 :: Int))]))) :: IO (Either EncodeError Int64)
      case r of
        Left (EncodeError msg) -> msg `shouldBe` "empty parameter name"
        Right v -> expectationFailure ("succeeded: " ++ show v)
      query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)
