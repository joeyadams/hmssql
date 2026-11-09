-- | Security review: a malicious or broken server can't make the client
-- buffer without bound while it waits for a message to end, and floods
-- of messages are not accumulated (mock server).
module Security.DosSpec (spec) where

import Control.Exception
import Control.Monad (forM_, replicateM_, void)
import qualified Data.Binary.Put as Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.Int (Int32)
import qualified Data.Text as T
import System.Timeout (timeout)
import Test.Hspec

import Hmssql
import Hmssql.Types
import Hmssql.Errors
import Hmssql.Tds.Client (Prelogin (..), PreloginOption (..), encryptionWord, putPrelogin)
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Token (tokenSizeLimit)
import MockServer
import Protocol.MockTokens (expectBroken, goodResponse, packet, trySync, within, withinSecs)

isProtocolError :: SomeException -> Bool
isProtocolError e = case fromException e of
  Just (ProtocolError _) -> True
  Nothing -> False

-- | The 'ProtocolError' of a token held past 'tokenSizeLimit'.
isTokenTooLong :: SomeException -> Bool
isTokenTooLong e = case fromException e of
  Just (ProtocolError msg) -> "unfinished after" `T.isInfixOf` T.pack msg
  Nothing -> False

-- | A full-size PRELOGIN-response packet without END_OF_MESSAGE.
continuationPacket :: B.ByteString
continuationPacket = case splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) (LB.replicate (4096 - 8 + 1) 0) of
  p : _ -> p
  [] -> error "no packets"

-- | The first bytes of a token, and a unit repeated after them for as
-- long as the mock sends: a token that never ends.
data Endless = Endless String B.ByteString B.ByteString

-- | Tokens whose length the bytes alone don't bound, each made to go on
-- for ever.
endlessTokens :: [Endless]
endlessTokens =
  [ Endless "FEATUREEXTACK with a feature of length 0xFFFFFFFF" (B.pack ([0xAE, 0x0A] ++ maxDword)) (B.singleton 0)
  , Endless "FEATUREEXTACK whose list of features never ends (no 0xFF)" (B.singleton 0xAE) (B.pack [0x01, 4, 0, 0, 0, 1, 2, 3, 4])
  , Endless "SESSIONSTATE of length 0xFFFFFFFF" (B.pack (0xE4 : maxDword)) (B.singleton 0)
  , Endless "FEDAUTHINFO of length 0xFFFFFFFF" (B.pack (0xEE : maxDword)) (B.singleton 0)
  , Endless "a Promote Transaction ENVCHANGE of length 0xFFFFFFFF" (B.pack ([0xE3, 1, 0, 15] ++ maxDword)) (B.singleton 0)
  , Endless "COLMETADATA of text columns whose table names have 255 parts of 65535 characters"
      -- 65534 columns: a user type, flags, TEXT of length 0x7FFFFFFF with
      -- a collation, and a table name of 255 parts.
      (B.pack ([0x81, 0xFE, 0xFF, 0, 0, 0, 0, 0, 0, 0x23, 0xFF, 0xFF, 0xFF, 0x7F, 9, 4, 0xD0, 0, 0x34, 255]))
      (B.pack [0xFF, 0xFF] <> B.replicate 131070 0x41)
  ]
  where
    maxDword = [0xFF, 0xFF, 0xFF, 0xFF]

-- | Send the token's first bytes and then its unit repeated, in packets
-- without END_OF_MESSAGE, until 4 MiB past 'tokenSizeLimit'; then wait for
-- the client to close.  A send the client's close cuts short is the
-- outcome expected.
sendEndless :: Endless -> MockConn -> IO ()
sendEndless (Endless _ prefix unit) mc = void $ try @SomeException $ do
  let total = tokenSizeLimit + 4 * 1024 * 1024
      -- Keep fixture construction proportional to its bytes, rather than
      -- allocating twenty million list nodes for a one-byte repeated unit.
      tile = B.concat (replicate (max 1 (4096 `div` B.length unit)) unit)
      body = B.take total (prefix <> B.concat (replicate (total `div` B.length tile + 1) tile))
      packets = map (packet False) (chunksOf 4088 body)
  mapM_ (sendRaw mc . B.concat) (groupsOf 64 packets)
  let loop = recvMessageMaybe mc >>= maybe (pure ()) (const loop)
  loop
  where
    chunksOf n bs
      | B.null bs = []
      | otherwise = let (a, b) = B.splitAt n bs in a : chunksOf n b
    groupsOf n xs = case splitAt n xs of
      ([], _) -> []
      (g, rest) -> g : groupsOf n rest

