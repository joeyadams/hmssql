-- | Names are data when reading the catalog and identifiers when executing
-- its output. Exercise both, plus metadata after ordinary schema evolution.
module Catalog.UnusualSpec (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Catalog hiding (readTable, readTables, readTablesIn)
import qualified Hmssql.Catalog as Catalog
import Hmssql.SqlType
import TestDb

spec :: Spec
spec = describe "catalog names and schema evolution" $ do
  forM_ ["space name", "dot.name", "close]bracket", "quote'name", "double\"quote", "semi;--comment", "日本語", "select", "percent%_wildcard", "😀𝄞", "line\nbreak", "trailing space "] $ \suffix ->
    it ("reads exact schema, table and column names containing " ++ T.unpack suffix) $ withOddSchema suffix $ \conn s -> do
      let name = ObjectName s suffix
          sqlName = objectNameSql name
      void $ execute conn $ rawSql ("CREATE TABLE " <> sqlName <> " (" <> quoteName suffix <> " nvarchar(20) NULL)")
      Just table <- readTable conn name
      tableName table `shouldBe` name
      map colName (tableColumns table) `shouldBe` [suffix]
      map colType (tableColumns table) `shouldBe` [Just (SqlType TyNVarChar (LengthArg (Length 20)))]
      readTablesIn conn s `shouldReturn` [table]
      void $ execute conn (rawSql ("INSERT INTO " <> sqlName <> " VALUES (N'\x1f600')"))
      query conn (rawSql ("SELECT " <> quoteName suffix <> " FROM " <> sqlName)) `shouldReturn` [Only ("\x1f600" :: Text)]
      readTablesIn conn (s <> "_missing") `shouldReturn` []
      readTable conn (ObjectName s (suffix <> "_missing")) `shouldReturn` Nothing

  it "does not conflate a dot in a table name with schema qualification" $ withOddSchema "dots" $ \conn s -> do
    let a = ObjectName s "a.b"
        b = ObjectName s "b"
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql a <> " (x int); CREATE TABLE " <> objectNameSql b <> " (y bigint)")
    Just ta <- readTable conn a
    Just tb <- readTable conn b
    map colName (tableColumns ta) `shouldBe` ["x"]
    map colName (tableColumns tb) `shouldBe` ["y"]

  it "keeps column_id gaps after dropping and adding columns" $ withOddSchema "evolution" $ \conn s -> do
    let name = ObjectName s "evolving"
        q = objectNameSql name
    void $ execute conn $ rawSql ("CREATE TABLE " <> q <> " (a int, gone int, c nvarchar(7)); ALTER TABLE " <> q <> " DROP COLUMN gone; ALTER TABLE " <> q <> " ADD d decimal(9,3)")
    Just t <- readTable conn name
    map (\c -> (colId c, colName c)) (tableColumns t) `shouldBe` [(1,"a"),(3,"c"),(4,"d")]
    lookupColumn t "gone" `shouldBe` Nothing
    void $ execute conn $ rawSql ("ALTER TABLE " <> q <> " ALTER COLUMN c nvarchar(max) NOT NULL")
    Just changed <- readTable conn name
    fmap colType (lookupColumn changed "c") `shouldBe` Just (Just (SqlType TyNVarChar (LengthArg Max)))
    fmap colNullable (lookupColumn changed "c") `shouldBe` Just False

  it "keeps cross-schema and self-referencing composite foreign keys in declared order" $ withOddSchema "foreign]keys" $ \conn s -> do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "catalog_parent" $ \other -> do
      let parent = ObjectName other "parent"
          child = ObjectName s "child"
          p = objectNameSql parent
          c = objectNameSql child
      void $ execute conn $ rawSql ("CREATE TABLE " <> p <> " (a int NOT NULL, b int NOT NULL, PRIMARY KEY (b,a)); CREATE TABLE " <> c <> " (x int NOT NULL, y int NOT NULL, px int, py int, CONSTRAINT [pk] PRIMARY KEY(y,x), CONSTRAINT [fk cross] FOREIGN KEY(px,py) REFERENCES " <> p <> "(b,a), CONSTRAINT [fk self] FOREIGN KEY(py,px) REFERENCES " <> c <> "(y,x))")
      Just table <- readTable conn child
      tablePrimaryKey table `shouldBe` Just (KeyConstraint "pk" ["y","x"])
      tableForeignKeys table `shouldBe`
        [ ForeignKey "fk cross" ["px","py"] parent ["b","a"]
        , ForeignKey "fk self" ["py","px"] child ["y","x"] ]

  it "does not report unique indexes as unique constraints" $ withOddSchema "indexes" $ \conn s -> do
    let name = ObjectName s "indexed"
        q = objectNameSql name
    void $ execute conn $ rawSql ("CREATE TABLE " <> q <> " (a int NOT NULL, b int, c int, CONSTRAINT [unique constraint] UNIQUE (c,a)); CREATE UNIQUE INDEX [unique index] ON " <> q <> "(a) INCLUDE (b); CREATE UNIQUE INDEX [filtered index] ON " <> q <> "(b) WHERE b IS NOT NULL")
    Just t <- readTable conn name
    tablePrimaryKey t `shouldBe` Nothing
    tableUniqueKeys t `shouldBe` [KeyConstraint "unique constraint" ["c","a"]]

  it "resolves alias types with punctuation to their actual base type" $ withOddSchema "aliases" $ \conn s -> do
    let name = ObjectName s "aliased"
        alias = objectNameSql (ObjectName s "odd.type]")
    void $ execute conn $ rawSql ("CREATE TYPE " <> alias <> " FROM nvarchar(13) NULL")
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql name <> " (v " <> alias <> ")")
    Just t <- readTable conn name
    map colTypeName (tableColumns t) `shouldBe` [s <> ".odd.type]"]
    map colType (tableColumns t) `shouldBe` [Just (SqlType TyNVarChar (LengthArg (Length 13)))]

  it "reads sparse columns and the XML column set" $ withOddSchema "sparse" $ \conn s -> do
    let name = ObjectName s "sparse"
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql name <> " (id int NOT NULL, a int SPARSE NULL, b nvarchar(30) SPARSE NULL, everything xml COLUMN_SET FOR ALL_SPARSE_COLUMNS)")
    Just t <- readTable conn name
    map colName (tableColumns t) `shouldBe` ["id","a","b","everything"]
    map colNullable (tableColumns t) `shouldBe` [False,True,True,True]
    fmap colType (lookupColumn t "everything") `shouldBe` Just (Just (SqlType TyXml NoArgs))

  it "round trips a quoted XML schema collection through SqlType rendering" $ withOddSchema "xml]schema" $ \conn s -> do
    let collection = "schema]collection.with dot"
        collectionSql = objectNameSql (ObjectName s collection)
        original = ObjectName s "typed"
        copied = ObjectName s "copy"
    void $ execute conn $ rawSql ("CREATE XML SCHEMA COLLECTION " <> collectionSql <> " AS N'<xs:schema xmlns:xs=\"http://www.w3.org/2001/XMLSchema\"><xs:element name=\"r\" type=\"xs:string\"/></xs:schema>'")
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql original <> " (v xml(" <> collectionSql <> "))")
    Just table <- readTable conn original
    let [Just typ] = map colType (tableColumns table)
    typ `shouldBe` SqlType TyXml (XmlSchemaArg s collection)
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql copied <> " (v " <> sqlTypeName typ <> ")")
    void $ execute conn $ mkQuery ("INSERT INTO " <> objectNameSql copied <> " VALUES (@p1)") (Only ("<r>😀</r>" :: Text))
    query1 conn (rawSql ("SELECT v FROM " <> objectNameSql copied)) `shouldReturn` Only ("<r>😀</r>" :: Text)
    Just clone <- readTable conn copied
    map colType (tableColumns clone) `shouldBe` [Just typ]

  skipOnAzure "changes the test database's collation" $
    it "keeps schemas, tables and columns differing only in case distinct" $ withScratchDatabase "catalog_case" $ \ci -> do
      master <- masterConnectInfo
      withConnection master $ \conn -> void $ execute conn $ rawSql ("ALTER DATABASE " <> quoteName (connectDatabase ci) <> " COLLATE Latin1_General_100_BIN2")
      withConnection ci $ \conn -> do
        void $ execute conn "CREATE SCHEMA [s]"
        void $ execute conn "CREATE SCHEMA [S]"
        void $ execute conn "CREATE TABLE [s].[item] ([value] int NOT NULL,[VALUE] bigint NOT NULL,CONSTRAINT [key] PRIMARY KEY ([VALUE],[value])); CREATE TABLE [s].[Item] (v nvarchar(10)); CREATE TABLE [S].[item] (v bit)"
        map tableName <$> readTables conn `shouldReturn` [ObjectName "S" "item",ObjectName "s" "Item",ObjectName "s" "item"]
        map tableName <$> readTablesIn conn "S" `shouldReturn` [ObjectName "S" "item"]
        map tableName <$> readTablesIn conn "s" `shouldReturn` [ObjectName "s" "Item",ObjectName "s" "item"]
        Just table <- readTable conn (ObjectName "s" "item")
        tablePrimaryKey table `shouldBe` Just (KeyConstraint "key" ["VALUE","value"])
        fmap colType (lookupColumn table "value") `shouldBe` Just (Just (SqlType TyInt NoArgs))
        fmap colType (lookupColumn table "VALUE") `shouldBe` Just (Just (SqlType TyBigInt NoArgs))
        lookupColumn table "Value" `shouldBe` Nothing
        readTable conn (ObjectName "s" "ITEM") `shouldReturn` Nothing

  it "respects catalog visibility for a user granted SELECT on only one table" $ withOddSchema "permissions" $ \conn s -> do
    user <- uniqueName "catalog_reader"
    let allowed = ObjectName s "allowed"
        hidden = ObjectName s "hidden"
    void $ execute conn $ rawSql ("CREATE TABLE " <> objectNameSql allowed <> " (id int NOT NULL PRIMARY KEY,v nvarchar(20)); CREATE TABLE " <> objectNameSql hidden <> " (secret int)")
    void $ execute conn $ rawSql ("CREATE USER " <> quoteName user <> " WITHOUT LOGIN")
    flip finally (void $ execute conn $ rawSql ("DROP USER " <> quoteName user)) $ do
      void $ execute conn $ rawSql ("GRANT SELECT ON " <> objectNameSql allowed <> " TO " <> quoteName user)
      void $ execute conn $ rawSql ("EXECUTE AS USER=N'" <> user <> "'")
      flip finally (void $ execute conn "REVERT") $ do
        tables <- readTablesIn conn s
        map tableName tables `shouldBe` [allowed]
        map (map colName . tableColumns) tables `shouldBe` [["id","v"]]
        readTable conn hidden `shouldReturn` Nothing
        fmap tableName <$> readTable conn allowed `shouldReturn` Just allowed

-- Other examples create and drop objects in the shared database. As in
-- CatalogSpec, retry a catalog read if concurrent DDL makes it the victim.
readTable :: Connection -> ObjectName -> IO (Maybe Table)
readTable conn = retryDeadlock . Catalog.readTable conn

readTables :: Connection -> IO [Table]
readTables = retryDeadlock . Catalog.readTables

readTablesIn :: Connection -> Text -> IO [Table]
readTablesIn conn = retryDeadlock . Catalog.readTablesIn conn

-- withSchema intentionally accepts simple names only. This fixture quotes
-- the unusual schema at creation and uses the catalog-based cleanup helper.
withOddSchema :: Text -> (Connection -> Text -> IO a) -> IO a
withOddSchema suffix action = withTestDb $ \conn -> do
  prefix <- uniqueName "catalog_odd"
  let schema = prefix <> "_" <> suffix
  retryDeadlock $ void $ execute conn $ rawSql ("CREATE SCHEMA " <> quoteName schema)
  action conn schema `finally` dropSchema conn schema
