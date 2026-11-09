-- | Names and values too long for the length prefix the wire format gives
-- them ([MS-TDS] 2.2.6.6 RPC Request: a parameter name is a B_VARCHAR, whose
-- length is one byte; a procedure name is a US_VARCHAR; a value's length
-- prefix is a BYTE, USHORT or LONG depending on its type, 2.2.5.2).
--
-- The encoder must refuse such a request instead of writing the length
-- modulo 256 (or 65536): a 300-character parameter name would otherwise go
-- out as a 44-character name followed by 512 bytes of the name that the
-- server reads as the parameter's status, type and value; a 65535-byte
-- value of a USHORT-length type would carry the NULL marker 0xFFFF as its
-- length.
module Wire.LengthLimitsSpec (spec) where

import RecipeParameters
import Control.Exception (ErrorCall, SomeException, evaluate, fromException, try)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Either (isRight)
import Data.Maybe (isJust)
import qualified Data.Text as T
import Test.Hspec

import Hmssql
import Hmssql.Query
import Hmssql.Encoding
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Primitives (putBVarChar, putUsVarChar)
import TestDb

-- | Force the encoding; 'Left' if it refused (with 'error').
encoded :: Put.Put -> IO (Either ErrorCall Int)
encoded p = try (evaluate (fromIntegral (LB.length (Put.runPut p))))

rpc :: RpcParam -> Put.Put
rpc p = putRpcRequest defaultTdsContext [RpcRequest procSpExecuteSql 0 [p]]

intParam :: T.Text -> RpcParam
intParam name = byteParam name 0 (TIIntN 4) (Just (B.pack [1, 0, 0, 0]))

-- | A name of @n@ UTF-16 code units, @\@@ included.
nameOf :: Int -> T.Text
nameOf n = "@" <> T.replicate (n - 1) "x"

isEncodeError :: SomeException -> Bool
isEncodeError e = isJust (fromException e :: Maybe EncodeError)

spec :: Spec
spec = do
  describe "encoding (pure)" $ do
    it "writes a parameter name of 255 UTF-16 code units, the most a B_VARCHAR holds" $
      (isRight <$> encoded (rpc (intParam (nameOf 255)))) `shouldReturn` True

    it "refuses a parameter name of 256 code units instead of wrapping its length byte to 0" $
      (isRight <$> encoded (rpc (intParam (nameOf 256)))) `shouldReturn` False

    it "counts code units, not characters: 128 non-BMP characters are 256 units" $
      (isRight <$> encoded (rpc (intParam ("@" <> T.replicate 128 "\x1F600")))) `shouldReturn` False

    it "refuses a USHORT-length value of 65535 bytes, whose length would read as NULL" $
      (isRight <$> encoded (rpc (byteParam "@v" 0 (TIBigVarBinary 8000) (Just (B.replicate 65535 0)))))
        `shouldReturn` False

    it "writes a USHORT-length value of 65534 bytes" $
      (isRight <$> encoded (rpc (byteParam "@v" 0 (TIBigVarBinary 8000) (Just (B.replicate 65534 0)))))
        `shouldReturn` True

    it "refuses a BYTE-length value of 256 bytes" $
      (isRight <$> encoded (rpc (byteParam "@v" 0 (TIDecimalN 38 0) (Just (B.replicate 256 1)))))
        `shouldReturn` False

    it "refuses a procedure name of 65535 code units, which is the procedure-ID marker" $
      (isRight <$> encoded (putRpcRequest defaultTdsContext [RpcRequest (RpcProcName (T.replicate 65535 "p")) 0 []]))
        `shouldReturn` False

    it "B_VARCHAR and US_VARCHAR refuse text longer than their length prefix" $ do
      (isRight <$> encoded (putBVarChar (T.replicate 256 "a"))) `shouldReturn` False
      (isRight <$> encoded (putUsVarChar (T.replicate 65536 "a"))) `shouldReturn` False
      (isRight <$> encoded (putBVarChar (T.replicate 255 "a"))) `shouldReturn` True

    describe "rpcParamProblem" $ do
      it "accepts a well-formed parameter" $
        rpcParamProblem (intParam "@x") `shouldBe` Nothing
      it "names a parameter name that is too long" $
        rpcParamProblem (intParam (nameOf 300)) `shouldSatisfy` isJust
      it "rejects an empty value of a BYTE-length type, which would be read as NULL" $
        rpcParamProblem (byteParam "@x" 0 (TIIntN 4) (Just B.empty)) `shouldSatisfy` isJust
      it "rejects a fixed-length value of the wrong length" $
        rpcParamProblem (byteParam "@x" 0 TIInt4 (Just (B.pack [1, 2]))) `shouldSatisfy` isJust
      it "rejects NULL for a type that can't carry it" $
        rpcParamProblem (byteParam "@x" 0 TIInt4 Nothing) `shouldSatisfy` isJust
      it "rejects an empty non-NULL sql_variant, which would be read as NULL" $
        rpcParamProblem (byteParam "@x" 0 (TISqlVariant 8016) (Just B.empty)) `shouldSatisfy` isJust

  describe "against the server" $ around withTestDb $ do
    it "a parameter name longer than 255 code units is an EncodeError, not a garbled request" $ \conn -> do
      let name = nameOf 300
      r <- try (query conn (mkQuery ("SELECT " <> name) (NamedParams [(name, SqlParam (1 :: Int))])) :: IO [Only Int])
      either (\e -> e `shouldSatisfy` isEncodeError) (\v -> expectationFailure ("accepted: " ++ show v)) r
      query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

    it "a 128-code-unit name still reaches the server, which reports its own limit" $ \conn -> do
      let name = nameOf 129
      r <- try (query conn (mkQuery ("SELECT " <> name) (NamedParams [(name, SqlParam (1 :: Int))])) :: IO [Only Int])
      case r of
        Left (e :: SomeException) | Just (SqlServerError _ _) <- fromException e -> pure ()
        other -> expectationFailure ("expected the server's error, got " ++ show other)
      query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

    it "callProcedure refuses a parameter name longer than 255 code units" $ \conn -> do
      _ <- execute conn "CREATE PROCEDURE #hmssql_wire_len @a int AS SELECT @a"
      let p = inParam (nameOf 300) (1 :: Int)
      r <- try (callProcedure conn "#hmssql_wire_len" [p])
      either (\e -> e `shouldSatisfy` isEncodeError) (\_ -> expectationFailure "accepted") r
      query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

    it "a RawParam value too long for its length prefix is an EncodeError" $ \conn -> do
      let v = RawParam (TIBigVarBinary 8000, Just (B.replicate 65535 7))
      r <- try (query conn (mkQuery "SELECT DATALENGTH(@p1)" (Only v)) :: IO [Only (Maybe Int)])
      either (\e -> e `shouldSatisfy` isEncodeError) (\x -> expectationFailure ("accepted: " ++ show x)) r
      query conn "SELECT 42" `shouldReturn` [Only (42 :: Int)]

    it "an empty RawParam value of a BYTE-length type is an EncodeError, not a NULL" $ \conn -> do
      r <- try (query conn (mkQuery "SELECT @p1" (Only (RawParam (TIIntN 4, Just B.empty)))) :: IO [Only (Maybe Int)])
      either (\e -> e `shouldSatisfy` isEncodeError) (\x -> expectationFailure ("accepted: " ++ show x)) r

    it "a valid nvarchar(max) parameter over 65535 bytes still works" $ \conn -> do
      let t = T.replicate 40000 "ab"
      query conn ("SELECT LEN(" <> param t <> ")") `shouldReturn` [Only (80000 :: Int)]
