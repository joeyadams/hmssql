{-# LANGUAGE DeriveAnyClass, DeriveGeneric, OverloadedStrings #-}
-- A small application that reaches connection, TLS, query, and record decoding.
-- The size script only links it; it never connects to a database.
module Main (main) where

import Control.Exception (bracket)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Hmssql
import System.Environment (getEnv)

data Item = Item !Int32 !Text deriving (Show, Generic, FromSqlRow)

main :: IO ()
main = do
  password <- T.pack <$> getEnv "HMSSQL_TEST_PASSWORD"
  bracket (connect defaultConnectInfo { connectPassword = password }) close $ \conn ->
    (query conn "SELECT 1, N'one'" :: IO [Item]) >>= print
