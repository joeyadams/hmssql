-- | The catalog check: will the target table take the source table's rows?
--
-- Both tables are read from their databases' catalogs ('Hmssql.Catalog'),
-- the columns are paired by name, and each pair gets a 'Verdict' before a
-- row is read.  The rules follow what the bulk load itself does with a
-- value ('Hmssql.BulkCopy.encodeBulkCell'), so the check refuses up front
-- what would fail on the first row anyway (a @varchar@ into an @int@, an
-- @int@ into a @varchar@, a @uniqueidentifier@ into a string), and lists
-- for the rest what each row is checked for: a string longer than the
-- target column, a number out of its range, a character its code page
-- lacks.  Those are refused per row, by the bulk load, on the client.
--
-- Kinds of value that convert:
--
-- * numbers to numbers (@bit@, the integers, @decimal@, @money@, @float@):
--   out of range refused, a fraction rounded or truncated;
-- * strings to strings (@char@, @varchar@, @nchar@, @nvarchar@, the old
--   @text@ types, @json@, and @xml@ in either direction): too long, or a
--   character outside a single-byte target's code page, refused;
-- * binary to binary (and @rowversion@ to @binary(8)@ or wider);
-- * dates and times between @date@, @datetime@, @smalldatetime@,
--   @datetime2@ and @datetimeoffset@ (a part dropped, or midnight or
--   offset zero supplied), and @time@ from a time or a date-time;
-- * anything but @xml@ into @sql_variant@.
--
-- Anything else is refused: convert it in the source query, or change the
-- target table.
module Copy.Check
  ( -- * Checking
    CheckOptions (..)
  , defaultCheckOptions
  , checkCopy
  , Plan (..)
  , planAccepted
  , Mapping (..)
  , Verdict (..)
  , typeVerdict

    -- * Reporting
  , renderPlan
  ) where

import Data.List (find)
import qualified Data.Set as Set
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T

import Hmssql.Catalog
import Hmssql.SqlType

-- | Which source columns to copy, and whether the target's identity
-- column may be given values.
data CheckOptions = CheckOptions
  { onlyColumns :: Maybe [Text]
    -- ^ Copy these source columns only (by default every column @SELECT *@
    -- returns).
  , skipColumns :: [Text]
    -- ^ Leave these source columns out.
  , keepIdentity :: Bool
    -- ^ Copy into the target's identity column (the bulk load's
    -- @KEEP_IDENTITY@) rather than refuse to.
  }
  deriving stock (Show)

defaultCheckOptions :: CheckOptions
defaultCheckOptions = CheckOptions { onlyColumns = Nothing, skipColumns = [], keepIdentity = False }

-- | Whether a target column takes a source column's values.
data Verdict
  = Identical
    -- ^ The same type: the values go as they are.
  | Fits
    -- ^ Another type that holds every value of the source's: @varchar(20)@
    -- into @nvarchar(40)@, @int@ into @bigint@, @datetime@ into
    -- @datetime2(3)@.
  | PerRow ![Text]
    -- ^ Converted row by row, and a value can be refused or changed as
    -- said: the load stops at a refused value.
  | Refused !Text
    -- ^ No value converts (or none would fit).
  deriving stock (Eq, Show)

-- | A source column and the target column of the same name.
data Mapping = Mapping
  { mapSource :: !Column
  , mapTarget :: !Column
  , mapVerdict :: !Verdict
  }
  deriving stock (Show)

-- | The outcome of the check.
data Plan = Plan
  { planSource :: !Table
  , planTarget :: !Table
  , planMappings :: ![Mapping]
    -- ^ In the source's column order: the columns the copy reads and
    -- sends.
  , planUnsent :: ![(Column, Text)]
    -- ^ The target's other columns, and what the rows get there.
  , planProblems :: ![Text]
    -- ^ What stops the copy besides the refused mappings.
  }
  deriving stock (Show)

-- | Whether the copy can go ahead: no problem, no refused column.
planAccepted :: Plan -> Bool
planAccepted p = null (planProblems p) && not (any (isRefused . mapVerdict) (planMappings p))
  where
    isRefused = \case
      Refused _ -> True
      _ -> False

