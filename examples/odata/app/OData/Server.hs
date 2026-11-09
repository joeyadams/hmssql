-- | The HTTP side: routes, errors, the connection pool, and streaming the
-- response.
--
-- A collection request runs one streaming query per level of its
-- @$expand@ tree, all on one MARS connection borrowed from the pool, and
-- writes the rows to the socket as SQL Server sends them: 'querySWith'
-- reads rows from the connection as they are consumed, each row is
-- decoded straight to JSON bytes ("OData.Decode"), and warp's
-- 'responseStream' sends them on.  Only a few buffers' worth of rows is
-- in memory at any time, however many rows the request returns.
module OData.Server
  ( Env (..)
  , app
  , onWarpException
  ) where

import Control.Concurrent (forkIO)
import Control.Exception
import Control.Monad (void)
import qualified Data.Aeson.Encoding as E
import qualified Data.ByteString as B
import Data.ByteString.Builder (byteString)
import qualified Data.ByteString.Char8 as B8
import Data.IORef
import Data.Maybe (fromMaybe, isJust)
import Data.Pool (Pool, destroyResource, putResource, takeResource)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp (defaultOnException)
import qualified Streaming.ByteString as Q
import qualified Streaming.Prelude as S
import System.IO (stderr)
import System.Timeout (timeout)

import Hmssql
import Hmssql.Errors
import Hmssql.Query (querySWith)
import OData.Decode (levelRow)
import OData.Expand
import OData.Model
import OData.Query

data Env = Env
  { pool :: Pool Connection
    -- ^ MARS connections, so that a request can keep a stream open per level.
  , model :: Model
  , snapshot :: Bool
    -- ^ Run each @$expand@ request in a snapshot transaction, so that its
    -- statements read one state of the database.
  , logSql :: Bool
  }

------------------------------------------------------------------------------
-- Errors

-- | An error that becomes an OData error response, if nothing of the
-- response has been sent yet.
data ApiError = ApiError
  { status :: Status
  , code :: Text
  , message :: Text
  }
  deriving stock (Show)

instance Exception ApiError

badRequest :: Either Text a -> IO a
badRequest = either (throwIO . ApiError status400 "BadRequest") pure

notFound :: Text -> ApiError
notFound = ApiError status404 "NotFound"

toApiError :: SomeException -> ApiError
toApiError e
  | Just err <- fromException e = err
  | Just (DecodeError col msg) <- fromException e =
      ApiError status500 "ModelMismatch" $
        "the table no longer matches the model read at startup (" <> maybe "" (<> ": ") col <> T.pack msg <> "); restart the server"
  | Just (err :: SqlServerError) <- fromException e = ApiError status500 "SqlServerError" (sqlErrorMessage err)
  | otherwise = ApiError status500 "InternalError" (describe e)

errorResponse :: ApiError -> Response
errorResponse err = responseLBS err.status jsonHeaders $ E.encodingToLazyByteString $
  E.pairs $ E.pair "error" $ E.pairs $ E.pair "code" (E.text err.code) <> E.pair "message" (E.text err.message)

jsonHeaders :: ResponseHeaders
jsonHeaders = [(hContentType, "application/json;odata.metadata=minimal"), ("OData-Version", "4.0")]

------------------------------------------------------------------------------
-- The pool

-- | Run an action with a connection from the pool, and give the connection
-- back afterwards, also when the action throws.  'release' decides whether
-- it is worth keeping: it cancels what is left of a stream the client hung
-- up on, so that the statement doesn't sit on the server holding its locks
-- while the connection idles, has the session reset, and returns 'False'
-- for a connection that is broken or closed.  It runs on a thread of its
-- own, so the request doesn't wait for the cancellation.
--
-- resource-pool's own 'Data.Pool.withResource' destroys the resource on
-- any exception, which here would cost a new login every time a client
-- hangs up mid-stream.
withPooledConnection :: Pool Connection -> (Connection -> IO a) -> IO a
withPooledConnection pool act = mask $ \restore -> do
  (conn, local) <- borrow
  restore (act conn) `finally` giveBack local conn
  where
    -- 'renew' refuses a connection the server ended while it sat in the
    -- pool, so that one is destroyed and the next one taken.
    borrow = do
      (conn0, local) <- takeResource pool
      try (renew conn0) >>= \case
        Right conn -> pure (conn, local)
        Left (e :: SomeException)
          | Just (_ :: SomeAsyncException) <- fromException e -> putResource local conn0 >> throwIO e
          | otherwise -> close conn0 >> destroyResource pool local conn0 >> borrow
    giveBack local conn = void $ forkIO $ do
      let discard = close conn >> destroyResource pool local conn
      ok <- fromMaybe False <$> timeout 5000000 (release conn) `onException` discard
      if ok then putResource local conn else discard

------------------------------------------------------------------------------
-- Routes

app :: Env -> Application
app env req respond0 = do
  -- Once the response has started, an exception can't become an error
  -- response any more.
  started <- newIORef False
  let respond r = writeIORef started True >> respond0 r
  route env req respond `catch` \(e :: SomeException) -> do
    already <- readIORef started
    if already || isJust (fromException @SomeAsyncException e)
      then throwIO e
      else do
        let err = toApiError e
        logLine (requestLine req <> " -> " <> T.pack (show (statusCode err.status)) <> " " <> err.message)
        respond0 (errorResponse err)

