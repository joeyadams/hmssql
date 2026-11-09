{-# LANGUAGE MagicHash #-}
{-# LANGUAGE QualifiedDo #-}
-- | Server tokens expressed as sequential reading recipes.
module Hmssql.Tds.Token
  ( Token (..), ColumnInfo (..), columnIsNullable, columnIsLong
  , ResultSetInfo, rsColumns, rsColumnArray, rsColumnCount, rsCells, compileResultSet
  , tokenSizeLimit, lobAllocAhead
  , Done (..), doneMore, doneError, doneInTransaction, doneHasCount
  , doneAttention, doneServerError, EnvChange (..), RoutingInfo (..)
  , ServerMessage (..), LoginAck (..), ReturnValue (..), FeatureAck (..)
  , readToken, readTokenWith, readTokenSkipping, doneOf, isFinalDone, failedDoneOf
  ) where

import Control.Monad (unless, when)
import Data.Bits (testBit, (.&.))
import qualified Data.ByteString as B
import Data.Int (Int32)
import Data.Primitive.SmallArray (SmallArray, smallArrayFromList, sizeofSmallArray)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word (Word8, Word16, Word32, Word64)
import Text.Printf (printf)
import GHC.Exts (noinline)
import Hmssql.Internal.Derived
import Hmssql.Tds.Context
import Hmssql.Tds.TypeInfo
import qualified Hmssql.Tds.Parser as P
import qualified Hmssql.Tds.Parser.OutOfLine as O
import qualified Hmssql.Tds.Value as V

-- | A column of a result set, as its COLMETADATA describes it.
data ColumnInfo = ColumnInfo
  { columnName :: !Text
    -- ^ The name, or empty for an unnamed expression.
  , columnType :: !TypeInfo
    -- ^ The wire type; 'Hmssql.SqlType.columnSqlType' names the SQL type.
  , columnFlags :: !Word16
    -- ^ MS-TDS 2.2.7.4 Flags: nullable ('columnIsNullable'),
    -- identity, updatable and the rest.
  , columnUserType :: !Word32
    -- ^ The @UserType@ field: 0x50 for @rowversion@, greater than 0xFF
    -- for alias types, and 0 for other types. An alias ID does not carry
    -- its name; 'columnType' describes its underlying storage type.
  , columnTableName :: !(Maybe [Text])
    -- ^ Only present for @text@, @ntext@ and @image@ columns.
  }

instance Show ColumnInfo where
  showsPrec p (ColumnInfo a b c e f) = showRecord p "ColumnInfo"#
    [ "columnName"# := a, "columnType"# := b, "columnFlags"# := c, "columnUserType"# := e
    , "columnTableName"# := f
    ]
  {-# OPAQUE showsPrec #-}

instance Eq ColumnInfo where
  ColumnInfo a b c e f == ColumnInfo a' b' c' e' f' =
    eq a a' && eq b b' && c == c' && e == e' && eq f f'
  {-# OPAQUE (==) #-}

-- | Whether the column may hold NULL.
columnIsNullable :: ColumnInfo -> Bool
columnIsNullable c = columnFlags c .&. 0x0001 /= 0

-- | Whether a column's values may be of any length: a @max@ type, @xml@, @json@, a
-- CLR type, or a legacy @text@, @ntext@ or @image@, which arrive in pieces rather
-- than behind a length of at most 8,000 bytes.  Such a column is the one to read
-- with a 'Hmssql.Decoding.FoldingCell' or 'Hmssql.Decoding.streamField'.
columnIsLong :: ColumnInfo -> Bool
columnIsLong c = case lengthKind (columnType c) of
  Plp -> True
  LongLen -> True
  _ -> False

-- | A result set's columns, prepared once for the rows that follow.
data ResultSetInfo = ResultSetInfo
  { rsColumns :: ![ColumnInfo]
    -- ^ The columns, in order.
  , rsColumnArray :: !(SmallArray ColumnInfo)
    -- ^ The same, for indexing.
  , rsCells :: ![(Int, V.ColumnShape)]
    -- ^ Each column's index, and how its values are delimited.
  }

-- | How many columns the result set has.
rsColumnCount :: ResultSetInfo -> Int
rsColumnCount = sizeofSmallArray . rsColumnArray

-- | Prepare a result set's columns for its rows.
compileResultSet :: [ColumnInfo] -> ResultSetInfo
compileResultSet cols = ResultSetInfo cols (smallArrayFromList cols) (zip [0 ..] (map (V.rowShape . columnType) cols))

-- | Maximum size of metadata tokens, which must not buffer unbounded input.
-- Rows and output parameter values aren't bound by it: they cost their size.
tokenSizeLimit :: Int
tokenSizeLimit = 16 * 1024 * 1024

-- | Default maximum allocation ahead of received value bytes.  A server that
-- declares a value it doesn't send costs this much, not what it declared.
lobAllocAhead :: Int
lobAllocAhead = 1024 * 1024

-- | A DONE, DONEPROC or DONEINPROC token: its status bits, which 'doneMore'
-- and the functions beside it read, the current command, and the row count.
data Done = Done
  { doneStatus :: !Word16
  , doneCurCmd :: !Word16
  , doneRowCount :: !Word64
    -- ^ Only meaningful when 'doneHasCount'.
  }

instance Show Done where
  showsPrec p (Done a b c) =
    showRecord p "Done"# ["doneStatus"# := a, "doneCurCmd"# := b, "doneRowCount"# := c]
  {-# OPAQUE showsPrec #-}

instance Eq Done where
  Done a b c == Done a' b' c' = a == a' && b == b' && c == c'
  {-# OPAQUE (==) #-}

-- | The status bits: more results follow; the statement failed; a transaction
-- is open; the row count is meaningful; the statement was canceled by an
-- Attention; and the server failed the request.
doneMore, doneError, doneInTransaction, doneHasCount, doneAttention, doneServerError :: Done -> Bool
doneMore d = testBit (doneStatus d) 0
doneError d = testBit (doneStatus d) 1
doneInTransaction d = testBit (doneStatus d) 2
doneHasCount d = testBit (doneStatus d) 4
doneAttention d = testBit (doneStatus d) 5
doneServerError d = testBit (doneStatus d) 8

-- | Where a routing ENVCHANGE sends the login: the protocol (0 is TCP), the
-- port and the server.
data RoutingInfo = RoutingInfo
  { routingProtocol :: !Word8
  , routingPort :: !Word16
  , routingServer :: !Text
  }

instance Show RoutingInfo where
  showsPrec p (RoutingInfo a b c) = showRecord p "RoutingInfo"#
    [ "routingProtocol"# := a, "routingPort"# := b, "routingServer"# := c ]
  {-# OPAQUE showsPrec #-}

instance Eq RoutingInfo where
  RoutingInfo a b c == RoutingInfo a' b' c' = a == a' && b == b' && eq c c'
  {-# OPAQUE (==) #-}

-- | An ENVCHANGE token: what changed in the session, with the old and the new
-- value where the token carries both.
data EnvChange
  = ECDatabase { oldValue :: !Text, newValue :: !Text }
  | ECLanguage { oldValue :: !Text, newValue :: !Text }
  | ECCharacterSet { oldValue :: !Text, newValue :: !Text }
  | ECPacketSize { oldSize :: !Word32, newSize :: !Word32 }
  | ECUnicodeSortingLocale { newValue :: !Text }
  | ECUnicodeComparisonFlags { newValue :: !Text }
  | ECSqlCollation { oldBytes :: !B.ByteString, newBytes :: !B.ByteString }
  | ECBeginTransaction { transaction :: !TransactionDescriptor }
  | ECCommitTransaction { transaction :: !TransactionDescriptor }
  | ECRollbackTransaction { transaction :: !TransactionDescriptor }
  | ECEnlistDtcTransaction { transaction :: !TransactionDescriptor }
  | ECDefectTransaction { transaction :: !TransactionDescriptor }
  | ECMirroringPartner { newValue :: !Text }
  | ECPromoteTransaction { dtcToken :: !B.ByteString }
  | ECTransactionManagerAddress { newBytes :: !B.ByteString }
  | ECTransactionEnded { transaction :: !TransactionDescriptor }
  | ECResetConnectionAck
  | ECUserInstance { newValue :: !Text }
  | ECRouting { routing :: !RoutingInfo }
  | ECUnknown { envChangeType :: !Word8, payload :: !B.ByteString }

instance Show EnvChange where
  showsPrec p = \case
    ECDatabase a b -> showRecord p "ECDatabase"# ["oldValue"# := a, "newValue"# := b]
    ECLanguage a b -> showRecord p "ECLanguage"# ["oldValue"# := a, "newValue"# := b]
    ECCharacterSet a b -> showRecord p "ECCharacterSet"# ["oldValue"# := a, "newValue"# := b]
    ECPacketSize a b -> showRecord p "ECPacketSize"# ["oldSize"# := a, "newSize"# := b]
    ECUnicodeSortingLocale a -> showRecord p "ECUnicodeSortingLocale"# ["newValue"# := a]
    ECUnicodeComparisonFlags a ->
      showRecord p "ECUnicodeComparisonFlags"# ["newValue"# := a]
    ECSqlCollation a b -> showRecord p "ECSqlCollation"# ["oldBytes"# := a, "newBytes"# := b]
    ECBeginTransaction a -> showRecord p "ECBeginTransaction"# ["transaction"# := a]
    ECCommitTransaction a -> showRecord p "ECCommitTransaction"# ["transaction"# := a]
    ECRollbackTransaction a -> showRecord p "ECRollbackTransaction"# ["transaction"# := a]
    ECEnlistDtcTransaction a -> showRecord p "ECEnlistDtcTransaction"# ["transaction"# := a]
    ECDefectTransaction a -> showRecord p "ECDefectTransaction"# ["transaction"# := a]
    ECMirroringPartner a -> showRecord p "ECMirroringPartner"# ["newValue"# := a]
    ECPromoteTransaction a -> showRecord p "ECPromoteTransaction"# ["dtcToken"# := a]
    ECTransactionManagerAddress a ->
      showRecord p "ECTransactionManagerAddress"# ["newBytes"# := a]
    ECTransactionEnded a -> showRecord p "ECTransactionEnded"# ["transaction"# := a]
    ECResetConnectionAck -> showString "ECResetConnectionAck"
    ECUserInstance a -> showRecord p "ECUserInstance"# ["newValue"# := a]
    ECRouting a -> showRecord p "ECRouting"# ["routing"# := a]
    ECUnknown a b -> showRecord p "ECUnknown"# ["envChangeType"# := a, "payload"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq EnvChange where
  x == y = case (x, y) of
    (ECDatabase a b, ECDatabase a' b') -> eq a a' && eq b b'
    (ECLanguage a b, ECLanguage a' b') -> eq a a' && eq b b'
    (ECCharacterSet a b, ECCharacterSet a' b') -> eq a a' && eq b b'
    (ECPacketSize a b, ECPacketSize a' b') -> a == a' && b == b'
    (ECUnicodeSortingLocale a, ECUnicodeSortingLocale a') -> eq a a'
    (ECUnicodeComparisonFlags a, ECUnicodeComparisonFlags a') -> eq a a'
    (ECSqlCollation a b, ECSqlCollation a' b') -> eq a a' && eq b b'
    (ECBeginTransaction a, ECBeginTransaction a') -> eq a a'
    (ECCommitTransaction a, ECCommitTransaction a') -> eq a a'
    (ECRollbackTransaction a, ECRollbackTransaction a') -> eq a a'
    (ECEnlistDtcTransaction a, ECEnlistDtcTransaction a') -> eq a a'
    (ECDefectTransaction a, ECDefectTransaction a') -> eq a a'
    (ECMirroringPartner a, ECMirroringPartner a') -> eq a a'
    (ECPromoteTransaction a, ECPromoteTransaction a') -> eq a a'
    (ECTransactionManagerAddress a, ECTransactionManagerAddress a') -> eq a a'
    (ECTransactionEnded a, ECTransactionEnded a') -> eq a a'
    (ECResetConnectionAck, ECResetConnectionAck) -> True
    (ECUserInstance a, ECUserInstance a') -> eq a a'
    (ECRouting a, ECRouting a') -> eq a a'
    (ECUnknown a b, ECUnknown a' b') -> a == a' && eq b b'
    _ -> False
  {-# OPAQUE (==) #-}

-- | A message from the server: an error ('Hmssql.Errors.SqlServerError')
-- or an informational message (@PRINT@ output, a low-severity message;
-- 'Hmssql.Connection.connectOnInfoMessage').
data ServerMessage = ServerMessage
  { msgNumber :: !Int32
    -- ^ The error number (@ERROR_NUMBER()@, @sys.messages@).
  , msgState :: !Word8
    -- ^ The state, which distinguishes the places one error is raised
    -- from.
  , msgClass :: !Word8
    -- ^ Severity. Values above 10 are errors; 20 and above close the
    -- connection.
  , msgText :: !Text
  , msgServer :: !Text
    -- ^ The server's name (@\@\@SERVERNAME@).
  , msgProcedure :: !Text
    -- ^ The procedure the message was raised in, or empty.
  , msgLine :: !Int32
    -- ^ The line in the batch or procedure.
  }

instance Show ServerMessage where
  showsPrec p (ServerMessage a b c e f g h) = showRecord p "ServerMessage"#
    [ "msgNumber"# := a, "msgState"# := b, "msgClass"# := c, "msgText"# := e, "msgServer"# := f
    , "msgProcedure"# := g, "msgLine"# := h
    ]
  {-# OPAQUE showsPrec #-}

instance Eq ServerMessage where
  ServerMessage a b c e f g h == ServerMessage a' b' c' e' f' g' h' =
    a == a' && b == b' && c == c' && eq e e' && eq f f' && eq g g' && h == h'
  {-# OPAQUE (==) #-}

-- | The LOGINACK token: the interface, the TDS version the server chose, and
-- the server's name and version.
data LoginAck = LoginAck
  { laInterface :: !Word8
  , laTdsVersion :: !Word32
  , laProgName :: !Text
  , laProgVersion :: !(Word8, Word8, Word8, Word8)
  }

instance Show LoginAck where
  showsPrec p (LoginAck a b c e) = showRecord p "LoginAck"#
    [ "laInterface"# := a, "laTdsVersion"# := b, "laProgName"# := c, "laProgVersion"# := e ]
  {-# OPAQUE showsPrec #-}

instance Eq LoginAck where
  LoginAck a b c e == LoginAck a' b' c' e' = a == a' && b == b' && eq c c' && eq e e'
  {-# OPAQUE (==) #-}

-- | A RETURNVALUE token: an output parameter's value, or a function's return
-- value, after a call.
data ReturnValue = ReturnValue
  { rvOrdinal :: !Word16
  , rvName :: !Text
  , rvStatus :: !Word8
  , rvUserType :: !Word32
  , rvFlags :: !Word16
  , rvType :: !TypeInfo
  , rvValue :: !RawBytes
  }

instance Show ReturnValue where
  showsPrec p (ReturnValue a b c e f g h) = showRecord p "ReturnValue"#
    [ "rvOrdinal"# := a, "rvName"# := b, "rvStatus"# := c, "rvUserType"# := e, "rvFlags"# := f
    , "rvType"# := g, "rvValue"# := h
    ]
  {-# OPAQUE showsPrec #-}

instance Eq ReturnValue where
  ReturnValue a b c e f g h == ReturnValue a' b' c' e' f' g' h' =
    a == a' && eq b b' && c == c' && e == e' && f == f' && eq g g' && eq h h'
  {-# OPAQUE (==) #-}

-- | One acknowledgment of a LOGIN7 feature extension, from a FEATUREEXTACK
-- token.
data FeatureAck = FeatureAck
  { featureId :: !Word8
  , featureData :: !B.ByteString
  }

instance Show FeatureAck where
  showsPrec p (FeatureAck a b) =
    showRecord p "FeatureAck"# ["featureId"# := a, "featureData"# := b]
  {-# OPAQUE showsPrec #-}

instance Eq FeatureAck where
  FeatureAck a b == FeatureAck a' b' = a == a' && eq b b'
  {-# OPAQUE (==) #-}

-- | A token of a response, as 'readToken' reads it.
data Token
  = TColMetaData ![ColumnInfo]        -- ^ 0x81; empty when the server reports no columns
  | TRow !V.Row                         -- ^ 0xD1 ROW or 0xD2 NBCROW; see "Hmssql.Tds.Value"
  | TDone !Done                       -- ^ 0xFD
  | TDoneProc !Done                   -- ^ 0xFE
  | TDoneInProc !Done                 -- ^ 0xFF
  | TEnvChange !EnvChange             -- ^ 0xE3
  | TError !ServerMessage             -- ^ 0xAA
  | TInfo !ServerMessage              -- ^ 0xAB
  | TLoginAck !LoginAck               -- ^ 0xAD
  | TReturnStatus !Int32              -- ^ 0x79
  | TReturnValue !ReturnValue         -- ^ 0xAC
  | TOrder ![Word16]                  -- ^ 0xA9
  | TColInfo !B.ByteString            -- ^ 0xA5, undecoded
  | TTabName !B.ByteString            -- ^ 0xA4, undecoded
  | TFeatureExtAck ![FeatureAck]      -- ^ 0xAE
  | TSessionState !B.ByteString       -- ^ 0xE4, undecoded
  | TFedAuthInfo !B.ByteString        -- ^ 0xEE, undecoded
  | TSspi !B.ByteString               -- ^ 0xED
  | TOffset !Word16 !Word16           -- ^ 0x78

instance Show Token where
  showsPrec p = \case
    TColMetaData a -> showCon1 p "TColMetaData"# a
    TRow a -> showCon1 p "TRow"# a
    TDone a -> showCon1 p "TDone"# a
    TDoneProc a -> showCon1 p "TDoneProc"# a
    TDoneInProc a -> showCon1 p "TDoneInProc"# a
    TEnvChange a -> showCon1 p "TEnvChange"# a
    TError a -> showCon1 p "TError"# a
    TInfo a -> showCon1 p "TInfo"# a
    TLoginAck a -> showCon1 p "TLoginAck"# a
    TReturnStatus a -> showCon1 p "TReturnStatus"# a
    TReturnValue a -> showCon1 p "TReturnValue"# a
    TOrder a -> showCon1 p "TOrder"# a
    TColInfo a -> showCon1 p "TColInfo"# a
    TTabName a -> showCon1 p "TTabName"# a
    TFeatureExtAck a -> showCon1 p "TFeatureExtAck"# a
    TSessionState a -> showCon1 p "TSessionState"# a
    TFedAuthInfo a -> showCon1 p "TFedAuthInfo"# a
    TSspi a -> showCon1 p "TSspi"# a
    TOffset a b -> showCon p "TOffset"# [Arg a, Arg b]
  {-# OPAQUE showsPrec #-}

instance Eq Token where
  x == y = case (x, y) of
    (TColMetaData a, TColMetaData a') -> eq a a'
    (TRow a, TRow a') -> eq a a'
    (TDone a, TDone a') -> eq a a'
    (TDoneProc a, TDoneProc a') -> eq a a'
    (TDoneInProc a, TDoneInProc a') -> eq a a'
    (TEnvChange a, TEnvChange a') -> eq a a'
    (TError a, TError a') -> eq a a'
    (TInfo a, TInfo a') -> eq a a'
    (TLoginAck a, TLoginAck a') -> eq a a'
    (TReturnStatus a, TReturnStatus a') -> a == a'
    (TReturnValue a, TReturnValue a') -> eq a a'
    (TOrder a, TOrder a') -> eq a a'
    (TColInfo a, TColInfo a') -> eq a a'
    (TTabName a, TTabName a') -> eq a a'
    (TFeatureExtAck a, TFeatureExtAck a') -> eq a a'
    (TSessionState a, TSessionState a') -> eq a a'
    (TFedAuthInfo a, TFedAuthInfo a') -> eq a a'
    (TSspi a, TSspi a') -> eq a a'
    (TOffset a b, TOffset a' b') -> a == a' && b == b'
    _ -> False
  {-# OPAQUE (==) #-}

-- | The DONE, DONEPROC or DONEINPROC a token is, if it is flagged as
-- failed (DONE_ERROR or DONE_SRVERROR).  In a response with no ERROR token
-- that is all the server says of a failed request
-- ('Hmssql.Errors.SevereError').
doneOf :: Token -> Maybe Done
doneOf (TDone d) = Just d
doneOf (TDoneProc d) = Just d
doneOf (TDoneInProc d) = Just d
doneOf _ = Nothing

failedDoneOf :: Token -> Maybe Done
failedDoneOf token = case doneOf token of
  Just d | doneError d || doneServerError d -> Just d
  _ -> Nothing

-- | A DONE-family token without MORE ends the response.
isFinalDone :: Token -> Bool
isFinalDone = maybe False (not . doneMore) . doneOf

-- | One token as a recipe, given the current result set's columns.  It reads
-- from the parser's input and suspends when that runs out, so nothing here knows
-- about packets, sessions or the end of a message.
readToken :: Maybe ResultSetInfo -> P.Parser Token
readToken = readTokenWith lobAllocAhead

-- | 'readToken' with the bound on allocating ahead of a value's bytes.
readTokenWith :: Int -> Maybe ResultSetInfo -> P.Parser Token
readTokenWith ahead = tokenWith (AssembleValues ahead)

-- | 'readToken' for a drain, which skips values rather than assembling them.
readTokenSkipping :: Maybe ResultSetInfo -> P.Parser Token
readTokenSkipping = tokenWith SkipValues

-- Whether values become bytes or are read past.  One definition of each wire form
-- serves ordinary reads and drains; a drain just asks for less.
data ValueMode = AssembleValues !Int | SkipValues

-- The rows are the tokens that come by the thousand, so 'tokenWith' reads the token
-- byte and the ROW and NBCROW bodies with the inlined binds, and everything else is
-- 'otherToken', a call.  With every token in the one case, each token, a row
-- included, allocated the closures of the other tokens' alternatives (the value
-- continuation of RETURNVALUE among them), because they were let-bound around the
-- continuation of the token byte; and RETURNVALUE's value read, a whole 'V.cellHead',
-- was inlined into that continuation.  Split, a row token allocates 96 bytes less
-- (Decode's token benchmarks, 2026-11-04).  Putting the case on the columns before
-- the bind, with NBCROW's body out of line, allocated 16 bytes more per ROW and 56
-- more per NBCROW, because the NBCROW recipe was then a thunk per token.
tokenWith :: ValueMode -> Maybe ResultSetInfo -> P.Parser Token
tokenWith mode currentColumns = P.word8 >>= \case
  0xD1 -> withColumns (readRowBody mode B.empty)
  0xD2 -> withColumns (readNbcRow mode)
  code -> otherToken mode code
  where
    withColumns k = case currentColumns of
      Nothing -> fail "readToken: ROW token received before COLMETADATA"
      Just cols -> k cols

readNbcRow :: ValueMode -> ResultSetInfo -> P.Parser Token
readNbcRow mode info = do
  bitmap <- P.boundedBytes ((rsColumnCount info + 7) `div` 8)
  readRowBody mode bitmap info

-- Only 'TRow' readers come here, not typed rows.  A value can turn out
-- discarded when a drain takes over a row already being read, and the later
-- cells are then skipped; the drain doesn't look at the short row it gets.
--
-- 'go' builds the rest of the row's recipe as it reads, and each step runs once, so
-- it is a 'P.oneShotRecipe'.  Without it, GHC gave 'go' arity 2: each cell built a
-- thunk of its delimiter's recipe, two thunks of the rest of the row, and the bind's
-- continuations, and then ran them.  Measured on 2026-11-04 with GHC 9.12.4: about
-- 390 bytes less per row of two columns (Decode int bigint x10000.tokens 13,795,596
-- bytes to 9,881,849, nullable no NULL ROW of five 28,927,504 to 21,255,502), and the
-- Decode token benchmarks of 10,000 rows 0.64 to 0.73 in time against 997107d.
readRowBody :: ValueMode -> B.ByteString -> ResultSetInfo -> P.Parser Token
readRowBody mode bitmap info = TRow . V.rowFromValues <$> go (case mode of SkipValues -> True; _ -> False) (rsCells info)
  where
    go _ [] = pure []
    go discarding ((i, shape) : later) = P.oneShotRecipe $ do
      cell <- V.cellAt bitmap i shape
      if discarding then V.skipValue cell >> go True later else do
        value <- V.wholeValueBytes (case mode of AssembleValues ahead -> ahead; SkipValues -> 0) cell
        case value of
          V.DiscardedValue -> go True later
          V.NullValue -> (Nothing :) <$> go False later
          V.PresentValue bytes -> (Just (P.keepBytes bytes) :) <$> go False later

-- | Every token but the rows, after its token byte.
otherToken :: ValueMode -> Word8 -> P.Parser Token
otherToken mode = \case
  0x81 -> TColMetaData O.<$> readColMetaData
  0xFD -> TDone O.<$> readDone
  0xFE -> TDoneProc O.<$> readDone
  0xFF -> TDoneInProc O.<$> readDone
  0xE3 -> TEnvChange O.<$> readEnvChange
  0xAA -> TError O.<$> readServerMessage
  0xAB -> TInfo O.<$> readServerMessage
  0xAD -> TLoginAck O.<$> readLoginAck
  0x79 -> TReturnStatus O.<$> (fromIntegral O.<$> O.word32le)
  0xAC -> TReturnValue O.<$> readReturnValue mode
  0xA9 -> O.do
    -- A USHORT column number per ORDER BY column.
    len <- O.word16le
    when (odd len) $ fail $ "readToken: ORDER token of odd length " ++ show len
    TOrder O.<$> P.count (fromIntegral len `div` 2) O.word16le
  0xA5 -> TColInfo O.<$> lengthPrefixed16
  0xA4 -> TTabName O.<$> lengthPrefixed16
  0xAE -> TFeatureExtAck O.<$> readFeatureExtAck
  0xE4 -> TSessionState O.<$> lengthPrefixed32
  0xEE -> TFedAuthInfo O.<$> lengthPrefixed32
  0xED -> TSspi O.<$> lengthPrefixed16
  0x78 -> TOffset O.<$> O.word16le O.<*> O.word16le
  0x88 -> fail "readToken: ALTMETADATA (COMPUTE BY) is not supported"
  0xD3 -> fail "readToken: ALTROW (COMPUTE BY) is not supported"
  code -> fail $ "readToken: unknown token 0x" ++ printf "%02x" code
  where
    lengthPrefixed16 = O.word16le O.>>= (P.ownedBytes lobAllocAhead) . fromIntegral
    lengthPrefixed32 = O.word32le O.>>= (P.ownedBytes lobAllocAhead) . fromIntegral
{-# NOINLINE otherToken #-}

readColMetaData :: P.Parser [ColumnInfo]
readColMetaData = O.do
  count <- O.word16le
  if count == 0xFFFF
    then pure []
    else P.count (fromIntegral count) $ O.do
      columnUserType <- O.word32le
      columnFlags <- O.word16le
      columnType <- readTypeInfo
      columnTableName <- case columnType of
        TIText{} -> Just O.<$> getMultiPartName
        TINText{} -> Just O.<$> getMultiPartName
        TIImage{} -> Just O.<$> getMultiPartName
        _ -> pure Nothing
      columnName <- P.bVarChar
      pure ColumnInfo{..}
  where
    getMultiPartName = O.do
      parts <- O.word8
      P.count (fromIntegral parts) P.usVarChar

readDone :: P.Parser Done
readDone = Done O.<$> O.word16le O.<*> O.word16le O.<*> O.word64le

-- 'P.isolate' takes the token's declared length as a sub-envelope, so its fields
-- can't read past it and leftover bytes are an error.  'P.limited' (which the
-- driver puts around metadata tokens) is different: it bounds what is received,
-- for tokens with no length of their own such as COLMETADATA.
readServerMessage :: P.Parser ServerMessage
readServerMessage = O.do
  len <- O.word16le
  P.isolate (fromIntegral len) $
    ServerMessage
      O.<$> (fromIntegral O.<$> O.word32le)
      O.<*> O.word8
      O.<*> O.word8
      O.<*> P.usVarChar
      O.<*> P.bVarChar
      O.<*> P.bVarChar
      O.<*> (fromIntegral O.<$> O.word32le)

readLoginAck :: P.Parser LoginAck
readLoginAck = O.do
  len <- O.word16le
  P.isolate (fromIntegral len) $ O.do
    laInterface <- O.word8
    laTdsVersion <- O.word32be
    -- SQL Server pads the name with NULs ("Microsoft SQL Server\0\0\0\0").
    laProgName <- T.dropWhileEnd (== '\0') O.<$> P.bVarChar
    laProgVersion <- (,,,) O.<$> O.word8 O.<*> O.word8 O.<*> O.word8 O.<*> O.word8
    pure LoginAck{..}

-- The value of an output parameter is read by the same value recipes as a column,
-- in the RETURNVALUE form, which has no text pointer ('V.valueShape').
readReturnValue :: ValueMode -> P.Parser ReturnValue
readReturnValue mode = O.do
  rv <- readReturnValueHead
  v <- readValue mode (rvType rv)
  pure rv { rvValue = v }

-- | A RETURNVALUE token after its token byte, up to its value ('rvValue'
-- is left 'Nothing').
readReturnValueHead :: P.Parser ReturnValue
readReturnValueHead = O.do
  rvOrdinal <- O.word16le
  rvName <- P.bVarChar
  rvStatus <- O.word8
  rvUserType <- O.word32le
  rvFlags <- O.word16le
  rvType <- readTypeInfo
  pure ReturnValue{rvValue = Nothing, ..}

readFeatureExtAck :: P.Parser [FeatureAck]
readFeatureExtAck = go []
  where
    go features = O.do
      fid <- O.word8
      if fid == 0xFF then pure (reverse features) else O.do
        len <- O.word32le
        dat <- P.ownedBytes lobAllocAhead (fromIntegral len)
        go (FeatureAck fid dat : features)

-- | [MS-TDS 2.2.7.9 ENVCHANGE](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-tds/2b3eb7e5-d43d-4d1b-bf4d-76b9e3afc791).
-- The wire order is type, new value, old value.
readEnvChange :: P.Parser EnvChange
readEnvChange = O.do
  len <- O.word16le
  when (len == 0) $ fail "readEnvChange: empty ENVCHANGE"
  ty <- P.peekWord8
  if ty == 15 && len == 1
    -- The server reports the length of Promote Transaction as 1 (just the
    -- type byte); the client has to read the rest itself.
    then P.skip 1 O.>> readEnvValue ty (fromIntegral len)
    else P.isolate (fromIntegral len) (P.skip 1 O.>> readEnvValue ty (fromIntegral len))

readEnvValue :: Word8 -> Int -> P.Parser EnvChange
readEnvValue ty len = case ty of
  1 -> newThenOld ECDatabase P.bVarChar
  2 -> newThenOld ECLanguage P.bVarChar
  3 -> newThenOld ECCharacterSet P.bVarChar
  4 -> O.do
    new <- P.bVarChar O.>>= readNumber
    old <- P.bVarChar O.>>= readNumber
    -- Framing requests with a size outside this range would loop (below
    -- the header size) or truncate the 16-bit packet length (above 64 KiB).
    unless (new >= toInteger minPacketSize && new <= toInteger maxPacketSize) $
      fail $ "readEnvChange: packet size " ++ show new ++ " is outside the range "
        ++ show minPacketSize ++ ".." ++ show maxPacketSize
    -- The old value is whatever LOGIN7 asked for, which is any DWORD.
    unless (old <= toInteger (maxBound :: Word32)) $
      fail $ "readEnvChange: old packet size " ++ show old ++ " is out of range"
    pure $ ECPacketSize (fromInteger old) (fromInteger new)
  5 -> newOnly ECUnicodeSortingLocale P.bVarChar
  6 -> newOnly ECUnicodeComparisonFlags P.bVarChar
  7 -> newThenOld ECSqlCollation readBVarByte
  8 -> txn ECBeginTransaction
  9 -> txn ECCommitTransaction
  10 -> txn ECRollbackTransaction
  11 -> txn ECEnlistDtcTransaction
  12 -> txn ECDefectTransaction
  13 -> newOnly ECMirroringPartner P.bVarChar
  15 -> newOnly ECPromoteTransaction (O.word32le O.>>= (P.ownedBytes lobAllocAhead) . fromIntegral)
  16 -> newOnly ECTransactionManagerAddress readBVarByte
  17 -> txn ECTransactionEnded
  18 -> ECResetConnectionAck O.<$ (expectEmpty O.>> expectEmpty)
  19 -> newOnly ECUserInstance P.bVarChar
  20 -> O.do
    -- NEWVALUE is RoutingData (a USHORT length, then protocol, port and
    -- server name); OLDVALUE is two zero bytes.
    n <- O.word16le
    when (n == 0) $ fail "readEnvChange: routing ENVCHANGE without routing data"
    info <- P.isolate (fromIntegral n) $
      RoutingInfo O.<$> O.word8 O.<*> O.word16le O.<*> P.usVarChar
    old <- O.word16le
    unless (old == 0) $ fail "readEnvChange: expected empty old value in routing ENVCHANGE"
    pure $ ECRouting info
  _ -> ECUnknown ty O.<$> (P.ownedBytes lobAllocAhead) (len - 1)
  where
    newThenOld f g = O.do { new <- g; old <- g; pure (f old new) }
    newOnly f g = O.do { v <- g; expectEmpty; pure (f v) }
    expectEmpty = O.do
      n <- O.word8
      unless (n == 0) $ fail $ "readEnvChange: expected empty value in type " ++ show ty
    -- The spec's table and its notes disagree about which side carries the
    -- descriptor for types 11, 12 and 17, so (like Microsoft's drivers)
    -- accept it on either side.
    txn f = O.do
      new <- txnValue
      old <- txnValue
      case (new, old) of
        (Just d, _) -> pure (f d)
        (Nothing, Just d) -> pure (f d)
        (Nothing, Nothing) -> fail $ "readEnvChange: no transaction descriptor in type " ++ show ty
    txnValue = O.word8 O.>>= \case
      0 -> pure Nothing
      8 -> Just . TransactionDescriptor O.<$> O.word64le
      _ -> fail "readEnvChange: transaction descriptor must be 8 bytes"
    readNumber :: Text -> P.Parser Integer
    readNumber t = case TR.decimal t of
      Right (n, rest) | T.null rest -> pure n
      _ -> fail $ "readEnvChange: packet size is not a number: " ++ show t

readBVarByte :: P.Parser B.ByteString
readBVarByte = O.word8 O.>>= P.ownedBoundedBytes . fromIntegral

readValue :: ValueMode -> TypeInfo -> P.Parser RawBytes
readValue mode = readCellValue mode . V.valueShape

-- An output parameter's value comes once per parameter, so its delimiter is read by
-- 'V.cellHead''s compiled copy and the binds are calls.  Inlined, this was a copy of
-- every delimiter form inside the token reader.
readCellValue :: ValueMode -> V.ColumnShape -> P.Parser RawBytes
readCellValue mode shape = noinline V.cellHead shape O.>>= \case
  V.NullCell -> pure Nothing
  cell -> case mode of
    AssembleValues ahead -> V.ownedValue ahead cell
    SkipValues -> Just B.empty O.<$ noinline V.skipValue cell
