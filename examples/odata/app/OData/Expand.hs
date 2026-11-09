-- | Zipping the streams of a request, and writing the nested result.
--
-- Each level of the tree is one stream, open on the request's MARS
-- connection beside the others.  The streams are sorted alike ("OData.Query"):
-- a child stream's rows come in the order of their parents, each carrying
-- its parent's row number.  So the walk is a merge join done by the
-- client: for each parent row, the rows at the front of each child stream
-- whose parent number is the parent's are that parent's collection, and
-- they are written as they are read.  Each child stream is held at one
-- row of lookahead, and a parent's collection is never a list, so a parent
-- with a million children costs the same memory as one with none.
module OData.Expand
  ( Node
  , openNodes
  , expandBody
  , Inconsistent (..)
  ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString.Builder (Builder, char7)
import qualified Data.Aeson.Encoding as E
import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Streaming (Of, Stream)
import qualified Streaming.ByteString as Q
import qualified Streaming.Prelude as S

import Hmssql
import Hmssql.Query (querySWith)
import OData.Decode (Row (..), levelRow)
import OData.Query (Level (..))

-- | A stream and the row at its front, so that a row can be looked at
-- without being consumed until it is known which parent it belongs to.
newtype Cursor = Cursor (IORef (Either () (Row, Stream (Of Row) IO ())))

-- | An expanded collection property: its stream, and its own expansions.
data Node = Node
  { name :: Text
  , cursor :: Cursor
  , kids :: [Node]
  }

-- | Open the streams of a level's children, and of theirs.  'querySWith'
-- sends the statement, and reading the first row makes the server answer
-- it, so a statement the server refuses, or a result set the decoder
-- rejects, fails here, before any of the response has been written.
openNodes :: (Query -> IO ()) -> Connection -> [(Text, Level)] -> IO [Node]
openNodes logSql conn = mapM $ \(name, level) -> do
  logSql level.statement
  rows <- querySWith (levelRow level) conn level.statement
  cursor <- Cursor <$> (S.next rows >>= newIORef)
  kids <- openNodes logSql conn level.children
  pure Node { name, cursor, kids }

-- | The streams of a request disagree about which parent a child row
-- belongs to.  That can only happen when the statements read different
-- states of the database, which the snapshot transaction rules out.
newtype Inconsistent = Inconsistent Text
  deriving stock (Show)

instance Exception Inconsistent

-- | The rows at the front of the node's stream that belong to the parent,
-- each consumed as it is yielded.  The first row of a later parent stays
-- in the cursor.
groupOf :: Node -> Row -> Stream (Of Row) IO ()
groupOf node parent = loop
  where
    Cursor ref = node.cursor
    loop = liftIO (readIORef ref) >>= \case
      Left () -> pure ()
      Right (row, rest) -> case compare row.parentRn parent.rn of
        GT -> pure ()
        LT -> liftIO (throwIO (inconsistent node row.parentRn))
        EQ -> do
          liftIO (S.next rest >>= writeIORef ref)
          S.yield row
          loop

-- | After the last parent, every child stream must be at its end.
drainAll :: [Node] -> IO ()
drainAll = mapM_ $ \node -> do
  let Cursor ref = node.cursor
  readIORef ref >>= \case
    Left () -> drainAll node.kids
    Right (row, _) -> throwIO (inconsistent node row.parentRn)

inconsistent :: Node -> Int64 -> Inconsistent
inconsistent node parentRn = Inconsistent $
  "a row of " <> node.name <> " belongs to parent row " <> T.pack (show parentRn) <> ", which the parent stream has passed"

-- | The rows of one level as JSON objects, comma-separated, each with its
-- collections nested in it.  A stream of builders: the effects, reading the
-- streams, run as the builders are written.
emitRows :: [Node] -> Stream (Of Row) IO () -> Stream (Of Builder) IO ()
emitRows nodes rows = S.for (S.zip (S.yield True >> S.repeat False) rows) $ \(first, row) -> do
  unless first (S.yield (char7 ','))
  S.yield (char7 '{' <> row.members)
  forM_ nodes $ \node -> do
    S.yield (char7 ',' <> E.fromEncoding (E.text node.name) <> ":[")
    emitRows node.kids (groupOf node row)
    S.yield (char7 ']')
  S.yield (char7 '}')

-- | The response body: the envelope and the root's rows with their
-- expansions.  Once the last parent is written, the child streams have
-- been read to their ends, so a transaction around the request can commit.
expandBody :: Text -> [Node] -> Stream (Of Row) IO () -> Q.ByteStream IO ()
expandBody set nodes rows = Q.toStreamingByteString $
  "{\"@odata.context\":" <> E.fromEncoding (E.text ("$metadata#" <> set)) <> ",\"value\":["
    <> Q.concatBuilders (emitRows nodes rows >> liftIO (drainAll nodes))
    <> "]}"
