-- | The copy: the source table's rows read by a query on one connection
-- and streamed, as they arrive, into a bulk load on another.
--
-- Two connections, always, even for two tables in one database: while
-- 'bulkInsertSWith' sends the rows it holds the target connection, and the
-- stream it pulls them from must not use that connection.  Here the stream
-- is a 'querySWith' on the source connection, so a table of any size is
-- copied a packet at a time, never held in memory.
--
-- The values are not decoded.  Each cell is read as the bytes the source
-- sent, tagged with the source column's wire type ('RawParam'); the bulk
-- load sends them unchanged when the target column has the same storage
-- (an @int@ into an @int@, an @nvarchar(50)@ into an @nvarchar(100)@), and
-- otherwise converts them, refusing what doesn't fit.
--
-- __Transactions.__  What a failure leaves in the target depends on how
-- the load is split and whether a transaction holds it:
--
-- * One batch (no 'batchSize'), no transaction: the load is one bulk
--   operation, and a failure (a refused value, a duplicate key, the source
--   failing) leaves none of its rows.
-- * Batches, no transaction: each batch is a bulk load of its own and is
--   committed when it ends, so a failure keeps the batches before it.
-- * In a transaction ('transaction', or 'replace', which deletes the
--   target's rows first): every batch, and the delete, commit together or
--   not at all.  The target's locks are held until the end.
module Copy.Run
  ( CopyOptions (..)
  , defaultCopyOptions
  , CopyResult (..)
  , SimulatedFailure (..)
  , CopyFailed (..)
  , copyTable
  , sourceQuery
  , rawRowDecoder
  ) where

import Control.Exception (Exception (..), SomeAsyncException, SomeException, throwIO, try)
import Data.Maybe (isJust)
import Data.Int (Int64)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Streaming.Prelude as S

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Catalog
import Hmssql.Decoding (FieldDecoder, RawValue (..), RowDecoder, compileField, fieldDecoderCompiled, singleField)
import Hmssql.Encoding (RawParam (..))
import Hmssql.Query (querySWith)
import Hmssql.Tds.Token (ColumnInfo (..))

import Copy.Check

-- | How the rows are loaded.
data CopyOptions = CopyOptions
  { transaction :: Bool
    -- ^ Load in one transaction on the target: all or nothing.
  , replace :: Bool
    -- ^ Delete the target's rows first, in the same transaction (implies
    -- 'transaction': the delete must not commit without the load).
  , batchSize :: Maybe Int
    -- ^ 'bulkBatchSize': rows per bulk load.
  , tableLock :: Bool
  , checkConstraints :: Bool
  , fireTriggers :: Bool
  , keepNulls :: Bool
  , failAfter :: Maybe Int
    -- ^ The source stream throws 'SimulatedFailure' after this many rows,
    -- as a source connection that drops would.
  , progress :: Maybe (Int64 -> IO ())
    -- ^ Called with the count of rows read so far, every 'progressEvery'
    -- rows.
  , progressEvery :: Int64
  }

defaultCopyOptions :: CopyOptions
defaultCopyOptions = CopyOptions
  { transaction = False
  , replace = False
  , batchSize = Nothing
  , tableLock = False
  , checkConstraints = False
  , fireTriggers = False
  , keepNulls = False
  , failAfter = Nothing
  , progress = Nothing
  , progressEvery = 100000
  }

-- | What the source stream throws under 'failAfter'.
newtype SimulatedFailure = SimulatedFailure Int64
  deriving stock (Show)

instance Exception SimulatedFailure where
  displayException (SimulatedFailure n) = "the source failed after " ++ show n ++ " rows (--fail-after)"

-- | A copy that failed, with how many rows had been read from the source
-- by then (a batch may have been committed).
data CopyFailed = CopyFailed
  { failedAfterRead :: Int64
  , failure :: SomeException
  }
  deriving stock (Show)

