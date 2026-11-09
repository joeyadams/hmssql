-- | The entity model, read from the database's catalog when the server
-- starts.  Every table and view in schema @dbo@ is an entity set, each
-- column of a type the service knows how to serve is a property, and
-- each foreign key that references a table's primary key gives that table
-- a collection property, named after the referencing table.
--
-- Later stages only ever match request text against this model.  The
-- names that end up in SQL come from here, never from the request.
module OData.Model
  ( Model
  , EntitySet (..)
  , Column (..)
  , ColumnType (..)
  , Navigation (..)
  , loadModel
  , lookupSet
  , lookupColumn
  , lookupNavigation
  ) where

import Control.Monad (forM)
import Data.List (find, sort)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hPutStrLn, stderr)

import Hmssql (Connection)
import qualified Hmssql.Catalog as Catalog
import Hmssql.SqlType

type Model = [EntitySet]

-- | A table or view, served under its own name.
data EntitySet = EntitySet
  { setName :: Text
  , columns :: [Column]
  , keyColumns :: [Text]
    -- ^ The primary key's columns, in key order; empty for a view.
  , navigations :: [Navigation]
  }

data Column = Column
  { colName :: Text
  , colType :: ColumnType
  , colNullable :: Bool
  }

-- | A collection property: the rows of another set that reference this one.
data Navigation = Navigation
  { navName :: Text
    -- ^ The name in @$expand@, and of the member in the JSON.
  , navTarget :: Text
    -- ^ The set the rows come from.
  , navJoin :: [(Text, Text)]
    -- ^ The foreign key as (referencing column, this set's key column) pairs.
  }

-- | The SQL types the service serves, grouped by the Haskell type a column
-- is decoded as.  A column of any other type is left out of the model.
data ColumnType
  = TInt             -- ^ tinyint, smallint, int and bigint, as Int64
  | TDecimal         -- ^ decimal, numeric, money and smallmoney, as Decimal
  | TDouble          -- ^ float and real
  | TBool            -- ^ bit
  | TString          -- ^ char, varchar, nchar, nvarchar, text and ntext
  | TDate            -- ^ date
  | TDateTime        -- ^ datetime, smalldatetime and datetime2, as LocalTime
  | TDateTimeOffset  -- ^ datetimeoffset
  | TTime            -- ^ time, as TimeOfDay
  | TGuid            -- ^ uniqueidentifier, as UUID
  deriving stock (Eq, Show)

columnTypeOf :: SqlDataType -> Maybe ColumnType
columnTypeOf = \case
  TyTinyInt -> Just TInt
  TySmallInt -> Just TInt
  TyInt -> Just TInt
  TyBigInt -> Just TInt
  TyDecimal -> Just TDecimal
  TyNumeric -> Just TDecimal
  TyMoney -> Just TDecimal
  TySmallMoney -> Just TDecimal
  TyFloat -> Just TDouble
  TyReal -> Just TDouble
  TyBit -> Just TBool
  TyChar -> Just TString
  TyVarChar -> Just TString
  TyNChar -> Just TString
  TyNVarChar -> Just TString
  TyText -> Just TString
  TyNText -> Just TString
  TyDate -> Just TDate
  TyDateTime -> Just TDateTime
  TySmallDateTime -> Just TDateTime
  TyDateTime2 -> Just TDateTime
  TyDateTimeOffset -> Just TDateTimeOffset
  TyTime -> Just TTime
  TyUniqueIdentifier -> Just TGuid
  _ -> Nothing

-- | Read the tables and views of @dbo@ and build the model.  Columns and
-- foreign keys the model can't serve are skipped with a warning on stderr.
loadModel :: Connection -> IO Model
loadModel conn = do
  tables <- Catalog.readTablesIn conn "dbo"
  sets <- mapM entitySet tables
  let served = [(set, table) | (set, table) <- zip sets tables, not (null set.columns)]
  forM served $ \(set, _) -> do
    navs <- navigationsOf served set
    pure set { navigations = navs }

entitySet :: Catalog.Table -> IO EntitySet
entitySet table = do
  cols <- fmap concat $ forM table.tableColumns $ \c ->
    case c.colType >>= columnTypeOf . sqlDataType of
      Just ty -> pure [Column c.colName ty c.colNullable]
      Nothing -> do
        warn ("skipping " <> name <> "." <> c.colName <> ": its type, " <> c.colTypeName <> ", is not served")
        pure []
  pure EntitySet
    { setName = name
    , columns = cols
    , keyColumns = maybe [] (.keyColumns) table.tablePrimaryKey
    , navigations = []
    }
  where
    name = Catalog.objectName table.tableName

-- | The collection properties of a set: one per foreign key, in a served
-- table, that references the set's primary key.  Each is named after the
-- referencing table, or after the constraint when that name is taken by a
-- column or another property.
navigationsOf :: [(EntitySet, Catalog.Table)] -> EntitySet -> IO [Navigation]
navigationsOf served parent = go (map (.colName) parent.columns) candidates
  where
    candidates =
      [ (child, fk)
      | (child, table) <- served
      , fk <- table.tableForeignKeys
      , fk.fkReferencedTable == Catalog.ObjectName "dbo" parent.setName
      ]
    go _ [] = pure []
    go taken ((child, fk) : rest)
      | null parent.keyColumns || sort fk.fkReferencedColumns /= sort parent.keyColumns = do
          warn ("skipping foreign key " <> fk.fkName <> ": it does not reference the primary key of " <> parent.setName)
          go taken rest
      | not (all (isJust . lookupColumn child) fk.fkColumns) = do
          warn ("skipping foreign key " <> fk.fkName <> ": a column of it is not served")
          go taken rest
      | otherwise = case filter (`notElem` taken) [child.setName, fk.fkName] of
          name : _ -> (Navigation name child.setName join :) <$> go (name : taken) rest
          [] -> do
            warn ("skipping foreign key " <> fk.fkName <> ": both " <> child.setName <> " and " <> fk.fkName <> " are taken as property names of " <> parent.setName)
            go taken rest
      where
        join = mapMaybe (\k -> (\(c, _) -> (c, k)) <$> find ((== k) . snd) (zip fk.fkColumns fk.fkReferencedColumns)) parent.keyColumns

warn :: Text -> IO ()
warn msg = hPutStrLn stderr ("warning: " <> T.unpack msg)

lookupSet :: Model -> Text -> Maybe EntitySet
lookupSet model name = find ((== name) . (.setName)) model

lookupColumn :: EntitySet -> Text -> Maybe Column
lookupColumn set name = find ((== name) . (.colName)) set.columns

lookupNavigation :: EntitySet -> Text -> Maybe Navigation
lookupNavigation set name = find ((== name) . (.navName)) set.navigations
