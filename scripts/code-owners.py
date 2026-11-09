#!/usr/bin/env python3
# code-owners.py BUILD-DIR [-nN] [MODULE...]: .text bytes per top-level binding, each
# local closure counted in the binding whose STG defines it.  Needs objects built
# with -fexpose-internal-symbols and -ddump-stg-final -ddump-to-file without
# -dsuppress-uniques (the dumps under BUILD-DIR/src).
import os, re, subprocess, sys
from collections import defaultdict
from code_symbols import text_symbols

def zdec(s):
    m = {'zi':'.','zd':'$','zu':'_','ze':'=','zl':'<','zg':'>','zm':'-','zp':'+','zt':'*','zc':':','zs':'/','zh':'#','zb':'!','zq':"'",'zr':'|','zv':'^','zz':'z','ZZ':'Z','ZL':'(','ZR':')','ZM':'[','ZN':']','ZC':':','zn':'\\','za':'&','zx':'%','zo':'@','zw':'?','zk':'~'}
    out=[];i=0
    while i < len(s):
        t=s[i:i+2]
        if t in m: out.append(m[t]); i+=2
        else: out.append(s[i]); i+=1
    return ''.join(out)

args = sys.argv[1:]
root = args.pop(0)
lim = 40
mods = []
for a in args:
    if a.startswith('-n'): lim = int(a[2:])
    else: mods.append(a)

def owners_of(stg):
    own = {}
    top = None
    for line in open(stg):
        m = re.match(r'^(\S+) =', line)
        if m:
            top = m.group(1)
            own[top] = top
            continue
        m = re.match(r'^\s+(\S+) =\s*$', line) or re.match(r'^\s+(\S+) =\s', line)
        if m and top:
            own.setdefault(m.group(1), top)
    return own

total = defaultdict(int)
unowned = defaultdict(int)
for dp, _, fs in os.walk(os.path.join(root, 'Hmssql')):
    for f in fs:
        if not f.endswith('.o'): continue
        o = os.path.join(dp, f)
        mod = os.path.relpath(o, root)[:-2].replace('/', '.')
        if mods and mod not in mods: continue
        stg = os.path.join(root, 'src', os.path.relpath(o, root)[:-2] + '.dump-stg-final')
        own = owners_of(stg) if os.path.exists(stg) else {}
        for n, size in text_symbols(o):
            name = zdec(re.sub(r'^_?hmssqlzm0zi1zi0zm[A-Za-z0-9]+_', '', n))
            name = re.sub(r'_(info|slow|entry|fast\d*)$', '', name)
            name = name[len(mod) + 1:] if name.startswith(mod + '_') or name.startswith(mod + '.') else name
            o_ = own.get(name)
            if o_ is None:
                # a local named with its unique: sat_skFr, $wgo_skzu
                o_ = own.get(name)
            if o_ is None:
                total[(mod, name + ' ?')] += size
            else:
                total[(mod, o_)] += size
rows = sorted(((s, m, n) for (m, n), s in total.items()), reverse=True)
for s, m, n in rows[:lim]:
    print(f'{s:7d} {m:28s} {n}')
print(sum(s for s, _, _ in rows), 'total;', sum(s for s, _, n in rows if n.endswith(' ?')), 'unowned')
