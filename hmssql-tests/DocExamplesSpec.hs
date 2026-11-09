{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Every Haskell code example quoted in "README.md" and the guide (@docs/guide/@)
-- and in haddock comments under @hmssql/src/@, adapted just enough to run against
-- the live test database
-- (a connection from the harness, placeholder tables replaced with @#temp@
-- tables or procedures this module creates and drops).  Each example is
-- checked to behave as documented; a mismatch is either a fixed doc (see the
-- corrections listed in the final report) or, if it would instead be a
-- library bug, a 'pendingWith'.
--
-- Sources, so a doc change can be traced back here:
--
-- * README.md: \"Getting started\" (the program, against a @#customer@
--   table); the guide (the sections the README
--   used to carry, named below by their old README headings): \"Deriving
--   row types\" (Reading rows), \"Dynamic decoding\" (Reading rows),
--   \"Composing queries\", \"Named and heterogeneous parameters\"
--   (Parameters), \"Batches with several result sets\" (Several result
--   sets), \"Many statements in one round trip\", \"Batch queries: several
--   statements, each with its own result\" (Many statements in one round
--   trip), \"Bulk copy\", \"Several open streams (MARS)\" (also the
--   examples of the MARS section of "Hmssql.Connection" and of
--   'withQueryS'); docs/guide/errors-and-security/encryption.md: \"Certificates\"
--   (@connectTls@); docs/dev/testing.md: \"Writing tests\" (the harness pattern).
-- * src\/Hmssql.hs: the top-of-module example, against a @#customer@
--   table, and the example of its Streaming section.
-- * docs\/guide\/getting-started\/first-program.md: the first program's query.
-- * src\/Hmssql\/Query.hs: 'outParam' (widening rules), 'rawOutParam' (an
--   exact declared type), 'ProcResult' ('procOutputValues' ordering), and the
--   sections on streaming queries and cells.
-- * src\/Hmssql\/Decoding.hs and src\/Hmssql\/Encoding.hs: their sections on
--   streaming a large value.
-- * docs\/guide\/writing-data\/bulk-copy.md: the record and NamedColumns rows,
--   a NamedParams row, DescribedColumns, the stream from another connection,
--   what batches and transactions leave behind, and constraint trust.
-- * docs\/guide\/decoders-and-encoders\/decoders.md and encoders.md: the
--   Booking decoder and encoder, the Rgb field decoder and encoder, the
--   hand-written form of a derived instance, byColumn, and the Status and
--   CustomerId instances of docs\/guide\/queries\/reading-rows.md.
-- * src\/Hmssql\/Connection.hs: 'reset' vs. @sp_reset_connection@, 'close',
--   'release' (the resource-pool recipe is prose only: resource-pool is not
--   a test dependency; its pieces are checked here).
-- * src\/Hmssql\/Tds\/CodePage.hs: the collation-properties query.
-- * src\/Hmssql\/Catalog.hs: the top-of-module example.
-- * docs\/guide\/errors-and-security\/errors-and-timeouts.md: \"A refused login\", and
--   src\/Hmssql\/Errors.hs: 'LoginError' (@connectRetrying@, against a mock
--   and with a shorter pause).
module DocExamplesSpec (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, throwIO, try)
import qualified Data.ByteString as B
import Hmssql.Decoding (fieldDecoder, singleField, streamField, valueChunks)
import Hmssql.Encoding (Source (..), binaryStream, sourceOf)
import Control.Monad (forM_, unless)
import Streaming (Of, Stream, inspect, lift)
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (IOMode (..), hClose, openTempFile, withBinaryFile)
import Data.ByteString (ByteString)
import Data.Decimal (Decimal, DecimalRaw (..), roundTo)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.Word (Word32)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (intersperse)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (Day, LocalTime (..), TimeOfDay (..), fromGregorian)
import GHC.Generics (Generic)
import qualified Streaming.Prelude as S
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.Decoding (FieldDecoder, RowDecoder, byColumn, fieldDecoderFor, nullableField, refineField, singleField, sqlValueDecoder)
import Hmssql.Encoding (FieldEncoder (..), ParamValue (..), RowEncoder, divideRow, singleParam)
import Hmssql.BatchQuery
import Hmssql.BulkCopy
import Hmssql.Transaction
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Errors
import qualified Hmssql.Catalog as Catalog
import Hmssql.SqlType (sqlTypeName)
import MockServer (cannedLoginServer, defaultLoginResponse, doneToken, errorToken, mockConnectInfo, withMockServer)
import TestDb

------------------------------------------------------------------------------
-- Local helpers (kept self-contained rather than importing another area's
-- test module; see Rpc.Common / Shapes.ProceduresSpec for the same pattern).

out :: ToSqlField a => Text -> a -> ProcParam
out = outParam

outValues :: ProcResult -> [Either DecodeError SqlValue]
outValues = map decodeReturnValue . procOutputValues

mkProc :: Connection -> Text -> Text -> IO ()
mkProc conn name body = () <$ execute conn (rawSql ("CREATE OR ALTER PROCEDURE dbo." <> name <> " " <> body))

dropProc :: Connection -> Text -> IO ()
dropProc conn name = () <$ execute conn (rawSql ("DROP PROCEDURE IF EXISTS dbo." <> name))

withProc :: Connection -> Text -> Text -> IO a -> IO a
withProc conn name body act = do
  mkProc conn name body
  act `finally` dropProc conn name

------------------------------------------------------------------------------
-- README.md and hmssql/src/Hmssql.hs: "Getting started".  The fields are renamed
-- (columns match them by position), since Person below has a @name@ too.

