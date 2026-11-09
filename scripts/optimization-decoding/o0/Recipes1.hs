{-# OPTIONS_GHC -O1 #-}
module Recipes1 (pair, nullable) where
import Data.Int
import Data.Text (Text)
import Data.Decimal (Decimal)
import Data.Time (LocalTime)
import Hmssql.Decoding
pair :: RowDecoder (Int32,Int64)
pair = (,) <$> singleField (fieldDecoder @Int32) <*> singleField (fieldDecoder @Int64)
nullable :: RowDecoder (Maybe Int32,Maybe Text,Maybe Decimal,Maybe LocalTime,Maybe Int64)
nullable = (,,,,) <$> singleField (fieldDecoder @(Maybe Int32)) <*> singleField (fieldDecoder @(Maybe Text)) <*> singleField (fieldDecoder @(Maybe Decimal)) <*> singleField (fieldDecoder @(Maybe LocalTime)) <*> singleField (fieldDecoder @(Maybe Int64))
