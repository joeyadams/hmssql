#!/usr/bin/env python3
# Generate modules of call sites of hmssql's common API, 40 functions each, for
# api-code-size.sh.  Each function is one use of the API with its own SQL text, so that
# nothing is shared between them; (module .text - Empty .text) / 40 is the code a use
# costs.  Base is 40 calls of an opaque local function: the cost of a function that
# makes one call.  CallRecords has 12 records with derived instances (not measured).
#
# Usage: api-code-size-program.py DIR   (writes DIR/src/*.hs and prints the module names)
import sys, os, random
d = sys.argv[1] + '/src'
os.makedirs(d, exist_ok=True)
rng = random.Random(20261104)
N = 40
ftypes = ['Int32', 'Text', 'Int64', 'Bool', 'Double', 'Maybe Int32', 'Day', 'Maybe Text',
          'UUID', 'Decimal', 'UTCTime', 'ByteString', 'Int', 'Maybe Double', 'LocalTime', 'Int16']
# a value of each type from an Int i and a Text t
vals = {'Int32': '(fromIntegral i)', 'Int64': '(fromIntegral i)', 'Int': 'i', 'Int16': '(fromIntegral i)',
        'Text': 't', 'Bool': '(even i)', 'Double': '(fromIntegral i)', 'Maybe Int32': '(Just (fromIntegral i))',
        'Day': '(toEnum i)', 'Maybe Text': '(Just t)', 'UUID': 'nil', 'Decimal': '(fromIntegral i)',
        'UTCTime': '(UTCTime (toEnum i) 0)', 'ByteString': '(encodeUtf8 t)', 'Maybe Double': 'Nothing',
        'LocalTime': '(LocalTime (toEnum i) midnight)'}
tuples = []
for n in [2, 2, 3, 3, 4, 4, 5, 6]:
    tuples.append('(' + ', '.join(rng.choice(ftypes) for _ in range(n)) + ')')
hdr = '''{-# LANGUAGE OverloadedStrings, ScopedTypeVariables, DeriveGeneric, DeriveAnyClass, DerivingStrategies #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-unused-imports #-}
module %s where
import Hmssql
import Hmssql.Query
import Hmssql.Decoding (singleField, sqlRowDecoder, refineField, sqlValueDecoder, nullableField)
import Control.Applicative (liftA2)
import Hmssql.SqlValue (SqlRow, SqlValue)
import Hmssql.BulkCopy (bulkInsert)
import Data.ByteString (ByteString)
import Data.Decimal (Decimal)
import Data.Int (Int16, Int32, Int64)
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Time (Day, UTCTime (..), LocalTime (..), midnight)
import Data.UUID.Types (UUID, nil)
import Streaming (Stream, Of)
import qualified Streaming.Prelude as S
'''
mods = {}
def ty(k): return ftypes[k % len(ftypes)]
def tup(k): return tuples[k % len(tuples)]
def rec(k): return f'Rec{k % 12}'
def fns(body):
    return ''.join(body(k) for k in range(N))

mods['Empty'] = ''
mods['Base'] = ('{-# NOINLINE opaque #-}\nopaque :: Connection -> Int -> IO Int64\nopaque _ n = pure (fromIntegral n)\n'
    + fns(lambda k: f'f{k} :: Connection -> IO Int64\nf{k} c = opaque c {k}\n'))
