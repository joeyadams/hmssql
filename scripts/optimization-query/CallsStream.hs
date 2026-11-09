{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module CallsStream where
import Hmssql
import Data.Int
import qualified Streaming.Prelude as S
stream :: Connection -> IO Int
stream conn = queryS @(Only Int32) conn "SELECT i" >>= S.length_
