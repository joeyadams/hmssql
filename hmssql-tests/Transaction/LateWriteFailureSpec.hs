{-# LANGUAGE DerivingStrategies #-}

module Transaction.LateWriteFailureSpec (spec) where

import Control.Exception (throwIO)
import Control.Monad (forM_, void, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List (sort)
import Data.Text (Text)
import qualified Streaming.Prelude as S
import Test.Hspec

import Hmssql
import Hmssql.Errors (sqlErrorNumber)
import Hmssql.Transaction
import TestDb

data Scope = Auto | Escape | Caught deriving stock (Eq, Show)

spec :: Spec
spec = forM_ [False, True] $ \streaming ->
    forM_ [Auto, Escape, Caught] $ \scope ->
        it ("observes OUTPUT rows and a later error independently of committed effects, streaming=" ++ show streaming ++ ", scope=" ++ show scope) $ fixture $ \ci writer table -> do
            exec writer "SET XACT_ABORT ON"
            seen <- newIORef []
            let statement = rawSql ("SET NOCOUNT ON; INSERT INTO " <> table <> "(v) OUTPUT inserted.v VALUES(20),(21); RAISERROR('late write failure',16,1); SELECT 99 AS later_result")
                action =
                    if streaming
                        then queryS writer statement >>= S.mapM_ (\(Only n) -> modifyIORef' seen (n :))
                        else void (query writer statement :: IO [Only Int32])
                lateError e = sqlErrorNumber e == 50000
            case scope of
                Auto -> action `shouldThrow` lateError
                Escape -> withTransaction writer action `shouldThrow` lateError
                Caught -> withTransaction writer $ do
                    action `shouldThrow` lateError
                    query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (1 :: Int32, 1 :: Int32)
                    write writer table 22
            when streaming $ (sort <$> readIORef seen) `shouldReturn` [20, 21 :: Int32]
            inTransaction writer `shouldReturn` False
            query1 writer "SELECT @@TRANCOUNT,XACT_STATE()" `shouldReturn` (0 :: Int32, 0 :: Int32)
            query1 writer "SELECT 42" `shouldReturn` Only (42 :: Int32)
            write writer table 30
            (withTransaction writer $ write writer table 40 >> throwIO (userError "subsequent independent rollback")) `shouldThrow` anyIOException
            let inside = case scope of Auto -> [20, 21]; Escape -> []; Caught -> [20, 21, 22]
            withConnection ci $ \observer -> query observer (rawSql ("SELECT v FROM " <> table <> " ORDER BY v")) `shouldReturn` map Only ([10] ++ inside ++ [30 :: Int32])

fixture :: (ConnectInfo -> Connection -> Text -> IO a) -> IO a
fixture action = do
    ci <- defaultTestConnectInfo
    withScratchSchema ci "late_write" $ \schema -> withConnection ci $ \writer -> do
        let table = schema <> ".target"
        exec writer ("CREATE TABLE " <> table <> "(v int PRIMARY KEY); INSERT INTO " <> table <> " VALUES(10)")
        action ci writer table
exec :: Connection -> Text -> IO ()
exec conn = void . execute conn . rawSql
write :: Connection -> Text -> Int32 -> IO ()
write conn table value = void $ execute conn (mkQuery ("INSERT INTO " <> table <> "(v) VALUES(@p1)") (Only value))