-- | Pair the source's columns with the target's by name (ignoring case,
-- as a case-insensitive collation's catalog does) and judge each pair.
checkCopy :: CheckOptions -> Table -> Table -> Plan
checkCopy opts src tgt = Plan
  { planSource = src
  , planTarget = tgt
  , planMappings = mappings
  , planUnsent = [(t, what) | (t, Right what) <- unsent]
  , planProblems = concat
      [ ["the source has no column " <> n | n <- fromMaybe [] opts.onlyColumns ++ opts.skipColumns, isNothing (named n (tableColumns src))]
      , [ "the source column " <> colName s <> " has no column of that name in the target (leave it out with --skip " <> colName s <> ")"
        | (s, Nothing) <- pairs ]
      , [problem | (_, Left problem) <- unsent]
      , ["no column to copy" | null mappings]
      ]
  }
  where
    wanted c = maybe (not (colHidden c)) (any (sameName (colName c))) opts.onlyColumns
      && not (any (sameName (colName c)) opts.skipColumns)
    pairs = [(s, named (colName s) (tableColumns tgt)) | s <- tableColumns src, wanted s]
    mappings = [Mapping s t (columnVerdict opts s t) | (s, Just t) <- pairs]
    sent = Set.fromList [T.toCaseFold (colName (mapTarget m)) | m <- mappings]
    unsent = [(t, unsentValue t) | t <- tableColumns tgt, not (Set.member (T.toCaseFold (colName t)) sent)]

named :: Text -> [Column] -> Maybe Column
named n = find (sameName n . colName)

sameName :: Text -> Text -> Bool
sameName a b = T.toCaseFold a == T.toCaseFold b

-- | What a target column the copy doesn't send gets, or why it can't be
-- left out.
unsentValue :: Column -> Either Text Text
unsentValue t
  | Just c <- colComputed t = Right ("computed: " <> computedDefinition c)
  | isJust (colGenerated t) = Right "generated always"
  | isRowVersion t = Right "rowversion, set by the server"
  | colIdentity t = Right "identity, numbered by the target"
  | Just d <- colDefault t = Right ("default " <> d)
  | colNullable t = Right "NULL"
  | otherwise = Left $
      "the target column " <> colName t <> " is NOT NULL with no default, and the source has no column of that name"

isRowVersion :: Column -> Bool
isRowVersion c = (sqlDataType <$> colType c) == Just TyRowVersion

-- | The verdict for a pair: whether the target column can be inserted
-- into at all, then the types, then NULLs.
columnVerdict :: CheckOptions -> Column -> Column -> Verdict
columnVerdict opts s t
  | isJust (colComputed t) = Refused "the target column is computed"
  | isJust (colGenerated t) = Refused "the target column is generated always"
  | isRowVersion t = Refused "the target column is a rowversion, which the server sets"
  | colIdentity t && not opts.keepIdentity =
      Refused "the target column is an identity column: --keep-identity to copy the source's values, or --skip it to let the target number the rows"
  | otherwise = withNulls (typeVerdict s t)
  where
    withNulls v
      | colNullable s && not (colNullable t) = case v of
          Refused _ -> v
          PerRow notes -> PerRow (notes ++ [nullNote])
          _ -> PerRow [nullNote]
      | otherwise = v
    nullNote = "a NULL is refused (the target is NOT NULL)"

------------------------------------------------------------------------------
-- Types

-- | What kind of value a type holds, for which conversions exist.
data Kind
  = KNumber
  | KString
  | KXml
  | KJson
  | KBinary
  | KRowVersion
  | KDate
  | KTime
  | KDateTime
  | KDateTimeOffset
  | KGuid
  | KVariant
  | KOther  -- ^ @vector@ and the CLR types: copied only into their own type
  deriving stock (Eq, Show)

kindOf :: SqlDataType -> Kind
kindOf t = case t of
  TyChar -> KString
  TyVarChar -> KString
  TyText -> KString
  TyNChar -> KString
  TyNVarChar -> KString
  TyNText -> KString
  TyXml -> KXml
  TyJson -> KJson
  TyBinary -> KBinary
  TyVarBinary -> KBinary
  TyImage -> KBinary
  TyRowVersion -> KRowVersion
  TyDate -> KDate
  TyTime -> KTime
  TyDateTime -> KDateTime
  TySmallDateTime -> KDateTime
  TyDateTime2 -> KDateTime
  TyDateTimeOffset -> KDateTimeOffset
  TyUniqueIdentifier -> KGuid
  TySqlVariant -> KVariant
  _ | dataTypeCategory t `elem` [ExactNumeric, ApproximateNumeric] -> KNumber
    | otherwise -> KOther

kindName :: Kind -> Text
kindName = \case
  KNumber -> "number"
  KString -> "string"
  KXml -> "xml"
  KJson -> "json"
  KBinary -> "binary"
  KRowVersion -> "rowversion"
  KDate -> "date"
  KTime -> "time"
  KDateTime -> "date-time"
  KDateTimeOffset -> "datetimeoffset"
  KGuid -> "uniqueidentifier"
  KVariant -> "sql_variant"
  KOther -> "other"

-- | Whether the target column's type takes the source column's values,
-- ignoring nullability.
typeVerdict :: Column -> Column -> Verdict
typeVerdict s t = case (colType s, colType t) of
  (Just a, Just b)
    | a == b && (colCollation s == colCollation t || not (singleByte b)) -> Identical
    | otherwise -> conversion (a, colCollation s) (b, colCollation t)
  _ | colTypeName s == colTypeName t -> Identical
    | otherwise -> Refused ("a " <> colTypeName s <> " column can be copied only into a column of its own type")

conversion :: (SqlType, Maybe Text) -> (SqlType, Maybe Text) -> Verdict
conversion (a, ca) (b, cb) = case (kindOf (sqlDataType a), kindOf (sqlDataType b)) of
  (KNumber, KNumber) -> perRow (numberNotes a b)
  (ka, KString) | ka `elem` [KString, KXml, KJson] -> stringVerdict (a, ca) (b, cb)
  (ka, KJson) | ka `elem` [KString, KJson] -> PerRow ["a value that isn't valid JSON is refused by the server"]
  (KXml, KXml) -> perRow ["the target's XML schema collection is checked by the server" | sqlTypeArgs b /= NoArgs]
  (ka, KXml) | ka `elem` [KString, KJson] -> PerRow ["a value that isn't well-formed XML is refused by the server"]
  (KBinary, KBinary) -> binaryVerdict a b
  (KRowVersion, KBinary) -> binaryVerdict (SqlType TyBinary (LengthArg (Length 8))) b
  (ka, kb) | Just v <- temporal ka kb a b -> v
  (KGuid, KGuid) -> Identical
  (ka, KVariant)
    | ka `elem` [KXml, KJson, KOther] -> Refused ("a " <> sqlTypeName a <> " value can't be stored in a sql_variant")
    | ka == KVariant -> Identical
    | ka == KString -> PerRow ["stored as nvarchar; a string over 4000 characters is refused"]
    | ka == KBinary -> PerRow ["a value over 8000 bytes is refused"]
    | otherwise -> Fits
  (KOther, KOther) | sqlDataType a == sqlDataType b -> PerRow ["the server converts " <> sqlTypeName a <> " to " <> sqlTypeName b]
  (ka, kb) -> Refused $
    sqlTypeName a <> " can't be copied into " <> sqlTypeName b <> ": a " <> kindName ka <> " isn't a " <> kindName kb
      <> "; convert it in the source query, or change the target"

perRow :: [Text] -> Verdict
perRow [] = Fits
perRow notes = PerRow notes

------------------------------------------------------------------------------
-- Numbers

-- | The range of a numeric type, and how many decimal places it keeps
-- ('Nothing': a floating-point type, with significant digits instead).
data NumericRange = NumericRange
  { lo :: Rational
  , hi :: Rational
  , places :: Maybe Integer
  , digits :: Integer  -- ^ significant decimal digits it holds exactly
  }

numericRange :: SqlType -> NumericRange
numericRange (SqlType t args) = case t of
  TyBit -> NumericRange 0 1 (Just 0) 1
  TyTinyInt -> NumericRange 0 255 (Just 0) 3
  TySmallInt -> integer 16 5
  TyInt -> integer 32 10
  TyBigInt -> integer 64 19
  TyMoney -> NumericRange (-922337203685477.5808) 922337203685477.5807 (Just 4) 19
  TySmallMoney -> NumericRange (-214748.3648) 214748.3647 (Just 4) 10
  TyReal -> NumericRange (-3.40282347e38) 3.40282347e38 Nothing 7
  TyFloat -> NumericRange (-1.7976931348623157e308) 1.7976931348623157e308 Nothing 15
  _ -> case args of  -- decimal, numeric
    PrecisionScaleArg p s ->
      let p' = toInteger p; s' = toInteger s
          m = 10 ^ (p' - s') - 1 / 10 ^ s' :: Rational
       in NumericRange (negate m) m (Just s') p'
    _ -> NumericRange (-(10 ^ (38 :: Int))) (10 ^ (38 :: Int)) (Just 0) 38
  where
    integer :: Int -> Integer -> NumericRange
    integer bits d = NumericRange (negate (2 ^ (bits - 1))) (2 ^ (bits - 1) - 1) (Just 0) d

numberNotes :: SqlType -> SqlType -> [Text]
numberNotes a b
  | sqlDataType b == TyBit = ["a nonzero value is stored as 1" | sqlDataType a /= TyBit]
  | otherwise = concat
      [ ["a value outside the range of " <> sqlTypeName b <> " is refused" | lo ra < lo rb || hi ra > hi rb]
      , case (places ra, places rb) of
          (_, Nothing) -> ["rounded to " <> sqlTypeName b <> "'s " <> tshow (digits rb) <> " significant digits" | digits ra > digits rb]
          (Nothing, Just 0) -> ["the fraction is truncated"]
          (Nothing, Just n) -> ["rounded to " <> tshow n <> " decimal places"]
          (Just m, Just 0) | m > 0 -> ["the fraction is truncated"]
          (Just m, Just n) | m > n -> ["rounded to " <> tshow n <> " decimal places"]
          _ -> []
      ]
  where
    ra = numericRange a
    rb = numericRange b

------------------------------------------------------------------------------
-- Strings and binary

-- | A string type's length in characters (bytes for a single-byte type),
-- or 'Nothing' for @max@ and the unbounded types.
stringLength :: SqlType -> Maybe Int
stringLength (SqlType _ args) = case args of
  LengthArg (Length n) -> Just n
  _ -> Nothing

fixedLength :: SqlType -> Bool
fixedLength t = sqlDataType t `elem` [TyChar, TyNChar, TyBinary]

singleByte :: SqlType -> Bool
singleByte t = sqlDataType t `elem` [TyChar, TyVarChar, TyText]

stringVerdict :: (SqlType, Maybe Text) -> (SqlType, Maybe Text) -> Verdict
stringVerdict (a, ca) (b, cb) = case lengthVerdict "characters" a b of
  Left refusal -> Refused refusal
  Right lengthNotes -> perRow (lengthNotes ++ codePage ++ source)
  where
    codePage
      | not (singleByte b) = []
      | singleByte a && ca == cb = []
      | otherwise = ["a character outside the code page of " <> fromMaybe "the target's collation" cb <> " is refused"]
    source = case kindOf (sqlDataType a) of
      KXml -> ["the XML is copied as its text"]
      _ -> []

binaryVerdict :: SqlType -> SqlType -> Verdict
binaryVerdict a b = either Refused perRow (lengthVerdict "bytes" a b)

-- | Notes on a length that may not fit, or a refusal when no value can: a
-- fixed-length source (@char(20)@) pads every value to its length, so a
-- shorter target refuses them all.
lengthVerdict :: Text -> SqlType -> SqlType -> Either Text [Text]
lengthVerdict unit a b = case (stringLength a, stringLength b) of
  (Just n, Just m)
    | n <= m -> Right []
    | fixedLength a -> Left $
        "every " <> sqlTypeName a <> " value is " <> tshow n <> " " <> unit <> " (padded), longer than " <> sqlTypeName b <> " holds"
  (_, Just m) -> Right ["a value longer than " <> tshow m <> " " <> unit <> " is refused"]
  _ -> Right []

------------------------------------------------------------------------------
-- Dates and times

-- | The conversions between the date and time types, as the bulk load
-- makes them; 'Nothing' if neither kind is one.
temporal :: Kind -> Kind -> SqlType -> SqlType -> Maybe Verdict
temporal ka kb a b = case (ka, kb) of
  (KDate, KDate) -> Just Identical
  (KDate, KDateTime) -> Just (perRow range)
  (KDate, KDateTimeOffset) -> Just (PerRow ["at midnight, offset +00:00"])
  (KTime, KTime) -> Just (perRow precision)
  (KDateTime, KDateTime) -> Just (perRow (range ++ precision))
  (KDateTime, KDate) -> Just (PerRow ["the time of day is dropped"])
  (KDateTime, KTime) -> Just (perRow ("the date is dropped" : precision))
  (KDateTime, KDateTimeOffset) -> Just (perRow ("taken as UTC: offset +00:00" : precision))
  (KDateTimeOffset, KDateTimeOffset) -> Just (perRow precision)
  (KDateTimeOffset, KDateTime) -> Just (perRow ("the offset is dropped, keeping the local time" : range ++ precision))
  (KDateTimeOffset, KDate) -> Just (PerRow ["the local date is kept; the time and offset are dropped"])
  (KDateTimeOffset, KTime) -> Just (perRow ("the local time is kept; the date and offset are dropped" : precision))
  (KTime, _) | kb `elem` [KDate, KDateTime, KDateTimeOffset] -> Just refused
  (_, KTime) | ka == KDate -> Just refused
  _ -> Nothing
  where
    refused = Refused (sqlTypeName a <> " can't be copied into " <> sqlTypeName b <> ": a " <> kindName ka <> " has no " <> kindName kb)
    -- The dates each type holds.
    earliest = \case
      TySmallDateTime -> 1900 :: Int
      TyDateTime -> 1753
      _ -> 1
    range
      | earliest (sqlDataType b) > earliest (sqlDataType a) = case sqlDataType b of
          TySmallDateTime -> ["a date outside 1900-01-01 through 2079-06-06 is refused"]
          _ -> ["a date before " <> tshow (earliest (sqlDataType b)) <> "-01-01 is refused"]
      | sqlDataType b == TySmallDateTime && sqlDataType a /= TySmallDateTime = ["a date after 2079-06-06 is refused"]
      | otherwise = []
    -- Decimal places of the seconds: datetime's 1/300 s are about 3.
    fraction t = case t of
      SqlType TySmallDateTime _ -> 0
      SqlType TyDateTime _ -> 3
      SqlType TyDate _ -> 0
      SqlType _ (ScaleArg s) -> toInteger s
      _ -> 7
    precision
      | sqlDataType b == TySmallDateTime && sqlDataType a /= TySmallDateTime = ["rounded to the minute"]
      | sqlDataType b == TyDateTime && sqlDataType a /= TyDateTime && fraction a > 2 = ["rounded to datetime's 1/300 second"]
      | sqlDataType b /= TyDateTime && fraction a > fraction b = case fraction b of
          0 -> ["rounded to the second"]
          n -> ["rounded to " <> tshow n <> " decimal places of a second"]
      | otherwise = []

------------------------------------------------------------------------------
-- Reporting

-- | The plan as a table for the terminal, then the problems.
renderPlan :: Plan -> Text
renderPlan p = T.unlines $
  [ objectNameSql (tableName (planSource p)) <> " -> " <> objectNameSql (tableName (planTarget p)) ]
    ++ concatMap mapping (planMappings p)
    ++ concat
      [ "  not sent:" : ["    " <> pad nameWidth (colName t) <> "  " <> what | (t, what) <- planUnsent p]
      | not (null (planUnsent p)) ]
    ++ ["  problem: " <> problem | problem <- planProblems p]
    ++ [if planAccepted p then "accepted" else "refused"]
  where
    nameWidth = maximum (1 : map (T.length . colName) (concatMap (\m -> [mapSource m, mapTarget m]) (planMappings p) ++ map fst (planUnsent p)))
    typeWidth = maximum (1 : map (T.length . typeOf) (concatMap (\m -> [mapSource m, mapTarget m]) (planMappings p)))
    typeOf c = maybe (colTypeName c) sqlTypeName (colType c) <> (if colNullable c then "" else " not null")
    mapping m = case mapVerdict m of
      Identical -> [line "same type"]
      Fits -> [line "fits"]
      PerRow notes -> line "per row:" : ["      - " <> n | n <- notes]
      Refused why -> [line "REFUSED", "      " <> why]
      where
        line v = "  " <> pad nameWidth (colName (mapSource m)) <> "  " <> pad typeWidth (typeOf (mapSource m))
          <> "  -> " <> pad typeWidth (typeOf (mapTarget m)) <> "  " <> v
    pad n t = t <> T.replicate (n - T.length t) " "

tshow :: Show a => a -> Text
tshow = T.pack . show
