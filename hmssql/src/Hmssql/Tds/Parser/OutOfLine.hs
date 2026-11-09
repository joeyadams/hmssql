{-# LANGUAGE NoImplicitPrelude #-}
-- | The recipe operations of "Hmssql.Tds.Parser" as calls, for recipes that run
-- once per token, per request or per connection, such as a token's header or the
-- login acknowledgement.  Use it with @QualifiedDo@:
--
-- > import qualified Hmssql.Tds.Parser.OutOfLine as O
-- >
-- > readDone = O.do
-- >   status <- O.word16le
-- >   ...
--
-- The 'Monad' instance of 'Recipe' and the primitive reads are INLINE, because a
-- row's cells go through them, and each inlined bind carries its three outcomes and
-- the resumption; written with these, a bind or a read is a call.  The recipe reads
-- the same bytes either way.  Keep them off the paths that run per row, per cell or
-- per byte.
module Hmssql.Tds.Parser.OutOfLine
  ( (>>=), (>>), (*>), (<$>), (<*>), (<$), pure, return, fail
  , word8, word16le, word32le, word64le, word32be
  ) where

import Data.Word (Word8, Word16, Word32, Word64)
import Data.String (String)
import qualified Prelude as M
import Hmssql.Tds.Parser (Recipe, Parser)
import qualified Hmssql.Tds.Parser as P

-- Measured on 2026-11-04 with GHC 9.12.4: with the token readers of Tds.Token and
-- 'readTypeInfo' written with these, Tds/Token.o went from 248,030 bytes of .text to
-- 164,918 and Tds/TypeInfo.o from 176,254 to 127,158, against this module's 2,853.
-- A result set's COLMETADATA then allocates about 1.4 KB more per column (Mock.query
-- of 50 columns x1000, +0.5% per query); the row tokens allocate 1 to 1.5% less in
-- Decode's token benchmarks, and the typed and SqlRow rows the same.

infixl 1 >>=, >>
infixl 4 <$>, <*>, <$, *>

(>>=) :: Recipe env a -> (a -> Recipe env b) -> Recipe env b
(>>=) = (M.>>=)
{-# NOINLINE (>>=) #-}

(>>) :: Recipe env a -> Recipe env b -> Recipe env b
a >> b = a >>= \_ -> b
{-# INLINE (>>) #-}

(*>) :: Recipe env a -> Recipe env b -> Recipe env b
a *> b = a >>= \_ -> b
{-# INLINE (*>) #-}

(<$>) :: (a -> b) -> Recipe env a -> Recipe env b
(<$>) = M.fmap
{-# NOINLINE (<$>) #-}

(<$) :: a -> Recipe env b -> Recipe env a
a <$ r = (\_ -> a) <$> r
{-# INLINE (<$) #-}

(<*>) :: Recipe env (a -> b) -> Recipe env a -> Recipe env b
(<*>) = (M.<*>)
{-# NOINLINE (<*>) #-}

pure, return :: a -> Recipe env a
pure = M.pure
return = M.pure
{-# INLINE pure #-}
{-# INLINE return #-}

fail :: String -> Recipe env a
fail = M.fail
{-# NOINLINE fail #-}

word8 :: Parser Word8
word8 = P.word8
{-# NOINLINE word8 #-}

word16le :: Parser Word16
word16le = P.word16le
{-# NOINLINE word16le #-}

word32le :: Parser Word32
word32le = P.word32le
{-# NOINLINE word32le #-}

word64le :: Parser Word64
word64le = P.word64le
{-# NOINLINE word64le #-}

word32be :: Parser Word32
word32be = P.word32be
{-# NOINLINE word32be #-}
