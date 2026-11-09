{-# LANGUAGE MagicHash #-}
-- | The database's schema, read from its catalog views: every user table
-- and view with its columns, their declared types ('SqlType'), the
-- primary key, the unique constraints and the foreign keys.
--
-- > tables <- readTablesIn conn "dbo"
-- > forM_ tables $ \t -> forM_ (tableColumns t) $ \c ->
-- >   putStrLn (T.unpack (objectName (tableName t) <> "." <> colName c <> ": " <> maybe (colTypeName c) sqlTypeName (colType c)))
--
-- Everything comes from @sys.objects@, @sys.columns@, @sys.types@ and the
-- constraint views, in one request.  A column's type is resolved through
-- an alias type (@dbo.phone@, based on @varchar(20)@, is a
-- @varchar(20)@; @sysname@ is @nvarchar(128)@), and a CLR user-defined type
-- or a type newer than this library leaves 'colType' 'Nothing' with the
-- name in 'colTypeName'.
--
-- What is not read: indexes, check constraints, triggers, the referential
-- actions of foreign keys, identity seeds, procedures and functions.
module Hmssql.Catalog
  ( -- * Tables and views
    ObjectName (..)
  , objectNameSql
  , Table (..)
  , TableKind (..)
  , Column (..)
  , Computed (..)
  , GeneratedAlways (..)
  , KeyConstraint (..)
  , ForeignKey (..)

    -- * Reading the catalog
  , readTables
  , readTablesIn
  , readTable
  , lookupColumn
  ) where

import Data.List (find, groupBy)
import Data.Function (on)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

import Hmssql.Connection (Connection)
import Hmssql.Decoding (FromSqlRow)
import Hmssql.Internal.Derived
import Hmssql.Query (mkQuery, queryResultSets, resultSet)
import Hmssql.SqlType

-- | A schema-qualified name: @dbo.customer@.
data ObjectName = ObjectName
  { objectSchema :: !Text
  , objectName :: !Text
  }
  deriving stock (Ord)

instance Show ObjectName where
  showsPrec p (ObjectName a b) =
    showRecord p "ObjectName"# ["objectSchema"# := a, "objectName"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq ObjectName where
  ObjectName a b == ObjectName a' b' = eq a a' && eq b b'
  {-# OPAQUE (==) #-}

-- | The name as SQL, bracket-quoted: @[dbo].[customer]@.
objectNameSql :: ObjectName -> Text
objectNameSql (ObjectName schema name) = quote schema <> "." <> quote name

quote :: Text -> Text
quote n = "[" <> T.replace "]" "]]" n <> "]"

-- | Whether an object is a table or a view.
data TableKind = UserTable | View
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | A table or view with its columns and constraints.
data Table = Table
  { tableName :: !ObjectName
  , tableKind :: !TableKind
  , tableColumns :: ![Column]
    -- ^ In column order.
  , tablePrimaryKey :: !(Maybe KeyConstraint)
  , tableUniqueKeys :: ![KeyConstraint]
    -- ^ The @UNIQUE@ constraints, by name.  (Unique indexes that are not
    -- constraints are not read.)
  , tableForeignKeys :: ![ForeignKey]
    -- ^ By name.
  }

instance Show Table where
  showsPrec p (Table a b c e f g) = showRecord p "Table"#
    [ "tableName"# := a, "tableKind"# := b, "tableColumns"# := c, "tablePrimaryKey"# := e
    , "tableUniqueKeys"# := f, "tableForeignKeys"# := g
    ]
  {-# OPAQUE showsPrec #-}

instance Eq Table where
  Table a b c e f g == Table a' b' c' e' f' g' =
    eq a a' && eq b b' && eq c c' && eq e e' && eq f f' && eq g g'
  {-# OPAQUE (==) #-}

-- | A column of a table or view.
data Column = Column
  { colName :: !Text
  , colId :: !Int
    -- ^ @column_id@: a column's position, with gaps where columns were
    -- dropped.
  , colTypeName :: !Text
    -- ^ The type the column is declared with, as named: a system type
    -- (@nvarchar@, @sysname@, @vector@, @hierarchyid@), or a user-defined
    -- type with its schema (@dbo.phone@).
  , colType :: !(Maybe SqlType)
    -- ^ The type with its arguments, an alias type resolved to what it is
    -- based on.  'Nothing' for a CLR user-defined type other than
    -- @hierarchyid@, @geometry@ and @geography@, and for a type newer
    -- than this library.
  , colNullable :: !Bool
  , colCollation :: !(Maybe Text)
    -- ^ Character types only.
  , colIdentity :: !Bool
  , colComputed :: !(Maybe Computed)
  , colDefault :: !(Maybe Text)
    -- ^ The default constraint's expression as the catalog stores it,
    -- e.g. @((0))@ or @(getdate())@.
  , colGenerated :: !(Maybe GeneratedAlways)
    -- ^ A column the server maintains: a system-versioned (temporal)
    -- table's period, or a ledger table's.
  , colHidden :: !Bool
    -- ^ Left out of @SELECT *@.
  }

instance Show Column where
  showsPrec p (Column a b c e f g h i j k l) = showRecord p "Column"#
    [ "colName"# := a, "colId"# := b, "colTypeName"# := c, "colType"# := e, "colNullable"# := f
    , "colCollation"# := g, "colIdentity"# := h, "colComputed"# := i, "colDefault"# := j
    , "colGenerated"# := k, "colHidden"# := l
    ]
  {-# OPAQUE showsPrec #-}

instance Eq Column where
  Column a b c e f g h i j k l == Column a' b' c' e' f' g' h' i' j' k' l' =
    eq a a' && b == b' && eq c c' && eq e e' && f == f' && eq g g' && h == h' && eq i i'
      && eq j j' && eq k k' && l == l'
  {-# OPAQUE (==) #-}

-- | A computed column's expression, and whether it is stored.
data Computed = Computed
  { computedDefinition :: !Text
  , computedPersisted :: !Bool
  }

instance Show Computed where
  showsPrec p (Computed a b) =
    showRecord p "Computed"# ["computedDefinition"# := a, "computedPersisted"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq Computed where
  Computed a b == Computed a' b' = eq a a' && b == b'
  {-# OPAQUE (==) #-}

-- | @sys.columns.generated_always_type@.
data GeneratedAlways
  = AsRowStart
  | AsRowEnd
  | AsTransactionIdStart
  | AsTransactionIdEnd
  | AsSequenceNumberStart
  | AsSequenceNumberEnd
  | AsOther !Int
    -- ^ A kind this library doesn't know, with the catalog's number.
  deriving stock (Ord)

instance Show GeneratedAlways where
  showsPrec p = \case
    AsRowStart -> showString "AsRowStart"
    AsRowEnd -> showString "AsRowEnd"
    AsTransactionIdStart -> showString "AsTransactionIdStart"
    AsTransactionIdEnd -> showString "AsTransactionIdEnd"
    AsSequenceNumberStart -> showString "AsSequenceNumberStart"
    AsSequenceNumberEnd -> showString "AsSequenceNumberEnd"
    AsOther a -> showCon1 p "AsOther"# a
  {-# OPAQUE showsPrec #-}

instance Eq GeneratedAlways where
  x == y = case (x, y) of
    (AsRowStart, AsRowStart) -> True
    (AsRowEnd, AsRowEnd) -> True
    (AsTransactionIdStart, AsTransactionIdStart) -> True
    (AsTransactionIdEnd, AsTransactionIdEnd) -> True
    (AsSequenceNumberStart, AsSequenceNumberStart) -> True
    (AsSequenceNumberEnd, AsSequenceNumberEnd) -> True
    (AsOther a, AsOther a') -> a == a'
    _ -> False
  {-# OPAQUE (==) #-}

-- | A primary key or unique constraint.
data KeyConstraint = KeyConstraint
  { keyName :: !Text
  , keyColumns :: ![Text]
    -- ^ In key order.
  }

instance Show KeyConstraint where
  showsPrec p (KeyConstraint a b) =
    showRecord p "KeyConstraint"# ["keyName"# := a, "keyColumns"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq KeyConstraint where
  KeyConstraint a b == KeyConstraint a' b' = eq a a' && eq b b'
  {-# OPAQUE (==) #-}

-- | A foreign key constraint.
data ForeignKey = ForeignKey
  { fkName :: !Text
  , fkColumns :: ![Text]
    -- ^ The referencing columns, paired with 'fkReferencedColumns'.
  , fkReferencedTable :: !ObjectName
  , fkReferencedColumns :: ![Text]
  }

instance Show ForeignKey where
  showsPrec p (ForeignKey a b c e) = showRecord p "ForeignKey"#
    [ "fkName"# := a, "fkColumns"# := b, "fkReferencedTable"# := c
    , "fkReferencedColumns"# := e
    ]
  {-# OPAQUE showsPrec #-}

instance Eq ForeignKey where
  ForeignKey a b c e == ForeignKey a' b' c' e' = eq a a' && eq b b' && eq c c' && eq e e'
  {-# OPAQUE (==) #-}

-- | The column of this name (exact match, as the catalog names it).
lookupColumn :: Table -> Text -> Maybe Column
lookupColumn t name = find ((== name) . colName) (tableColumns t)

------------------------------------------------------------------------------
-- Reading the catalog

-- | Every user table and view the login can see, in every schema, in name
-- order.  Objects marked as shipped by Microsoft are left out.
readTables :: Connection -> IO [Table]
readTables conn = readCatalog conn Nothing Nothing

-- | The user tables and views of one schema.
readTablesIn :: Connection -> Text -> IO [Table]
readTablesIn conn schema = readCatalog conn (Just schema) Nothing

-- | One table or view, if it exists.
readTable :: Connection -> ObjectName -> IO (Maybe Table)
readTable conn (ObjectName schema name) = case' <$> readCatalog conn (Just schema) (Just name)
  where
    case' = \case
      [t] -> Just t
      _ -> Nothing

-- | One row of the column query, in SELECT order.
data ColumnRow = ColumnRow
  { rSchema :: Text
  , rObject :: Text
  , rIsView :: Bool
  , rColumnId :: Int
  , rColumn :: Text
  , rTypeSchema :: Text
  , rTypeName :: Text
  , rTypeUserDefined :: Bool
  , rTypeClr :: Bool
  , rBaseTypeName :: Maybe Text
  , rMaxLength :: Int
  , rPrecision :: Int
  , rScale :: Int
  , rCollation :: Maybe Text
  , rNullable :: Bool
  , rIdentity :: Bool
  , rComputedDefinition :: Maybe Text
  , rComputedPersisted :: Maybe Bool
  , rDefault :: Maybe Text
  , rGeneratedAlways :: Int
  , rHidden :: Bool
  , rXmlSchema :: Maybe Text
  , rXmlCollection :: Maybe Text
  }
  deriving stock (Generic)
  deriving anyclass (FromSqlRow)

data KeyRow = KeyRow
  { kSchema :: Text
  , kObject :: Text
  , kName :: Text
  , kIsPrimary :: Bool
  , kOrdinal :: Int
  , kColumn :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromSqlRow)

data FkRow = FkRow
  { fSchema :: Text
  , fObject :: Text
  , fName :: Text
  , fReferencedSchema :: Text
  , fReferencedObject :: Text
  , fOrdinal :: Int
  , fColumn :: Text
  , fReferencedColumn :: Text
  }
  deriving stock (Generic)
  deriving anyclass (FromSqlRow)

-- | The three catalog queries as one statement (one request), each
-- restricted to the schema and object given.
catalogSql :: Text
catalogSql = T.intercalate ";\n"
  [ "SELECT s.name, o.name, CAST(CASE o.type WHEN 'V' THEN 1 ELSE 0 END AS bit), c.column_id, c.name,\n\
    \  tys.name, ty.name, ty.is_user_defined, ty.is_assembly_type, base.name,\n\
    \  CAST(c.max_length AS int), CAST(c.precision AS int), CAST(c.scale AS int), c.collation_name, c.is_nullable,\n\
    \  c.is_identity, cc.definition, cc.is_persisted, dc.definition, CAST(c.generated_always_type AS int), c.is_hidden,\n\
    \  xs.name, xsc.name\n\
    \FROM sys.objects AS o\n\
    \JOIN sys.schemas AS s ON s.schema_id = o.schema_id\n\
    \JOIN sys.columns AS c ON c.object_id = o.object_id\n\
    \JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id\n\
    \JOIN sys.schemas AS tys ON tys.schema_id = ty.schema_id\n\
    \LEFT JOIN sys.types AS base ON ty.is_user_defined = 1 AND base.user_type_id = ty.system_type_id\n\
    \LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id\n\
    \LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id\n\
    \LEFT JOIN sys.xml_schema_collections AS xsc ON xsc.xml_collection_id = c.xml_collection_id\n\
    \LEFT JOIN sys.schemas AS xs ON xs.schema_id = xsc.schema_id\n\
    \WHERE " <> objectFilter <> "\n\
    \ORDER BY s.name, o.name, c.column_id"
  , "SELECT s.name, o.name, kc.name, CAST(CASE kc.type WHEN 'PK' THEN 1 ELSE 0 END AS bit), CAST(ic.key_ordinal AS int), c.name\n\
    \FROM sys.key_constraints AS kc\n\
    \JOIN sys.objects AS o ON o.object_id = kc.parent_object_id\n\
    \JOIN sys.schemas AS s ON s.schema_id = o.schema_id\n\
    \JOIN sys.index_columns AS ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id\n\
    \JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id\n\
    \WHERE ic.key_ordinal > 0 AND " <> objectFilter <> "\n\
    \ORDER BY s.name, o.name, kc.name, ic.key_ordinal"
  , "SELECT s.name, o.name, fk.name, rs.name, ro.name, fkc.constraint_column_id, pc.name, rc.name\n\
    \FROM sys.foreign_keys AS fk\n\
    \JOIN sys.objects AS o ON o.object_id = fk.parent_object_id\n\
    \JOIN sys.schemas AS s ON s.schema_id = o.schema_id\n\
    \JOIN sys.objects AS ro ON ro.object_id = fk.referenced_object_id\n\
    \JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id\n\
    \JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id\n\
    \JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id\n\
    \JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id AND rc.column_id = fkc.referenced_column_id\n\
    \WHERE " <> objectFilter <> "\n\
    \ORDER BY s.name, o.name, fk.name, fkc.constraint_column_id"
  ]
  where
    objectFilter =
      "o.type IN ('U', 'V') AND o.is_ms_shipped = 0\
      \ AND (@p1 IS NULL OR s.name = @p1) AND (@p2 IS NULL OR o.name = @p2)"

readCatalog :: Connection -> Maybe Text -> Maybe Text -> IO [Table]
readCatalog conn schema object = do
  (columns, keys, fks) <- queryResultSets ((,,) <$> resultSet <*> resultSet <*> resultSet) conn (mkQuery catalogSql (schema, object))
  let keysOf = Map.fromListWith (flip (++))
        [ (ObjectName (kSchema r) (kObject r), [(kIsPrimary r, KeyConstraint (kName r) (map kColumn rs))])
        | rs@(r : _) <- groupBy ((==) `on` \r -> (kSchema r, kObject r, kName r)) keys ]
      fksOf = Map.fromListWith (flip (++))
        [ (ObjectName (fSchema r) (fObject r), [ForeignKey (fName r) (map fColumn rs) (ObjectName (fReferencedSchema r) (fReferencedObject r)) (map fReferencedColumn rs)])
        | rs@(r : _) <- groupBy ((==) `on` \r -> (fSchema r, fObject r, fName r)) fks ]
      table rs@(r : _) =
        let name = ObjectName (rSchema r) (rObject r)
            ks = Map.findWithDefault [] name keysOf
         in Table
              { tableName = name
              , tableKind = if rIsView r then View else UserTable
              , tableColumns = map toColumn rs
              , tablePrimaryKey = lookup True ks
              , tableUniqueKeys = [k | (False, k) <- ks]
              , tableForeignKeys = Map.findWithDefault [] name fksOf
              }
      table [] = error "readCatalog: empty group"
  pure (map table (groupBy ((==) `on` \r -> (rSchema r, rObject r)) columns))

toColumn :: ColumnRow -> Column
toColumn r = Column
  { colName = rColumn r
  , colId = rColumnId r
  , colTypeName = if rTypeSchema r == "sys" then rTypeName r else rTypeSchema r <> "." <> rTypeName r
  , colType = SqlType <$> dataType <*> pure args
  , colNullable = rNullable r
  , colCollation = rCollation r
  , colIdentity = rIdentity r
  , colComputed = Computed <$> rComputedDefinition r <*> (rComputedPersisted r `orElse` False)
  , colDefault = rDefault r
  , colGenerated = case rGeneratedAlways r of
      0 -> Nothing
      1 -> Just AsRowStart
      2 -> Just AsRowEnd
      7 -> Just AsTransactionIdStart
      8 -> Just AsTransactionIdEnd
      9 -> Just AsSequenceNumberStart
      10 -> Just AsSequenceNumberEnd
      n -> Just (AsOther n)
  , colHidden = rHidden r
  }
  where
    orElse m d = Just (maybe d id m)
    -- The system type: the declared type's own name, or the base of an
    -- alias type.  A user-defined CLR type is named by the user, so its
    -- name says nothing.
    dataType
      | rTypeUserDefined r = rBaseTypeName r >>= dataTypeFromName
      | rTypeClr r && rTypeSchema r /= "sys" = Nothing
      | otherwise = dataTypeFromName (rTypeName r)
    args = case dataType of
      Just TyChar -> LengthArg (bytesLength (rMaxLength r))
      Just TyVarChar -> LengthArg (bytesLength (rMaxLength r))
      Just TyBinary -> LengthArg (bytesLength (rMaxLength r))
      Just TyVarBinary -> LengthArg (bytesLength (rMaxLength r))
      Just TyNChar -> LengthArg (charsLength (rMaxLength r))
      Just TyNVarChar -> LengthArg (charsLength (rMaxLength r))
      Just TyDecimal -> PrecisionScaleArg (fromIntegral (rPrecision r)) (fromIntegral (rScale r))
      Just TyNumeric -> PrecisionScaleArg (fromIntegral (rPrecision r)) (fromIntegral (rScale r))
      Just TyTime -> ScaleArg (fromIntegral (rScale r))
      Just TyDateTime2 -> ScaleArg (fromIntegral (rScale r))
      Just TyDateTimeOffset -> ScaleArg (fromIntegral (rScale r))
      -- A vector's storage is 8 bytes plus 4 per dimension.
      Just TyVector -> DimensionsArg ((rMaxLength r - 8) `div` 4)
      Just TyXml | Just schema <- rXmlSchema r, Just collection <- rXmlCollection r -> XmlSchemaArg schema collection
      _ -> NoArgs
    -- max_length is in bytes, -1 for (max).
    bytesLength n
      | n < 0 = Max
      | otherwise = Length n
    charsLength n
      | n < 0 = Max
      | otherwise = Length (n `div` 2)
