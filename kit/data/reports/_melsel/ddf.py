#!/usr/bin/env python3
"""Dump exactly the function containing ADDRESS (per get_funcs extents)."""
import sys
sys.path.insert(0,'/home/hatch/workspace/suikoden/kit/work/_melsel')
from mipsx import *
def dumpfn(path, base, addr):
    data,words,ins,tab,funcs=get_funcs(path,base)
    k=(addr-base)//4
    for s,seen in funcs.items():
        if k in seen:
            fh=sys.stdout
            for kk in sorted(seen):
                w=words[kk]; i=dis(w); extra=''
                a=base+kk*4
                if i.op==2 or i.op==3:
                    t=((a+4)&0xF0000000)|((w&0x3FFFFFF)<<2); extra=' -> 0x%08x'%t
                elif i.op in (4,5,6,7,1):
                    t=a+4+(sx16(w&0xFFFF)<<2); extra=' -> 0x%08x'%t
                fh.write('0x%08x %08x %s%s\n'%(a, w, i.txt, extra))
            return
    print('address not in any function', file=sys.stderr)
if __name__=='__main__':
    dumpfn(sys.argv[1], 0x80010000, int(sys.argv[2],16))
