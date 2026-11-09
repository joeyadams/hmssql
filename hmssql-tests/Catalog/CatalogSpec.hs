-- | "Hmssql.Catalog" against the server: a table with a column of every
-- type, an alias type, a typed xml column, a computed column, defaults,
-- identity and a temporal period; keys and foreign keys, including
-- multi-column ones; a view; and what the reader says about a table that
-- doesn't exist.
module Catalog.CatalogSpec (spec) where

import Control.Monad (forM_, void)
import Data.Maybe (isJust)
import Data.Text (Text)
import Test.Hspec

import Hmssql
import Hmssql.Catalog hiding (readTable, readTables, readTablesIn)
import qualified Hmssql.Catalog as Catalog
import Hmssql.SqlType
import TestDb

-- | The objects, in schema @s@ and in schema @o@, both the test's own.
setupSql :: Text -> Text -> [Text]
setupSql s o =
  [ "CREATE TYPE " <> s <> ".phone FROM varchar(20) NOT NULL"
  , "CREATE XML SCHEMA COLLECTION " <> s <> ".Person AS N'<?xml version=\"1.0\"?>\
    \<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"><xs:element name=\"a\" type=\"xs:string\"/></xs:schema>'"
  , "CREATE TABLE " <> s <> ".probe (\n\
    \  i int IDENTITY(1,1) NOT NULL CONSTRAINT pk_probe PRIMARY KEY,\n\
    \  ti tinyint, si smallint, bi bigint, b bit,\n\
    \  d decimal(10,2), nu numeric(5), m money, sm smallmoney, f float, f24 float(24), r real,\n\
    \  ch char(5), vc varchar(30), vcm varchar(max), nc nchar(4), nv nvarchar(50), nvm nvarchar(max), tx text, ntx ntext,\n\
    \  bn binary(4), vb varbinary(16), vbm varbinary(max), im image,\n\
    \  dd date, t time(4), dt datetime, sdt smalldatetime, dt2 datetime2(3), dto datetimeoffset,\n\
    \  u uniqueidentifier NOT NULL CONSTRAINT df_probe_u DEFAULT NEWID(),\n\
    \  x xml, xt xml(" <> s <> ".Person), sv sql_variant, ts rowversion,\n\
    \  s sysname, ph " <> s <> ".phone, h hierarchyid, geo geography, geom geometry,\n\
    \  c AS (i * 2) PERSISTED,\n\
    \  dflt int NOT NULL CONSTRAINT df_probe_dflt DEFAULT 7,\n\
    \  vfrom datetime2 GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,\n\
    \  vto datetime2 GENERATED ALWAYS AS ROW END HIDDEN NOT NULL,\n\
    \  PERIOD FOR SYSTEM_TIME (vfrom, vto),\n\
    \  CONSTRAINT uq_probe_nv UNIQUE (nv, si)\n\
    \)"
  , "CREATE TABLE " <> s <> ".parent (a int NOT NULL, b nvarchar(10) NOT NULL, note nvarchar(max), CONSTRAINT pk_parent PRIMARY KEY (b, a))"
  , "CREATE TABLE " <> s <> ".child (\n\
    \  id int NOT NULL CONSTRAINT pk_child PRIMARY KEY,\n\
    \  pa int NOT NULL, pb nvarchar(10) NOT NULL, probe_id int NULL,\n\
    \  CONSTRAINT fk_child_parent FOREIGN KEY (pb, pa) REFERENCES " <> s <> ".parent (b, a),\n\
    \  CONSTRAINT fk_child_probe FOREIGN KEY (probe_id) REFERENCES " <> s <> ".probe (i)\n\
    \)"
  , "CREATE VIEW " <> s <> ".parent_view AS SELECT a AS aa, b FROM " <> s <> ".parent"
  , "CREATE TABLE " <> o <> ".elsewhere (id int NOT NULL PRIMARY KEY)"
  ]

-- | @json@ and @vector@ (SQL Server 2025 and Azure SQL Database), when the
-- server has them.
newTypesSql :: Text -> [Text]
newTypesSql s =
  [ "CREATE TABLE " <> s <> ".probe_new (j json, v vector(3) NOT NULL)" ]

-- | The schema the test's objects are in besides @s@.
otherSchema :: Text -> Text
otherSchema s = s <> "_other"

-- | The objects in two schemas of the test's own, in the shared database
-- (rather than a scratch database, which on Azure SQL takes 25-60 s to
-- create); the action gets the first schema's name.  Both are dropped
-- afterwards, with everything in them.
-- | The catalog reads, tried again when the server picks one as a
-- deadlock victim ('retryDeadlock'): the tests' schemas are in the shared
-- database, where other tests create and drop objects at the same time.
readTable :: Connection -> ObjectName -> IO (Maybe Table)
readTable conn = retryDeadlock . Catalog.readTable conn

readTables :: Connection -> IO [Table]
readTables = retryDeadlock . Catalog.readTables

readTablesIn :: Connection -> Text -> IO [Table]
readTablesIn conn = retryDeadlock . Catalog.readTablesIn conn

