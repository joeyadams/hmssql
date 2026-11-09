{-# LANGUAGE MagicHash #-}
-- | Runtime state that affects how TDS messages are serialized and parsed.
--
-- Every @get@/@put@ function in "Hmssql.Tds.*" takes a 'TdsContext' so that
-- protocol-version-dependent encodings are decided in one place.
module Hmssql.Tds.Context
  ( TdsVersion (..)
  , tdsVersionWord
  , tdsVersionFromWord
  , TransactionDescriptor (..)
  , TdsContext (..)
  , defaultTdsContext
  , minPacketSize
  , maxPacketSize
  , clampPacketSize
  ) where

import qualified Data.ByteString as B
import Data.Word (Word32, Word64)
import Hmssql.Internal.Derived

-- | Protocol versions this library can negotiate.
--
-- TDS 7.4 is the baseline (SQL Server 2017 and later, Azure SQL).  TDS 8.0 is the
-- same token stream over TLS from byte zero ("strict" encryption).
data TdsVersion
  = Tds74
  | Tds80
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The version DWORD sent in LOGIN7 (little-endian on the wire).
tdsVersionWord :: TdsVersion -> Word32
tdsVersionWord = \case
  Tds74 -> 0x74000004
  Tds80 -> 0x08000000

-- | Interpret the version DWORD from LOGINACK (big-endian on the wire).
tdsVersionFromWord :: Word32 -> Maybe TdsVersion
tdsVersionFromWord = \case
  0x74000004 -> Just Tds74
  0x08000000 -> Just Tds80
  _ -> Nothing

-- | The server's identifier for the session's transaction, from a transaction
-- ENVCHANGE, which every request sends back in its ALL_HEADERS.
newtype TransactionDescriptor = TransactionDescriptor Word64
  deriving newtype (Eq, Ord)

instance Show TransactionDescriptor where
  showsPrec p (TransactionDescriptor a) = showCon1 p "TransactionDescriptor"# a
  {-# OPAQUE showsPrec #-}

-- | The protocol state a connection has negotiated, which the encoders
-- and parsers take as an argument; 'Hmssql.Connection.connectionContext'
-- reads a connection's.
data TdsContext = TdsContext
  { tdsVersion :: !TdsVersion
    -- ^ The version the server agreed to in LOGINACK.
  , tdsPacketSize :: !Word32
    -- ^ Negotiated packet size, including the 8-byte header.
  , tdsTransaction :: !(Maybe TransactionDescriptor)
    -- ^ Current transaction, sent in the ALL_HEADERS of every request.
  , tdsUtf8Support :: !Bool
    -- ^ Server acknowledged the UTF8_SUPPORT feature extension.
  , tdsCollation :: !(Maybe B.ByteString)
    -- ^ The session's default collation, the five bytes of the last SQL
    -- collation ENVCHANGE (at login, and after a @USE@), if any: what a
    -- string is sent with where a collation is needed and none is known
    -- (a @sql_variant@ value in "Hmssql.BulkCopy").
  }

instance Show TdsContext where
  showsPrec p (TdsContext a b c e f) = showRecord p "TdsContext"#
    [ "tdsVersion"# := a, "tdsPacketSize"# := b, "tdsTransaction"# := c
    , "tdsUtf8Support"# := e, "tdsCollation"# := f
    ]
  {-# OPAQUE showsPrec #-}

instance Eq TdsContext where
  TdsContext a b c e f == TdsContext a' b' c' e' f' =
    eq a a' && b == b' && eq c c' && e == e' && eq f f'
  {-# OPAQUE (==) #-}

-- | The range of packet sizes, header included, that SQL Server negotiates
-- (its @network packet size@ option; MS-TDS 2.2.6.4 LOGIN7
-- PacketSize).
minPacketSize, maxPacketSize :: Word32
minPacketSize = 512
maxPacketSize = 32767

-- | The nearest packet size in 'minPacketSize' .. 'maxPacketSize'.
clampPacketSize :: Word32 -> Word32
clampPacketSize = max minPacketSize . min maxPacketSize

-- | TDS 7.4, 4096-byte packets, no transaction: what a connection starts
-- from, and what the pure encoders are tested with.
defaultTdsContext :: TdsContext
defaultTdsContext = TdsContext
  { tdsVersion = Tds74
  , tdsPacketSize = 4096
  , tdsTransaction = Nothing
  , tdsUtf8Support = False
  , tdsCollation = Nothing
  }
