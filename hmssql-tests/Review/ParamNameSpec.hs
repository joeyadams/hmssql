-- | 'NamedParams' names must be T-SQL variable names: they are spliced into
-- the @\@params@ declaration string of @sp_executesql@, so a name such as
-- @"x int=1)DELETE ...--"@ would change the declaration (and run a
-- statement); names are therefore checked before anything is sent.  The
-- same holds for 'namedParam'.  Names of the form @\@pN@ are valid T-SQL but
-- reserved for the positional parameters, and refused likewise.
-- 'callProcedure' names aren't spliced into SQL (they are sent as data in
-- the RPC request), so they are not checked: the server matches them
-- against the procedure's parameters and reports what it can't match.
module Review.ParamNameSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Errors
import LiveProperty (liveHedgehog)
import TestDb

isEncodeError :: Either SomeException a -> Bool
isEncodeError = \case
  Left e -> isJust (fromException e :: Maybe EncodeError)
  Right _ -> False

-- | Names that are not T-SQL variable names (with or without the leading @).
invalidNames :: [Text]
invalidNames =
  [ "x int, @y", "x int=1)SELECT 1--", "x--", "x/*", "x;", "x'", "x\"", "x y", "x)", "x(", "x]", "[x]"
  , "x,", "x=1", "x.y", "x-y", "x+", "x\t", "x\n", "x\r", "x\0", "@", "@ x"
  , "x\x00A0"   -- no-break space (the server treats it as whitespace)
  , "x\x200B"   -- zero width space (likewise)
  , "x\x3000"   -- ideographic space
  , "x\x00B2"   -- superscript two: a number, but not a decimal digit
  , "x\x200D"   -- zero width joiner (a format character)
  , "x\x1D400"  -- a letter outside the BMP (the server rejects surrogates)
  , "x\xFF0C"   -- fullwidth comma
  ]

-- | Valid names; the server accepts each in a declaration.
validNames :: [Text]
validNames =
  [ "x", "@x", "X1", "@x$1", "@1", "@_", "#x", "@@x", "x#y", "x@y", "$"
  , "\233t\233"         -- precomposed letters
  , "e\x0301"           -- a combining mark
  , "\x53D8\x91CF"      -- CJK
  , "x\x2163"           -- a letter number (Roman numeral four)
  , "x\x0661"           -- an Arabic-Indic digit
  , "x\xFF11"           -- a fullwidth digit
  ]

withAt :: Text -> Text
withAt n = if "@" `T.isPrefixOf` n then n else "@" <> n

