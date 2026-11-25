import struct, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mx, mipsdec
W=[struct.unpack_from('<I',mx.BODY,4*i)[0] for i in range(len(mx.BODY)//4)]
V=[mx.BASE+4*i for i in range(len(W))]
def f(w): return dict(op=(w>>26)&0x3F,rs=(w>>21)&0x1F,rt=(w>>16)&0x1F,rd=(w>>11)&0x1F,sa=(w>>6)&0x1F,fn=w&0x3F,imm=mipsdec.sx16(w))

def enclosing_loops(addr):
    """backward branches whose [target, branch] span contains addr"""
    idx=V.index(addr)
    out=[]
    for i,w in enumerate(W):
        g=f(w)
        if g['op'] not in (0x01,0x04,0x05,0x06,0x07): continue
        tgt=((V[i]+4)&0xF0000000)|(((w&0xFFFF)<<2)) if False else V[i]+4+(g['imm']<<2)
        ti=None
        # locate target index by dict
        ti=TGT.get(tgt)
        if ti is None or ti>=i: continue
        if ti<=idx<=i: out.append((tgt,V[i],i-ti+1))
    return out
IDX={v:i for i,v in enumerate(V)}
TGT=IDX