mods['Lit'] = fns(lambda k: f'q{k} :: Query\nq{k} = "SELECT {k} FROM t{k}"\n')
mods['ExecArg'] = fns(lambda k: f'f{k} :: Connection -> Query -> IO Int64\nf{k} c q = execute c q\n')
mods['ExecLit'] = fns(lambda k: f'f{k} :: Connection -> IO Int64\nf{k} c = execute c "UPDATE t{k} SET a = 1"\n')
mods['Exec_'] = fns(lambda k: f'f{k} :: Connection -> IO ()\nf{k} c = execute_ c "UPDATE t{k} SET a = 1"\n')
mods['QueryArg'] = fns(lambda k: f'f{k} :: Connection -> Query -> IO [Only Int32]\nf{k} c q = query c q\n')
mods['QueryOnly'] = fns(lambda k: f'f{k} :: Connection -> IO [Only ({ty(k)})]\nf{k} c = query c "SELECT a FROM t{k}"\n')
mods['QueryTup'] = fns(lambda k: f'f{k} :: Connection -> IO [{tup(k)}]\nf{k} c = query c "SELECT * FROM t{k}"\n')
mods['QueryRec'] = fns(lambda k: f'f{k} :: Connection -> IO [{rec(k)}]\nf{k} c = query c "SELECT * FROM t{k}"\n')
mods['QuerySqlRow'] = fns(lambda k: f'f{k} :: Connection -> IO [SqlRow]\nf{k} c = queryMWith sqlRowDecoder c "SELECT * FROM t{k}"\n')
mods['QueryWith'] = fns(lambda k: f'f{k} :: Connection -> IO [({ty(k)}, {ty(k+3)})]\nf{k} c = queryWith ((,) <$> singleField fieldDecoder <*> singleField fieldDecoder) c "SELECT a, b FROM t{k}"\n')
mods['QueryWith3'] = fns(lambda k: f'f{k} :: Connection -> IO [({ty(k)}, {ty(k+3)}, Int32)]\nf{k} c = queryWith ((,,) <$> singleField fieldDecoder <*> singleField fieldDecoder <*> singleField (refineField (\\x -> if x > {k} then Right x else Left "small") fieldDecoder)) c "SELECT a, b, c FROM t{k}"\n')
mods['QueryWithLift'] = fns(lambda k: f'f{k} :: Connection -> IO [({ty(k)}, {ty(k+3)})]\nf{k} c = queryWith (liftA2 (,) (singleField fieldDecoder) (singleField fieldDecoder)) c "SELECT a, b FROM t{k}"\n')
mods['QueryWithSeq'] = fns(lambda k: f'f{k} :: Connection -> IO [[SqlValue]]\nf{k} c = queryWith (sequenceA (replicate {k + 2} (singleField sqlValueDecoder))) c "SELECT * FROM t{k}"\n')
mods['QueryRefine'] = fns(lambda k: f'f{k} :: Connection -> IO [Only Int32]\nf{k} c = queryWith (Only <$> singleField (refineField (\\x -> if x > {k} then Right x else Left "small") fieldDecoder)) c "SELECT a FROM t{k}"\n')
mods['QueryFmapField'] = fns(lambda k: f'f{k} :: Connection -> IO [Only Int]\nf{k} c = queryWith (Only <$> singleField ((\\x -> fromIntegral (x :: Int32) + {k}) <$> fieldDecoder)) c "SELECT a FROM t{k}"\n')
mods['QueryNullable'] = fns(lambda k: f'f{k} :: Connection -> IO [Only (Maybe ({ty(k)}))]\nf{k} c = queryWith (Only <$> singleField (nullableField fieldDecoder)) c "SELECT a FROM t{k}"\n')
mods['Query1'] = fns(lambda k: f'f{k} :: Connection -> IO (Only ({ty(k)}))\nf{k} c = query1 c "SELECT a FROM t{k}"\n')
mods['QueryMay'] = fns(lambda k: f'f{k} :: Connection -> IO (Maybe (Only ({ty(k)})))\nf{k} c = queryMay c "SELECT a FROM t{k}"\n')
mods['QueryFold'] = fns(lambda k: f'f{k} :: Connection -> IO Int64\nf{k} c = queryFold c "SELECT a FROM t{k}" 0 (\\acc (Only (x :: Int32)) -> pure $! acc + fromIntegral x)\n')
mods['QueryS'] = fns(lambda k: f'f{k} :: Connection -> IO Int\nf{k} c = queryS c "SELECT a FROM t{k}" >>= \\(s :: Stream (Of (Only ({ty(k)}))) IO ()) -> S.length_ s\n')
mods['WithQueryS'] = fns(lambda k: f'f{k} :: Connection -> IO Int\nf{k} c = withQueryS c "SELECT a FROM t{k}" (\\(s :: Stream (Of (Only ({ty(k)}))) IO ()) -> S.length_ s)\n')
mods['WithQuerySFold'] = fns(lambda k: f'f{k} :: Connection -> IO Int64\nf{k} c = withQueryS c "SELECT a FROM t{k}" (S.fold_ (\\acc (Only (x :: Int32)) -> acc + fromIntegral x) 0 id)\n')
mods['QueryMulti'] = fns(lambda k: f'f{k} :: Connection -> IO [ResultSet SqlRow]\nf{k} c = queryMulti c "SELECT 1; SELECT {k}"\n')
mods['ResultSets'] = fns(lambda k: f'f{k} :: Connection -> IO ([Only ({ty(k)})], [Only Int32])\nf{k} c = queryResultSets ((,) <$> resultSet <*> resultSet) c "SELECT a FROM t{k}; SELECT 1"\n')
mods['ExecMany'] = fns(lambda k: f'f{k} :: Connection -> [{tup(k)}] -> IO [Int64]\nf{k} c xs = executeMany c "INSERT INTO t{k} VALUES (@p1, @p2)" xs\n')
mods['ExecManyRec'] = fns(lambda k: f'f{k} :: Connection -> [{rec(k)}] -> IO [Int64]\nf{k} c xs = executeMany c "INSERT INTO t{k} VALUES (@p1, @p2)" xs\n')
mods['ExecStatements'] = fns(lambda k: f'f{k} :: Connection -> Query -> IO [Int64]\nf{k} c q = executeStatements c [q, "DELETE FROM t{k}"]\n')
mods['Tx'] = fns(lambda k: f'f{k} :: Connection -> IO Int64\nf{k} c = withTransaction c (execute c "UPDATE t{k} SET a = 1")\n')
mods['TxArg'] = fns(lambda k: f'f{k} :: Connection -> IO a -> IO a\nf{k} c act = withTransaction c act\n')
mods['TxLevel'] = fns(lambda k: f'f{k} :: Connection -> IO a -> IO a\nf{k} c act = withTransactionLevel Serializable c act\n')
mods['CallProc'] = fns(lambda k: f'f{k} :: Connection -> Int -> Text -> IO ProcResult\nf{k} c i t = callProcedure c "dbo.p{k}" [inParam "@a" ({vals[ty(k)]} :: {ty(k)}), outParam "@b" (Nothing :: Maybe Int32)]\n')
mods['Bulk'] = fns(lambda k: f'f{k} :: Connection -> [{tup(k)}] -> IO Int64\nf{k} c xs = bulkInsert c "dbo.t{k}" xs\n')
mods['BulkRec'] = fns(lambda k: f'f{k} :: Connection -> [{rec(k)}] -> IO Int64\nf{k} c xs = bulkInsert c "dbo.t{k}" xs\n')
def mkq(n):
    def body(k):
        ts = [ty(k + 5 * j) for j in range(n)]
        args = ' '.join(f'a{j}' for j in range(n))
        sig = ' -> '.join(f'({t})' for t in ts)
        ph = ' AND '.join(f'c{j} = @p{j+1}' for j in range(n))
        tupv = f'(Only a0)' if n == 1 else '(' + ', '.join(f'a{j}' for j in range(n)) + ')'
        return f'q{k} :: {sig} -> Query\nq{k} {args} = mkQuery "SELECT {k} WHERE {ph}" {tupv}\n'
    return fns(body)