withCatalogDb :: (Text -> Connection -> IO a) -> IO a
withCatalogDb act = do
  ci <- defaultTestConnectInfo
  withScratchSchema ci "catalog" $ \s -> withSchema ci (otherSchema s) $ withConnection ci $ \conn -> do
    forM_ (setupSql s (otherSchema s)) $ \sql -> retryDeadlock (void (execute conn (rawSql sql)))
    act s conn

spec :: Spec
spec = describe "Hmssql.Catalog" $ do
  it "reads every column type, resolving alias types and reading arguments" $ withCatalogDb $ \s conn -> do
    Just t <- readTable conn (ObjectName s "probe")
    tableKind t `shouldBe` UserTable
    let typed = [(colName c, colTypeName c, colType c) | c <- tableColumns t]
        len = LengthArg . Length
    typed `shouldBe`
      [ ("i", "int", Just (SqlType TyInt NoArgs))
      , ("ti", "tinyint", Just (SqlType TyTinyInt NoArgs))
      , ("si", "smallint", Just (SqlType TySmallInt NoArgs))
      , ("bi", "bigint", Just (SqlType TyBigInt NoArgs))
      , ("b", "bit", Just (SqlType TyBit NoArgs))
      , ("d", "decimal", Just (SqlType TyDecimal (PrecisionScaleArg 10 2)))
      , ("nu", "numeric", Just (SqlType TyNumeric (PrecisionScaleArg 5 0)))
      , ("m", "money", Just (SqlType TyMoney NoArgs))
      , ("sm", "smallmoney", Just (SqlType TySmallMoney NoArgs))
      , ("f", "float", Just (SqlType TyFloat NoArgs))
      , ("f24", "real", Just (SqlType TyReal NoArgs))
      , ("r", "real", Just (SqlType TyReal NoArgs))
      , ("ch", "char", Just (SqlType TyChar (len 5)))
      , ("vc", "varchar", Just (SqlType TyVarChar (len 30)))
      , ("vcm", "varchar", Just (SqlType TyVarChar (LengthArg Max)))
      , ("nc", "nchar", Just (SqlType TyNChar (len 4)))
      , ("nv", "nvarchar", Just (SqlType TyNVarChar (len 50)))
      , ("nvm", "nvarchar", Just (SqlType TyNVarChar (LengthArg Max)))
      , ("tx", "text", Just (SqlType TyText NoArgs))
      , ("ntx", "ntext", Just (SqlType TyNText NoArgs))
      , ("bn", "binary", Just (SqlType TyBinary (len 4)))
      , ("vb", "varbinary", Just (SqlType TyVarBinary (len 16)))
      , ("vbm", "varbinary", Just (SqlType TyVarBinary (LengthArg Max)))
      , ("im", "image", Just (SqlType TyImage NoArgs))
      , ("dd", "date", Just (SqlType TyDate NoArgs))
      , ("t", "time", Just (SqlType TyTime (ScaleArg 4)))
      , ("dt", "datetime", Just (SqlType TyDateTime NoArgs))
      , ("sdt", "smalldatetime", Just (SqlType TySmallDateTime NoArgs))
      , ("dt2", "datetime2", Just (SqlType TyDateTime2 (ScaleArg 3)))
      , ("dto", "datetimeoffset", Just (SqlType TyDateTimeOffset (ScaleArg 7)))
      , ("u", "uniqueidentifier", Just (SqlType TyUniqueIdentifier NoArgs))
      , ("x", "xml", Just (SqlType TyXml NoArgs))
      , ("xt", "xml", Just (SqlType TyXml (XmlSchemaArg s "Person")))
      , ("sv", "sql_variant", Just (SqlType TySqlVariant NoArgs))
      , ("ts", "timestamp", Just (SqlType TyRowVersion NoArgs))
      , ("s", "sysname", Just (SqlType TyNVarChar (len 128)))
      , ("ph", s <> ".phone", Just (SqlType TyVarChar (len 20)))
      , ("h", "hierarchyid", Just (SqlType TyHierarchyId NoArgs))
      , ("geo", "geography", Just (SqlType TyGeography NoArgs))
      , ("geom", "geometry", Just (SqlType TyGeometry NoArgs))
      , ("c", "int", Just (SqlType TyInt NoArgs))
      , ("dflt", "int", Just (SqlType TyInt NoArgs))
      , ("vfrom", "datetime2", Just (SqlType TyDateTime2 (ScaleArg 7)))
      , ("vto", "datetime2", Just (SqlType TyDateTime2 (ScaleArg 7)))
      ]
    -- Every resolved type renders as T-SQL accepts it.
    forM_ (tableColumns t) $ \c -> forM_ (colType c) $ \st -> (colName c, sqlTypeProblem st) `shouldBe` (colName c, Nothing)
    map colId (tableColumns t) `shouldBe` [1 .. length (tableColumns t)]

  it "reads nullability, identity, defaults, computed columns, the period and hidden columns" $ withCatalogDb $ \s conn -> do
    Just t <- readTable conn (ObjectName s "probe")
    let col name = maybe (error ("no column " ++ show name)) id (lookupColumn t name)
    colNullable (col "i") `shouldBe` False
    colNullable (col "ti") `shouldBe` True
    colNullable (col "ph") `shouldBe` False   -- the alias type's NOT NULL
    colNullable (col "s") `shouldBe` False    -- sysname is NOT NULL
    colIdentity (col "i") `shouldBe` True
    colIdentity (col "ti") `shouldBe` False
    colDefault (col "u") `shouldBe` Just "(newid())"
    colDefault (col "dflt") `shouldBe` Just "((7))"
    colDefault (col "ti") `shouldBe` Nothing
    colComputed (col "c") `shouldBe` Just (Computed "([i]*(2))" True)
    colComputed (col "i") `shouldBe` Nothing
    colGenerated (col "vfrom") `shouldBe` Just AsRowStart
    colGenerated (col "vto") `shouldBe` Just AsRowEnd
    colGenerated (col "dt2") `shouldBe` Nothing
    colHidden (col "vfrom") `shouldBe` True
    colHidden (col "dt2") `shouldBe` False
    colCollation (col "nv") `shouldSatisfy` isJust
    colCollation (col "ch") `shouldSatisfy` isJust
    colCollation (col "i") `shouldBe` Nothing
    colCollation (col "vb") `shouldBe` Nothing

  it "reads primary keys, unique constraints and foreign keys, multi-column ones in order" $ withCatalogDb $ \s conn -> do
    Just probe <- readTable conn (ObjectName s "probe")
    tablePrimaryKey probe `shouldBe` Just (KeyConstraint "pk_probe" ["i"])
    tableUniqueKeys probe `shouldBe` [KeyConstraint "uq_probe_nv" ["nv", "si"]]
    tableForeignKeys probe `shouldBe` []
    Just parent <- readTable conn (ObjectName s "parent")
    tablePrimaryKey parent `shouldBe` Just (KeyConstraint "pk_parent" ["b", "a"])
    Just child <- readTable conn (ObjectName s "child")
    tableForeignKeys child `shouldBe`
      [ ForeignKey "fk_child_parent" ["pb", "pa"] (ObjectName s "parent") ["b", "a"]
      , ForeignKey "fk_child_probe" ["probe_id"] (ObjectName s "probe") ["i"]
      ]

  it "reads views, with their columns and no keys" $ withCatalogDb $ \s conn -> do
    Just v <- readTable conn (ObjectName s "parent_view")
    tableKind v `shouldBe` View
    [(colName c, colType c) | c <- tableColumns v] `shouldBe`
      [("aa", Just (SqlType TyInt NoArgs)), ("b", Just (SqlType TyNVarChar (LengthArg (Length 10))))]
    tablePrimaryKey v `shouldBe` Nothing
    tableForeignKeys v `shouldBe` []

  it "lists one schema, or every schema, in name order" $ withCatalogDb $ \s conn -> do
    let o = otherSchema s
    mine <- readTablesIn conn s
    map tableName mine `shouldBe` map (ObjectName s) ["child", "parent", "parent_view", "probe"]
    -- The shared database has the other tests' tables too: those of the
    -- two schemas come in name order, and others (the fixtures table, say)
    -- are listed as well.
    everything <- map tableName <$> readTables conn
    filter ((`elem` [s, o]) . objectSchema) everything `shouldBe`
      map (ObjectName s) ["child", "parent", "parent_view", "probe"] ++ [ObjectName o "elsewhere"]
    everything `shouldContain` [ObjectName "dbo" "_hmssql_fixtures"]
    nowhere <- readTablesIn conn "no_such_schema"
    nowhere `shouldBe` []

  it "says Nothing for a table that doesn't exist" $ withCatalogDb $ \s conn -> do
    readTable conn (ObjectName s "nope") `shouldReturn` Nothing
    readTable conn (ObjectName "nope" "probe") `shouldReturn` Nothing

  it "renders an object's name quoted" $
    objectNameSql (ObjectName "dbo" "we]ird") `shouldBe` "[dbo].[we]]ird]"

  describe "json and vector" $
    skipWhen (not <$> serverHasJsonAndVector) "the server has no json or vector type" $
      it "are read with the vector's dimensions" $ withCatalogDb $ \s conn -> do
        forM_ (newTypesSql s) $ \sql -> void (execute conn (rawSql sql))
        Just t <- readTable conn (ObjectName s "probe_new")
        [(colName c, colTypeName c, colType c, colNullable c) | c <- tableColumns t] `shouldBe`
          [ ("j", "json", Just (SqlType TyJson NoArgs), True)
          , ("v", "vector", Just (SqlType TyVector (DimensionsArg 3)), False)
          ]

serverHasJsonAndVector :: IO Bool
serverHasJsonAndVector = withTestDb $ \conn -> do
  Only n <- query1 conn "SELECT COUNT(*) FROM sys.types WHERE name IN ('json', 'vector')"
  pure (n == (2 :: Int))
