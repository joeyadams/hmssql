{-# LANGUAGE OverloadedStrings #-}
module CallsMany where
import Hmssql
import Hmssql.Query
import Data.Int
many :: Connection -> [Only Int32] -> IO [Int64]
many conn xs = executeMany conn "SELECT @p1" xs
