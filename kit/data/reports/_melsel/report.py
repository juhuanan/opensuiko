#!/usr/bin/env python3
"""Full per-function report: calls (resolved), data refs, immediates."""
import sys, csv
sys.path.insert(0,'/home/hatch/workspace/suikoden/kit/work/_melsel')
from mipsx import *

MAIN={}
for r in csv.DictReader(open('/home/hatch/workspace/suikoden/kit/work/function_labels.csv')):
    MAIN[int(r['address'],16)]=r['name']

def report(path, base):
    data,words,ins,tab,funcs=get_funcs(path,base)
    flen=len(data)
    print('=====',path.split('/')[-1],'table slots:',len(tab),'functions:',len(funcs))
    print('table:',', '.join('0x%08x'%t[1] for t in tab))
    for s in sorted(funcs):
        seen=funcs[s]
        calls,refs,imms=sym_run(base,words,ins,seen)
        ext=[c for c in calls if c[0]=='jalr' or (c[0]=='jal' and not (base<=c[1]<base+flen))]
        inref=sorted(r for r in refs if base<=r<base+flen)
        outref=sorted(r for r in refs if not (base<=r<base+flen))
        print('0x%08x sz=%d'%(s,len(seen)))
        for k,t in ext:
            print('    %s 0x%08x %s'%(k,t,MAIN.get(t,'?')))
        if inref: print('    in-file:',', '.join('0x%08x'%x for x in inref[:12]))
        if outref: print('    RAM:',', '.join('0x%08x'%x for x in outref[:12]))
        if imms: print('    imm:',', '.join('0x%x'%x for x in sorted(imms)[:16]))

if __name__=='__main__':
    for p in sys.argv[1:]:
        report(p, 0x80010000)