instance Exception CopyFailed where
  displayException (CopyFailed n e) = displayException e ++ " (after reading " ++ show n ++ " rows)"

data CopyResult = CopyResult
  { rowsRead :: Int64
    -- ^ Rows the stream yielded.
  , rowsInserted :: Int64
    -- ^ Rows the server reported inserted (every batch's count).
  , rowsDeleted :: Int64
    -- ^ Under 'replace'.
  }
  deriving stock (Show)

-- | Copy the rows the plan maps.  The plan must be accepted
-- ('planAccepted'); the rows are still converted and checked one by one,
-- and the first one refused ends the copy with 'EncodeError', as a server
-- error ends it with 'SqlServerError'.  Either is thrown inside a
-- 'CopyFailed' with the count of rows read.
copyTable :: CopyOptions -> Connection -> Connection -> Plan -> IO CopyResult
copyTable opts src dst plan = do
  let target = objectNameSql (tableName (planTarget plan))
      columns = planMappings plan
      settings = (bulkCopy target)
        { bulkColumns = NamedColumns [colName (mapTarget m) | m <- columns]
          -- The check refused an identity target column unless
          -- --keep-identity; one that is mapped gets the source's values.
        , bulkKeepIdentity = any (colIdentity . mapTarget) columns
        , bulkKeepNulls = opts.keepNulls
        , bulkCheckConstraints = opts.checkConstraints
        , bulkFireTriggers = opts.fireTriggers
        , bulkTableLock = opts.tableLock
        , bulkBatchSize = opts.batchSize
        }
  readCount <- newIORef (0 :: Int64)
  -- The query goes out now; its rows are read as the load pulls them.
  rows <- querySWith (rawRowDecoder (length columns)) src (sourceQuery plan)
  let counted = flip S.mapM rows $ \row -> do
        n <- readIORef readCount
        case opts.failAfter of
          Just k | n >= fromIntegral k -> throwIO (SimulatedFailure n)
          _ -> pure ()
        writeIORef readCount (n + 1)
        case opts.progress of
          Just report | (n + 1) `rem` opts.progressEvery == 0 -> report (n + 1)
          _ -> pure ()
        pure row
      load = do
        deleted <- if opts.replace then execute dst (rawSql ("DELETE FROM " <> target)) else pure 0
        inserted <- bulkInsertSWith settings dst counted
        pure (deleted, inserted)
  outcome <- try (if opts.transaction || opts.replace then withTransaction dst load else load)
  n <- readIORef readCount
  case outcome of
    Right (deleted, inserted) -> pure CopyResult { rowsRead = n, rowsInserted = inserted, rowsDeleted = deleted }
    Left e
      | isJust (fromException @SomeAsyncException e) -> throwIO e
      | otherwise -> throwIO (CopyFailed n e)

-- | The query that reads the mapped columns, in the plan's order.
sourceQuery :: Plan -> Query
sourceQuery plan = rawSql $
  "SELECT " <> T.intercalate ", " [quote (colName (mapSource m)) | m <- planMappings plan]
    <> " FROM " <> objectNameSql (tableName (planSource plan))
  where
    quote :: Text -> Text
    quote n = "[" <> T.replace "]" "]]" n <> "]"

-- | A row of @n@ columns as they arrived: each cell's bytes with its
-- column's wire type, ready to be sent again.
rawRowDecoder :: Int -> RowDecoder [RawParam]
rawRowDecoder n = traverse (const (singleField rawParamField)) [1 .. n]

-- | A cell's bytes and its column's type (the type is looked at once per
-- column, when the decoder is compiled for the result set).
rawParamField :: FieldDecoder RawParam
rawParamField = fieldDecoderCompiled $ \ctx col -> do
  cell <- compileField (fieldDecoder @(Maybe RawValue)) ctx col
  let ty = columnType col
  pure (fmap (\v -> RawParam (ty, fmap (\(RawValue b) -> b) v)) cell)
