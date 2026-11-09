-- | Server-side parsing of LOGIN7, the inverse of
-- 'Hmssql.Tds.Client.putLogin7', for the mock server and the round-trip
-- tests.  A client never parses LOGIN7, so this is not part of the library.
module Wire.Login7Parser
  ( getLogin7
  , deobfuscatePassword
  ) where

import Control.Monad (unless, when)
import Data.Binary.Get (Get)
import qualified Data.Binary.Get as Get
import Data.Bits (complement, shiftL, shiftR, xor, (.&.), (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Text.Printf (printf)

import Hmssql.Tds.Client (Feature (..), Login7 (..))
import Hmssql.Tds.Context (tdsVersionWord)
import Hmssql.Tds.Primitives (decodeUtf16LE)

-- | The length of LOGIN7's fixed part, up to the variable-length data.
login7FixedLength :: Int
login7FixedLength = 94

-- | Inverse of 'Hmssql.Tds.Client.obfuscatePassword'.
deobfuscatePassword :: B.ByteString -> B.ByteString
deobfuscatePassword = B.map $ \b0 -> let b = b0 `xor` 0xA5 in (b `shiftL` 4) .|. (b `shiftR` 4)

-- | Parse a LOGIN7 message body, as a server would.  The inverse of
-- 'Hmssql.Tds.Client.putLogin7' (the FeatureExt bit of 'l7OptionFlags3' is
-- reported through 'l7Features' only).  SSPI, AtchDBFile and ChangePassword
-- are ignored.
getLogin7 :: Get Login7
getLogin7 = do
  totalLength <- fromIntegral <$> Get.getWord32le
  unless (totalLength >= login7FixedLength) $ fail "getLogin7: length smaller than the fixed part"
  rest <- Get.getByteString (totalLength - 4)
  let whole = B.replicate 4 0 <> rest
      slice o n
        | o + n <= B.length whole = pure $ B.take n (B.drop o whole)
        | otherwise = fail "getLogin7: field extends past the end of the message"
      getOffLen = (,) <$> (fromIntegral <$> Get.getWord16le) <*> (fromIntegral <$> Get.getWord16le)
      str (o, n) = decodeUtf16LE <$> slice o (2 * n)
  (fixed, offLens) <- case Get.runGetOrFail (Get.skip 4 >> fixedPart getOffLen) (LB.fromStrict whole) of
    Right (_, _, r) -> pure r
    Left (_, _, err) -> fail $ "getLogin7: " ++ err
  let (versionWord, packetSize, progVer, pid, connId, f1, f2, tf, f3, tz, lcid, clientId) = fixed
      (host, user, pass, app, server, ext, lib, lang, db) = offLens
  version <- case [v | v <- [minBound .. maxBound], tdsVersionWord v == versionWord] of
    v : _ -> pure v
    [] -> fail $ "getLogin7: unknown TDS version 0x" ++ printf "%08x" versionWord
  features <-
    if f3 .&. 0x10 == 0
      then pure []
      else do
        extBytes <- slice (fst ext) (snd ext)
        unless (B.length extBytes == 4) $ fail "getLogin7: FeatureExt offset must be 4 bytes"
        let featureOffset = fromIntegral (Get.runGet Get.getWord32le (LB.fromStrict extBytes))
        when (featureOffset > B.length whole) $ fail "getLogin7: FeatureExt offset out of range"
        case Get.runGetOrFail getFeatures (LB.fromStrict (B.drop featureOffset whole)) of
          Right (_, _, fs) -> pure fs
          Left (_, _, err) -> fail $ "getLogin7: FeatureExt: " ++ err
  l7HostName <- str host
  l7UserName <- str user
  l7Password <- decodeUtf16LE . deobfuscatePassword <$> slice (fst pass) (2 * snd pass)
  l7AppName <- str app
  l7ServerName <- str server
  l7LibraryName <- str lib
  l7Language <- str lang
  l7Database <- str db
  pure Login7
    { l7Version = version
    , l7PacketSize = packetSize
    , l7ClientProgVer = progVer
    , l7ClientPid = pid
    , l7ConnectionId = connId
    , l7OptionFlags1 = f1
    , l7OptionFlags2 = f2
    , l7TypeFlags = tf
    , l7OptionFlags3 = f3 .&. complement 0x10
    , l7TimeZone = tz
    , l7Collation = lcid
    , l7ClientId = clientId
    , l7Features = features
    , ..
    }
  where
    fixedPart getOffLen = do
      versionWord <- Get.getWord32le
      packetSize <- Get.getWord32le
      progVer <- Get.getWord32le
      pid <- Get.getWord32le
      connId <- Get.getWord32le
      f1 <- Get.getWord8
      f2 <- Get.getWord8
      tf <- Get.getWord8
      f3 <- Get.getWord8
      tz <- Get.getInt32le
      lcid <- Get.getWord32le
      host <- getOffLen
      user <- getOffLen
      pass <- getOffLen
      app <- getOffLen
      server <- getOffLen
      ext <- getOffLen
      lib <- getOffLen
      lang <- getOffLen
      db <- getOffLen
      let offLens = (host, user, pass, app, server, ext, lib, lang, db)
      clientId <- Get.getByteString 6
      pure ((versionWord, packetSize, progVer, pid, connId, f1, f2, tf, f3, tz, lcid, clientId), offLens)

    getFeatures = Get.getWord8 >>= \case
      0xFF -> pure []
      fid -> do
        len <- Get.getWord32le
        dat <- Get.getByteString (fromIntegral len)
        (Feature fid dat :) <$> getFeatures