data ReadmeCustomer = ReadmeCustomer
  { rcCustomerId :: Int
  , rcName :: Text
  , rcEmail :: Text
  , rcBirthDate :: Maybe Day
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

data ReadmeNewCustomer = ReadmeNewCustomer
  { rcNewName :: Text
  , rcNewEmail :: Text
  , rcNewBirthDate :: Maybe Day
  }
  deriving stock (Generic)
  deriving anyclass (ToSqlRow)

data HaddockCustomer = HaddockCustomer
  { hcCustomerId :: Int
  , hcName :: Text
  , hcBirthDate :: Maybe Day
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

createCustomerTable :: Connection -> IO ()
createCustomerTable conn = () <$ execute conn
  "CREATE TABLE #customer (id int IDENTITY PRIMARY KEY, name nvarchar(100) NOT NULL, email nvarchar(200) NULL, birth_date date NULL)"

------------------------------------------------------------------------------
-- README.md: "Deriving row types"

data Person = Person { name :: Text, age :: Maybe Int, born :: Day }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

------------------------------------------------------------------------------
-- README.md: "Batches with several result sets"

data ParentRow = ParentRow { parentId :: Int32, parentName :: Text }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

data ChildRow = ChildRow { childId :: Int32, childParentId :: Int32, childName :: Text }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

newtype TagRow = TagRow { tagText :: Text }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromSqlRow)

------------------------------------------------------------------------------
-- docs/guide/errors-and-security/errors-and-timeouts.md: "A refused login", with a pause of
-- 10 ms instead of 2 s.

connectRetrying :: ConnectInfo -> IO Connection
connectRetrying ci = go (5 :: Int)
  where
    go n = try (connect ci) >>= \case
      Left e | n > 1, isTransientLoginError e -> threadDelay 10000 >> go (n - 1)
      Left e -> throwIO e
      Right conn -> pure conn

------------------------------------------------------------------------------
-- docs/guide/decoders-and-encoders/decoders.md and encoders.md, and the Status
-- instance of docs/guide/queries/reading-rows.md.

data Period = Period { periodStart :: Day, periodEnd :: Day }
  deriving stock (Eq, Show)
data Booking = Booking { bookingRoom :: Int, bookingPeriod :: Period }
  deriving stock (Eq, Show)

bookingDecoder :: RowDecoder Booking
bookingDecoder = Booking <$> singleField fieldDecoder <*> periodDecoder
  where
    periodDecoder = Period <$> singleField fieldDecoder <*> singleField fieldDecoder

bookingEncoder :: RowEncoder Booking
bookingEncoder = divideRow (\b -> (bookingRoom b, bookingPeriod b)) (singleParam fieldEncoder) periodEncoder
  where
    periodEncoder = divideRow (\p -> (periodStart p, periodEnd p)) (singleParam fieldEncoder) (singleParam fieldEncoder)

instance ToSqlRow Booking where
  rowEncoder = bookingEncoder

-- "What a derived instance amounts to", for ReadmeCustomer, which is the
-- guide's Customer with its fields renamed.
customerByHand :: RowDecoder ReadmeCustomer
customerByHand = ReadmeCustomer <$> fieldRowDecoder <*> fieldRowDecoder <*> fieldRowDecoder <*> fieldRowDecoder

newCustomerByHand :: RowEncoder ReadmeNewCustomer
newCustomerByHand = divideRow (\(ReadmeNewCustomer a b c) -> (a, (b, c)))
  (singleParam fieldEncoder)
  (divideRow id (singleParam fieldEncoder) (singleParam fieldEncoder))

newtype ByHand = ByHand ReadmeNewCustomer
instance ToSqlRow ByHand where
  rowEncoder = contramap (\(ByHand c) -> c) newCustomerByHand

data Status = Active | Suspended
  deriving stock (Eq, Show)

instance FromSqlField Status where
  fieldDecoder = refineField parse fieldDecoder
    where
      parse :: Text -> Either String Status
      parse "active" = Right Active
      parse "suspended" = Right Suspended
      parse other = Left ("unknown status " ++ show other)

instance ToSqlField Status where
  fieldEncoder = contramap statusText fieldEncoder
    where
      statusText :: Status -> Text
      statusText Active = "active"
      statusText Suspended = "suspended"

newtype CustomerId = CustomerId { unCustomerId :: Int }

instance ToSqlField CustomerId where
  fieldEncoder = contramap unCustomerId fieldEncoder

newtype Rgb = Rgb Word32 deriving (Eq, Show)

rgbDecoder :: FieldDecoder Rgb
rgbDecoder = fieldDecoderFor "Rgb" isInt $ \_ctx _ti bytes ->
  if B.length bytes == 4
    then Right (Rgb (B.foldr (\b acc -> acc `shiftL` 8 .|. fromIntegral b) 0 bytes))
    else Left ("expected 4 bytes, got " ++ show (B.length bytes))
  where
    isInt ti = ti == TIInt4 || ti == TIIntN 4

instance FromSqlField Rgb where
  fieldDecoder = rgbDecoder

rgbEncoder :: FieldEncoder Rgb
rgbEncoder = FieldEncoder
  { encodeParam = \_ctx (Rgb w) ->
      Right (TIIntN 4, ParamBytes (Just (B.pack [fromIntegral (w `shiftR` s) | s <- [0, 8, 16, 24]])))
  , nullParamType = const (TIIntN 4)
  }

instance ToSqlField Rgb where
  fieldEncoder = rgbEncoder

asValue :: RowDecoder SqlValue
asValue = byColumn $ \col -> case columnType col of
  TIIntN 4 -> SqlInt32 <$> fieldRowDecoder
  _ -> singleField sqlValueDecoder

------------------------------------------------------------------------------
-- docs/guide/writing-data/bulk-copy.md: "Rows"

data NewItem = NewItem { itemId :: Int, itemName :: Text, itemPrice :: Decimal }
  deriving stock (Generic)
  deriving anyclass (ToSqlRow)

------------------------------------------------------------------------------

spec :: Spec
spec = do
  around withTestDb $ describe "guide streamed values" $ do
    it "streams a parameter into a table and counts a streamed column" $ \conn -> do
      _ <- execute conn "CREATE TABLE #documents(payload varbinary(max))"
      let chunks = S.each ["first", "second"]
      execute conn ("INSERT INTO #documents(payload) VALUES (" <> param (binaryStream (sourceOf chunks)) <> ")") `shouldReturn` 1
      let byteCount = singleField (streamField (S.sum_ . S.map B.length . valueChunks))
      queryWith byteCount conn "SELECT payload FROM #documents" `shouldReturn` [11]

  around withTestDb $ describe "hmssql/src/Hmssql: the streaming sections" $ do
    let payload = B.replicate 200000 42
        withTempPath :: (FilePath -> IO a) -> IO a
        withTempPath act = do
          dir <- getTemporaryDirectory
          (path, h) <- openTempFile dir "hmssql-doc-example"
          hClose h
          act path `finally` removeFile path
        fileSource :: FilePath -> Source B.ByteString
        fileSource path = Source $ \use -> withBinaryFile path ReadMode (use . chunks)
          where
            chunks h = do
              chunk <- lift (B.hGetSome h 65536)
              unless (B.null chunk) (S.yield chunk >> chunks h)
        toFile path value = withBinaryFile path WriteMode $ \h ->
          S.mapM_ (B.hPut h) (valueChunks value)
        createDocuments conn = () <$ execute conn
          "CREATE TABLE #documents(id int IDENTITY PRIMARY KEY, name nvarchar(200), payload varbinary(max))"

    it "Encoding sends a file, and a Query built on a Source can be sent again" $ \conn ->
      withTempPath $ \path -> do
        createDocuments conn
        B.writeFile path payload
        let insert = "INSERT INTO #documents (payload) VALUES (" <> param (binaryStream (fileSource path)) <> ")"
        execute conn insert `shouldReturn` 1
        execute conn insert `shouldReturn` 1
        query conn "SELECT CAST(DATALENGTH(payload) AS int) FROM #documents"
          `shouldReturn` [Only (200000 :: Int), Only 200000]

    it "Decoding saves a column to a file" $ \conn ->
      withTempPath $ \path -> do
        createDocuments conn
        _ <- execute conn ("INSERT INTO #documents (payload) VALUES (" <> param payload <> ")")
        let docId = 1 :: Int
        query1With (singleField (streamField (toFile path))) conn
          ("SELECT payload FROM #documents WHERE id = " <> param docId) :: IO ()
        B.readFile path `shouldReturn` payload

    it "Decoding composes a streamed column with another" $ \conn ->
      withTempPath $ \path -> do
        createDocuments conn
        _ <- execute conn ("INSERT INTO #documents (payload) VALUES (" <> param payload <> ")")
        queryWith ((,) <$> singleField (fieldDecoder @Int) <*> singleField (streamField (toFile path))) conn
          "SELECT id, payload FROM #documents" `shouldReturn` [(1, ())]
        B.readFile path `shouldReturn` payload

    it "Query streams rows" $ \conn -> do
      seen <- newIORef []
      withQueryS conn "SELECT 1, N'a' UNION ALL SELECT 2, N'b'" $ \rows ->
        S.mapM_ (\(i :: Int64, name :: Text) -> modifyIORef' seen ((i, name) :)) rows
      readIORef seen `shouldReturn` [(2, "b"), (1, "a")]

    it "hmssql/src/Hmssql.hs's Streaming section: withQueryS with S.mapM_ over (Int, Text) rows" $ \conn -> do
      seen <- newIORef []
      withQueryS conn "SELECT 1, N'a' UNION ALL SELECT 2, N'b'" $ \rows ->
        S.mapM_ (\(i :: Int, name :: Text) -> modifyIORef' seen ((i, name) :)) rows
      readIORef seen `shouldReturn` [(2, "b"), (1, "a")]

    it "Query's cells let one column name the file for the next" $ \conn ->
      withTempPath $ \path -> do
        createDocuments conn
        _ <- execute conn ("INSERT INTO #documents (name, payload) VALUES (" <> param (T.pack path) <> ", " <> param payload <> ")")
        withQueryCells conn "SELECT name, payload FROM #documents" $ \_ rows ->
          let nextRow remaining = inspect remaining >>= \case
                Left () -> pure ()
                Right row -> do
                  Right nameCell <- inspect row
                  (Right name, afterName) <- cellDecoded (fieldDecoder @FilePath) nameCell
                  Right payloadCell <- inspect afterName
                  (Right (), afterPayload) <- cellDecoded (streamField (toFile name)) payloadCell
                  Left more <- inspect afterPayload
                  nextRow more
           in nextRow rows
        B.readFile path `shouldReturn` payload

  describe "docs/guide/errors-and-security/errors-and-timeouts.md: A refused login" $ do
    let refusal number = errorToken (ServerMessage number 1 14 "Refused by the mock." "mock" "" 1)
        -- The first two logins are refused with this number, the rest accepted.
        refusingTwice number = do
          logins <- newIORef (0 :: Int)
          pure $ \mc -> do
            n <- atomicModifyIORef' logins (\k -> (k + 1, k))
            cannedLoginServer (if n < 2 then [refusal number, doneToken 0x0002 0] else defaultLoginResponse) mc
    it "connectRetrying gets through two refusals of 40613" $ do
      handler <- refusingTwice 40613
      withMockServer handler $ \srv -> do
        conn <- connectRetrying (mockConnectInfo srv)
        close conn
    it "connectRetrying gives up at once on a wrong password (18456)" $ do
      handler <- refusingTwice 18456
      withMockServer handler $ \srv -> do
        r <- try (connectRetrying (mockConnectInfo srv))
        case r of
          Left e -> loginErrorNumber e `shouldBe` 18456
          Right conn -> close conn >> expectationFailure "connected"

  -- Manages its own connection (closes it mid-test), so it can't share the
  -- `around withTestDb` connection the rest of this module uses.
  describe "hmssql/src/Hmssql/Connection.hs: close" $
    it "'A request in progress ... fails with ConnectionClosedBy ClosedByClient', as does any later use" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      resultVar <- newEmptyMVar
      _ <- forkIO $ (try (execute conn "WAITFOR DELAY '00:00:05'") :: IO (Either ConnectionClosed Int64))
             >>= putMVar resultVar
      threadDelay 200_000 -- let the WAITFOR start
      close conn
      r <- takeMVar resultVar
      case r of
        Left (ConnectionClosedBy ClosedByClient) -> pure ()
        Left e -> expectationFailure ("wrong reason for the in-flight request: " ++ show e)
        Right n -> expectationFailure ("the query finished despite close: " ++ show n)
      -- "A request in progress ... as does any later use of the connection."
      -- The catch-all pattern the doc mentions: "\ConnectionClosed -> ..."
      r2 <- try (execute conn "SELECT 1") :: IO (Either ConnectionClosed Int64)
      case r2 of
        Left ConnectionClosed -> pure ()
        Right n -> expectationFailure ("reuse after close succeeded: " ++ show n)

  -- Own connections too: 'release' invalidates the handle it is given.
  describe "hmssql/src/Hmssql/Connection.hs: release" $ do
    it "rolls an open transaction back at once, the old handle is refused and a renewed one works" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      flip finally (close conn) $ do
        begin conn
        -- "fromMaybe False <$> timeout t (release conn) is the whole answer"
        ok <- fromMaybe False <$> timeout 5_000_000 (release conn)
        ok `shouldBe` True
        -- "carried out now": no further request needed.
        inTransaction conn `shouldReturn` False
        (execute conn "SELECT 1" >> pure ()) `shouldThrow` (\ConnectionReleased -> True)
        conn' <- renew conn
        query1 conn' "SELECT 1" `shouldReturn` Only (1 :: Int)

    it "'False' for a closed connection, without throwing; close works through any handle" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      conn' <- renew conn
      close conn  -- the stale handle closes the connection
      release conn' `shouldReturn` False

  describe "docs/guide/errors-and-security/errors-and-timeouts.md: unusableReason" $
    it "is Nothing for a healthy connection, and names close after it" $ do
      ci <- defaultTestConnectInfo
      conn <- connect ci
      flip finally (close conn) $ do
        let check = unusableReason conn >>= \case
              Nothing -> pure "usable"
              Just reason -> pure (show reason)
        check `shouldReturn` ("usable" :: String)
        close conn
        check `shouldReturn` "Closed ClosedByClient"

  around withTestDb $ do

    ----------------------------------------------------------------------
    describe "README.md: Getting started" $
      it "inserts a record with mkQuery and reads records back with param" $ \conn -> do
        createCustomerTable conn
        _ <- execute conn "INSERT INTO #customer (name, email, birth_date) VALUES (N'Grace', N'grace@example.com', '1906-12-09')"
        n <- execute conn $ mkQuery
          "INSERT INTO #customer (name, email, birth_date) VALUES (@p1, @p2, @p3)"
          (ReadmeNewCustomer "Ada" "ada@example.com" (Just (fromGregorian 1815 12 10)))
        n `shouldBe` 1
        customers <- query conn $
          "SELECT id, name, email, birth_date FROM #customer WHERE birth_date < "
            <> param (fromGregorian 1900 1 1)
        customers `shouldBe`
          [ReadmeCustomer 2 "Ada" "ada@example.com" (Just (fromGregorian 1815 12 10))]

    describe "hmssql/src/Hmssql.hs: Getting started" $
      it "reads records with param, then inserts a tuple with mkQuery" $ \conn -> do
        createCustomerTable conn
        _ <- execute conn "INSERT INTO #customer (name, birth_date) VALUES (N'Babbage', '1791-12-26'), (N'Grace', '1906-12-09')"
        customers <- query conn $
          "SELECT id, name, birth_date FROM #customer WHERE birth_date < "
            <> param (fromGregorian 1900 1 1)
        customers `shouldBe` [HaddockCustomer 1 "Babbage" (Just (fromGregorian 1791 12 26))]
        n <- execute conn $ mkQuery
          "INSERT INTO #customer (name, birth_date) VALUES (@p1, @p2)"
          ("Ada" :: Text, Just (fromGregorian 1815 12 10))
        n `shouldBe` 1

    describe "docs/guide/getting-started/first-program.md: Connect to your database" $
      it "query1 decodes SELECT 1 into Only Int" $ \conn -> do
        Only n <- query1 conn "SELECT 1" :: IO (Only Int)
        n `shouldBe` 1

    ----------------------------------------------------------------------
    describe "docs/guide/decoders-and-encoders: decoders.md and encoders.md" $ do
      it "a Booking goes out through divideRow and singleParam, and comes back through singleField" $ \conn -> do
        _ <- execute conn "CREATE TABLE #booking (room int NOT NULL, start_date date NOT NULL, end_date date NOT NULL)"
        let booking = Booking 12 (Period (fromGregorian 2026 11 8) (fromGregorian 2026 11 10))
        n <- execute conn (mkQuery "INSERT INTO #booking (room, start_date, end_date) VALUES (@p1, @p2, @p3)" booking)
        n `shouldBe` 1
        queryWith bookingDecoder conn "SELECT room, start_date, end_date FROM #booking" `shouldReturn` [booking]

      it "a RowDecoder is checked against the column count before the first row, even of an empty result" $ \conn -> do
        r <- try (queryWith bookingDecoder conn "SELECT 1 AS room WHERE 1 = 0")
        case r of
          Left (DecodeError _ msg) -> msg `shouldContain` "column"
          Right rows -> expectationFailure ("decoded " ++ show rows)

      it "the hand-written form of a derived FromSqlRow instance decodes the same rows" $ \conn -> do
        createCustomerTable conn
        _ <- execute conn "INSERT INTO #customer (name, email, birth_date) VALUES (N'Ada', N'ada@example.com', '1815-12-10'), (N'Grace', N'grace@example.com', NULL)"
        derived <- query conn "SELECT id, name, email, birth_date FROM #customer ORDER BY id"
        byHand <- queryWith customerByHand conn "SELECT id, name, email, birth_date FROM #customer ORDER BY id"
        byHand `shouldBe` (derived :: [ReadmeCustomer])
        length byHand `shouldBe` 2

      it "the hand-written form of a derived ToSqlRow instance sends the same parameters" $ \conn -> do
        createCustomerTable conn
        let c = ReadmeNewCustomer "Ada" "ada@example.com" (Just (fromGregorian 1815 12 10))
            insert = "INSERT INTO #customer (name, email, birth_date) VALUES (@p1, @p2, @p3)"
        _ <- execute conn (mkQuery insert c)
        _ <- execute conn (mkQuery insert (ByHand c))
        rows <- query conn "SELECT name, email, birth_date FROM #customer"
        rows `shouldBe` replicate 2 ("Ada" :: Text, "ada@example.com" :: Text, Just (fromGregorian 1815 12 10))

      it "Status: refineField decodes the text, contramap encodes it, and a bad value is a DecodeError" $ \conn -> do
        query1 conn ("SELECT " <> param Suspended) `shouldReturn` Only Suspended
        statuses <- queryWith (singleField (nullableField fieldDecoder)) conn
          "SELECT N'active' UNION ALL SELECT NULL"
        statuses `shouldBe` [Just Active, Nothing]
        r <- try (query1 conn "SELECT N'bogus'" :: IO (Only Status))
        case r of
          Left (DecodeError _ msg) -> msg `shouldContain` "unknown status"
          Right (Only v) -> expectationFailure ("decoded " ++ show v)

      it "CustomerId: contramap over the Int encoder sends a bigint" $ \conn -> do
        query1 conn ("SELECT " <> param (CustomerId 5)) `shouldReturn` Only (5 :: Int)
        query1 conn ("SELECT CAST(SQL_VARIANT_PROPERTY(CAST(" <> param (CustomerId 5) <> " AS sql_variant), 'BaseType') AS nvarchar(20))")
          `shouldReturn` Only ("bigint" :: Text)

      it "Rgb: fieldDecoderFor reads the int's bytes, the FieldEncoder writes them, and a bigint is refused up front" $ \conn -> do
        query1 conn ("SELECT " <> param (Rgb 0x112233)) `shouldReturn` Only (Rgb 0x112233)
        query1 conn "SELECT CAST(16777215 AS int)" `shouldReturn` Only (Rgb 0xFFFFFF)
        r <- try (query1 conn "SELECT CAST(1 AS bigint) WHERE 1 = 0" :: IO (Only Rgb))
        case r of
          Left (DecodeError (Just _) msg) -> msg `shouldContain` "Rgb"
          Left e -> expectationFailure ("unexpected " ++ show e)
          Right (Only v) -> expectationFailure ("decoded " ++ show v)

      it "byColumn reads an int through its own decoder and anything else through sqlValueDecoder" $ \conn -> do
        queryWith asValue conn "SELECT CAST(7 AS int)" `shouldReturn` [SqlInt32 7]
        queryWith asValue conn "SELECT N'x'" `shouldReturn` [SqlText "x"]

    describe "README.md / hmssql/src/Hmssql.hs: top-level Example" $ do
      it "query with a parameter composed in, decoded into a tuple" $ \conn -> do
        -- README's own snippet: `SELECT name, create_date FROM sys.tables
        -- WHERE schema_id = ` <> param (1 :: Int), decoded as
        -- `[(Text, LocalTime)]`. sys.tables is a stable system view, so no
        -- #temp table is needed here.
        rows <- query conn
          ("SELECT name, create_date FROM sys.tables WHERE schema_id = " <> param (1 :: Int)) -- schema_id 1 is dbo
        (rows :: [(Text, LocalTime)]) `shouldSatisfy` not . null

      it "hmssql/src/Hmssql.hs's own example: object_id decodes as Int32" $ \conn -> do
        rows <- query conn
          ("SELECT name, object_id FROM sys.tables WHERE schema_id = " <> param (1 :: Int))
        (rows :: [(Text, Int32)]) `shouldSatisfy` not . null

      it "queryS streams a large result set" $ \conn -> do
        _ <- execute conn "CREATE TABLE #big_table (id int, payload varbinary(100))"
        _ <- execute conn "INSERT INTO #big_table SELECT TOP 500 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 0x01 FROM sys.all_columns"
        s <- queryS conn "SELECT id, payload FROM #big_table"
        total <- S.sum_ (S.map (\(i, _p) -> i) (s :: S.Stream (S.Of (Int64, ByteString)) IO ()))
        total `shouldBe` sum [1 .. 500]

      it "withTransaction, execute with mkQuery and positional parameters" $ \conn -> do
        _ <- execute conn "CREATE TABLE #t (id int PRIMARY KEY, x int)"
        _ <- execute conn "INSERT INTO #t (id, x) VALUES (7, 0)"
        withTransaction conn $ do
          _ <- execute conn (mkQuery "UPDATE #t SET x = @p1 WHERE id = @p2" (42 :: Int, 7 :: Int))
          pure ()
        query1 conn "SELECT x FROM #t WHERE id = 7" `shouldReturn` Only (42 :: Int)

    ----------------------------------------------------------------------
    describe "README.md: Deriving row types" $
      it "a FromSqlRow-derived record decodes columns positionally" $ \conn -> do
        rows <- query conn
          "SELECT N'Ada' AS name, CAST(NULL AS int) AS age, CAST('1815-12-10' AS date) AS born"
        (rows :: [Person]) `shouldBe` [Person "Ada" Nothing (fromGregorian 1815 12 10)]

    ----------------------------------------------------------------------
    describe "README.md: Dynamic decoding" $
      it "queryMulti decodes every result set as [SqlRow]; statements with no rows are skipped" $ \conn -> do
        name <- uniqueName "hmssql_docexamples_report"
        withProc conn name
          "AS BEGIN SET NOCOUNT ON; DECLARE @unused int = 1; SELECT 1 AS a; SELECT N'x' AS b, N'y' AS c END" $ do
          sets <- queryMulti conn (rawSql ("EXEC dbo." <> name))
          map (map sqlRowValues . resultRows) sets `shouldBe`
            [ [[SqlInt32 1]]
            , [[SqlText "x", SqlText "y"]]
            ]
          map (map columnName . resultColumns) sets `shouldBe` [["a"], ["b", "c"]]

    ----------------------------------------------------------------------
    describe "README.md: Composing queries" $ do
      it "optional conditions, param and escapeIdentifier compose into one query" $ \conn -> do
        _ <- execute conn "CREATE TABLE #product (id int, name nvarchar(50), price decimal(10,2))"
        _ <- execute conn "INSERT INTO #product VALUES (1, N'apple', 1.5), (2, N'apricot', 9.5), (3, N'banana', 2.5)"
        let search :: Maybe Decimal -> Maybe Text -> Text -> IO (Text, [(Int32, Text)])
            search maxPrice namePattern sortColumn = do
              let conds = catMaybes
                    [ (\p -> "price < " <> param p) <$> maxPrice
                    , (\t -> "name LIKE " <> param t <> " ESCAPE '\\'") <$> namePattern
                    ]
                  whereClause = if null conds then mempty else " WHERE " <> mconcat (intersperse " AND " conds)
                  q = "SELECT id, name FROM #product" <> whereClause <> " ORDER BY " <> escapeIdentifier sortColumn
              rows <- query conn q
              pure (queryText q, rows)
        search (Just 5) (Just "ap%") "name" `shouldReturn`
          ("SELECT id, name FROM #product WHERE price < @p1 AND name LIKE @p2 ESCAPE '\\' ORDER BY [name]", [(1, "apple")])
        search Nothing Nothing "id" `shouldReturn`
          ("SELECT id, name FROM #product ORDER BY [id]", [(1, "apple"), (2, "apricot"), (3, "banana")])
        search Nothing (Just "%an%") "id" `shouldReturn`
          ("SELECT id, name FROM #product WHERE name LIKE @p1 ESCAPE '\\' ORDER BY [id]", [(3, "banana")])

      it "show renders the text as sent and never a parameter value" $ \_ -> do
        let q = "SELECT name FROM t WHERE pw = " <> param ("hunter2" :: Text) <> " AND id = " <> namedParam "id" (7 :: Int)
        show q `shouldBe` show ("SELECT name FROM t WHERE pw = @p1 AND id = @id" :: Text)

    ----------------------------------------------------------------------
    describe "README.md: Named and heterogeneous parameters" $ do
      it "mkQuery with [SqlParam ...] mixes types in one positional parameter list" $ \conn -> do
        _ <- execute conn "CREATE TABLE #t (id int PRIMARY KEY, tenant_id int, name nvarchar(50), modified datetime2)"
        let recordId = 7 :: Int32
            newName = "new name" :: Text
            now = LocalTime (fromGregorian 2026 9 24) (TimeOfDay 12 0 0)
        _ <- execute conn "INSERT INTO #t (id, tenant_id, name, modified) VALUES (7, 3, N'old', '2000-01-01')"
        n <- execute conn (mkQuery "UPDATE #t SET name = @p1, modified = @p2 WHERE id = @p3"
          [SqlParam newName, SqlParam now, SqlParam recordId])
        n `shouldBe` 1
        query1 conn "SELECT name, modified FROM #t WHERE id = 7" `shouldReturn` (newName, now)

      it "mkQuery with NamedParams binds parameters by name" $ \conn -> do
        _ <- execute conn "CREATE TABLE #t (id int PRIMARY KEY, tenant_id int, name nvarchar(50), modified datetime2)"
        _ <- execute conn "INSERT INTO #t (id, tenant_id, name, modified) VALUES (7, 3, N'old', '2000-01-01')"
        let tid = 3 :: Int32
            rid = 7 :: Int32
        rows <- query conn (mkQuery "SELECT * FROM #t WHERE tenant_id = @tenantId AND id = @id"
          (NamedParams [("tenantId", SqlParam tid), ("id", SqlParam rid)]))
        (rows :: [(Int32, Int32, Text, LocalTime)]) `shouldBe`
          [(7, 3, "old", LocalTime (fromGregorian 2000 1 1) (TimeOfDay 0 0 0))]

    ----------------------------------------------------------------------
    describe "README.md: Batches with several result sets" $
      it "ResultSets is Applicative: (,,) <$> resultSet <*> resultSet <*> resultSet" $ \conn -> do
        _ <- execute conn
          "CREATE TABLE #parent (id int, name nvarchar(50)); \
          \CREATE TABLE #child (id int, parent_id int, name nvarchar(50)); \
          \CREATE TABLE #tag (parent_id int, tag nvarchar(50)); \
          \INSERT INTO #parent VALUES (1, N'root'), (2, N'other'); \
          \INSERT INTO #child VALUES (10, 1, N'kid'); \
          \INSERT INTO #tag VALUES (1, N'red'), (1, N'blue'), (2, N'unrelated')"
        (parents, children, tags) <-
          queryResultSets ((,,) <$> resultSet <*> resultSet <*> resultSet) conn $ mkQuery
            "SELECT id, name FROM #parent WHERE id = @id; \
            \SELECT id, parent_id, name FROM #child WHERE parent_id = @id; \
            \SELECT tag FROM #tag WHERE parent_id = @id"
            (NamedParams [("id", SqlParam (1 :: Int32))])
        parents `shouldBe` [ParentRow 1 "root"]
        children `shouldBe` [ChildRow 10 1 "kid"]
        tags `shouldBe` [TagRow "red", TagRow "blue"]

    ----------------------------------------------------------------------
    describe "README.md / hmssql/src/Hmssql/Query.hs: Many statements in one round trip (executeMany)" $
      it "executeMany returns one count per row, and a failure is thrown after the rest ran" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int PRIMARY KEY, name nvarchar(50))"
        counts <- executeMany conn "INSERT INTO #item (id, name) VALUES (@p1, @p2)"
                    [(1 :: Int, "one" :: Text), (2, "two"), (3, "three")]
        counts `shouldBe` [1, 1, 1]
        r <- try (executeMany conn "INSERT INTO #item (id, name) VALUES (@p1, @p2)" [(4 :: Int, "four" :: Text), (1, "dup"), (5, "five")])
        either sqlErrorNumber (const 0) r `shouldBe` 2627
        query conn "SELECT id FROM #item ORDER BY id" `shouldReturn` map Only [1, 2, 3, 4, 5 :: Int32]

    describe "README.md / hmssql/src/Hmssql/BatchQuery.hs: Batch queries (runBatchQuery)" $
      it "pairs each statement with its result, in one round trip (dbo.item is a #temp table here)" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int PRIMARY KEY, name nvarchar(50), category nvarchar(20), price float)"
        _ <- executeMany conn "INSERT INTO #item (id, name, category, price) VALUES (@p1, @p2, @p3, @p4)"
               [(1 :: Int, "one" :: Text, "a" :: Text, 10 :: Double), (2, "two", "a", 20), (3, "three", "b", 30)]
        let cat = "a" :: Text
        (updated, Only total, items) <- runBatchQuery conn $ (,,)
          <$> batchExecute ("UPDATE #item SET price = price * 1.1 WHERE category = " <> param cat)
          <*> batchQuery1 ("SELECT SUM(price) FROM #item WHERE category = " <> param cat)
          <*> batchQuery ("SELECT id, name FROM #item WHERE category = " <> param cat <> " ORDER BY id")
        updated `shouldBe` (2 :: Int64)
        round (total :: Double) `shouldBe` (33 :: Int)
        items `shouldBe` [(1 :: Int32, "one" :: Text), (2, "two")]

    describe "README.md: Bulk copy" $
      it "bulkInsert loads rows and returns the count (dbo.item is a #temp table here)" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
        n <- bulkInsert conn "#item" [(1 :: Int, "one" :: Text, 9.99 :: Double), (2, "two", 0.5)]
        n `shouldBe` 2
        query conn "SELECT id, name, CAST(price AS varchar(10)) FROM #item ORDER BY id"
          `shouldReturn` [(1 :: Int32, "one" :: Text, "9.99" :: Text), (2, "two", "0.50")]

    describe "docs/guide/writing-data/bulk-copy.md" $ do
      it "Rows: a derived ToSqlRow record loads positionally into a table whose columns it matches" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
        bulkInsert conn "#item" [NewItem 1 "one" 9.99, NewItem 2 "two" 0.5] `shouldReturn` 2
        query conn "SELECT id, name, CAST(price AS varchar(10)) FROM #item ORDER BY id"
          `shouldReturn` [(1 :: Int32, "one" :: Text, "9.99" :: Text), (2, "two", "0.50")]

      it "Rows: a positional row for a table with an extra column is an EncodeError; NamedColumns and a NamedParams row pin the columns" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int NOT NULL PRIMARY KEY, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL DEFAULT 0, note nvarchar(50) NULL)"
        r <- try (bulkInsert conn "#item" [NewItem 1 "one" 9.99])
        case r of
          Left (EncodeError msg) -> msg `shouldContain` "values for 4 columns"
          Right n -> expectationFailure ("inserted " ++ show n)
        bulkInsertWith (bulkCopy "#item") { bulkColumns = NamedColumns ["id", "name", "price"] } conn [NewItem 1 "one" 9.99]
          `shouldReturn` 1
        bulkInsert conn "#item"
          [ NamedParams [("name", SqlParam ("two" :: Text)), ("price", SqlParam (0.5 :: Double)), ("id", SqlParam (2 :: Int)), ("note", SqlParam (Nothing :: Maybe Text))] ]
          `shouldReturn` 1
        query conn "SELECT id, name, CAST(price AS varchar(10)), note FROM #item ORDER BY id"
          `shouldReturn` [(1 :: Int32, "one" :: Text, "9.99" :: Text, Nothing :: Maybe Text), (2, "two", "0.50", Nothing)]

      it "Settings: DescribedColumns describes once and loads twice" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
        cols <- describeBulkColumns conn (bulkCopy "#item")
        map bulkColumnName cols `shouldBe` ["id", "name", "price"]
        let settings = (bulkCopy "#item") { bulkColumns = DescribedColumns cols }
        forM_ [[NewItem 1 "one" 9.99], [NewItem 2 "two" 0.5]] $ \rows ->
          bulkInsertWith settings conn rows `shouldReturn` 1
        query1 conn "SELECT COUNT(*) FROM #item" `shouldReturn` Only (2 :: Int)

      it "Streams: a query on another connection loads a packet at a time" $ \conn -> do
        _ <- execute conn "CREATE TABLE #expensive_item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
        withTestDb $ \source -> do
          _ <- execute source "CREATE TABLE #item (id int NOT NULL, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
          _ <- bulkInsert source "#item" [NewItem i (T.pack ("item " ++ show i)) (fromIntegral i / 10) | i <- [1 .. 500]]
          src <- queryS source "SELECT id, name, price FROM #item WHERE price > 1"
          n <- bulkInsertS conn "#expensive_item" (src :: Stream (Of (Int, Text, Decimal)) IO ())
          n `shouldBe` 490
        query1 conn "SELECT COUNT(*), MIN(id) FROM #expensive_item" `shouldReturn` (490 :: Int, 11 :: Int32)

      it "Batches and transactions: the batches before a failure stay, except inside withTransaction or in one load" $ \conn -> do
        _ <- execute conn "CREATE TABLE #item (id int NOT NULL PRIMARY KEY, name nvarchar(50) NOT NULL, price decimal(10,2) NOT NULL)"
        let rows = [NewItem 1 "one" 1, NewItem 2 "two" 2, NewItem 3 "three" 3, NewItem 3 "duplicate" 3, NewItem 5 "five" 5]
            batched = (bulkCopy "#item") { bulkBatchSize = Just 2 }
            count = query1 conn "SELECT COUNT(*) FROM #item" :: IO (Only Int)
            duplicateKey :: Either SqlServerError Int64 -> Expectation
            duplicateKey = \case
              Left e -> msgNumber (sqlError e) `shouldBe` 2627
              Right n -> expectationFailure ("inserted " ++ show n)
        try (bulkInsertWith batched conn rows) >>= duplicateKey
        count `shouldReturn` Only 2
        _ <- execute conn "DELETE FROM #item"
        try (withTransaction conn (bulkInsertWith batched conn rows)) >>= duplicateKey
        count `shouldReturn` Only 0
        try (bulkInsert conn "#item" rows) >>= duplicateKey
        count `shouldReturn` Only 0

      it "What the server skips: a default load leaves a check constraint not trusted, and bulkCheckConstraints keeps the trust" $ \conn -> do
        _ <- execute conn "CREATE TABLE #checked (id int NOT NULL CHECK (id > 0))"
        let trusted = query1 conn "SELECT is_not_trusted FROM tempdb.sys.check_constraints WHERE parent_object_id = OBJECT_ID('tempdb..#checked')" :: IO (Only Bool)
        trusted `shouldReturn` Only False
        _ <- bulkInsert conn "#checked" [Only (1 :: Int)]
        trusted `shouldReturn` Only True
        _ <- execute conn "ALTER TABLE #checked WITH CHECK CHECK CONSTRAINT ALL"
        trusted `shouldReturn` Only False
        _ <- bulkInsertWith (bulkCopy "#checked") { bulkCheckConstraints = True } conn [Only (2 :: Int)]
        trusted `shouldReturn` Only False

    describe "README.md: Encryption (connectTls)" $
      -- The example names localhost, so it needs the local server's
      -- certificate (what HMSSQL_TEST_TLS_HOSTNAME defaults to).
      skipWhen ((/= Just "localhost") <$> testTlsHostName)
        "the README's example names localhost; the server certificate is for HMSSQL_TEST_TLS_HOSTNAME" $
      it "the documented tlsCaCertificateFiles / tlsHostNameInCertificate record update connects" $ \_ -> do
        cert <- testCertFile
        ci <- defaultTestConnectInfo
        let connectTls' = defaultTlsSettings
              { tlsCaCertificateFiles = maybe [] (: []) cert
              , tlsHostNameInCertificate = Just "localhost"
              }
        withConnection ci { connectTls = connectTls' } $ \conn ->
          query1 conn "SELECT 1" `shouldReturn` Only (1 :: Int)

    ----------------------------------------------------------------------
    describe "hmssql/src/Hmssql/Connection.hs: reset vs. sp_reset_connection" $ do
      it "callProcedure conn \"sp_reset_connection\" [] resets the session immediately" $ \conn -> do
        begin conn
        inTransaction conn `shouldReturn` True
        _ <- callProcedure conn "sp_reset_connection" []
        -- No further request needed for the reset to be visible.
        inTransaction conn `shouldReturn` False

      it "by contrast, reset only takes effect on the next request ('Nothing is sent now')" $ \conn -> do
        begin conn
        inTransaction conn `shouldReturn` True
        reset conn
        inTransaction conn `shouldReturn` True -- unchanged: nothing was sent yet
        _ <- execute conn "SELECT 1"
        inTransaction conn `shouldReturn` False

    ----------------------------------------------------------------------
    describe "hmssql/src/Hmssql/Catalog.hs: the top-of-module example" $
      it "readTablesIn conn \"dbo\" lists every column with its type, as the example prints it" $ \conn -> do
        -- Other tests' DDL in the shared database can make this read a
        -- deadlock victim.
        tables <- retryDeadlock (Catalog.readTablesIn conn "dbo")
        let line t c = Catalog.objectName (Catalog.tableName t) <> "." <> Catalog.colName c <> ": "
              <> maybe (Catalog.colTypeName c) sqlTypeName (Catalog.colType c)
            lines' = [line t c | t <- tables, c <- Catalog.tableColumns t]
        -- The shared database has at least the fixtures table.
        lines' `shouldSatisfy` (not . null)
        lines' `shouldSatisfy` all (\l -> T.count ": " l >= 1 && not (T.null (T.takeWhileEnd (/= ' ') l)))

    describe "hmssql/src/Hmssql/Tds/CodePage.hs: the collation-properties query" $
      it "the exact query quoted in the haddock comment runs" $ \conn -> do
        -- COLLATIONPROPERTY returns sql_variant, decoded dynamically as SqlValue.
        rows <- query conn
          "SELECT name, COLLATIONPROPERTY(name, 'CodePage'), COLLATIONPROPERTY(name, 'LCID'), \
          \       COLLATIONPROPERTY(name, 'SortId') \
          \FROM sys.fn_helpcollations()"
        (rows :: [(Text, SqlValue, SqlValue, SqlValue)]) `shouldSatisfy` not . null

    ----------------------------------------------------------------------
    describe "hmssql/src/Hmssql/Query.hs: outParam widening" $ do
      it "strings and binary are declared (max), so a long output value isn't truncated" $ \conn -> do
        name <- uniqueName "hmssql_docexamples_outparam_wide_str"
        withProc conn name
          "@s nvarchar(max) OUTPUT AS SET @s = REPLICATE(CAST(N'x' AS nvarchar(max)), 5000)" $ do
          res <- callProcedure conn ("dbo." <> name) [out "@s" ("" :: Text)]
          outValues res `shouldBe` [Right (SqlText (T.replicate 5000 "x"))]

      it "decimal(38,10) by default; a larger initial scale (roundTo) keeps more places" $ \conn -> do
        name <- uniqueName "hmssql_docexamples_outparam_decimal_scale"
        withProc conn name
          "@x decimal(38,12) OUTPUT AS SET @x = CAST('1.234567890123' AS decimal(38,12))" $ do
          res10 <- callProcedure conn ("dbo." <> name) [out "@x" (0 :: Decimal)]
          res20 <- callProcedure conn ("dbo." <> name) [out "@x" (roundTo 20 (0 :: Decimal))]
          outValues res10 `shouldBe` [Right (SqlDecimal (Decimal 10 12345678901))]
          outValues res20 `shouldBe` [Right (SqlDecimal (Decimal 20 123456789012300000000))]

      it "the declared decimal scale is kept below 10 when the integer part needs the room" $ \conn -> do
        name <- uniqueName "hmssql_docexamples_outparam_decimal_bigint"
        let bigInt = 12345678901234567890123456789 :: Decimal -- 29 integer digits, scale 0
            expected = Decimal 9 (12345678901234567890123456789 * 10 ^ (9 :: Int))
        withProc conn name "@x decimal(38,9) OUTPUT AS SET @x = @x" $ do
          res <- callProcedure conn ("dbo." <> name) [out "@x" bigInt]
          outValues res `shouldBe` [Right (SqlDecimal expected)]

      it "an xml OUTPUT parameter needs SqlXml, not a Text initial value" $ \conn -> do
        name <- uniqueName "hmssql_docexamples_outparam_xml"
        withProc conn name "@x xml OUTPUT AS SET @x = CAST('<a>1</a>' AS xml)" $ do
          res <- callProcedure conn ("dbo." <> name) [out "@x" (SqlXml "")]
          outValues res `shouldBe` [Right (SqlXml "<a>1</a>")]

      it "rawOutParam gives full control of the declared type" $ \conn -> do
        -- "For full control of the declared type, use rawOutParam"
        name <- uniqueName "hmssql_docexamples_procparam_direct"
        withProc conn name "@x decimal(20,4) OUTPUT AS SET @x = @x" $ do
          let p = rawOutParam "@x" (TIDecimalN 20 4, Nothing)
          res <- callProcedure conn ("dbo." <> name) [p]
          outValues res `shouldBe` [Right SqlNull]

      it "procOutputValues is in caller order: zip outputParams (procOutputValues res)" $ \conn -> do
        -- "SQL Server sends (max)-typed values ... after the others": @s here
        -- is nvarchar(max) and would arrive last from the server, but the
        -- caller passed it in the middle.
        name <- uniqueName "hmssql_docexamples_output_order"
        withProc conn name
          "@a int OUTPUT, @s nvarchar(max) OUTPUT, @b int OUTPUT \
          \AS BEGIN SET @a = 1; SET @s = N'hello'; SET @b = 2 END" $ do
          res <- callProcedure conn ("dbo." <> name)
            [out "@a" (0 :: Int32), out "@s" ("" :: Text), out "@b" (0 :: Int32)]
          outValues res `shouldBe` [Right (SqlInt32 1), Right (SqlText "hello"), Right (SqlInt32 2)]

  ------------------------------------------------------------------------
  -- docs/guide/streaming/mars.md, on a MARS connection of
  -- its own (whatever HMSSQL_TEST_MARS says).  dbo.customer, dbo.orders
  -- and dbo.product are #temp tables here, which every session of the
  -- connection shares.
  describe "docs/guide/streaming/mars.md" $
    around (withTestDbWith (\ci -> ci { connectMars = True })) $ do
      it "the N+1 read: a query per row of an open withQueryS stream (also Hmssql.Connection#mars, withQueryS)" $ \conn -> do
        _ <- execute conn "CREATE TABLE #customer (id int PRIMARY KEY, name nvarchar(50))"
        _ <- execute conn "CREATE TABLE #orders (id int PRIMARY KEY, customer_id int, placed_at datetime2)"
        _ <- execute conn
          "INSERT INTO #customer SELECT TOP 300 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), N'c' FROM sys.all_columns"
        _ <- execute conn
          "INSERT INTO #orders SELECT id * 10 + k, id, '2026-09-30' FROM #customer CROSS JOIN (VALUES (1), (2)) AS v (k)"
        seen <- newIORef []
        let report name orders = modifyIORef' seen ((name, length orders) :)
        withQueryS conn "SELECT id, name FROM #customer ORDER BY id" $ \customers ->
          flip S.mapM_ customers $ \(cid :: Int, name :: Text) -> do
            orders <- query conn ("SELECT id, placed_at FROM #orders WHERE customer_id = " <> param cid)
            report name (orders :: [(Int, LocalTime)])
        r <- readIORef seen
        length r `shouldBe` 300
        all ((== 2) . snd) r `shouldBe` True

      it "a write to the scanned table inside withTransaction, through withQueryS: committed" $ \conn -> do
        _ <- execute conn "CREATE TABLE #product (id int PRIMARY KEY, category varchar(10), price decimal(10, 2))"
        _ <- execute conn
          "INSERT INTO #product SELECT TOP 2000 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'tea', 10 FROM sys.all_columns"
        withTransaction conn $
          withQueryS conn "SELECT id, price FROM #product WHERE category = 'tea'" $ \products ->
            flip S.mapM_ products $ \(pid :: Int, price :: Decimal) ->
              execute conn (mkQuery "UPDATE #product SET price = @p1 WHERE id = @p2" (price * 1.1, pid))
        inTransaction conn `shouldReturn` False
        query conn "SELECT COUNT(*) FROM #product WHERE price = 11" `shouldReturn` [Only (2000 :: Int)]

      it "a stream taken up to its last row is not finished: the commit is refused (TransactionRequestsActive)" $ \conn -> do
        _ <- execute conn "CREATE TABLE #t (i int)"
        r <- try $ withTransaction conn $ do
          _ <- execute conn "INSERT INTO #t VALUES (1)"
          s <- queryS conn "SELECT 1"
          S.toList_ (S.take 1 (s :: S.Stream (S.Of (Only Int)) IO ())) `shouldReturn` [Only 1]
        case r of
          Left (TransactionRequestsActive [_]) -> pure ()
          Left e -> expectationFailure ("another TransactionError: " ++ show e)
          Right () -> expectationFailure "committed with a stream unfinished"
        query conn "SELECT COUNT(*) FROM #t" `shouldReturn` [Only (0 :: Int)]

  ------------------------------------------------------------------------
  -- docs/dev/testing.md: "Writing tests" -- the harness usage pattern itself, run almost
  -- verbatim (renamed fixture; this module's own instead of "decimal_values").
  describe "docs/dev/testing.md: the withFixture / around withTestDb harness pattern" $
    withFixture "doc_examples_readme_pattern" fixture $ around withTestDb $
      it "reads the fixture" $ \conn ->
        query conn "SELECT v FROM dbo.doc_examples_readme_pattern" `shouldReturn` [Only (1.5 :: Decimal)]
  where
    fixture =
      [ "DROP TABLE IF EXISTS dbo.doc_examples_readme_pattern"
      , "CREATE TABLE dbo.doc_examples_readme_pattern (v decimal(10, 2))"
      , "INSERT INTO dbo.doc_examples_readme_pattern VALUES (1.5)"
      ]
