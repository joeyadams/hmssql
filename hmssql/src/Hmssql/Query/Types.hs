{-# LANGUAGE MagicHash #-}
{-# OPTIONS_HADDOCK not-home #-}

-- | The representations of the query types, constructors and fields
-- included, for the tests and for libraries built on top of hmssql (a
-- quasiquoter, a reader of responses token by token).  "Hmssql.Query"
-- exports these types with only the constructors that code running queries
-- uses; nothing here is stable.
--
-- A 'Query' is a tree of pieces.  Each piece holds fragments (static text
-- and placeholders numbered from 1 among the piece's own positional
-- parameters) and its parameters; a node caches how many positional
-- parameters are below it.  So '<>' is a constant-time node, and the
-- absolute numbering (@\@p1@, @\@p2@, ... across the whole query) is
-- computed in one pass when the query is flattened ('queryFragments',
-- 'queryParams', 'queryText'): building a query from @n@ pieces costs
-- @O(n)@ however the '<>'s associate.
module Hmssql.Query.Types
  ( -- * Queries
    Query (..)
  , Node (..)
  , piece
  , Fragment (..)
  , QueryParam (..)
  , queryFragments
  , queryParams
  , queryText
  , renderFragments
  , placeholderText
  , queryProblem
  , fragmentsProblem

    -- * Requests
  , Request (..)

    -- * Responses
  , ResponseReader (..)
  , BatchScope (..)
  , RowBatch (..)
  , ResponseStep (..)

    -- * Result sets
  , ResultSet (..)
  , ResultSets (..)
  ) where

import Data.IORef (IORef)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)

import Hmssql.Internal.Derived
import Hmssql.Tds.PacketWriter (PacketWriter)
import Hmssql.Connection.Internal (ActiveResponse, Connection, ResponseStep (..), RowBatch (..))
import Hmssql.Encoding (EncodedParam)
import Hmssql.Query.Lexer
import Hmssql.Tds.Context (TdsContext)
import Hmssql.Tds.Packet (PacketType)
import Hmssql.Tds.Token (ColumnInfo, Done, ServerMessage, Token)

------------------------------------------------------------------------------
-- Queries

-- | SQL text together with the parameters it refers to.  Build one from a
-- string literal, with 'Hmssql.Query.mkQuery', or from pieces joined with
-- '<>'; "Hmssql.Query#g:building" shows each way.
--
-- The positional parameters are sent as @\@p1@, @\@p2@, ... in the order
-- 'queryParams' lists them, and the named parameters by name.  '<>'
-- appends the text and the parameters of two queries and renumbers the
-- right operand's placeholders past the left operand's positional
-- parameters, so any two queries can be joined.  A placeholder that
-- refers to no parameter makes sending the query throw
-- 'Hmssql.Errors.EncodeError'.
--
-- A query with no parameters is sent as a plain SQL batch, and one with
-- parameters through @sp_executesql@.  'fromString' (@OverloadedStrings@)
-- is text as it is, with no parameters.  'Show' is the text as it would
-- be sent, without the parameter values.
data Query = Query
  { queryPositional :: !Int
    -- ^ How many positional parameters the query has.
  , queryNode :: Node
  }

-- | The tree of a 'Query': empty, one piece, or two queries appended.
data Node
  = Empty
  | Piece [Fragment] [QueryParam]
    -- ^ Placeholders are numbered among this piece's own positional
    -- parameters, from 1.
  | Append Query Query

-- | A parameter: its name (@\"\"@ for a positional one, otherwise with the
-- leading @\@@) and how to encode its value for a connection.
data QueryParam = QueryParam
  { paramName :: !Text
  , paramEncode :: TdsContext -> Either String EncodedParam
  }

-- | The name only; the value is not shown.
instance Show QueryParam where
  showsPrec d p = showCon d "QueryParam"# [Arg (paramName p), Arg (Verbatim "<value>")]
  {-# OPAQUE showsPrec #-}

-- | A query of one piece: fragments whose placeholders are numbered among
-- the positional parameters given, from 1.
piece :: [Fragment] -> [QueryParam] -> Query
piece [] [] = mempty
piece frags params = Query (length (filter (T.null . paramName) params)) (Piece frags params)

instance Semigroup Query where
  Query _ Empty <> b = b
  a <> Query _ Empty = a
  a <> b = Query (queryPositional a + queryPositional b) (Append a b)
  -- Inlined, each '<>' of an application's query was a tree of cases on both
  -- operands, and a query composed of four 'param's and their text was 4.4 KB of
  -- object code; called, it is a few instructions.
  {-# NOINLINE (<>) #-}

instance Monoid Query where
  mempty = Query 0 Empty

instance IsString Query where
  fromString s = piece [Static (T.pack s) | not (null s)] []

instance Show Query where
  showsPrec d q = showsPrec d (queryText q)

-- | The fragments of the whole query, placeholders numbered across it.
-- Built strictly, right to left (the whole list is always consumed):
-- lazily, every node and fragment left a thunk, about 190 bytes per
-- fragment.
queryFragments :: Query -> [Fragment]
queryFragments q = go 0 q []
  where
    go !off (Query _ node) rest = case node of
      Empty -> rest
      Piece frags _ -> shiftAll off frags rest
      Append l r -> let !rest' = go (off + queryPositional l) r rest in go off l rest'
    shiftAll !off frags rest = case frags of
      [] -> rest
      f : fs -> let !more = shiftAll off fs rest; !f' = shift off f in f' : more
    shift 0 f = f
    shift off (Placeholder n) = Placeholder (n + off)
    shift _ f = f

-- | The parameters of the whole query, in order.
queryParams :: Query -> [QueryParam]
queryParams q = go q []
  where
    go (Query _ node) rest = case node of
      Empty -> rest
      Piece _ params -> params ++ rest
      Append l r -> go l (go r rest)

-- | The SQL text as it is sent, with @\@pN@ for the placeholders.
--
-- A placeholder next to a character that could continue a variable name
-- gets a space between them: @\"x = \" <> param 1 <> \"1\"@ is sent as
-- @x = \@p1 1@, not @x = \@p11@ (another parameter), and @\"N\" <> param s@
-- as @N \@p1@, not the identifier @N\@p1@.
queryText :: Query -> Text
queryText = renderFragments . queryFragments

-- | 'queryText' of the fragments: the static text as it is, each
-- placeholder as @\@pN@ with a space on either side where a variable-name
-- character would otherwise run into it, concatenated once.
renderFragments :: [Fragment] -> Text
renderFragments = \case
  [] -> T.empty
  [Static t] -> t
  frags -> T.concat (go '\0' frags)
  where
    -- @prev@ is the character before, or NUL at the start.
    go _ [] = []
    go prev (f : fs) = case f of
      Static t -> t : go (if T.null t then prev else T.last t) fs
      Placeholder n ->
        (if isVariableChar prev then [" "] else [])
          ++ placeholderText n
          : (if spaceAfter fs then [" "] else [])
          ++ go ' ' fs
    -- A space after a placeholder: before a character that could continue
    -- a variable name, or before another placeholder.
    spaceAfter = \case
      Static t : _ | Just (c, _) <- T.uncons t -> isVariableChar c
      Placeholder _ : _ -> True
      _ -> False

-- | @\@p@ and the number, as 'queryText' writes a placeholder.
placeholderText :: Int -> Text
placeholderText n = T.pack ('@' : 'p' : show n)

-- | Why the query can't be sent, if it can't: a placeholder that refers to
-- a positional parameter it doesn't have.
queryProblem :: Query -> Maybe String
queryProblem q = fragmentsProblem (queryPositional q) (queryFragments q)

-- | 'queryProblem' of a query's fragments, given how many positional
-- parameters it has.
fragmentsProblem :: Int -> [Fragment] -> Maybe String
fragmentsProblem count frags = case [n | Placeholder n <- frags, n < 1 || n > count] of
  [] -> Nothing
  n : _ -> Just $
    "the query refers to @p" ++ show n ++ " but has "
      ++ (case count of
            0 -> "no positional parameters"
            1 -> "one positional parameter"
            _ -> show count ++ " positional parameters")
      ++ (if n < 1 then " (they are numbered from 1)" else "")

------------------------------------------------------------------------------
-- Requests and responses

-- | A message to send: its packet type and its body, written for the
-- connection's context when it is sent.  'Hmssql.Query.queryRequest'
-- builds one from a 'Query'; 'Hmssql.Query.startResponse' and
-- 'Hmssql.Query.responseS' send one.
data Request = Request
  { requestPacketType :: !PacketType
  , requestBody :: !(TdsContext -> PacketWriter -> IO ())
  , requestStatement :: !(Maybe Text)
    -- ^ For error messages.
  }

-- | A response being read: the reader the query functions share, pulling
-- one step at a time ('Hmssql.Query.readStep') until 'StepEnd'.  ERROR
-- tokens are withheld (the first kept) and thrown as
-- 'Hmssql.Errors.SqlServerError' once the response is complete, so the
-- connection is never left mid-message; a DONE flagged as failed in a
-- response with no ERROR token is thrown as 'Hmssql.Errors.SevereError'
-- then.
--
-- Not a SQL cursor: it reads one response forwards, once.
data ResponseReader = ResponseReader
  { respConn :: !Connection
  , respActive :: !ActiveResponse
  , respFirstError :: !(IORef (Maybe ServerMessage))
  , respFailedDone :: !(IORef (Maybe Done))
  , respPushback :: !(IORef (Maybe Token))
    -- ^ A token read ahead, returned by the next 'Hmssql.Query.readStep'.
  , respStatement :: !(Maybe Text)
  , respEnded :: !(IORef Bool)
    -- ^ The response's end has been read: reading on would throw
    -- 'Hmssql.Errors.ResultAbandoned', so 'Hmssql.Query.drainResponse'
    -- stops here.
  , respBatch :: !(Maybe BatchScope)
    -- ^ Reading one statement of a batch query
    -- ('Hmssql.BatchQuery.BatchQuery'): 'StepEnd' at the statement's
    -- DONEPROC, and an ERROR ends the batch at once.
  }

-- | One result set of a response: its columns and its rows.
data ResultSet r = ResultSet
  { resultColumns :: ![ColumnInfo]
  , resultRows :: ![r]
  }
  deriving stock (Eq, Functor)

instance Show r => Show (ResultSet r) where
  showsPrec p (ResultSet a b) =
    showRecord p "ResultSet"# ["resultColumns"# := a, "resultRows"# := b]
  {-# OPAQUE showsPrec #-}

-- | How to decode a response that holds several result sets, one at a
-- time in order, for 'Hmssql.Query.queryResultSets'.  Build one from
-- 'Hmssql.Query.resultSet' and 'Hmssql.Query.skipResultSet' with the
-- 'Applicative' or 'Monad' combinators; as a 'Monad', a later decoder may
-- depend on earlier rows.  Statements that produce no result set, such as
-- @DECLARE@, @SET@ and @UPDATE@, are skipped over.
--
-- > (parents, children) <- queryResultSets ((,) <$> resultSet <*> resultSet) conn
-- >   "SELECT id, name FROM dbo.parent; SELECT id, parent_id FROM dbo.child"
newtype ResultSets a = ResultSets
  { runResultSets :: TdsContext -> ResponseReader -> IO a
  }

-- The instances run once per result set, so they are out of line: inlined, a
-- composition such as @(,) <$> resultSet <*> resultSet@ was its own copy of them
-- at each use.  A function calling 'Hmssql.Query.queryResultSets' with that
-- composition was 881 bytes of object code, and is 305 with these, 'resultSetWith'
-- and the 'Only' decoder out of line.
instance Functor ResultSets where
  fmap f (ResultSets m) = ResultSets $ \ctx resp -> f <$> m ctx resp
  {-# NOINLINE fmap #-}

instance Applicative ResultSets where
  pure a = ResultSets $ \_ _ -> pure a
  mf <*> ma = mf >>= \f -> fmap f ma
  {-# NOINLINE (<*>) #-}
  liftA2 f ma mb = ma >>= \a -> fmap (f a) mb
  {-# NOINLINE liftA2 #-}

instance Monad ResultSets where
  ResultSets m >>= k = ResultSets $ \ctx resp -> do
    a <- m ctx resp
    runResultSets (k a) ctx resp
  {-# NOINLINE (>>=) #-}

-- | What bounds a 'ResponseReader' to one statement of a batch.
data BatchScope = BatchScope
  { scopeEnded :: !(IORef Bool)
    -- ^ The statement's DONEPROC has been returned.
  , scopeStatement :: !(IORef Text)
    -- ^ The statement's text, for its error.
  , scopeFail :: ServerMessage -> IO Void
    -- ^ An ERROR token arrived: read the rest of the batch, then throw.
  }
