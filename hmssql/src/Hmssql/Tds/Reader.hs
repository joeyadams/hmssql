-- | A row decoder compiled for a result set, and how a row that spans two
-- packets reaches its decoder.  The response holds the suspended recipe, and
-- the decoder's 'RowRead' holds only a slot for the row's result; a row that
-- completes within one packet never touches the slot.
module Hmssql.Tds.Reader
  ( CompiledRow (..), Prepared (..), rowRecipe, rowReader, ReadFailure (..), RowRead (..), newRowRead, wholeRows, discardRows, drainingRows, skippedAs
  ) where

import Data.IORef
import Hmssql.Tds.Parser (Parser, ReadFailure (..))
import qualified Hmssql.Tds.Parser as P
import Hmssql.Tds.Value (Row)

-- | A row decoder compiled against a result set's columns.
data CompiledRow a = CompiledRow
  { rowPrepare :: Int -> Prepared (Parser a)
    -- ^ The row's recipe, given the bound on allocating ahead of a value's bytes.
    -- A row that doesn't decode fails the recipe ('P.failValue') once the row has
    -- been read, and the driver takes the failure ('P.runParserAt'); 'rowRecipe'
    -- takes it out with the failure caught.
  }

-- | A value built once and then used many times, such as a row's recipe, which is
-- prepared once for a result set and then read for each row.
data Prepared a = Prepared a

-- Why a constructor: a recipe is a function, so GHC can eta-expand a function that
-- returns one into a function of the row's input as well.  The preparation then runs
-- again for every row, rebuilding each column's recipe as it goes: 144 of the 300
-- bytes per row that a typed (Int32, Int64) row allocated, by ticky.  It can't
-- eta-expand past a constructor.

-- | The row's recipe, given the bound on allocating ahead of a value's bytes.  A
-- 'Left' is a failure of this row alone, with the row fully read: the driver stops the
-- batch there and a 'DecodeFailed' is thrown once the response is drained.  An
-- exception thrown by the recipe means the bytes can't be read, and it breaks the
-- connection.  Prepare it once per result set and use it for each row.
rowRecipe :: CompiledRow a -> Int -> Parser (Either ReadFailure a)
rowRecipe compiled ahead = P.attempt (rowReader compiled ahead)

-- | The row's recipe with its failure left in the recipe, for a driver that takes it
-- with 'P.runParserAt'.  The connection's driver reads rows this way, so that a row
-- costs no 'Right'.
rowReader :: CompiledRow a -> Int -> Parser a
rowReader compiled ahead = case rowPrepare compiled ahead of Prepared recipe -> recipe

-- | What to do with rows, as a response is read.
data RowRead a
  = ReadRows !(Parser a) !(IORef (Maybe (Either ReadFailure a)))
    -- ^ Decode each row: the prepared recipe ('rowReader'), which serves the whole
    -- result set, and the slot through which a row suspended across packets
    -- delivers its result.
  | WholeRows (Row -> a)
    -- ^ Keep each row as a 'Row' of raw cells, for the token-level interface.
  | DiscardRows a
    -- ^ Skip the rows and keep the other tokens, output parameters included.
  | DrainRows a
    -- ^ Throw the whole response away, the values of output parameters
    -- included.
  | StopAtRow
    -- ^ Stop before a row, consuming nothing.  A request waiting behind a
    -- reset reads only the reset's leading tokens, and reading a row there
    -- would mean keeping it for the consumer and parsing it a second time.

-- | Read rows with this compiled row decoder, given the bound on allocating ahead
-- of a value's bytes.  One 'RowRead' serves a whole result set.
newRowRead :: Int -> CompiledRow a -> IO (RowRead a)
newRowRead ahead compiled =
  ReadRows (rowReader compiled ahead) <$> newIORef Nothing

-- | Every row as a 'Row'.
wholeRows :: RowRead Row
wholeRows = WholeRows id

-- | Skip the rows, keeping the other tokens.
discardRows :: RowRead ()
discardRows = DiscardRows ()

-- | Discard token payloads too, including large RETURNVALUE values.
drainingRows :: RowRead ()
drainingRows = DrainRows ()

-- | The value associated with a row that is deliberately skipped.
skippedAs :: RowRead a -> Maybe a
skippedAs (DiscardRows a) = Just a
skippedAs (DrainRows a) = Just a
skippedAs _ = Nothing
