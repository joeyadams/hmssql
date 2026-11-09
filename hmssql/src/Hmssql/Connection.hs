-- | Opening and closing connections.
--
-- A connection is for one thread at a time, with one request outstanding
-- at a time (unless it is a MARS connection, below).  Give each thread
-- its own, from a pool: 'release' returns a connection to the pool clean,
-- and 'renew' hands the next borrower a fresh handle.
-- "Hmssql.Connection#g:pools" has a recipe for resource-pool.
--
-- = MARS: several responses open at once #mars#
--
-- With 'connectMars', a connection can have several responses open at
-- once (SQL Server's Multiple Active Result Sets): a request made while a
-- 'Hmssql.Query.queryS' stream is being read leaves the stream open,
-- where without MARS it abandons it.  Nothing else in the API changes.
-- Each request quietly takes a session of the connection and gives it
-- back when its response has been read to the end or canceled;
-- 'connectionMars' says whether a connection negotiated MARS.
--
-- > withQueryS conn "SELECT id, name FROM dbo.parent" $ \parents ->
-- >   S.mapM_ (\(pid, name) -> do
-- >       children <- query conn ("SELECT name FROM dbo.child WHERE parent_id = " <> param (pid :: Int))
-- >       report name children) parents
--
-- These rules come with it:
--
-- * Open streams with 'Hmssql.Query.withQueryS', which cancels a stream
--   its action didn't finish.  An open stream holds a session and its
--   statement's locks, so every stream needs an end.  A plain
--   'Hmssql.Query.queryS' stream stays open until it is read to its end or
--   until 'Hmssql.Query.cancelResponse', 'cancelActiveStatement' or
--   'release' cancels it.
--
-- * Begin a transaction first and open the streams inside it, then finish
--   or cancel every one before the body returns.  SQL Server refuses to
--   begin or commit a transaction beside an unfinished request, and a
--   refused commit loses the transaction, so hmssql checks first and throws
--   'Hmssql.Transaction.TransactionRequestsActive'.  A stream has finished
--   when it has returned, so having seen its last row isn't enough.
--
--   > withTransaction conn $
--   >   withQueryS conn "SELECT id, price FROM dbo.product WHERE category = 'tea'" $ \products ->
--   >     flip S.mapM_ products $ \(pid :: Int, price :: Decimal) ->
--   >       execute conn (mkQuery "UPDATE dbo.product SET price = @p1 WHERE id = @p2" (price * 1.1, pid))
--
-- * Write to a table under an open stream only inside a transaction, or
--   with @READ_COMMITTED_SNAPSHOT@ on the database.  Otherwise the write
--   waits for the locks of the open scan, which can't be released while your
--   thread waits, and it ends as a deadlock victim (error 1205), at the lock
--   timeout (error 1222), or never.  Set a lock timeout in
--   'connectSessionSetup', so that this mistake is an error rather than a
--   hang.  Reads beside a stream, and writes to other tables, need nothing.
--
-- * Change session settings (@SET@, @USE@) with no stream open, or in
--   'connectSessionSetup'.  SQL Server undoes a change made beside a
--   running stream when that stream ends, which includes the isolation
--   level and @XACT_ABORT@.  'Hmssql.Transaction.withTransactionLevel',
--   @#temp@ tables and @SESSION_CONTEXT@ are safe.
--
-- * Read a stream to its end where a transaction must survive under
--   @SET XACT_ABORT ON@.  Canceling a statement that is still running can
--   roll the transaction back
--   ('Hmssql.Transaction.TransactionEndedEarly').
--
-- * MARS interleaves; it doesn't run statements side by side, and the
--   connection is still for one thread at a time.
--
-- * Large parameters and bulk loads belong on a connection of their own.
--
-- * On Azure SQL Database, count open streams as requests, because the
--   Basic tier allows 30 at once.  Under load, a cancel right behind its
--   request can occasionally end the connection, and a pool replaces it.
--
-- A transaction at @Snapshot@ isolation gives every stream in it the same
-- snapshot, taken at the transaction's first read of a table.  That keeps
-- several streams consistent while other connections write, and it needs
-- @ALLOW_SNAPSHOT_ISOLATION@ on the database.
module Hmssql.Connection
  ( -- * Connecting
    Connection
  , ConnectInfo (..)
  , defaultConnectInfo
  , Protocol (..)
  , defaultSessionSetup
  , withConnection
  , connect
  , close

    -- * Returning a connection to a pool #pools#
    -- | Give each thread its own connection from a pool.  With the @resource-pool@
    -- package, take a connection out with 'renew', and give it back with 'release'
    -- whether your action returned or threw.  A connection the server ended while it
    -- sat in the pool is refused by 'renew', so it is destroyed and the next one taken:
    --
    -- > import Control.Concurrent (forkIO)
    -- > import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, onException, throwIO, try)
    -- > import Control.Monad (void)
    -- > import Data.Maybe (fromMaybe)
    -- > import Data.Pool
    -- > import System.Timeout (timeout)
    -- >
    -- > withPooled :: Pool Connection -> (Connection -> IO a) -> IO a
    -- > withPooled pool act = mask $ \restore -> do
    -- >   (conn, local) <- borrow
    -- >   restore (act conn) `finally` giveBack local conn
    -- >   where
    -- >     borrow = do
    -- >       (conn0, local) <- takeResource pool
    -- >       try (renew conn0) >>= \case
    -- >         Right conn -> pure (conn, local)
    -- >         Left (e :: SomeException)
    -- >           | Just (_ :: SomeAsyncException) <- fromException e -> putResource local conn0 >> throwIO e
    -- >           | otherwise -> close conn0 >> destroyResource pool local conn0 >> borrow
    -- >     giveBack local conn = void $ forkIO $ do
    -- >       let discard = close conn >> destroyResource pool local conn
    -- >       ok <- fromMaybe False <$> timeout 5000000 (release conn) `onException` discard
    -- >       if ok then putResource local conn else discard
    --
    -- This is used rather than @withResource@ because an exception from your code, such
    -- as a 'System.Timeout.timeout' or a client hanging up, usually leaves the connection
    -- fine.  'release' keeps such a connection, where @withResource@ would destroy it and
    -- pay for a new login.
    --
    -- 'release' runs on a thread of its own because canceling a stream is a round trip,
    -- which the caller shouldn't wait for.  The 'System.Timeout.timeout' bounds it.  A
    -- 'release' that times out leaves a broken connection, so 'Nothing' counts as 'False'.
  , release
  , renew
  , unusableReason
  , cancelActiveStatement
  , reset

    -- * Encryption
  , Encryption (..)
  , TlsSettings (..)
  , defaultTlsSettings

    -- * The negotiated protocol state
  , connectionContext
  , connectionMars
  , TdsContext (..)
  , TdsVersion (..)
  ) where

