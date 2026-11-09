{-# LANGUAGE OverloadedStrings #-}
module CallsProc where
import Hmssql
import Hmssql.Query
import Data.Int
proc :: Connection -> Int32 -> IO ProcResult
proc c x = callProcedure c "p" [inParam "@x" x,outParam "@y" (Nothing :: Maybe Int32)]
