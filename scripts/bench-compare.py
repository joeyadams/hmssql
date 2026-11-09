#!/usr/bin/env python3
"""Compare two benchmark binaries in time and allocation.

Usage: bench-compare.py [--live] [--stdev N] BASE-BINARY NEW-BINARY PATTERN PAIRS CPU OUTPUT-DIRECTORY

It runs the binaries alternately, PAIRS times each, pinned to one CPU when taskset
exists, on the cases that PATTERN selects (a tasty pattern).  For every case it
takes the median over the pairs of NEW / BASE, and it prints the geometric mean of
those ratios per group (the second component of a case's name) and then every case,
fastest first. Below 1 is better. Unless --live is explicit, the server's password
is dropped from the environment, so only groups needing no server run. See docs/dev/testing.md,
"Comparing two commits".
"""
import argparse, csv, os, shutil, statistics as st, subprocess, sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--live', action='store_true')
parser.add_argument('--stdev', default='15')
for name in ('base', 'new', 'pattern', 'pairs', 'cpu', 'out'):
    parser.add_argument(name)
args = parser.parse_args()
base, new, pattern, cpu, out = args.base, args.new, args.pattern, args.cpu, args.out
pairs = int(args.pairs)
env = dict(os.environ)
if not args.live:
    env.pop('HMSSQL_TEST_PASSWORD', None)
pin = ['taskset', '-c', cpu] if shutil.which('taskset') else []

def run(binary, label, i):
    path = os.path.join(out, f'time-{label}-{i}.csv')
    subprocess.run(pin + [binary, '-p', pattern, '--stdev', args.stdev, '--timeout', '20s',
                          '--csv', path, '+RTS', '-N1'],
                   env=env, stdout=subprocess.DEVNULL, check=True)
    with open(path) as f:
        return {r['Name']: r for r in csv.DictReader(f)}

runs = []
for i in range(pairs):
    runs.append((run(base, 'base', i), run(new, 'new', i)))
    print(f'pair {i + 1} of {pairs} done', file=sys.stderr)

def ratio(n, column):
    def one(a, b):
        x, y = float(a[n].get(column) or 0), float(b[n].get(column) or 0)
        return y / x if x > 0 else 1.0
    return st.median(one(a, b) for a, b in runs)

names = [n for n in runs[0][0] if all(n in a and n in b for a, b in runs)]
rows = [(n, ratio(n, 'Mean (ps)'), ratio(n, 'Allocated')) for n in names]
group = lambda n: n.split('.')[1]
print(f'{"Group":<8} {"cases":>5} {"time":>6} {"alloc":>6}')
for g in sorted({group(n) for n, _, _ in rows}):
    rs = [r for r in rows if group(r[0]) == g]
    print(f'{g:<8} {len(rs):>5} {st.geometric_mean(r[1] for r in rs):>6.3f} '
          f'{st.geometric_mean(r[2] for r in rs):>6.3f}')
print(f'{"All":<8} {len(rows):>5} {st.geometric_mean(r[1] for r in rows):>6.3f} '
      f'{st.geometric_mean(r[2] for r in rows):>6.3f}')
print('\ntime  alloc  case')
for n, t, a in sorted(rows, key=lambda r: r[1]):
    print(f'{t:.3f} {a:.3f}  {n.removeprefix("All.")}')
