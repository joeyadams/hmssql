#!/usr/bin/env python3
# code-inner.py BUILD-DIR MODULE TOPLEVEL: .text bytes of a top-level binding's code,
# by the innermost enclosing named local binder (sat_ and lvl closures are counted
# in the binder they are nested in).
import os, re, subprocess, sys
from collections import defaultdict
from code_symbols import text_symbols
sys.path.insert(0, os.path.dirname(__file__))
root, mod, top = sys.argv[1:4]
rel = mod.replace('.', '/')
stg = os.path.join(root, 'src', rel + '.dump-stg-final')
o = os.path.join(root, rel + '.o')

def zdec(s):
    m = {'zi':'.','zd':'$','zu':'_','ze':'=','zl':'<','zg':'>','zm':'-','zp':'+','zt':'*','zc':':','zs':'/','zh':'#','zb':'!','zq':"'",'zr':'|','zv':'^','zz':'z','ZZ':'Z','ZL':'(','ZR':')','ZM':'[','ZN':']','ZC':':','zn':'\\','za':'&','zx':'%','zo':'@','zw':'?','zk':'~'}
    out=[];i=0
    while i < len(s):
        t=s[i:i+2]
        if t in m: out.append(m[t]); i+=2
        else: out.append(s[i]); i+=1
    return ''.join(out)

anon = re.compile(r'^(sat|lvl|wild|ds|fail|\$j|eta|x|y|w|ww)[_0-9]')
owner = {}
inside = False
stack = []
for line in open(stg):
    m = re.match(r'^(\S+) =', line)
    if m:
        inside = (m.group(1) == top)
        stack = [(-1, top)]
        continue
    if not inside: continue
    m = re.match(r'^(\s+)(\S+) =', line)
    if m:
        ind = len(m.group(1)); name = m.group(2)
        while stack and stack[-1][0] >= ind: stack.pop()
        named = [n for _, n in stack if not anon.match(n)]
        owner[name] = name if not anon.match(name) else (named[-1] if named else top)
        stack.append((ind, name))
owner[top] = top
tot = defaultdict(int)
for n, size in text_symbols(o):
    name = zdec(re.sub(r'^_?hmssqlzm0zi1zi0zm[A-Za-z0-9]+_', '', n))
    name = re.sub(r'_(info|slow|entry|fast\d*)$', '', name)
    for pre in (mod + '_', mod + '.'):
        if name.startswith(pre): name = name[len(pre):]
    if name in owner: tot[owner[name]] += size
for n, s in sorted(tot.items(), key=lambda x: -x[1])[:40]:
    print(f'{s:7d} {n}')
print(sum(tot.values()), 'total')
