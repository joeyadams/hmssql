{-# LANGUAGE OverloadedStrings #-}
module Calls where
import Hmssql
import Hmssql.Query
import Data.Int
named :: Int32 -> Query
named x = mkQuery "SELECT @x" (NamedParams [("x",SqlParam x)])
proc :: Connection -> Int32 -> IO ProcResult
proc c x = callProcedure c "p" [inParam "@x" x,outParam "@y" (Nothing :: Maybe Int32)]
literal :: Int32 -> Query
literal x = mkQuery "SELECT @p1" (Only x)
