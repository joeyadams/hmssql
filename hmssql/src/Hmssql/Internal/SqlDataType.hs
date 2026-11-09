{-# OPTIONS_HADDOCK hide #-}
-- | 'SqlDataType' and 'typeInfoDataType', which "Hmssql.SqlType" exports.  Not
-- part of the API.
--
-- They are a module of their own because the decoders classify columns with
-- 'typeInfoDataType', which is INLINE, so "Hmssql.Decoding" and
-- "Hmssql.Tds.Scalar" refer to the constructors.  Without split sections an
-- object file is linked whole, and in "Hmssql.SqlType" those references
-- linked the type names, the catalog's type arguments and their instances
-- into every program: 57 KB of @.text@ and 71 KB in all (GHC 9.12.4,
-- 2026-11-08, docs/dev/performance-research.md, "The size breakdown").
module Hmssql.Internal.SqlDataType
  ( SqlDataType (..)
  , typeInfoDataType
  ) where

import qualified Data.Text as T

import Hmssql.Tds.TypeInfo

-- | Every data type SQL Server ships with, in the groups of its
-- documentation ('Hmssql.SqlType.dataTypeCategory').  The three CLR system
-- types are here because the catalog lists them; hmssql neither decodes nor
-- sends their values.  @float(n)@ is stored as @real@ or @float@, and @sysname@ is
-- @nvarchar(128)@: neither is a type of its own.
data SqlDataType
  -- Exact numerics
  = TyBit
  | TyTinyInt
  | TySmallInt
  | TyInt
  | TyBigInt
  | TyDecimal
  | TyNumeric
  | TyMoney
  | TySmallMoney
  -- Approximate numerics
  | TyFloat
  | TyReal
  -- Date and time
  | TyDate
  | TyTime
  | TyDateTime
  | TySmallDateTime
  | TyDateTime2
  | TyDateTimeOffset
  -- Character strings
  | TyChar
  | TyVarChar
  | TyText
  -- Unicode character strings
  | TyNChar
  | TyNVarChar
  | TyNText
  -- Binary strings
  | TyBinary
  | TyVarBinary
  | TyImage
  -- Other data types
  | TyUniqueIdentifier
  | TyRowVersion       -- ^ @rowversion@, which the catalog still calls @timestamp@
  | TyXml
  | TySqlVariant
  | TyJson             -- ^ SQL Server 2025
  | TyVector           -- ^ SQL Server 2025
  | TyHierarchyId      -- ^ a CLR system type
  | TyGeometry         -- ^ a CLR system type
  | TyGeography        -- ^ a CLR system type
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

-- | The data type a column or parameter of this wire type was declared
-- as, as far as the wire says: a @json@ column arrives as @nvarchar(max)@,
-- a @vector@ as @varchar@ and a @rowversion@ as @binary(8)@, and that is
-- what they come back as.  'Nothing' for 'TINull', for a CLR user-defined
-- type other than the three system ones, and for a width the wire doesn't
-- have (a @TIIntN 3@).
--
-- One case match, and the results are constants, so it costs nothing to
-- call per value: "Hmssql.Decoding" classifies columns with it, on every
-- row for a 'Hmssql.Decoding.RowDecoderMonadic'.
typeInfoDataType :: TypeInfo -> Maybe SqlDataType
typeInfoDataType = \case
  TINull -> Nothing
  TIBit -> Just TyBit
  TIInt1 -> Just TyTinyInt
  TIInt2 -> Just TySmallInt
  TIInt4 -> Just TyInt
  TIInt8 -> Just TyBigInt
  TIMoney4 -> Just TySmallMoney
  TIMoney8 -> Just TyMoney
  TIDateTime4 -> Just TySmallDateTime
  TIDateTime8 -> Just TyDateTime
  TIFlt4 -> Just TyReal
  TIFlt8 -> Just TyFloat
  TIBitN -> Just TyBit
  TIIntN 1 -> Just TyTinyInt
  TIIntN 2 -> Just TySmallInt
  TIIntN 4 -> Just TyInt
  TIIntN 8 -> Just TyBigInt
  TIIntN _ -> Nothing
  TIMoneyN 4 -> Just TySmallMoney
  TIMoneyN 8 -> Just TyMoney
  TIMoneyN _ -> Nothing
  TIDateTimeN 4 -> Just TySmallDateTime
  TIDateTimeN 8 -> Just TyDateTime
  TIDateTimeN _ -> Nothing
  TIFltN 4 -> Just TyReal
  TIFltN 8 -> Just TyFloat
  TIFltN _ -> Nothing
  TIGuid -> Just TyUniqueIdentifier
  TIDecimalN _ _ -> Just TyDecimal
  TINumericN _ _ -> Just TyNumeric
  TIDateN -> Just TyDate
  TITimeN _ -> Just TyTime
  TIDateTime2N _ -> Just TyDateTime2
  TIDateTimeOffsetN _ -> Just TyDateTimeOffset
  TIBigChar _ _ -> Just TyChar
  TIBigVarChar _ _ -> Just TyVarChar
  TIText _ _ -> Just TyText
  TINChar _ _ -> Just TyNChar
  TINVarChar _ _ -> Just TyNVarChar
  TINText _ _ -> Just TyNText
  TIBigBinary _ -> Just TyBinary
  TIBigVarBinary _ -> Just TyVarBinary
  TIImage _ -> Just TyImage
  TIXml _ -> Just TyXml
  TISqlVariant _ -> Just TySqlVariant
  TIUdt UdtInfo{..}
    | T.toLower udtSchemaName == "sys" -> case T.toLower udtTypeName of
        "hierarchyid" -> Just TyHierarchyId
        "geometry" -> Just TyGeometry
        "geography" -> Just TyGeography
        _ -> Nothing
    | otherwise -> Nothing
{-# INLINE typeInfoDataType #-}
