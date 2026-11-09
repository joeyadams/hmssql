{-# LANGUAGE OverloadedStrings #-}
module CallsBulk where
import Hmssql
import Hmssql.BulkCopy
import Data.Int
bulk :: Connection -> [(Int32, Int64)] -> IO Int64
bulk conn xs = bulkInsert conn "t" xs
