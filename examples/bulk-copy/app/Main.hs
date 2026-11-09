-- | @hmssql-example-bulk-copy@: copy a table from one database to another
-- with the TDS bulk load, after checking in both catalogs that the target
-- takes the source's rows.
--
-- The two connections are configured by the environment, as the other
-- examples are ("ShopDb"), each variable looked up with a prefix first:
-- @SOURCE_MSSQL_HOST@, then @MSSQL_HOST@; @TARGET_MSSQL_DATABASE@, then
-- @MSSQL_DATABASE@.  So two databases on one server differ only in
-- @SOURCE_MSSQL_DATABASE@ and @TARGET_MSSQL_DATABASE@.
module Main (main) where

import Control.Exception (SomeException, displayException, fromException, try)
import Control.Monad (forM_, unless, void, when)
import qualified Data.ByteString as B
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Options.Applicative
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import Text.Printf (printf)

import Hmssql
import Hmssql.Catalog
import Hmssql.Decoding (sqlRowDecoder)
import Hmssql.Errors (EncodeError (..), SqlServerError, sqlErrorMessage, sqlErrorNumber)
import Hmssql.Query (queryMWith)
import Hmssql.SqlValue (SqlRow (..), SqlValue (..))
import Hmssql.Transaction (inTransaction)
import Paths_hmssql_example_bulk_copy (getDataFileName)
import ShopDb (connectInfoFromEnvPrefixed, sqlBatches)

import Copy.Check
import Copy.Run

data Side = Source | Target
  deriving stock (Eq, Show)

data Command
  = Check Text Text CheckOptions
  | Copy Text Text CheckOptions CopyOptions Bool
  | SetupDemo Int Int
  | Sql Side Text

main :: IO ()
main = do
  cmd <- execParser $ info (commandParser <**> helper) $
    fullDesc <> progDesc "Copy a table between databases with the TDS bulk load, after a catalog check"
  case cmd of
    Check s t opts -> withBoth $ \src dst -> do
      plan <- planFor src dst s t opts
      T.putStr (renderPlan plan)
      unless (planAccepted plan) $ exitWith (ExitFailure 2)
    Copy s t opts flags quiet -> do
      same <- sameTable s t
      when same $ do
        -- The load would wait for the source query's locks, and the query
        -- for the load to take its rows: neither would finish.
        hPutStrLn stderr "the source and the target are the same table"
        exitWith (ExitFailure 2)
      withBoth $ \src dst -> do
        plan <- planFor src dst s t opts
        unless (quiet && planAccepted plan) $ T.putStr (renderPlan plan)
        unless (planAccepted plan) $ exitWith (ExitFailure 2)
        copy src dst plan flags
    SetupDemo rows longAt -> setupDemo rows longAt
    Sql side sql -> do
      info <- connectInfo side
      withConnection info $ \conn -> do
        rows <- queryMWith sqlRowDecoder conn (rawSql sql)
        forM_ rows $ \r -> T.putStrLn (T.intercalate "\t" (map render (sqlRowValues r)))

-- | Both connections, source first.
withBoth :: (Connection -> Connection -> IO a) -> IO a
withBoth body = do
  s <- connectInfo Source
  t <- connectInfo Target
  withConnection s $ \src -> withConnection t $ \dst -> body src dst

connectInfo :: Side -> IO ConnectInfo
connectInfo side = do
  info <- connectInfoFromEnvPrefixed (if side == Source then "SOURCE_" else "TARGET_")
  pure info { connectApplicationName = "hmssql-example-bulk-copy" }

