-- | Get adapters for scalar fixtures. Conversion is always performed by
-- the library's checked scalar read function, not a second value decoder.
module Wire.PrimitiveGet where
import Control.Monad (when)
import qualified Data.Binary.Get as Get
import Data.Binary.Get (Get)
import qualified Data.ByteString as B
import Data.Decimal (Decimal)
import Data.Text (Text)
import Data.Time
import Data.UUID.Types (UUID)
import Hmssql.Tds.Primitives

getWith :: Int -> ValueReader a -> Get a
getWith n r = do
  bs <- Get.getByteString n
  either fail pure (r bs)
{-# INLINE getWith #-}

getCheckScale :: String -> Scale -> Get ()
getCheckScale name s = mapM_ fail (scaleProblem name s)
{-# INLINE getCheckScale #-}

getMoney4 :: Get Money
getMoney4 = getWith 4 readMoney

getMoney8 :: Get Money
getMoney8 = getWith 8 readMoney

getDateTime4 :: Get LocalTime
getDateTime4 = getWith 4 (readDateTime4With localTimeOf)

getDateTime8 :: Get LocalTime
getDateTime8 = getWith 8 (readDateTime8With localTimeOf)

getDate :: Get Day
getDate = getWith 3 readDate

getTime :: Scale -> Get TimeOfDay
getTime scale = getCheckScale "time" scale >> getWith (timeLength scale) (readTime scale)

getDateTime2 :: Scale -> Get LocalTime
getDateTime2 scale = getCheckScale "datetime2" scale >> getWith (timeLength scale + 3) (readDateTime2 scale)

getDateTimeOffset :: Scale -> Get DateTimeOffset
getDateTimeOffset scale = do
  getCheckScale "datetimeoffset" scale
  getWith (timeLength scale + 5) (readDateTimeOffset scale)

getDecimal :: Precision -> Scale -> Int -> Get Decimal
getDecimal precision scale len = do
  when (len `notElem` [5, 9, 13, 17]) $ fail $ decimalLengthError len
  getWith len (readDecimal precision scale)

getGuid :: Get UUID
getGuid = getWith 16 readGuid

getCollation :: Get Collation
getCollation = (`collationAt` 0) <$> Get.getByteString 5

getBVarByte :: Get B.ByteString
getBVarByte = Get.getWord8 >>= Get.getByteString . fromIntegral

getBVarChar :: Get Text
getBVarChar = Get.getWord8 >>= getUcs2 . fromIntegral

getUsVarChar :: Get Text
getUsVarChar = Get.getWord16le >>= getUcs2 . fromIntegral

getUcs2 :: Int -> Get Text
getUcs2 chars = decodeUtf16LE <$> Get.getByteString (chars * 2)

decimalLengthError len = "decimal: invalid length " ++ show len ++ " (5, 9, 13 or 17 bytes)"
