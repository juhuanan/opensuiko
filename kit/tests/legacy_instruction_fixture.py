"""Legacy fixture for older tests that execute original instructions."""
import os
import struct

if os.environ.get("SUIKODEN_STATIC_ONLY") == "1":
    raise RuntimeError("The legacy instruction runner is unavailable in a static-only rebuild")

import maindec as M
from exp_award import _Mem, s32


class Instructions:
    """Only the instruction subset in these bounded functions; external calls explicit."""
    def __init__(self):
        self.mem=_Mem();self.r=[0]*32;self.r[29]=0x80900000
        self.r[31]=0xFFFFFFFC;self.hi=self.lo=self.clock=0;self.loads=[]
        self.random=0;self.effects=[];self.zone=1
    def read(self,address,size):
        if M.MBASE<=address and address+size<=M.MBASE+len(M.body()):
            return sum(self.mem.b.get(address+i,M.body()[address+i-M.MBASE])<<(8*i) for i in range(size))
        return sum(self.mem.rb(address+i)<<(8*i) for i in range(size))
    def word(self,pc):
        return M.mword(pc)
    def basic(self,pc):
        for when,reg,value in self.loads[:]:
            if when<=self.clock:self.r[reg]=value;self.loads.remove((when,reg,value))
        w=self.word(pc);assert w is not None,hex(pc)
        o=w>>26;s=(w>>21)&31;t=(w>>16)&31;d=(w>>11)&31;imm=w&65535
        signed=imm-65536 if imm&32768 else imm;shift=(w>>6)&31;f=w&63
        r=self.r;target=None
        if o==0:
            if f==0:r[d]=r[t]<<shift
            elif f==2:r[d]=r[t]>>shift
            elif f==3:r[d]=s32(r[t])>>shift
            elif f==4:r[d]=r[t]<<(r[s]&31)
            elif f==6:r[d]=r[t]>>(r[s]&31)
            elif f==7:r[d]=s32(r[t])>>(r[s]&31)
            elif f==8:target=r[s]
            elif f==9:target=r[s];r[d]=pc+8
            elif f==16:r[d]=self.hi
            elif f==18:r[d]=self.lo
            elif f in (24,25):
                value=(s32(r[s])*s32(r[t])) if f==24 else r[s]*r[t]
                self.lo=value&0xFFFFFFFF;self.hi=(value>>32)&0xFFFFFFFF
            elif f==26:
                a,b=s32(r[s]),s32(r[t]);assert b
                self.lo=(abs(a)//abs(b))*(-1 if (a<0)!=(b<0) else 1)
                self.hi=a-self.lo*b
            elif f==27:self.lo,self.hi=divmod(r[s],r[t])
            elif f==33:r[d]=r[s]+r[t]
            elif f==35:r[d]=r[s]-r[t]
            elif f==36:r[d]=r[s]&r[t]
            elif f==37:r[d]=r[s]|r[t]
            elif f==38:r[d]=r[s]^r[t]
            elif f==39:r[d]=~(r[s]|r[t])
            elif f==42:r[d]=int(s32(r[s])<s32(r[t]))
            elif f==43:r[d]=int(r[s]<r[t])
            else:raise AssertionError((hex(pc),hex(w)))
        elif o==1:
            take=s32(r[s])<0 if t==0 else s32(r[s])>=0
            target=pc+4+4*signed if take else pc+8
        elif o in (2,3):
            target=((pc+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
            if o==3:r[31]=pc+8
        elif o in (4,5,6,7):
            take={4:r[s]==r[t],5:r[s]!=r[t],6:s32(r[s])<=0,7:s32(r[s])>0}[o]
            target=pc+4+4*signed if take else pc+8
        elif o==9:r[t]=r[s]+signed
        elif o==10:r[t]=int(s32(r[s])<signed)
        elif o==11:r[t]=int(r[s]<(signed&0xFFFFFFFF))
        elif o==12:r[t]=r[s]&imm
        elif o==13:r[t]=r[s]|imm
        elif o==14:r[t]=r[s]^imm
        elif o==15:r[t]=imm<<16
        elif o in (34,38):
            address=(r[s]+signed)&0xFFFFFFFF
            # Only aligned word-copy pairs are needed; reject other merge alignments.
            assert address&3==(3 if o==34 else 0),(hex(pc),hex(address))
            self.loads.append((self.clock+2,t,self.read(address&~3,4)))
        elif o in (42,46):
            address=(r[s]+signed)&0xFFFFFFFF
            assert address&3==(3 if o==42 else 0),(hex(pc),hex(address))
            for i in range(4):self.mem.sb((address&~3)+i,r[t]>>(8*i))
        elif o in (32,33,35,36,37):
            size={32:1,33:2,35:4,36:1,37:2}[o];value=self.read((r[s]+signed)&0xFFFFFFFF,size)
            if o in (32,33) and value&(1<<(size*8-1)):value-=1<<(size*8)
            self.loads.append((self.clock+2,t,value&0xFFFFFFFF))
        elif o in (40,41,43):
            size={40:1,41:2,43:4}[o]
            for i in range(size):self.mem.sb(r[s]+signed+i,r[t]>>(8*i))
        else:raise AssertionError((hex(pc),hex(w)))
        self.r=[v&0xFFFFFFFF for v in r];self.r[0]=0
        self.lo&=0xFFFFFFFF;self.hi&=0xFFFFFFFF;self.clock+=1
        return target
    def external_call(self,pc):
        if pc not in (0x80147E38,0x8013CCF0,0x80137304,0x801373D4):return False
        self.effects.append((pc,tuple(self.r[4:7])))
        self.r[2]=self.random if pc==0x80147E38 else self.zone if pc==0x80137304 else 0
        return True
    def run(self,pc,limit=20000):
        for _ in range(limit):
            if pc==0xFFFFFFFC:return self.r[2]
            if self.external_call(pc):
                pc=self.r[31];continue
            target=self.basic(pc)
            if target is None:pc+=4
            else:
                assert self.basic(pc+4) is None,hex(pc)
                pc=target
        raise RuntimeError('instruction budget exhausted')


BASE = 0x80010000


class Writes(_Mem):
    def __init__(self):
        super().__init__()
        self.written = []

    def sb(self, address, value):
        self.written.append(address & 0xFFFFFFFF)
        super().sb(address, value)


def run_with_sentinel(cpu, address, *args):
    cpu.r[31] = 0xFFFFFFFC
    cpu.r[4:4 + len(args)] = args
    return cpu.run(address, limit=100000)


class OverlayInstructions(Instructions):
    def __init__(self,data):
        super().__init__();self.data=data;self.hooks={};self.visited=set()
    def word(self,pc):
        self.visited.add(pc)
        if BASE<=pc<BASE+len(self.data):return struct.unpack_from('<I',self.data,pc-BASE)[0]
        return M.mword(pc)
    def read(self,address,size):
        if not (BASE<=address and address+size<=BASE+len(self.data)):return super().read(address,size)
        return sum(self.mem.b.get(address+i,self.data[address+i-BASE])<<(8*i) for i in range(size))
    def external_call(self,pc):
        if pc not in self.hooks:return super().external_call(pc)
        self.effects.append((pc,tuple(self.r[4:8])))
        value=self.hooks[pc]
        self.r[2]=value(self) if callable(value) else value
        return True


def call(c,pc,*args):
    c.r[31]=0xFFFFFFFC;c.r[29]=0x80900000;c.r[4:4+len(args)]=args;c.run(pc,limit=100000)


class ModuleInstructions(OverlayInstructions):
    def __init__(self,data,base):
        super().__init__(b'');self.module=data;self.base=base
    def word(self,pc):
        if self.base<=pc<self.base+len(self.module):
            self.visited.add(pc);return struct.unpack_from('<I',self.module,pc-self.base)[0]
        return super().word(pc)
    def read(self,address,size):
        if self.base<=address and address+size<=self.base+len(self.module):
            return sum(self.mem.b.get(address+i,self.module[address+i-self.base])<<(8*i) for i in range(size))
        return super().read(address,size)