-- | Whether the two names are one table: the same server, database and
-- name (as configured; two names for one server aren't recognized).
sameTable :: Text -> Text -> IO Bool
sameTable s t = do
  si <- connectInfo Source
  ti <- connectInfo Target
  let place i = (T.toCaseFold (connectHost i), connectPort i, T.toCaseFold (connectDatabase i))
      folded n = let ObjectName a b = parseName n in (T.toCaseFold a, T.toCaseFold b)
  pure (place si == place ti && folded s == folded t)

-- | Read both tables from their catalogs and check them.
planFor :: Connection -> Connection -> Text -> Text -> CheckOptions -> IO Plan
planFor src dst s t opts = do
  srcTable <- readTable src (parseName s) >>= maybe (fail ("no source table " ++ T.unpack s)) pure
  dstTable <- readTable dst (parseName t) >>= maybe (fail ("no target table " ++ T.unpack t)) pure
  pure (checkCopy opts srcTable dstTable)

-- | @schema.table@, @[schema].[table]@, or @table@ in @dbo@.
parseName :: Text -> ObjectName
parseName n = case T.breakOn "." n of
  (table, "") -> ObjectName "dbo" (unquote table)
  (schema, rest) -> ObjectName (unquote schema) (unquote (T.drop 1 rest))
  where
    unquote x
      | "[" `T.isPrefixOf` x && "]" `T.isSuffixOf` x = T.replace "]]" "]" (T.drop 1 (T.dropEnd 1 x))
      | otherwise = x

copy :: Connection -> Connection -> Plan -> CopyOptions -> IO ()
copy src dst plan opts = do
  let target = objectNameSql (tableName (planTarget plan))
  putStrLn $ "copying: " ++ describeMode opts
  hFlush stdout
  start <- getCurrentTime
  outcome <- try (copyTable opts src dst plan)
  end <- getCurrentTime
  let secs = realToFrac (diffUTCTime end start) :: Double
  case outcome of
    Right r -> do
      when opts.replace $ putStrLn ("deleted " ++ show r.rowsDeleted ++ " rows first")
      printf "copied %d rows (read %d) in %.2f s, %.0f rows/s\n"
        r.rowsInserted r.rowsRead secs (fromIntegral r.rowsInserted / max secs 1e-6)
    Left (CopyFailed n e) -> do
      putStrLn ("copy failed after reading " ++ show n ++ " rows: " ++ describeFailure e)
      -- What the failure left: counted on the same connection, which a
      -- failed load leaves usable (or on a new one if the server dropped it).
      active <- inTransaction dst
      counted <- try (countRows dst target)
      case counted of
        Right c -> putStrLn ("the target now has " ++ show c ++ " rows (counted on the same connection; transaction open: " ++ show active ++ ")")
        Left (err :: SomeException) -> do
          putStrLn ("the target connection is unusable: " ++ displayException err)
          c <- connectInfo Target >>= \i -> withConnection i (\conn -> countRows conn target)
          putStrLn ("the target now has " ++ show c ++ " rows (counted on a new connection)")
      exitWith (ExitFailure 1)

describeMode :: CopyOptions -> String
describeMode f = case (f.transaction || f.replace, f.batchSize) of
  (False, Nothing) -> "one bulk load, no transaction"
  (False, Just n) -> "batches of " ++ show n ++ " rows, each committed on its own"
  (True, Nothing) -> "one bulk load in a transaction" ++ replacing
  (True, Just n) -> "batches of " ++ show n ++ " rows in one transaction" ++ replacing
  where
    replacing = if f.replace then ", after deleting the target's rows" else ""

describeFailure :: SomeException -> String
describeFailure e
  | Just (EncodeError m) <- fromException e = "refused on the client: " ++ m
  | Just (s :: SqlServerError) <- fromException e =
      "SQL Server error " ++ show (sqlErrorNumber s) ++ ": " ++ T.unpack (sqlErrorMessage s)
  | otherwise = displayException e

countRows :: Connection -> Text -> IO Int64
countRows conn table = do
  Only n <- query1 conn (rawSql ("SELECT COUNT_BIG(*) FROM " <> table))
  pure n

------------------------------------------------------------------------------
-- The tables of setup-demo

-- | Create the databases if they don't exist (on Azure SQL Database they
-- must: its @CREATE DATABASE@ makes a billed database), then the source
-- table with its rows and the target tables, empty.  Both may be the same
-- database: the scripts touch only their own tables in schema @copydemo@.
setupDemo :: Int -> Int -> IO ()
setupDemo rows longAt = forM_ [(Source, "sql/demo-source.sql"), (Target, "sql/demo-target.sql")] $ \(side, file) -> do
  info <- connectInfo side
  ensureDatabase info
  path <- getDataFileName file
  script <- T.readFile path
  let vars = T.replace "$(ROWS)" (T.pack (show rows)) . T.replace "$(LONG_TITLE_AT)" (T.pack (show longAt))
  hPutStrLn stderr ("running " ++ file ++ " in " ++ T.unpack (connectDatabase info) ++ " on " ++ T.unpack (connectHost info))
  withConnection info $ \conn -> forM_ (sqlBatches (vars script)) $ \batch -> void (execute conn (rawSql batch))

ensureDatabase :: ConnectInfo -> IO ()
ensureDatabase info = withConnection info { connectDatabase = "master" } $ \conn -> do
  let db = connectDatabase info
  Only exists <- query1 conn ("SELECT CAST(COUNT(*) AS int) FROM sys.databases WHERE name = " <> param db)
  when (exists == (0 :: Int)) $ do
    hPutStrLn stderr ("creating database " ++ T.unpack db)
    void (execute conn ("CREATE DATABASE " <> escapeIdentifier db))

