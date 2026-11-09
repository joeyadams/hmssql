{-# LANGUAGE OverloadedStrings #-}
module CallsText where
import Hmssql
import Hmssql.Query
import Data.Int
import Data.Text (Text)
import qualified Data.Text as T
smallText :: String -> Text
smallText = T.pack
{-# OPAQUE smallText #-}
proc :: Connection -> Int32 -> IO ProcResult
proc c x = callProcedure c (smallText "p") [inParam (smallText "@x") x,outParam (smallText "@y") (Nothing :: Maybe Int32)]
