-- | Shared helpers for the @Rpc.*@ spec modules (procedure-call shapes, in
-- depth).  Not itself a spec module (no 'spec' export), so hspec-discover
-- skips it.
module Rpc.Common
  ( out
  , inp
  , outValues
  , tshow
  , mkProc
  , dropProc
  , withProc
  , mkProcIn
  , withProcIn
  ) where

import Control.Exception (finally)
import Data.Text (Text)
import qualified Data.Text as T

import Hmssql

import Hmssql.Query
import Hmssql.SqlValue
import Hmssql.Errors
-- | Short names for 'outParam' and 'inParam', so that a call's parameter
-- list reads as a table.
out :: ToSqlField a => Text -> a -> ProcParam
out = outParam

inp :: ToSqlField a => Text -> a -> ProcParam
inp = inParam

outValues :: ProcResult -> [Either DecodeError SqlValue]
outValues = map decodeReturnValue . procOutputValues

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Create or replace a procedure named @dbo.\<name>@ with the given body
-- (starting at the parameter list or @AS@).
mkProc :: Connection -> Text -> Text -> IO ()
mkProc conn name body = () <$ execute conn (rawSql ("CREATE OR ALTER PROCEDURE dbo." <> name <> " " <> body))

dropProc :: Connection -> Text -> IO ()
dropProc conn name = () <$ execute conn (rawSql ("DROP PROCEDURE IF EXISTS dbo." <> name))

-- | Create @dbo.\<name>@, run the action, then drop it even on failure.
withProc :: Connection -> Text -> Text -> IO a -> IO a
withProc conn name body act = do
  mkProc conn name body
  act `finally` dropProc conn name

-- | Like 'mkProc', but for a fully-qualified or otherwise pre-formed
-- procedure identifier (bracketed, schema-qualified, temp, numbered, ...):
-- the caller supplies the whole @CREATE OR ALTER PROCEDURE \<ident> ...@ text
-- after @PROCEDURE@, and the whole @DROP PROCEDURE ...@ text separately.
mkProcIn :: Connection -> Text -> Text -> IO ()
mkProcIn conn createSuffix body =
  () <$ execute conn (rawSql ("CREATE OR ALTER PROCEDURE " <> createSuffix <> " " <> body))

withProcIn :: Connection -> Text -> Text -> Text -> IO a -> IO a
withProcIn conn createSuffix body dropSql act = do
  mkProcIn conn createSuffix body
  act `finally` (() <$ execute conn (rawSql dropSql))
