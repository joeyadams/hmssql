{-# LANGUAGE ExistentialQuantification, MagicHash #-}
{-# OPTIONS_HADDOCK hide #-}
-- | Show and Eq instances that do what derived ones do, in less code.  Not
-- part of the API.
--
-- A derived 'showsPrec' is a chain of 'ShowS' compositions, and GHC compiles
-- each field into two or three lazy closures of its own, with the field
-- type's 'showsPrec' inlined into them: about 250 bytes of object code per
-- field, and more for a 'Data.Text.Text'.  It also copied the whole
-- 'showsPrec' into 'show' and 'showList'.  Derived Show was 280 KB of the
-- library's 2.28 MB of @.text@, and derived Eq 70 KB.  The Show instances
-- written with these helpers build a list of fields, each a constructor
-- holding the field's 'Show' dictionary, and one out-of-line function writes
-- them; with 'showsPrec' OPAQUE in the instance, 'show' and 'showList' call
-- it rather than copy it.  The output is the derived output, character for
-- character (@InternalDerivedSpec@ checks the helpers against derived
-- instances).  The Eq instances compare fields as derived ones do, in order
-- ('eq' has the details).  Show saved 167 KB and Eq 20 KB.
--
-- An enumeration keeps its derived instances: a derived nullary
-- constructor is a string literal and a tag comparison.  The instances were
-- generated from the derived ones (@-ddump-deriv@ for Show, the
-- declaration's field types for Eq) and name their constructors' fields
-- positionally, so a field added to a constructor is a compile error in
-- its instances until it is listed there too.
module Hmssql.Internal.Derived
  ( Field (..), showRecord
  , Arg (..), showCon, showCon1
  , Verbatim (..)
  , eq
  ) where

import GHC.Exts (Addr#, unpackAppendCString#)

-- A constructor or field name is an 'Addr#' literal (@"Con"#@), which GHC emits
-- as a static NUL-terminated string, rather than a 'String'.  As a 'String', each
-- name was a CAF of its own, with a closure and entry code beside the bytes; as
-- an address it is the bytes alone.  Only the three functions below read a name,
-- through 'unpackAppendCString#', which takes each byte as a Latin-1 character,
-- and that is exact because every name is ASCII.  The values are shown by their
-- own 'Show' instances.

-- | A record field: its static name and its value.
data Field = forall a. Show a => Addr# := a

infix 0 :=

-- | 'showsPrec' of a record constructor, as derived: @Con {f = x, g = y}@,
-- parenthesized at precedence 11 and above.
showRecord :: Int -> Addr# -> [Field] -> ShowS
showRecord p con fields = showParen (p >= 11) $ \s ->
  unpackAppendCString# con (' ' : '{' : go fields ('}' : s))
  where
    go [] s = s
    go [f] s = field f s
    go (f : rest) s = field f (',' : ' ' : go rest s)
    field (name := v) s = unpackAppendCString# name (' ' : '=' : ' ' : showsPrec 0 v s)
{-# NOINLINE showRecord #-}

-- | A constructor argument.
data Arg = forall a. Show a => Arg a

-- | 'showsPrec' of a prefix constructor with arguments, as derived:
-- @Con x y@, each argument at precedence 11.
showCon :: Int -> Addr# -> [Arg] -> ShowS
showCon p con args = showParen (p >= 11) $ \s -> unpackAppendCString# con (go args s)
  where
    go [] s = s
    go (Arg v : rest) s = ' ' : showsPrec 11 v (go rest s)
{-# NOINLINE showCon #-}

-- | 'showCon' of a constructor with one argument.
showCon1 :: Show a => Int -> Addr# -> a -> ShowS
showCon1 p con v = showParen (p >= 11) $ \s -> unpackAppendCString# con (' ' : showsPrec 11 v s)
{-# NOINLINE showCon1 #-}

-- | '==' out of line, for the Eq instances written beside these Show ones.  A
-- derived '==' inlined each field's comparison (a 'Data.Text.Text''s length,
-- offset and memcmp, a list's loop), and GHC copied the whole of it into
-- '/='.  An instance compares a field of a small primitive type inline and
-- calls this for any other, with its '==' OPAQUE.
eq :: Eq a => a -> a -> Bool
eq = (==)
{-# NOINLINE eq #-}

-- | A field shown as this text, such as @<redacted>@ in place of a password.
newtype Verbatim = Verbatim String

instance Show Verbatim where
  showsPrec _ (Verbatim s) = showString s