-- | A value for the @sql@ command's tab-separated output.
render :: SqlValue -> Text
render = \case
  SqlNull -> "NULL"
  SqlBool b -> if b then "1" else "0"
  SqlWord8 i -> tshow i
  SqlInt16 i -> tshow i
  SqlInt32 i -> tshow i
  SqlInt64 i -> tshow i
  SqlDecimal d -> tshow d
  SqlDouble d -> tshow d
  SqlMoney m -> tshow m
  SqlGuid g -> tshow g
  SqlDateTime t -> tshow t
  SqlDate d -> tshow d
  SqlTime t -> tshow t
  SqlText t -> t
  SqlXml t -> t
  SqlBinary b -> "0x" <> T.concat [T.pack (printf "%02X" w) | w <- B.unpack b]
  v -> tshow v
  where
    tshow :: Show a => a -> Text
    tshow = T.pack . show

------------------------------------------------------------------------------
-- Command line

commandParser :: Parser Command
commandParser = hsubparser $ mconcat
  [ command "check" $ info (Check <$> sourceArg <*> targetArg <*> checkOptions) $
      progDesc "Check that the target table takes the source table's rows (exit 2 if not)"
  , command "copy" $ info (Copy <$> sourceArg <*> targetArg <*> checkOptions <*> copyOptions <*> quietOpt) $
      progDesc "Check, then copy the rows"
  , command "setup-demo" $ info (SetupDemo <$> rowsOpt <*> longAtOpt) $
      progDesc "Create the source table with its rows, and the empty target tables (schema copydemo)"
  , command "sql" $ info (Sql <$> sideArg <*> strArgument (metavar "SQL")) $
      progDesc "Run SQL on the source or target and print the first result set"
  ]
  where
    sourceArg = strArgument (metavar "SOURCE" <> help "The source table, schema.table (in SOURCE_MSSQL_DATABASE)")
    targetArg = strArgument (metavar "TARGET" <> help "The target table, schema.table (in TARGET_MSSQL_DATABASE)")
    quietOpt = switch (long "quiet" <> help "Don't print the check's plan unless it refuses the copy")
    sideArg = argument (eitherReader side) (metavar "source|target")
    side = \case
      "source" -> Right Source
      "target" -> Right Target
      other -> Left ("expected source or target, not " ++ other)
    rowsOpt = option auto (long "rows" <> value 50000 <> showDefault <> metavar "N" <> help "Rows in the source table")
    longAtOpt = option auto (long "long-title-at" <> value 40000 <> showDefault <> metavar "ID"
      <> help "The id of the one row whose title is too long for copydemo.event_narrow")

checkOptions :: Parser CheckOptions
checkOptions = CheckOptions
  <$> optional (option (T.splitOn "," <$> str) (long "only" <> metavar "COL,COL,..." <> help "Copy only these source columns"))
  <*> many (strOption (long "skip" <> metavar "COL" <> help "Leave this source column out (repeatable)"))
  <*> switch (long "keep-identity" <> help "Copy into the target's identity column (KEEP_IDENTITY)")

copyOptions :: Parser CopyOptions
copyOptions = mk
  <$> switch (long "transaction" <> help "Load in one transaction on the target: all rows or none")
  <*> switch (long "replace" <> help "Delete the target's rows first, in the same transaction (implies --transaction)")
  <*> optional (option auto (long "batch-size" <> metavar "N" <> help "Rows per bulk load; outside a transaction each batch commits on its own"))
  <*> switch (long "table-lock" <> help "TABLOCK: lock the table for the load (minimal logging)")
  <*> switch (long "check-constraints" <> help "CHECK_CONSTRAINTS: check the target's check and foreign key constraints")
  <*> switch (long "fire-triggers" <> help "FIRE_TRIGGERS: run the target's insert triggers")
  <*> switch (long "keep-nulls" <> help "KEEP_NULLS: insert NULL, not the column default, for a NULL")
  <*> optional (option auto (long "fail-after" <> metavar "N" <> help "Make the source stream fail after N rows, to see what a failed copy leaves behind"))
  <*> optional (option auto (long "progress" <> metavar "N" <> help "Report every N rows read"))
  where
    mk transaction replace batchSize tableLock checkConstraints fireTriggers keepNulls failAfter every = defaultCopyOptions
      { transaction, replace, batchSize, tableLock, checkConstraints, fireTriggers, keepNulls, failAfter
      , progress = (\_ n -> hPutStrLn stderr ("  " ++ show n ++ " rows read") >> hFlush stderr) <$> every
      , progressEvery = fromMaybe 100000 every
      }