route :: Env -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
route env req respond
  | requestMethod req /= methodGet = throwIO (ApiError status405 "MethodNotAllowed" "this service is read-only")
  | otherwise = case filter (not . T.null) (pathInfo req) of
      [] -> respond (responseLBS status200 jsonHeaders (E.encodingToLazyByteString (serviceDocument env.model)))
      [name] -> collection name
      _ -> throwIO (notFound "no such resource")
  where
    collection name = do
      set <- maybe (throwIO (notFound ("no entity set named " <> name))) pure (lookupSet env.model name)
      opts <- badRequest (parseOptions (queryItems req))
      root <- badRequest (compile env.model set opts)
      -- The connection stays borrowed until the body has been written:
      -- warp runs the body inside 'respond', and the rows are read from
      -- the connection as they are sent.
      withPooledConnection env.pool $ \conn -> inSnapshot root conn $ do
        showSql root.statement
        rows <- querySWith (levelRow root) conn root.statement
        -- Read the first row before the headers go out.  This is when the
        -- result set's metadata arrives and the decoder is checked against
        -- it, and when an error the server reports at once comes back, so
        -- both still get an error status.  The child streams are opened
        -- once there is a parent for their rows.
        first <- S.next rows
        (rows', nodes) <- case first of
          Left () -> pure (pure (), [])
          Right (row, rest) -> (\nodes -> (S.yield row >> rest, nodes)) <$> openNodes showSql conn root.children
        r <- respond (responseStream status200 jsonHeaders (streamBody req (expandBody set.setName nodes rows')))
        logLine (requestLine req <> " -> 200")
        pure r
    -- The statements of an $expand start at different times and run as
    -- the response is written.  In one snapshot transaction they still
    -- read one state of the database.  The transaction commits after the
    -- body, when every stream has been read to its end; if the client
    -- hangs up first, 'withTransactionLevel' cancels the open streams and
    -- rolls back.
    inSnapshot root conn
      | null root.children || not env.snapshot = id
      | otherwise = withTransactionLevel Snapshot conn
    showSql sql
      | env.logSql = logLine ("  SQL: " <> queryText sql)
      | otherwise = pure ()

-- | The query string's options, percent-decoded.  Not wai's 'queryString',
-- which splits on @;@ as well as @&@, and @;@ separates the options
-- inside an @$expand@ item's parentheses.
queryItems :: Request -> [(Text, Text)]
queryItems req =
  [ (decode k, decode (B.drop 1 v))
  | item <- B8.split '&' (B.drop 1 (rawQueryString req))
  , not (B.null item)
  , let (k, v) = B8.break (== '=') item
  ]
  where
    decode = T.decodeUtf8Lenient . urlDecode True

serviceDocument :: Model -> E.Encoding
serviceDocument model = E.pairs $
  E.pair "@odata.context" (E.text "$metadata")
    <> E.pair "value" (E.list entry model)
  where
    entry set = E.pairs $
      E.pair "name" (E.text set.setName) <> E.pair "kind" (E.text "EntitySet") <> E.pair "url" (E.text set.setName)

------------------------------------------------------------------------------
-- Streaming

-- | Write the body to the client chunk by chunk.  Two things can end it
-- early, and both are logged and rethrown as 'ResponseCutOff', so that
-- warp closes the connection without the final chunk and the client sees
-- an incomplete response rather than a complete one with broken JSON:
--
-- * The client disconnects.  warp's @write@ throws, which abandons the
--   rest of the hmssql streams.  'release' cancels them as the connection
--   goes back to the pool ('withPooledConnection').
--
-- * The query fails after the first row: an error the server reports
--   mid-result, or the connection dropping.  The headers, with their 200,
--   are already out.
streamBody :: Request -> Q.ByteStream IO () -> StreamingBody
streamBody req body write _flush = do
  clientGone <- newIORef False
  let send chunk = write (byteString chunk) `onException` writeIORef clientGone True
  S.mapM_ send (Q.toChunks body) `catch` \(e :: SomeException) -> do
    gone <- readIORef clientGone
    logLine $ requestLine req <> ": " <> if gone
      then "client went away (" <> describe e <> "); the rest of the result is abandoned"
      else "response cut off: " <> describe e
    case fromException e of
      Just (_ :: SomeAsyncException) -> throwIO e
      Nothing -> throwIO (ResponseCutOff e)

-- | A response body that ended early, and has been logged.
newtype ResponseCutOff = ResponseCutOff SomeException
  deriving stock (Show)

instance Exception ResponseCutOff

-- | For warp's 'Network.Wai.Handler.Warp.setOnException': warp's default,
-- except for responses 'streamBody' has already logged.
onWarpException :: Maybe Request -> SomeException -> IO ()
onWarpException req e = case fromException e of
  Just (ResponseCutOff _) -> pure ()
  Nothing -> defaultOnException req e

requestLine :: Request -> Text
requestLine req = T.decodeUtf8Lenient (requestMethod req <> " " <> rawPathInfo req <> rawQueryString req)

logLine :: Text -> IO ()
logLine = T.hPutStrLn stderr

-- | An exception's message, without the backtrace that 'displayException'
-- of a 'SomeException' appends.
describe :: SomeException -> Text
describe e = case fromException e of
  Just (err :: SqlServerError) -> "SQL Server error " <> T.pack (show (sqlErrorNumber err)) <> ": " <> sqlErrorMessage err
  Nothing -> case fromException e of
    Just (Inconsistent msg) -> msg
    Nothing -> case e of SomeException inner -> T.pack (displayException inner)