spec :: Spec
spec = around withTestDb $ do
  describe "NamedParams" $ do
    it "refuses a name that would inject a statement into the sp_executesql declaration" $ \conn -> do
      void $ execute conn "DROP TABLE IF EXISTS #inj; CREATE TABLE #inj (a int)"
      r <- try (query conn (mkQuery "SELECT @x" (NamedParams [("x int=1)INSERT INTO #inj VALUES (1)--", SqlParam (1 :: Int32))])) :: IO [Only Int32])
      r `shouldSatisfy` isEncodeError
      query conn "SELECT COUNT(*) FROM #inj" `shouldReturn` [Only (0 :: Int32)]

    it "refuses names that aren't T-SQL variable names, before sending anything" $ \conn ->
      forM_ invalidNames $ \n -> do
        r <- try (query conn (mkQuery "SELECT 1" (NamedParams [(n, SqlParam (1 :: Int32))])) :: IO [Only Int32])
        (n, isEncodeError r) `shouldBe` (n, True)

    it "names the offending parameter in the error" $ \conn -> do
      r <- try (query conn (mkQuery "SELECT 1" (NamedParams [("ok", SqlParam (1 :: Int32)), ("x y", SqlParam (2 :: Int32))])) :: IO [Only Int32])
      case r of
        Left (EncodeError msg) -> msg `shouldContain` "@x y"
        Right _ -> expectationFailure "no EncodeError"

    it "accepts every valid name the server does, with or without the @" $ \conn ->
      forM_ validNames $ \n -> do
        r <- query conn (mkQuery ("SELECT " <> withAt n) (NamedParams [(n, SqlParam (5 :: Int32))]))
        (n, r) `shouldBe` (n, [Only (5 :: Int32)])

    it "names made of arbitrary characters are refused or round-trip (never change the declaration)" $ \conn ->
      liveHedgehog $ do
        let pool = Gen.element (T.unpack " \t\n,;()'\"[]-/*=.@#$_xYz9\233\x0301\x200D\x00A0\x2163\x0661")
        body <- forAll (T.pack <$> Gen.list (Range.linear 1 6) pool)
        let n = "@x" <> body
        r <- evalIO (try (query conn (mkQuery ("SELECT " <> n) (NamedParams [(n, SqlParam (7 :: Int32))]))))
        case r of
          Left e | isJust (fromException e :: Maybe EncodeError) -> success
          Left e -> annotate (show e) >> failure
          Right rows -> rows === [Only (7 :: Int32)]

    it "refuses the names of the positional parameters, @p1, @P2, ..., as reserved" $ \conn ->
      forM_ ["p1", "@P2"] $ \n -> do
        r <- try (query conn (mkQuery "SELECT 1" (NamedParams [(n, SqlParam (1 :: Int32))])) :: IO [Only Int32])
        case r of
          Left (EncodeError msg) -> msg `shouldContain` "reserved"
          Right _ -> expectationFailure (show n ++ ": no EncodeError")

    it "positional parameters are unaffected" $ \conn ->
      query conn (mkQuery "SELECT @p1 + @p2" (1 :: Int32, 2 :: Int32)) `shouldReturn` [Only (3 :: Int32)]

  describe "callProcedure" $ do
    -- The names are sent to the server as they are; whatever it makes of
    -- one, the result is its answer (a SqlServerError, or the call binding
    -- @x), never an EncodeError, and the connection stays usable.
    it "sends names that aren't T-SQL variable names to the server, which refuses or matches them" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #pn; EXEC ('CREATE PROCEDURE #pn @x int AS SELECT @x')"
      forM_ (" @x" : invalidNames) $ \n -> do
        let p = inParam n (1 :: Int32)
        r <- try (callProcedure conn "#pn" [p])
        case r of
          Left e | Just (_ :: SqlServerError) <- fromException e -> pure ()
          Left e -> expectationFailure (show n ++ ": " ++ show e)
          Right res -> (n, map (map sqlRowValues . resultRows) (procResultSets res)) `shouldBe` (n, [[[SqlInt32 1]]])
        query conn "SELECT 1" `shouldReturn` [Only (1 :: Int32)]

    it "a name without the @ doesn't match the parameter (server error 201, \"expects parameter '@x'\")" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #pn; EXEC ('CREATE PROCEDURE #pn @x int AS SELECT @x')"
      r <- try (callProcedure conn "#pn" [inParam "x" (1 :: Int32)])
      either (Just . sqlErrorNumber) (const Nothing) r `shouldBe` Just 201

    it "a name with trailing spaces matches the parameter (the server ignores them)" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #pn; EXEC ('CREATE PROCEDURE #pn @x int AS SELECT @x')"
      res <- callProcedure conn "#pn" [inParam "@x " (1 :: Int32)]
      map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 1]]]

    it "accepts valid names and positional parameters" $ \conn -> do
      void $ execute conn "DROP PROCEDURE IF EXISTS #pv; EXEC ('CREATE PROCEDURE #pv @\233t\233 int, @b int AS SELECT @\233t\233 + @b')"
      forM_ [[("@\233t\233", 1), ("@b", 2)], [("", 1), ("", 2)], [("@b", 2), ("@\233t\233", 1 :: Int32)]] $ \args -> do
        let ps = [inParam n v | (n, v) <- args]
        res <- callProcedure conn "#pv" ps
        map (map sqlRowValues . resultRows) (procResultSets res) `shouldBe` [[[SqlInt32 3]]]