for n in [1, 2, 3, 4]: mods[f'MkQuery{n}'] = mkq(n)
mods['MkQueryNamed'] = fns(lambda k: f'q{k} :: ({ty(k)}) -> ({ty(k+1)}) -> Query\nq{k} a b = mkQuery "SELECT {k} WHERE x = @a AND y = @b" (NamedParams [("a", SqlParam a), ("b", SqlParam b)])\n')
mods['Param'] = fns(lambda k: f'q{k} :: ({ty(k)}) -> Query\nq{k} v = param v\n')
mods['NamedParam'] = fns(lambda k: f'q{k} :: ({ty(k)}) -> Query\nq{k} v = namedParam "v{k}" v\n')
mods['ParamCompose'] = fns(lambda k: f'q{k} :: ({ty(k)}) -> ({ty(k+1)}) -> ({ty(k+2)}) -> ({ty(k+3)}) -> Query\nq{k} a b c d = "SELECT {k} WHERE a = " <> param a <> " AND b = " <> param b <> " AND c = " <> param c <> " AND d = " <> param d\n')
mods['RawSql'] = fns(lambda k: f'q{k} :: Text -> Query\nq{k} t = "SELECT {k} FROM " <> rawSql t\n')
mods['EscapeId'] = fns(lambda k: f'q{k} :: Text -> Query\nq{k} t = "SELECT {k} FROM " <> escapeIdentifier t\n')
mods['QueryParam'] = fns(lambda k: f'f{k} :: Connection -> ({ty(k)}) -> IO [Only Int32]\nf{k} c v = query c ("SELECT a FROM t{k} WHERE b = " <> param v)\n')

recs = []
for r in range(12):
    fs = [f'r{r}f{j} :: !({rng.choice(ftypes)})' for j in range(6)]
    recs.append(f'data Rec{r} = Rec{r}\n  {{ ' + '\n  , '.join(fs) + '\n  } deriving stock (Generic) deriving anyclass (FromSqlRow, ToSqlRow)\n')
with open(d + '/CallRecords.hs', 'w') as h:
    h.write((hdr % 'CallRecords') + 'import GHC.Generics (Generic)\n' + ''.join(recs))
for m, body in mods.items():
    with open(d + f'/{m}.hs', 'w') as h:
        h.write(hdr % m + 'import CallRecords\n' + body)
print(' '.join(mods))