import Control.Concurrent.STM (readTVarIO)
import Control.Applicative ((<|>))
import Control.Exception
import Control.Monad (forM_, unless, when)
import qualified Data.Binary.Get as Get
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as LB
import Data.IORef
import Data.List (intercalate)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32, Word8)
import GHC.IO.Exception (IOException (..))
import Network.HostName (getHostName)
import qualified Network.TLS as TLS
import Text.Printf (printf)

import Hmssql.Connection.Backend
import Hmssql.Connection.Internal
import Hmssql.Connection.Tls
import Hmssql.Errors
import Hmssql.Tds.Client
import Hmssql.Tds.Context
import Hmssql.Tds.Packet
import Hmssql.Tds.Token

-- | How to connect.  Start from 'defaultConnectInfo' and change the fields
-- that differ.  Textual settings are 'Text', the host, port and instance
-- included.
--
-- __Azure SQL Database__ accepts both the default 'EncryptOn', which is
-- TDS 7.4, and 'EncryptStrict', which is TDS 8.0.  The server name in the
-- login defaults to 'connectHost'.  Under Azure's Default connection
-- policy, a connection from inside Azure through the public endpoint is
-- redirected to the node that hosts the database, on a port from 11000 to
-- 11999, and 'connect' follows the redirect, so those outbound ports must
-- be open.
--
-- > azure = defaultConnectInfo
-- >   { connectHost = "myserver.database.windows.net"
-- >   , connectUser = "your_login"
-- >   , connectPassword = "..."
-- >   , connectDatabase = "your_database"
-- >   }
--
-- To log in with Entra ID instead of a SQL login, put an access token in
-- 'connectAccessToken' and leave the user and password empty.
data ConnectInfo = ConnectInfo
  { connectHost :: !Text
    -- ^ A host name or an IP address.  A name that resolves to several
    -- addresses is tried in the resolver's order until one accepts.  An
    -- address that hasn't answered within 4 seconds is given up and the
    -- next is tried; the last one waits as long as the operating system
    -- allows.  Whatever the protocol, this is also the name the server's
    -- certificate is checked against.
  , connectPort :: !Text
    -- ^ A port number, or a service name.  Used over TCP only.
  , connectProtocol :: !Protocol
    -- ^ What the connection travels on.  The default, 'ProtocolAuto', is
    -- TCP everywhere but on Windows, where it does what Microsoft's
    -- clients do, so that a SQL Server on the same machine is reached
    -- even with TCP\/IP turned off, as it is after a default
    -- installation of some editions.
  , connectInstance :: !Text
    -- ^ The name of a named instance, for 'ProtocolSharedMemory' and
    -- 'ProtocolNamedPipes', which find an instance by its name; empty for
    -- the default instance.  TCP ignores it: a named instance is reached
    -- by its port (hmssql doesn't ask the SQL Server Browser).
  , connectUser :: !Text
    -- ^ The SQL Server login.  (Windows authentication is not supported;
    -- Entra ID is, through 'connectAccessToken'.)
  , connectPassword :: !Text
  , connectAccessToken :: !(Maybe Text)
    -- ^ An Entra ID access token, used in place of 'connectUser' and
    -- 'connectPassword', which must then be empty, or 'connect' throws
    -- 'EncodeError'.  Obtaining the token is the caller's job.  It is what
    -- Azure Managed Identity's endpoint, a service principal's credentials
    -- or @az account get-access-token@ return for the audience
    -- @https:\/\/database.windows.net\/@, passed as it comes: hmssql sends
    -- it in the login, as SqlClient's @AccessToken@ does, and never parses
    -- it.
    --
    -- The server checks the token at login only, so a connection outlives
    -- its token's expiry.  A pool should get a fresh token before each
    -- 'connect'; the managed identity endpoint caches them.  With
    -- 'EncryptOff' or 'EncryptNotSup' the token would travel in plaintext,
    -- like a password, but Azure SQL requires encryption anyway.
  , connectDatabase :: !Text
    -- ^ The database to open in; empty for the login's default.
  , connectEncryption :: !Encryption
    -- ^ The default, 'EncryptOn', encrypts the whole session and refuses a
    -- server that can't.  'EncryptStrict' selects TDS 8.0, where TLS starts
    -- before the first byte of TDS; the other modes negotiate TLS in
    -- PRELOGIN, under TDS 7.4.
  , connectTls :: !TlsSettings
    -- ^ How the server's certificate is validated: against the system
    -- store by default.  A local server with a self-signed certificate
    -- needs 'tlsTrustServerCertificate', or its certificate in
    -- 'tlsCaCertificateFiles'.
  , connectApplicationName :: !Text
    -- ^ What the session shows as @program_name@ in
    -- @sys.dm_exec_sessions@.
  , connectServerName :: !Text
    -- ^ The server name sent in the login.  Empty, the default, sends
    -- 'connectHost' as it is, a fully qualified Azure SQL host name
    -- included.  Set it when a tunnel or an alias gives the server a
    -- different network address from its logical name.  A login redirect
    -- replaces it with the destination the server names.
  , connectLanguage :: !Text
    -- ^ The session's language (@SET LANGUAGE@), which sets the date
    -- format and the language of the server's messages; empty for the
    -- login's default.
  , connectPacketSize :: !Word32
    -- ^ The packet size to ask for, header included: 8000 by default, as
    -- SqlClient's.  Values outside 512 to 32767 are clamped to that
    -- range.  The server may grant less than asked, and
    -- 'connectionContext' has the negotiated size.  With 'connectMars'
    -- over TLS, at most 16368 is asked for, because a packet and the 16
    -- bytes MARS adds to it must fit in one TLS record.
  , connectReadOnlyIntent :: !Bool
    -- ^ Declare the connection read-only in the login (what
    -- @ApplicationIntent=ReadOnly@ does in other drivers), so that an
    -- Availability Group listener routes it to a readable secondary.  A
    -- standalone server ignores it.
  , connectSessionSetup :: ![Text]
    -- ^ Statements run after login, joined with newlines into one batch,
    -- and run again as one batch after each 'reset', which includes each
    -- 'release'.  With an empty list, 'reset' costs no round trip of its
    -- own.  See 'defaultSessionSetup' for what the login already sets.
  , connectMars :: !Bool
    -- ^ Multiple Active Result Sets: several responses can be open on the
    -- connection at once, each request on a session of its own, as
    -- SqlClient's @MultipleActiveResultSets=True@ does.  Off by default,
    -- so a new request abandons a response that is still open
    -- ('Hmssql.Errors.ResultAbandoned').  "Hmssql.Connection#mars" has the
    -- rules.  'connect' throws 'MarsNotSupported' if the server doesn't
    -- support MARS.
  , connectMarsWindow :: !Int
    -- ^ With 'connectMars': how many packets the server may send ahead of
    -- what has been read, on each open response; at least 4.  It bounds
    -- what a response nobody is reading keeps in memory (the window times
    -- the packet size) and, over a long round trip, how fast one stream
    -- can be read.  The default, 64, kept up with a plain connection over
    -- a 45 ms round trip.
  , connectPinReader :: !Bool
    -- ^ Pin the connection's reader thread to the capability of the
    -- thread that calls 'connect', instead of leaving it unbound (the
    -- default).  When that thread is the one that makes the requests, a
    -- local round trip with @+RTS -N@ on many cores is 30 to 40% faster;
    -- but every connection a pool opens from one thread then has its
    -- reader on that one capability.
  , connectValueAllocAhead :: !Int
    -- ^ How much buffer a large value, such as a row longer than 64 KiB or
    -- an output parameter, may be allocated before its bytes arrive.  A
    -- value declared at most this long gets its whole buffer as it starts
    -- arriving, and a longer one grows as it arrives.  The limit bounds
    -- what a server that declares a value it doesn't send can make the
    -- client allocate.  1 MiB by default, and 0 allocates nothing ahead.
  , connectOnInfoMessage :: !(ServerMessage -> IO ())
    -- ^ Called for every INFO token (PRINT output, low-severity messages),
    -- on the thread reading the response, while it holds the connection.  It
    -- must not use the connection (that throws 'ReentrantCallback') or wait
    -- for another thread that does (that deadlocks).  An exception it throws
    -- propagates to the reader; the connection stays usable.
  }

-- | What a connection travels on ('connectProtocol').
--
-- Shared Memory and Named Pipes exist on Windows only; asking for one
-- elsewhere makes 'connect' throw.  Both carry the same bytes as TCP, so
-- encryption, logins and everything after work the same.  On Windows
-- under GHC's native I/O manager (@+RTS --io-manager=native@), TCP goes
-- through network's own calls and the pipes through the manager when
-- hmssql was built against network 3.3 or later with a GHC whose native
-- manager network supports, with or without @-threaded@.  Without
-- @-threaded@, network's blocking calls (the lookup, the connect, and a
-- send once the server stops reading) and the open of a pipe stop every
-- Haskell thread while they block.  A build that can't use the native
-- manager needs @-threaded@ to run under it.
data Protocol
  = ProtocolAuto
    -- ^ On Windows: Shared Memory if 'connectHost' is this machine
    -- (@localhost@, @.@, @(local)@ or the machine's name), then TCP, then
    -- Named Pipes, the order Microsoft's clients use.  The next is tried
    -- only when one can't be opened; a server that was reached and then
    -- refused the TLS handshake or the login is not tried another way.
    -- Elsewhere: TCP.
    --
    -- A 'connectPort' other than the default, 1433, means TCP and nothing
    -- else, on Windows too: the port names one server, and a pipe might
    -- lead to another.  With a 'connectInstance' and the default port,
    -- only the pipes are tried, since TCP would need the instance's port.
  | ProtocolTcp
    -- ^ TCP, to 'connectHost' and 'connectPort'.
  | ProtocolSharedMemory
    -- ^ Shared Memory: a SQL Server on this machine, whatever
    -- 'connectHost' says.
  | ProtocolNamedPipes
    -- ^ Named Pipes, at the pipe SQL Server listens on by default.  On
    -- another machine the pipe is reached over SMB, so Windows first
    -- authenticates the user running the program to that machine.
  | ProtocolCustom (IO Backend)
    -- ^ A byte stream of the caller's making
    -- ("Hmssql.Connection.Backend"): the action connects and returns it,
    -- and 'connect' closes it when the login fails or the connection is
    -- closed.  It runs with asynchronous exceptions masked, and should
    -- close what it opened if it is interrupted.  A login redirect is
    -- still followed over TCP.

-- | The defaults, which the example at the top of "Hmssql" starts from:
--
-- * @localhost@ on port 1433, over 'ProtocolAuto', to the default
--   instance.
-- * No user, password, access token or database.
-- * 'EncryptOn' with 'defaultTlsSettings': the whole session is encrypted,
--   and the server's certificate is validated against the system store.
-- * 8000-byte packets, no session setup and no MARS.
defaultConnectInfo :: ConnectInfo
defaultConnectInfo = ConnectInfo
  { connectHost = "localhost"
  , connectPort = "1433"
  , connectProtocol = ProtocolAuto
  , connectInstance = ""
  , connectUser = ""
  , connectPassword = ""
  , connectAccessToken = Nothing
  , connectDatabase = ""
  , connectEncryption = EncryptOn
  , connectTls = defaultTlsSettings
  , connectApplicationName = "hmssql"
  , connectServerName = ""
  , connectLanguage = ""
  , connectPacketSize = 8000
  , connectReadOnlyIntent = False
  , connectSessionSetup = defaultSessionSetup
  , connectMars = False
  , connectMarsWindow = 64
  , connectPinReader = False
  , connectValueAllocAhead = lobAllocAhead
  , connectOnInfoMessage = \_ -> pure ()
  }

-- | The default session setup: none.  The login already sets what
-- Microsoft's drivers set (the ANSI options on, @IMPLICIT_TRANSACTIONS@
-- off, @TEXTSIZE@ unlimited).  The one option they leave off and SQL
-- Server Management Studio turns on is @ARITHABORT@, which only matters
-- as a plan-cache key; to share plans with SSMS, opt in:
--
-- @
-- 'defaultConnectInfo' { 'connectSessionSetup' = [\"SET ARITHABORT ON\"] }
-- @
defaultSessionSetup :: [Text]
defaultSessionSetup = []

-- | Open a connection with 'connect', run the action with it, and 'close'
-- it afterward, whether the action returns or throws.
withConnection :: ConnectInfo -> (Connection -> IO a) -> IO a
withConnection ci = bracket (connect ci) close

-- | Open a connection and log in.
--
-- If the server can't be reached, this throws @'ConnectionClosedBy'
-- ('TransportFailed' e)@ with the underlying 'IOException'.  When
-- 'ProtocolAuto' tried several protocols, the exception says why each one
-- failed.  There is no built-in connect timeout, so wrap the call in
-- 'System.Timeout.timeout' where one is needed.  A host with several
-- addresses gives each but the last 4 seconds to answer before the next
-- is tried, so a 'System.Timeout.timeout' of 15 seconds still reaches a
-- working address behind a silent one.
--
-- A login the server redirects, as Azure SQL does from inside Azure and
-- an availability group listener does, is sent again to the host and
-- port named, over TCP and with the same settings otherwise, up to ten
-- times in a row.  The eleventh redirect throws 'LoginRedirected', and so
-- does a redirect received in plaintext under 'EncryptOff'.
connect :: ConnectInfo -> IO Connection
connect ci = do
  forM_ (connectAccessToken ci) $ \token -> do
    when (T.null token) $
      throwIO $ EncodeError "connectAccessToken is set but empty"
    unless (T.null (connectUser ci) && T.null (connectPassword ci)) $
      throwIO $ EncodeError
        "connectAccessToken is set along with connectUser or connectPassword; an access token replaces them"
  -- One mask around all the logins, as the last thing 'connect' does: the
  -- connection is returned masked, so an asynchronous exception can't land
  -- between its login and the caller's hands.
  mask $ \restore ->
    let go :: Int -> ConnectInfo -> IO Connection
        go redirects target = connectWith restore target >>= \case
          Right conn -> pure conn
          Left routing@RoutingInfo{..}
            | redirects >= maxRedirects ->
                throwIO LoginRedirected { redirectServer = routingServer, redirectPort = routingPort }
            | otherwise -> redirectedTo routing >>= go (redirects + 1)
    in go 0 ci
  where
    -- Every hop starts from the caller's settings, as MS-TDS asks (nothing
    -- from a login that was redirected applies to the next).  The server
    -- may name an instance (host\instance); the port is what reaches it.
    -- The server name in the login becomes the target's, as SqlClient
    -- sends it (host,port): Azure's node takes the logical server from it,
    -- as its gateway did from 'connectServerName', and refuses the
    -- gateway's value with error 40613 ("Database ... on server '' is not
    -- currently available").
    redirectedTo RoutingInfo{..} = do
      let host = T.takeWhile (/= '\\') routingServer
          refuse why = throwIO $ ProtocolError $
            "the login was redirected to " ++ show routingServer ++ ", port " ++ show routingPort ++ ", " ++ why
      unless (routingProtocol == 0) $
        refuse ("with protocol " ++ show routingProtocol ++ ", not TCP")
      when (T.null host) $ refuse "which names no host"
      when (routingPort == 0) $ refuse "which is not a port"
      pure ci { connectHost = host
              , connectPort = T.pack (show routingPort)
              , connectProtocol = ProtocolTcp
              , connectServerName = routingServer <> "," <> T.pack (show routingPort) }

-- | How many login redirects 'connect' follows, one after another: the
-- limit SqlClient sets (which, counting from zero, follows 11).  No known
-- server chains redirects at all (Azure SQL's gateway redirects to the
-- database's node, an availability group listener to a replica); the limit
-- stops a loop.
maxRedirects :: Int
maxRedirects = 10

-- | Connect and log in; or, if the server redirects the login, close the
-- connection and say where to.  Called masked, with the caller's @restore@.
connectWith :: (forall a. IO a -> IO a) -> ConnectInfo -> IO (Either RoutingInfo Connection)
connectWith restore ci = do
  -- Masked from the moment the backend exists until the cleanup for the
  -- rest is installed, so an async exception (a 'System.Timeout.timeout') can't land in
  -- between and leave the socket for the garbage collector to close (or a
  -- pipe open for good); the lookup, the connect and everything after run
  -- with the caller's masking state.
  backend <- openBackend restore ci `catch` \(e :: IOException) ->
    throwIO (ConnectionClosedBy (TransportFailed (toException e)))
  result <- flip onException (backendClose backend) $ restore $ do
    -- Packets are 4096 bytes until the server grants the requested size
    -- (an ENVCHANGE in the login response); a LOGIN7 carrying an access
    -- token is longer than that, and Azure SQL resets a connection that
    -- sends it as one larger packet.
    let ctx0 = defaultTdsContext
    conn <- (\c -> c { connSessionSetup = connectSessionSetup ci, connPinReader = connectPinReader ci
                     , connValueAllocAhead = max 0 (connectValueAllocAhead ci) })
      <$> newConnection backend ctx0 (connectOnInfoMessage ci)
    routed <- case connectEncryption ci of
      EncryptStrict -> do
        strictTlsHandshake conn (connectTls ci) (T.unpack (connectHost ci))
        -- MS-TDS has a PRELOGIN inside the TLS session too, whose
        -- encryption value the server ignores.  SQL Server accepts LOGIN7
        -- without it, so it is sent only when the login needs the
        -- server's FEDAUTHREQUIRED answer, to echo it.
        -- The server takes the MARS option from it too.
        answer <- if usesToken || mars then prelogin conn EncryptOn usesToken mars else pure noPreloginAnswer
        login conn Tds80 answer (pure ())
      requested -> do
        answer <- prelogin conn requested usesToken mars
        serverEnc <- case plaEncryption answer of
          Nothing -> throwIO $ ProtocolError "PRELOGIN response lacks the ENCRYPTION option"
          Just w -> case encryptionFromWord w of
            -- ENCRYPT_STRICT is never a valid answer in TDS 7.x.
            Just e | e /= EncryptStrict -> pure e
            _ -> throwIO $ ProtocolError $
              "PRELOGIN response has an invalid ENCRYPTION value " ++ show w
        mode <- negotiateEncryption requested serverEnc
        when (mode /= NoEncryption) $
          hostedTlsHandshake conn (connectTls ci) (T.unpack (connectHost ci))
        -- With ENCRYPT_OFF only the LOGIN7 packet itself is encrypted; the
        -- server's response is already plaintext.
        routed <- login conn Tds74 answer $ when (mode == LoginOnly) $
          writeIORef (connTransport conn) (TransportPlain backend)
        -- Nor is a redirect in it, then: anyone on the path could have
        -- written it, to have the login, sent encrypted to this server,
        -- sent again to a host of their choosing.
        case routed of
          Just RoutingInfo{..} | mode == LoginOnly ->
            throwIO LoginRedirected { redirectServer = routingServer, redirectPort = routingPort }
          _ -> pure routed
    case routed of
      Just routing -> pure (Left routing)
      Nothing -> do
        -- On a MARS connection SMP starts here, after the login in plain
        -- TDS (SQL Server drops a connection whose LOGIN7 comes as SMP,
        -- and one that sends anything but SMP after it): the SYN for
        -- session 0, which the server doesn't answer.  The session setup
        -- then needs the reader thread (below).
        if mars
          then Right <$> enableMars conn (connectMarsWindow ci)
          else do
            unless (null setup) $ runPlainBatch conn (T.intercalate "\n" setup)
            pure (Right conn)
  case result of
    -- Redirected: nothing more is said to this server (no reader was
    -- started).
    Left routing -> do
      backendClose backend
      pure (Left routing)
    -- Outside the cleanup above, which closes the backend without stopping
    -- the reader: a reader still running might start to wait on the
    -- descriptor just after the close (see 'closeConnection').  Masked, and
    -- nothing in it is interruptible, so no exception can arrive between
    -- starting the reader and returning the connection, whose finalizer
    -- stops the reader and closes the backend if the caller drops it.
    Right conn -> do
      startReader conn
      -- From here the cleanup is 'close', which stops the reader first.
      when (mars && not (null setup)) $
        restore (runPlainBatch conn (T.intercalate "\n" setup)) `onException` close conn
      pure (Right conn)
  where
    setup = connectSessionSetup ci
    -- On an encrypted MARS connection a packet and its SMP header must
    -- fit one TLS record (16384 bytes): SQL Server 2025 grants packets of
    -- up to 16384 bytes over TLS, and then drops the connection at the
    -- first response, which it can't send that way.
    packetSize
      | mars && connectEncryption ci /= EncryptNotSup = min 16368 (clampPacketSize (connectPacketSize ci))
      | otherwise = clampPacketSize (connectPacketSize ci)
    usesToken = isJust (connectAccessToken ci)
    mars = connectMars ci

    login :: Connection -> TdsVersion -> PreloginAnswer -> IO () -> IO (Maybe RoutingInfo)
    login conn version answer afterSend = do
      hostName <- getHostName
      let l7 = defaultLogin7
            { l7Version = version
            , l7PacketSize = packetSize
            , l7HostName = T.pack hostName
            , l7UserName = connectUser ci
            , l7Password = connectPassword ci
            , l7AppName = connectApplicationName ci
            , l7ServerName = if T.null (connectServerName ci)
                then connectHost ci
                else connectServerName ci
            , l7Language = connectLanguage ci
            , l7Database = connectDatabase ci
            , l7TypeFlags = if connectReadOnlyIntent ci then 0x20 else 0
            , l7Features = l7Features defaultLogin7
                ++ [ featureFedAuthToken (plaFedAuthRequired answer) token (plaNonce answer)
                   | Just token <- [connectAccessToken ci] ]
            }
      mapM_ (throwIO . EncodeError) (login7Problem l7)
      ar <- startRequest conn PTLogin7 (\_ -> runBody (putLogin7 l7))
      afterSend
      readLoginResponse conn ar

-- | Reset the session before the next request.  A pool should call
-- 'release' instead, which does this and more.
--
-- Nothing is sent now: the next request carries the RESETCONNECTION bit,
-- which does what @sp_reset_connection@ does without a round trip of its
-- own.  The server returns the session to its state right after login: an
-- open transaction is rolled back, @#temp@ tables and cursors are
-- dropped, and @SET@ options revert.  The session setup
-- ('connectSessionSetup') then runs again; with a non-empty setup, one
-- batch carrying the reset and the setup precedes the next request.
--
-- The reset happens once, however often 'reset' is called before the
-- next request.  On a MARS connection every open response is canceled
-- first, as 'cancelActiveStatement' does.  Calling it inside
-- 'Hmssql.Transaction.withTransaction' is unsupported: the reset rolls
-- the transaction back, and 'Hmssql.Transaction.withTransaction' ends with
-- 'Hmssql.Transaction.TransactionEndedEarly'.
--
-- Unlike @sp_reset_connection@, the bit leaves the isolation level as it
-- was on SQL Server (Azure SQL Database puts READ COMMITTED back).  To
-- reset at once, call the procedure: @'Hmssql.Query.callProcedure' conn
-- "sp_reset_connection" []@, a round trip that does not re-run the
-- session setup.
reset :: Connection -> IO ()
reset = requestReset

-- | Cancel the statement whose response the connection is still
-- receiving, if any, and discard what remains of the response.  On a MARS
-- connection, every open response, in one round trip.  This is the first
-- step of 'release'; 'Hmssql.Query.cancelResponse' cancels one response.
--
-- A 'Hmssql.Query.queryS' stream whose consumer stopped early leaves its
-- statement running on the server, holding its locks, until something
-- cancels it, and an interrupted request ('System.Timeout.timeout' around
-- 'Hmssql.Query.query' or 'Hmssql.Query.withQueryS') is canceled at
-- once but drained only by the connection's next operation, so its locks
-- may be held until then.  This is the way to wait for them to go: if the
-- response has been read to its end, nothing is sent; if its last packet
-- has arrived, the rest is discarded locally; otherwise an Attention is
-- sent (none if an interruption sent it already) and the response read
-- up to the server's acknowledgement.  When it returns, no response is
-- pending and the connection is not known to be broken or closed; it
-- throws 'Hmssql.Errors.ConnectionBroken' or 'Hmssql.Errors.ConnectionClosed'
-- otherwise, as a request would.  A stream of the canceled response
-- throws 'Hmssql.Errors.ResultAbandoned' if read on.
--
-- SQL Server treats an Attention like a timeout: a statement still
-- running is rolled back, and under @SET XACT_ABORT ON@ so is the
-- transaction it runs in ('Hmssql.Transaction.withTransaction' then
-- throws 'Hmssql.Transaction.TransactionEndedEarly').
--
-- This is not a way to interrupt a request from another thread: it takes
-- the connection's lock, so it waits for a request in progress.
-- Interrupt the thread instead ('System.Timeout.timeout',
-- 'Control.Concurrent.killThread'), which sends the Attention at once.
-- If the drain is interrupted, the connection is broken.
cancelActiveStatement :: Connection -> IO ()
cancelActiveStatement conn = withConnectionLock conn $ do
  -- After the lock's own check for a released handle.
  refuseUnusable conn
  finishResponse conn

-- | Reset the connection so that it can be returned to a connection pool.
-- Return 'False' if the connection is not usable, because it was closed,
-- it is broken, or the reset itself failed, and so a later request could
-- not use it; that means it should be closed instead of returned to the
-- pool.
--
-- The reset does two things:
--
-- * It cancels the active query, as 'cancelActiveStatement' does, so that
--   a stream that wasn't read to its end doesn't leave the connection
--   busy.  On a MARS connection, every open stream is canceled.
-- * It marks the next request with the RESETCONNECTION bit, so that the
--   server resets the session before running that request.  That costs no
--   round trip now.  However, if 'release' is called in the middle of a
--   transaction, it resets the connection immediately instead, so that the
--   transaction's locks are released before the connection idles in the
--   pool.
--
-- Nothing is sent to probe the server.  A session the server dropped
-- without closing the socket is found by the next request, not here.
--
-- The handle given is released whether the cleanup succeeded or not.
-- Further requests through it, and further reads from its streams, throw
-- 'ConnectionReleased'.  'close', 'renew' and read-only inspection still
-- work through it, and the next borrower gets a new handle from 'renew'.
--
-- Like a request, 'release' waits while another thread holds the
-- connection, and it can be interrupted.  An interrupted 'release' leaves
-- the connection broken, so a pool can wrap it in a timeout and treat
-- 'Nothing' as 'False':
--
-- > ok <- fromMaybe False <$> timeout 5000000 (release conn)
--
-- Calling 'release' inside 'Hmssql.Transaction.withTransaction' is not
-- supported.  "Hmssql.Connection#g:pools" has a complete recipe for the
-- resource-pool package.
release :: Connection -> IO Bool
release conn = withConnectionLock conn $ (`finally` invalidateLease conn) $ do
  ended <- isJust <$> readTVarIO (connEnded conn)
  broken <- isJust <$> readIORef (connBroken conn)
  if ended || broken
    then pure False
    else (clean >> pure True) `catchSync` \e -> do
      markBroken conn (resetFailure e)
      pure False
  where
    clean = do
      finishResponse conn
      atomicWriteIORef (connResetPending conn) True
      -- After the drain: the unread response may have begun or ended one.
      open <- isJust . tdsTransaction <$> readIORef (connContext conn)
      -- The request consumes the reset flag and carries the bit, and the
      -- reset's ENVCHANGE ends the transaction.
      when open $
        if null (connSessionSetup conn)
          then runPlainBatch conn "SELECT 1" `catch` \(e :: SomeException) -> do
            markBroken conn (resetFailure e)
            throwIO e
          else resetWithSessionSetup conn

-- | Issue a new handle to the connection, for the next borrower from a
-- pool, and make every earlier handle stale.  A stale handle throws
-- 'ConnectionReleased', so a borrower that kept its handle past 'release'
-- can't use the connection under the next borrower's feet.  The connection
-- itself is shared, and only the handle is new.  Like a request, 'renew' waits while another
-- thread holds the connection.  It sends nothing.  The handle 'connect'
-- returns needs no 'renew'.
--
-- A connection known to be unusable is refused with the exception a
-- request would throw, 'ConnectionClosed' or 'ConnectionBroken'.  The
-- usual case is a session the server ended while the connection idled in
-- the pool.  The earlier handles are then left as they were, so close the
-- connection and borrow another.  'unusableReason' says what is known
-- without throwing.
renew :: Connection -> IO Connection
renew = renewUsable

-- | Whether the connection is known to be unusable, and why: it was
-- closed, an earlier failure broke it, or the server ended it while it
-- idled.  'Nothing' means that no failure has been seen, not that the
-- connection is healthy.  Nothing is sent to probe the server, so a
-- session the server dropped without closing the socket is found by the
-- next request.  Like a request, it waits while another thread holds the
-- connection.
--
-- It describes the connection, not the handle.  A released handle to a
-- healthy connection gives 'Nothing', and a request through that handle
-- still throws 'ConnectionReleased'.
unusableReason :: Connection -> IO (Maybe UnusableReason)
unusableReason = currentUnusableReason

-- | Close the connection.  It is safe to call from any thread, and more
-- than once, through any handle to the connection, a released one
-- included.  A request in progress on another thread is interrupted and
-- fails with @'ConnectionClosedBy' 'ClosedByClient'@, as does any later
-- use of the connection.
--
-- The TLS goodbye can block if the server doesn't read.  It can be
-- interrupted, and calling 'close' again completes it.  A closed
-- connection keeps under a kilobyte alive, so one that a pool still
-- references costs nothing.
close :: Connection -> IO ()
close conn = do
  -- The goodbye runs only while nothing is being sent, and the socket is
  -- closed after it ('closeConnection').  A failure to close is not
  -- reported: the connection is closed either way ('closeSocket' closes
  -- the descriptor all the same).
  closeConnection conn $ readIORef (connTransport conn) >>= \case
    TransportTls ctx -> TLS.bye ctx `catchSync` \_ -> pure ()
    TransportPlain _ -> pure ()
  releaseTransport conn

------------------------------------------------------------------------------

-- | Open what the connection travels on ('connectProtocol').  Called
-- masked, with the caller's @restore@ for the waits of the TCP connect;
-- returns still masked.  Throws 'IOException' if nothing could be opened.
openBackend :: (forall a. IO a -> IO a) -> ConnectInfo -> IO Backend
openBackend restore ci = case connectProtocol ci of
  ProtocolTcp -> tcp
  ProtocolSharedMemory -> sharedMemory
  ProtocolNamedPipes -> namedPipes
  ProtocolCustom open -> open
  ProtocolAuto
    -- A port that was chosen names a TCP endpoint.  Trying a pipe as
    -- well could reach another server than the one asked for: the
    -- machine's default instance, in place of whatever listens on the
    -- port.
    | not pipesSupported || portChosen -> tcp
    | otherwise -> do
        local <- isLocalHost host
        firstOf $ [("Shared Memory", sharedMemory) | local]
          -- A named instance is not on the default port, and nothing
          -- here asks the SQL Server Browser which port it is on.
          ++ [("TCP/IP", tcp) | isDefaultInstance instanceName]
          ++ [("Named Pipes", namedPipes)]
  where
    -- Backend APIs use the platform's String host, service and pipe names.
    host = T.unpack (connectHost ci)
    port = T.unpack (connectPort ci)
    instanceName = T.unpack (connectInstance ci)
    portChosen = connectPort ci /= connectPort defaultConnectInfo
    tcp = tcpBackendWith restore host port
    sharedMemory = pipeBackendMasked (sharedMemoryPipe instanceName)
    namedPipes = do
      local <- (|| host `elem` ["127.0.0.1", "::1"]) <$> isLocalHost host
      pipeBackendMasked (namedPipe local host instanceName)

    -- The first that opens.  Only a failure to open moves on to the next:
    -- what happens on an open backend (the TLS handshake, the login) is
    -- outside this.  When none opens, the failure says why each didn't;
    -- its type is that of the TCP attempt, the one other platforms have.
    firstOf :: [(String, IO Backend)] -> IO Backend
    firstOf = go []
      where
        go failures [] = throwIO (allFailed (reverse failures))
        go failures ((name, open) : rest) = try open >>= \case
          Right backend -> pure backend
          Left (e :: IOException) -> go ((name, e) : failures) rest

    allFailed :: [(String, IOException)] -> IOException
    allFailed failures = base
      { ioe_location = "hmssql: connect to " ++ host
      , ioe_description = intercalate "; " [name ++ ": " ++ displayException e | (name, e) <- failures]
      , ioe_filename = Nothing
      }
      where
        base = case [e | ("TCP/IP", e) <- failures] ++ map snd failures of
          e : _ -> e
          [] -> userError "no protocol to try"

data EncryptionMode = NoEncryption | LoginOnly | FullEncryption
  deriving stock (Eq, Show)

-- | MS-TDS 2.2.6.5 PRELOGIN, encryption negotiation.  A conforming
-- server answers:
--
-- @
-- client sends     server has OFF   server has ON    server has NOT_SUP
-- ENCRYPT_OFF      ENCRYPT_OFF      ENCRYPT_REQ      ENCRYPT_NOT_SUP
-- ENCRYPT_ON       ENCRYPT_ON       ENCRYPT_ON       ENCRYPT_NOT_SUP (terminate)
-- ENCRYPT_NOT_SUP  ENCRYPT_NOT_SUP  ENCRYPT_REQ (terminate)   ENCRYPT_NOT_SUP
-- ENCRYPT_REQ      ENCRYPT_ON       ENCRYPT_ON       ENCRYPT_NOT_SUP (terminate)
-- @
--
-- and the client then encrypts the login packet only (OFF\/OFF), the whole
-- connection (OFF\/ON, OFF\/REQ, ON\/ON, ON\/REQ), or nothing
-- (OFF\/NOT_SUP, NOT_SUP\/NOT_SUP).  Any other answer, and every
-- \"terminate\" cell, is refused before anything else is sent.
negotiateEncryption :: Encryption -> Encryption -> IO EncryptionMode
negotiateEncryption client server = case (client, server) of
  (EncryptOff, EncryptOff) -> pure LoginOnly
  (EncryptOff, EncryptOn) -> pure FullEncryption
  (EncryptOff, EncryptReq) -> pure FullEncryption
  (EncryptOff, EncryptNotSup) -> pure NoEncryption
  (EncryptOn, EncryptOn) -> pure FullEncryption
  (EncryptOn, EncryptReq) -> pure FullEncryption
  (EncryptReq, EncryptOn) -> pure FullEncryption
  (EncryptReq, EncryptReq) -> pure FullEncryption
  (EncryptNotSup, EncryptNotSup) -> pure NoEncryption
  -- Not in the table (a server with encryption off answers NOT_SUP), but
  -- neither side wants encryption.
  (EncryptNotSup, EncryptOff) -> pure NoEncryption
  (EncryptNotSup, _) -> refuse "the server requires encryption, but the client was configured not to encrypt"
  (EncryptStrict, _) -> pure FullEncryption  -- not negotiated via PRELOGIN
  (_, EncryptNotSup) -> refuse "the server does not support encryption"
  _ -> refuse "unexpected answer"
  where
    refuse why = throwIO $ ProtocolError $
      "PRELOGIN encryption negotiation failed: " ++ why ++ " (client requested "
        ++ show client ++ ", server answered " ++ show server ++ ")"

-- | What the server's PRELOGIN answer said.
data PreloginAnswer = PreloginAnswer
  { plaEncryption :: !(Maybe Word8)
    -- ^ The ENCRYPTION option, as sent.
  , plaFedAuthRequired :: !Bool
    -- ^ The FEDAUTHREQUIRED option was 0x01 (the value a FEDAUTH login
    -- echoes).
  , plaNonce :: !(Maybe B.ByteString)
    -- ^ The NONCEOPT option, which the server sends only if the client did.
  }

-- | For a login without PRELOGIN (strict encryption): nothing.
noPreloginAnswer :: PreloginAnswer
noPreloginAnswer = PreloginAnswer Nothing False Nothing

-- | Send PRELOGIN and read the answer.  The FEDAUTHREQUIRED option is sent
-- (with the value MS-TDS prescribes, 0x01) when the login will use
-- federated authentication.
--
-- MARS is asked for with the MARS option, and must be granted:
-- 'MarsNotSupported' otherwise.
prelogin :: Connection -> Encryption -> Bool -> Bool -> IO PreloginAnswer
prelogin conn enc fedAuth mars = do
  let msg = Prelogin $
        [ PLVersion 0 0 0 0
        , PLEncryption (encryptionWord enc)
        , PLInstance ""
        , PLThreadId (Just 0)
        , PLMars (if mars then 1 else 0)
        ] ++ [PLFedAuthRequired 0x01 | fedAuth]
  sendMessage conn PTPrelogin (putPrelogin msg)
  -- The options are located by 16-bit offsets and lengths, so a response
  -- can't meaningfully be longer than this.
  (ptype, body) <- readWholeMessageUpTo conn (0xFFFF + 0xFFFF)
  unless (ptype == PTTabularResult) $
    throwIO $ ProtocolError $ "unexpected PRELOGIN response packet type " ++ show ptype
  Prelogin opts <- case Get.runGetOrFail getPrelogin (LB.fromStrict body) of
    Right (_, _, p) -> pure p
    Left (_, _, err) -> throwIO $ ProtocolError $ "PRELOGIN response: " ++ err
  let marsAnswer = listToMaybe [m | PLMars m <- opts]
  if mars
    then unless (marsAnswer == Just 1) $ throwIO MarsNotSupported
    else forM_ marsAnswer $ \m ->
      unless (m == 0) $ throwIO $ ProtocolError "the server turned MARS on, which was not asked for"
  pure PreloginAnswer
    { plaEncryption = listToMaybe [e | PLEncryption e <- opts]
    , plaFedAuthRequired = listToMaybe [f | PLFedAuthRequired f <- opts] == Just 0x01
    , plaNonce = listToMaybe [n | PLNonce n <- opts]
    }

-- | Read the login response to its end: 'Just' where the server redirects
-- the login, 'Nothing' once logged in.
readLoginResponse :: Connection -> ActiveResponse -> IO (Maybe RoutingInfo)
readLoginResponse conn ar = go Nothing Nothing
  where
    go acked routed = nextLoginToken >>= \case
      Nothing -> case acked of
        Just la -> finish la routed
        Nothing -> throwIO $ ProtocolError "login response did not include LOGINACK"
      Just tok -> case tok of
        TLoginAck la -> go (Just la) routed
        TError msg -> do
          drainActiveResponse conn ar `catchSync` \_ -> pure ()
          throwIO (LoginError msg)
        TFeatureExtAck acks -> do
          forM_ acks $ \FeatureAck{..} ->
            when (featureId == 0x0A) $
              modifyIORef' (connContext conn) (\c -> c { tdsUtf8Support = featureData == "\1" })
          go acked routed
        TEnvChange (ECRouting info) -> go acked (Just info)
        _ -> go acked routed

    -- An ERROR of severity 20 or more is thrown by the token reader as it
    -- is parsed ('nextToken' breaks the connection at a fatal error),
    -- before the arm above sees it; in the login response it is a refused
    -- login all the same.
    nextLoginToken = nextToken conn ar `catch` \(SqlServerError msg _) -> throwIO (LoginError msg)

    -- A client that receives a routing ENVCHANGE must close the connection
    -- and log in to the server it names (MS-TDS 2.2.7.9).
    finish _ (Just routing) = pure (Just routing)
    finish la Nothing = case tdsVersionFromWord (laTdsVersion la) of
      Just v -> Nothing <$ modifyIORef' (connContext conn) (\c -> c { tdsVersion = v })
      Nothing -> throwIO $ ProtocolError $
        "server negotiated unsupported TDS version 0x" ++ printf "%08x" (laTdsVersion la)

-- | Run a batch that returns nothing wanted, read to its end; then an
-- ERROR token is thrown as 'SqlServerError', and a DONE flagged as failed
-- in a response without one as 'SevereError' (never reported as success).
runPlainBatch :: Connection -> Text -> IO ()
runPlainBatch conn sql = do
  ar <- startRequest conn PTSqlBatch (\ctx -> sqlBatchBody ctx sql)
  let go err done = nextToken conn ar >>= \case
        Nothing -> case (err, done) of
          (Just msg, _) -> throwIO (SqlServerError msg (Just sql))
          (Nothing, Just d) -> throwSevere conn d (Just sql)
          (Nothing, Nothing) -> pure ()
        Just (TError msg) -> go (err <|> Just msg) done
        Just tok -> go err (done <|> failedDoneOf tok)
  go Nothing Nothing

-- | Catch synchronous exceptions only: an asynchronous one (a 'Control.Concurrent.killThread',
-- or 'System.Timeout.timeout' firing) must reach the code that sent it.
catchSync :: IO a -> (SomeException -> IO a) -> IO a
catchSync act handler = act `catch` \e -> case fromException e of
  Just (_ :: SomeAsyncException) -> throwIO e
  Nothing -> handler e
