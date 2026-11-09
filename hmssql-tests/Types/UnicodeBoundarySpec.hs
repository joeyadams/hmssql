-- | Supplementary characters occupy two UTF-16 units and four UTF-8 bytes.
-- Put them on either side of short-value, PLP and packet boundaries and
-- compare complete values, including after a slice of a larger Text.
module Types.UnicodeBoundarySpec (spec) where

import Control.Monad (forM_, void)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import qualified Data.ByteString as B
import Test.Hspec

import Hmssql
import Hmssql.BulkCopy
import Hmssql.Query (queryMWith)
import Hmssql.Decoding
import Hmssql.SqlValue
import TestDb

spec :: Spec
spec = around withTestDb $ describe "supplementary character boundaries" $ do
  forM_ [0,1,7,8,9,254,255,256,1999,2000,2001,3997,3998,3999,4000,4001,7997,7998,7999,8000,8001,16000] $ \n -> do
    it ("preserves an nvarchar parameter with a surrogate pair after " ++ show n ++ " BMP characters") $ \conn -> do
      let value = T.replicate n "a" <> "😀𝄞𐀀\x10ffff" <> " é \0 tail  "
      query1 conn (mkQuery "SELECT @p1, DATALENGTH(@p1)" (Only value))
        `shouldReturn` (value, fromIntegral (B.length (TE.encodeUtf16LE value)) :: Int32)
      query1 conn (mkQuery "SELECT @p1" (Only (TL.fromStrict value))) `shouldReturn` Only value
    it ("preserves a sliced Text with " ++ show n ++ " supplementary characters") $ \conn -> do
      let middle = T.replicate n "😀" <> "𝄞x"
          value = T.dropEnd 5 (T.drop 7 ("prefix!" <> middle <> "tail!"))
      query1 conn (mkQuery "SELECT @p1" (Only value)) `shouldReturn` Only middle
      query1 conn (mkQuery "SELECT @p1" (Only (T.unpack value))) `shouldReturn` Only middle

  forM_ ["nvarchar(max)", "ntext"] $ \typ ->
    forM_ [0,1,1999,2000,2001,4000,8001] $ \n ->
      it ("reads " ++ T.unpack typ ++ " containing " ++ show n ++ " pairs through every row decoder") $ \conn -> do
        let value = T.replicate n "😀" <> "end  "
        void $ execute conn $ rawSql ("CREATE TABLE #unicode (v " <> typ <> " NULL)")
        void $ execute conn $ mkQuery "INSERT INTO #unicode(v) VALUES (@p1), (NULL), (N'')" (Only value)
        query conn "SELECT v FROM #unicode" `shouldReturn` [Only (Just value), Only Nothing, Only (Just "")]
        queryMWith (Only <$> singleFieldM fieldDecoder) conn "SELECT v FROM #unicode"
          `shouldReturn` [Only (Just value), Only Nothing, Only (Just "")]
        rows <- queryMWith sqlRowDecoder conn "SELECT v FROM #unicode"
        map sqlRowValues rows `shouldBe` [[SqlText value],[SqlNull],[SqlText ""]]

  skipBeforeSql2019 "UTF-8 collations" $
    forM_ [1,3,4,7,8,7995,7996,7997,7998,7999,8000,8001,16001] $ \n ->
      it ("round trips UTF-8 varchar(max) with a four-byte character near byte " ++ show n) $ \conn -> do
        let value = T.replicate n "a" <> "😀𝄞" <> " é tail  "
        void $ execute conn "CREATE TABLE #utf8 (v varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8)"
        void $ execute conn $ mkQuery "INSERT INTO #utf8 VALUES (@p1)" (Only value)
        query1 conn "SELECT v, DATALENGTH(v) FROM #utf8" `shouldReturn` (value, fromIntegral (B.length (TE.encodeUtf8 value)) :: Int32)
        query1 conn "SELECT v FROM #utf8" `shouldReturn` Only (TE.encodeUtf8 value)

  forM_ ["nvarchar(4)","nchar(4)"] $ \typ ->
    it ("bulk copies exactly two pairs into " ++ T.unpack typ) $ \conn -> do
      void $ execute conn $ rawSql ("CREATE TABLE #bulk_unicode (v " <> typ <> ")")
      bulkInsert conn "#bulk_unicode" [Only ("😀𝄞" :: Text)] `shouldReturn` 1
      query1 conn "SELECT v, DATALENGTH(v) FROM #bulk_unicode" `shouldReturn` ("😀𝄞" :: Text, 8 :: Int32)