spec :: Spec
spec = do
  describe "a token other than a row that never ends" $ do
    forM_ endlessTokens $ \endless@(Endless name _ _) -> do
      it ("is refused with a ProtocolError in the login response: " ++ name) $
        withMockServer (\mc -> do
            _ <- respondPrelogin (preloginReply (encryptionWord EncryptNotSup)) mc
            _ <- expectLogin7 mc
            sendEndless endless mc) $ \srv -> do
          r <- withinSecs 30 (try (withConnection (mockConnectInfo srv) (\_ -> pure ())))
          case r of
            Right () -> expectationFailure "connected"
            Left e -> e `shouldSatisfy` isTokenTooLong

      it ("is refused with a ProtocolError in a response, and breaks the connection: " ++ name) $
        withMockServer (\mc -> do
            _ <- serveLogin defaultLoginResponse mc
            _ <- recvMessage mc
            sendEndless endless mc) $ \srv ->
          withConnection (mockConnectInfo srv) $ \conn -> do
            r <- withinSecs 30 (trySync (execute conn "endless"))
            either (`shouldSatisfy` isTokenTooLong) (\n -> expectationFailure ("returned " ++ show n)) r
            expectBroken conn

    it "is not refused at 4 MiB: a SESSIONSTATE that long is read, and the response with it" $ do
      let state = B.replicate (4 * 1024 * 1024) 0x5A
          sessionState = do
            Put.putWord8 0xE4
            Put.putWord32le (fromIntegral (B.length state))
            Put.putByteString state
      withMockServer (\mc -> do
          _ <- serveLogin defaultLoginResponse mc
          serveRequests (\_ _ -> pure (sessionState : goodResponse)) mc) $ \srv ->
        withConnection (mockConnectInfo srv) $ \conn -> do
          r <- within (query conn "SELECT 42")
          r `shouldBe` [Only (42 :: Int32)]

  describe "a PRELOGIN response that never ends" $
    it "is refused with a ProtocolError once it is longer than a PRELOGIN response can be" $ do
      withMockServer (\mc -> do
          _ <- recvMessage mc
          -- 64 MiB without END_OF_MESSAGE, then silence: a client that
          -- buffers until the message ends waits (and holds it all).
          replicateM_ (64 * 256) (sendRaw mc continuationPacket)
          _ <- recvMessageMaybe mc
          pure ()) $ \srv -> do
        r <- timeout 10_000_000 (try (withConnection (mockConnectInfo srv) (\_ -> pure ())))
        case r of
          Nothing -> expectationFailure "still waiting for the end of the PRELOGIN response"
          Just (Right ()) -> expectationFailure "connected"
          Just (Left e) -> e `shouldSatisfy` isProtocolError

  describe "a server that accepts the connection and says nothing" $
    it "keeps connect waiting (there is no connect timeout), but a timeout ends it and closes the socket" $
      withMockServer (\mc -> recvMessage mc >> recvMessageMaybe mc) $ \srv -> do
        r <- timeout 500_000 (connect (mockConnectInfo srv))
        case r of
          Just conn -> close conn >> expectationFailure "connected"
          Nothing -> pure ()
        -- The mock saw the client's PRELOGIN, then the end of the stream.
        fmap (fmap fst) <$> nextResult srv >>= \case
          Right Nothing -> pure ()
          other -> expectationFailure ("the mock saw " ++ either show show other)

  describe "an accepted PRELOGIN response" $
    it "may fill several packets" $
      withMockServer (\mc -> do
          _ <- recvMessage mc
          let Prelogin opts = preloginReply 2
              -- Pad the response with an unknown option of 20000 bytes.
              body = Put.runPut (putPrelogin (Prelogin (opts ++ [padding])))
          mapM_ (sendRaw mc) (splitIntoPackets defaultTdsContext PTTabularResult (PacketStatus 0) body)
          _ <- expectLogin7 mc
          sendTokens mc defaultLoginResponse
          serveRequests (\_ _ -> pure [doneToken 0 0]) mc) $ \srv ->
        withConnection (mockConnectInfo srv) (\_ -> pure ())

  describe "a flood of messages in one response" $
    it "keeps the first error and discards the rest" $
      withMockServer (\mc -> do
          _ <- serveLogin defaultLoginResponse mc
          serveRequests (\_ _ -> pure (map (errorToken . msg) [1 .. 100_000] ++ [doneToken 0x0002 0])) mc) $ \srv ->
        withConnection (mockConnectInfo srv) $ \conn -> do
          r <- try (execute conn "flood")
          case r of
            Left e -> sqlErrorMessage e `shouldBe` "error 1"
            Right n -> expectationFailure ("no error, " ++ show n ++ " rows")
  where
    padding = PLUnknown 0x42 (B.replicate 20000 0x5A)
    msg :: Int32 -> ServerMessage
    msg n = ServerMessage
      { msgNumber = 50000, msgState = 1, msgClass = 16, msgText = "error " <> T.pack (show n)
      , msgServer = "mock", msgProcedure = "", msgLine = 1 }
