#!/usr/bin/env python3
"""32-register SPU reverb DSP, transcribed from Mednafen's pinned scalar kernel.

Copyright (C) 2011-2020 Mednafen Team; Python transcription2026.
SPDX-License-Identifier: GPL-2.0-or-later
Source/provenance and numerical limits: archive/docs/seq_reverb_network.md.
This module processes synthetic/offline audio; it does not execute a machine.
"""
from array import array
from spu import clamp16

RESAMPLE=(-1,2,-10,35,-103,266,-616,1332,-2960,10246,
          10246,-2960,1332,-616,266,-103,35,-10,2,-1)
MASK=0x3FFFF


def signed(value):return ((value+32768)&65535)-32768


def mix_sample(dry,wet,depth,master=16383):
    """Signed wet depth, sum saturation, then signed static master volume."""
    if not 0<=master<32768:raise ValueError('static master volume required')
    return clamp16((clamp16(dry+((wet*signed(depth))>>15))*signed(master<<1))>>15)


def disc_preset(kind=3):
    """MAIN80178C8C: ten native32-halfword presets and work-start registers."""
    import struct
    import maindec as M
    if not 0<=kind<10:raise ValueError('invalid disc reverb preset')
    mask,*registers=struct.unpack_from('<I32H',M.body(),0x80178C8C-M.MBASE+68*kind)
    if mask:raise ValueError('incomplete disc reverb preset')
    return registers,M.mword(0x80178C3C+4*kind)&65535


class Reverb:
    def __init__(self,registers,work_start):
        if len(registers)!=32 or any(not isinstance(v,int) or not 0<=v<=65535 for v in registers):
            raise ValueError('reverb needs32 unsigned halfword registers')
        if not isinstance(work_start,int) or not 0<=work_start<=65535:
            raise ValueError('invalid work-start register')
        self.regs=tuple(registers);self.base=work_start<<2;self.cur=self.base;self.pos=0
        self.ram=array('h',[0])*0x40000
        self.down=[[0]*128 for _ in range(2)];self.up=[[0]*64 for _ in range(2)]

    def _offset(self,offset):
        address=self.cur+(offset&MASK)
        if address&0x40000:address+=self.base
        return address&MASK

    def _read(self,raw,extra=0):return self.ram[self._offset(((raw&65535)<<2)+extra)]

    def _write(self,raw,value,enabled):
        if enabled:self.ram[self._offset((raw&65535)<<2)]=value

    def process(self,left,right,enabled=True):
        r=self.regs;p=self.pos
        for channel,value in enumerate((left,right)):
            self.down[channel][p]=self.down[channel][p|64]=clamp16(value)
        if p&1:
            alpha=signed(r[2]);wall=signed(r[7]);feedback=signed(r[8]);cross=signed(r[9])
            neg=lambda value:32767 if value==-32768 else -value
            for channel in range(2):
                start=(p-38)&63;src=self.down[channel]
                down=clamp16((sum(c*src[start+2*i] for i,c in enumerate(RESAMPLE))+16384*src[start+19])>>15)
                inputs=[]
                for index in (r[16+channel],r[24+(channel^1)]):
                    inputs.append(clamp16((((self._read(index)*wall)>>14)+((down*signed(r[30+channel]))>>14))>>1))
                for value,dest in zip(inputs,(r[10+channel],r[18+channel])):
                    previous=self._read(dest,-1)
                    complement=(0 if previous==-32768 else previous*-65536) if alpha==-32768 else previous*(32768-alpha)
                    value=clamp16((((value*alpha)>>14)+(complement>>14))>>1)
                    self._write(dest,value,enabled)
                acc=sum((self._read(r[index+channel])*signed(r[coefficient]))>>14
                        for index,coefficient in ((12,3),(14,4),(20,5),(22,6)))
                a=self._read(r[26+channel]-r[0]);b=self._read(r[28+channel]-r[1])
                first=clamp16((acc+((a*neg(feedback))>>14))>>1)
                second=clamp16(a+((((first*feedback)>>14)+((b*neg(cross))>>14))>>1))
                value=clamp16(b+((second*cross)>>15))
                self._write(r[26+channel],first,enabled);self._write(r[28+channel],second,enabled)
                self.up[channel][p>>1]=self.up[channel][(p>>1)|32]=value
            self.cur=(self.cur+1)&MASK
            if self.cur==0:self.cur=self.base
        output=[];start=((p>>1)-19)&31
        for channel in range(2):
            src=self.up[channel]
            output.append(clamp16(sum(c*src[start+i] for i,c in enumerate(RESAMPLE))>>14)
                          if p&1 else src[start+9])
        self.pos=(p+1)&63
        return tuple(output)
