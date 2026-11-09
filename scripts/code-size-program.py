# Generate a program shaped like an application with many records, for
# scripts/code-size.sh: 50 records, three of 60 to 80 fields and the rest 10 to 30,
# with derived FromSqlRow and ToSqlRow.  Records.hs has the types, and FromRows.hs
# and ToRows.hs the instances, so that each one's object code is measured alone.
# With --quick, the first 12 records (one of each large size and nine others).
#
# Usage: code-size-program.py OUTPUT-DIRECTORY [--quick]
import random, sys, os
out = sys.argv[1]
quick = '--quick' in sys.argv[2:]
os.makedirs(out, exist_ok=True)
rng = random.Random(20261104)
types = ['Int32', 'Int64', 'Text', 'Bool', 'Double', 'Decimal', 'UTCTime', 'Day', 'UUID', 'ByteString']
sizes = [80, 64, 60] + [rng.randint(10, 30) for _ in range(47)]
recs = []
for r, n in enumerate(sizes):
    fields = []
    for f in range(n):
        t = rng.choice(types)
        if rng.random() < 0.35: t = 'Maybe ' + (t if t != 'ByteString' else 'Text')
        fields.append((f'r{r}f{f}', t))
    recs.append((f'Rec{r}', fields))
if quick:
    recs = recs[:12]
    sizes = sizes[:12]
imports = """import Data.ByteString (ByteString)
import Data.Decimal (Decimal)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (Day, UTCTime)
import Data.UUID.Types (UUID)
import GHC.Generics (Generic)
"""
with open(f'{out}/Records.hs', 'w') as h:
    h.write('{-# LANGUAGE DeriveGeneric, DuplicateRecordFields #-}\nmodule Records where\n' + imports)
    for name, fields in recs:
        h.write(f'data {name} = {name}\n  {{ ' + '\n  , '.join(f'{f} :: !({t})' for f, t in fields) + '\n  } deriving (Generic)\n')
for cls, mod in [('FromSqlRow', 'FromRows'), ('ToSqlRow', 'ToRows')]:
    with open(f'{out}/{mod}.hs', 'w') as h:
        h.write(f'{{-# OPTIONS_GHC -Wno-orphans #-}}\nmodule {mod} where\nimport Hmssql\nimport Records\n')
        for name, _ in recs: h.write(f'instance {cls} {name}\n')
print(sum(sizes), 'fields in', len(sizes), 'records')
