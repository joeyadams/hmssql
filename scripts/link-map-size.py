#!/usr/bin/env python3
# link-map-size.py MAP [--members PKG] [--top N]: the .text of a GNU ld map, by package
# (the archive's libHS<pkg>-<ver>-<hash>.a, or the object file), and with
# --members PKG by archive member of that package.
import re, sys, collections
args = sys.argv[1:]
path = args[0]
members = args[args.index('--members') + 1] if '--members' in args else None
top = int(args[args.index('--top') + 1]) if '--top' in args else 40
lines = open(path).read().split('\n')
start = next(i for i, l in enumerate(lines) if l.startswith('Linker script and memory map'))
i = next(j for j in range(start, len(lines)) if re.match(r'^\.text\s', lines[j]))
by = collections.Counter()
total = 0
pend = None
def owner(f):
    m = re.search(r'/libHS(.+?)\.a\((.+)\)$', f)
    if m:
        lib = m.group(1)
        lib = re.sub(r'_thr$', '', lib)
        pm = re.match(r'(.+?)-\d[\d.]*(-[A-Za-z0-9]+)?(-ghc[\d.]+)?$', lib)
        pkg = pm.group(1) if pm else lib
        return pkg, m.group(2)
    m = re.search(r'/([^/]+\.a)\((.+)\)$', f)
    if m: return 'C:' + m.group(1), m.group(2)
    return 'obj:' + f.split('/')[-1], f.split('/')[-1]
for l in lines[i + 1:]:
    if re.match(r'^\.\S', l): break   # next output section
    m = re.match(r'^ (\.text\S*)\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(\S.*)$', l)
    if not m:
        m2 = re.match(r'^ (\.text\S*)\s*$', l)
        if m2: pend = m2.group(1); continue
        m3 = re.match(r'^\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)\s+(/\S.*|\S+\.o.*)$', l)
        if m3 and pend:
            size, f = int(m3.group(2), 16), m3.group(3)
            pend = None
        else:
            continue
    else:
        size, f = int(m.group(3), 16), m.group(4)
    pkg, mem = owner(f)
    total += size
    if members:
        if pkg == members: by[mem] += size
    else:
        by[pkg] += size
print(f'total input .text {total}')
for k, v in by.most_common(top):
    print(f'{v:>10} {k}')
rest = sum(v for k, v in by.most_common()[top:])
if rest: print(f'{rest:>10} ({len(by) - top} more)')
