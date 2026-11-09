{-# LANGUAGE MagicHash #-}
{-# LANGUAGE UnboxedTuples #-}

-- | Regression tests from an adversarial review of the client layer
-- (Hmssql.Connection*, Query, Decoding, Encoding, Transaction).
module Review.ClientSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (forM_, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as BI
import qualified Data.ByteString.Lazy as LB
import Data.Decimal (Decimal)
import Data.Text (Text)
import GHC.Exts (Int (I#), getSizeofMutableByteArray#)
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.IO (IO (..))
import GHC.Exts.Heap (GenClosure (..), getClosureData)
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Connection (reset)
import Hmssql.Query
import Hmssql.Transaction
import Hmssql.Decoding
import Hmssql.SqlValue
import Hmssql.Types
import Hmssql.Tds.Client (encryptionWord)
import Hmssql.Tds.Token (ReturnValue (..))
import MockServer
import TestDb

-- | The size of the buffer a strict ByteString is a slice of, when it is a
-- GHC heap buffer.
bufferSize :: B.ByteString -> IO (Maybe Int)
bufferSize bs = case BI.toForeignPtr0 bs of
  (ForeignPtr _ contents, _) -> case contents of
    PlainPtr mba -> Just <$> IO (\s -> case getSizeofMutableByteArray# mba s of (# s', n #) -> (# s', I# n #))
    MallocPtr mba _ -> Just <$> IO (\s -> case getSizeofMutableByteArray# mba s of (# s', n #) -> (# s', I# n #))
    _ -> pure Nothing

-- | The value owns its buffer (isn't a slice of a packet).
shouldOwnBuffer :: B.ByteString -> Expectation
shouldOwnBuffer bs = do
  size <- bufferSize bs
  -- Pinned allocations are rounded up to a word.
  size `shouldSatisfy` maybe True (\n -> n < B.length bs + 8)

noSetup, withSetup :: IO ConnectInfo
noSetup = (\ci -> ci { connectSessionSetup = [] }) <$> defaultTestConnectInfo
-- | Whatever @HMSSQL_TEST_SESSION_SETUP@ says, a session setup: a reset sends a setup
-- batch before the request.
withSetup = (\ci -> ci { connectSessionSetup = ["SET ARITHABORT ON"] }) <$> defaultTestConnectInfo

-- | The value is in weak head normal form.
shouldBeEvaluated :: a -> Expectation
shouldBeEvaluated a = getClosureData a >>= \case
  ThunkClosure{} -> expectationFailure "a thunk"
  APClosure{} -> expectationFailure "an AP thunk"
  SelectorClosure{} -> expectationFailure "a selector thunk"
  _ -> pure ()

spec :: Spec
spec = do
  describe "connect" $
    it "tries every address the host name resolves to" $
      -- The mock listens on 127.0.0.1 only; "localhost" may resolve to ::1
      -- first.
      withMockServer (cannedLoginServer defaultLoginResponse) $ \srv -> do
        r <- timeout 10_000_000 $ withConnection (mockConnectInfo srv) { connectHost = "localhost" } $ \conn ->
          execute conn "SELECT 1"
        r `shouldBe` Just 0

  describe "close" $
    it "stops a connection that was opened with asynchronous exceptions masked uninterruptibly" $ do
      ci <- defaultTestConnectInfo
      conn <- uninterruptibleMask_ (connect ci)
      r <- timeout 5_000_000 (close conn)
      r `shouldBe` Just ()

  describe "login failure" $
    it "lets timeout interrupt draining a failed login's response" $ do
      let err = ServerMessage 18456 1 14 "Login failed for user 'mockuser'." "mock" "" 1
          body = LB.toStrict (Put.runPut (errorToken err))
          -- A packet without EOM holding the ERROR, then nothing: the
          -- response never ends.
          header = B.pack [0x04, 0x00, 0, fromIntegral (8 + B.length body), 0, 0, 1, 0]
          handler mc = do
            _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
            _ <- expectLogin7 mc
            sendRaw mc (header <> body)
            threadDelay 5_000_000
      withMockServer handler $ \srv -> do
        r <- try (timeout 500_000 (connect (mockConnectInfo srv)))
        case r of
          Right Nothing -> pure ()
          Right (Just c) -> close c >> expectationFailure "connected"
          Left (e :: SomeException) -> expectationFailure ("timeout did not fire: " ++ show e)

  describe "transactions after reset" $ do
    forM_ [("without a session setup", noSetup), ("with a session setup", withSetup)] $ \(name, getCi) ->
      describe name $ do
        it "rollback of a transaction the pending reset will roll back" $ do
          ci <- getCi
          withConnection ci $ \conn -> do
            begin conn
            reset conn
            rollback conn
            inTransaction conn `shouldReturn` False
            query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)

        it "withTransaction after reset commits" $ do
          ci <- getCi
          withConnection ci $ \conn -> do
            reset conn
            withTransaction conn $ void $ execute conn "SELECT 1"
            inTransaction conn `shouldReturn` False

        -- withTransaction refuses to start whenever a transaction is
        -- active, reset pending or not; the reset stays pending.
        it "withTransaction after reset, inside a transaction begun by hand, refuses to start (TransactionAlreadyActive)" $ do
          ci <- getCi
          withConnection ci $ \conn -> do
            begin conn
            reset conn
            r <- try (withTransaction conn $ void $ execute conn "SELECT 1")
            case r of
              Left TransactionAlreadyActive -> pure ()
              other -> expectationFailure ("expected TransactionAlreadyActive, got " ++ either show (const "success") other)
            -- The next request carries the reset, which rolls the
            -- transaction begun by hand back.
            query1 conn "SELECT @@TRANCOUNT" `shouldReturn` Only (0 :: Int)
            inTransaction conn `shouldReturn` False

  describe "decoded values don't keep packet buffers alive" $ around withTestDb $ do
    it "ByteString" $ \conn -> do
      Only (bs :: B.ByteString) <- query1 conn "SELECT 0x0102"
      shouldOwnBuffer bs
    it "ByteString from varbinary(max)" $ \conn -> do
      Only (bs :: B.ByteString) <- query1 conn "SELECT CAST(0x0102 AS varbinary(max))"
      shouldOwnBuffer bs
    it "lazy ByteString" $ \conn -> do
      Only (bs :: LB.ByteString) <- query1 conn "SELECT 0x0102"
      mapM_ shouldOwnBuffer (LB.toChunks bs)
    it "RawValue" $ \conn -> do
      Only (RawValue bs) <- query1 conn "SELECT 0x0102"
      shouldOwnBuffer bs
    it "RawValue of a CLR UDT (hierarchyid)" $ \conn -> do
      Only (RawValue bs) <- query1 conn "SELECT CAST('/1/' AS hierarchyid)"
      B.length bs `shouldSatisfy` (> 0)
      shouldOwnBuffer bs
    it "SqlBinary in a SqlRow" $ \conn -> do
      [ResultSet _ [SqlRow _ [SqlBinary bs]]] <- queryMulti conn "SELECT 0x0102"
      shouldOwnBuffer bs
    it "output parameter values" $ \conn -> do
      let p = outParam "@b" (B.pack [1, 2])
      res <- callProcedure conn "sp_executesql"
        [ inParam "" ("SET @b = @b + 0x03" :: Text)
        , inParam "" ("@b varbinary(max) OUTPUT" :: Text)
        , p
        ]
      forM_ (procOutputValues res) $ \rv -> mapM_ shouldOwnBuffer (rvValue rv)

    -- A value left unevaluated would keep the packet it was decoded from.
    it "Text, Maybe Text, varchar Text and Decimal are evaluated" $ \conn -> do
      [(t, mt, vt, d)] <- query conn "SELECT N'abc', N'def', 'ghi', CAST(1.5 AS decimal(10,2))"
      shouldBeEvaluated (t :: Text)
      case mt of
        Just (t' :: Text) -> shouldBeEvaluated t'
        Nothing -> expectationFailure "NULL"
      shouldBeEvaluated (vt :: Text)
      shouldBeEvaluated (d :: Decimal)
    it "SqlValues are evaluated" $ \conn -> do
      [ResultSet _ [SqlRow _ vals]] <- queryMulti conn "SELECT N'abc', 'def', CAST(1.5 AS decimal(10,2)), 0x01"
      length vals `shouldBe` 4
      mapM_ shouldBeEvaluated vals
    it "output parameter values decode to evaluated values" $ \conn -> do
      let p = outParam "@t" ("x" :: Text)
      res <- callProcedure conn "sp_executesql"
        [ inParam "" ("SET @t = N'abc'" :: Text)
        , inParam "" ("@t nvarchar(max) OUTPUT" :: Text)
        , p
        ]
      [rv] <- pure (procOutputValues res)
      case decodeReturnValue rv of
        Right (t :: Text) -> shouldBeEvaluated t >> (t `shouldBe` "abc")
        Left e -> expectationFailure (show e)

