#!/usr/bin/env python3
"""Reverb scalar DSP against frozen vectors from an isolated upstream C++ kernel.

Optional --reference-dir checks full sample/state equality using pinned sources;
normal builds need no compiler/network. Synthetic audio only, never a game run.
"""
from array import array
from itertools import product
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile

KIT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(KIT/'tools'),str(KIT/'tools/seq')]
from reverb import Reverb,disc_preset,mix_sample

VECTORS=KIT/'work/seq_reverb_vectors.json'
COMMIT='f0ee9d595db68ad5247ba5ac6a8367fdced9c3fc'
SOURCES={'spu_reverb.inc':'d0a0db06fd8a1fcc6f13ec656827a4ef679048332b87517b24a8ca0cafe101a5',
         'spu.h':'77c81a26a48976113b60e02e1c2db6e63eb4e39a69c2372d1cccdda08ebfeb3f',
         'spu.cpp':'8dc226a6e91dbe2ca7c503abd590c7c801f500d21029b5d90c20a96b26fcfde8'}


def little_bytes(values):
    values=array('h',values)
    if sys.byteorder!='little':values.byteswap()
    return values.tobytes()


def cases():
    rows=[]
    for preset in range(10):
        rows.append(dict(name='disc'+str(preset),preset=preset,frames=24000,signal='impulse',seed=0))
    for preset in (0,3,9):
        rows.append(dict(name='silence'+str(preset),preset=preset,frames=256,signal='zero',seed=0))
    for phase in (0,1,31,62,63):
        for work in (0,0xF6F8,0xFFFF):
            rows.append(dict(name=f'wrap{phase}-{work}',preset=3,frames=128,signal='noise',seed=phase+work+1,
                             phase=phase,work=work,cur_end=True))
    for alpha in (0x8000,0x7FFF,0):
        for enabled in ('off','toggle','on'):
            rows.append(dict(name=f'corner{alpha}-{enabled}',preset=3,frames=512,signal='extremes',seed=11,
                             overrides={'2':alpha,'8':0x8000,'9':0x8000},enabled=enabled,fill=-32768))
    return rows


def seed_state(unit,case):
    if case['seed']:
        rng=random.Random(case['seed'])
        fill=case.get('fill')
        unit.ram=array('h',([fill]*0x40000 if fill is not None else
                            (rng.randrange(-32768,32768) for _ in range(0x40000))))
        unit.down=[[rng.randrange(-32768,32768) for _ in range(128)] for _ in range(2)]
        unit.up=[[rng.randrange(-32768,32768) for _ in range(64)] for _ in range(2)]
    unit.pos=case.get('phase',0)
    if case.get('cur_end'):unit.cur=0x3FFFF


def signal(case):
    rng=random.Random(case['seed']^0x5A4D)
    for i in range(case['frames']):
        if case['signal']=='zero':left=right=0
        elif case['signal']=='impulse':left,right=(24000,-16000) if i==0 else (0,0)
        elif case['signal']=='extremes':left,right=(32767,-32768) if i&1 else (-32768,32767)
        else:left,right=rng.randrange(-32768,32768),rng.randrange(-32768,32768)
        mode=case.get('enabled','on');enabled=mode=='on' or mode=='toggle' and i%7<3
        yield left,right,enabled


def state_hash(unit):
    values=little_bytes(unit.ram)+struct.pack('<II',unit.cur,unit.pos)
    values+=little_bytes(v for row in (*unit.down,*unit.up) for v in row)
    return hashlib.sha256(values).hexdigest()


def reference(directory,output):
    for name,digest in SOURCES.items():
        assert hashlib.sha256((directory/name).read_bytes()).hexdigest()==digest,name
    header=(directory/'spu.h').read_text()
    fields=header.split('uint16 FB_SRC_A;',1)[1].split('int16 IN_COEF[2];',1)[0]
    fields='uint16 FB_SRC_A;'+fields+'int16 IN_COEF[2];'
    wrapper='''#include <cstdint>
#include <cstring>
using int16=int16_t;using int32=int32_t;using uint16=uint16_t;using uint32=uint32_t;
#define INLINE inline
#define NO_INLINE __attribute__((noinline))
#define MDFN_WARN_UNUSED_RESULT __attribute__((warn_unused_result))
#define MDFN_UNLIKELY(x) (x)
template<class T> void clamp(T* v,T lo,T hi){if(*v<lo)*v=lo;if(*v>hi)*v=hi;}
class PS_SPU { public:
uint32 ReverbCur,ReverbWA;uint16 SPUControl;int32 RvbResPos;
uint16 SPURAM[0x40000];int16 RDSB[2][128],RUSB[2][64];
union {uint16 ReverbRegs[32];struct {FIELDS};};
uint32 Get_Reverb_Offset(uint32);int16 RD_RVB(uint16,int32=0);void WR_RVB(uint16,int16);
void RunReverb(const int32*,int32*);
uint16 ReadSPURAM(uint32 a){return SPURAM[a];}void WriteSPURAM(uint32 a,uint16 v){SPURAM[a]=v;}
};
#include "spu_reverb.inc"
extern "C" {
PS_SPU* make(const uint16* r,uint16 w){auto* p=new PS_SPU{};std::memcpy(p->ReverbRegs,r,64);p->ReverbCur=p->ReverbWA=w<<2;return p;}
void discard(PS_SPU* p){delete p;}
void process(PS_SPU* p,int l,int r,int on,int32* out){int32 in[2]={l,r};p->SPUControl=on?128:0;p->RunReverb(in,out);}
int16* ram(PS_SPU* p){return (int16*)p->SPURAM;}int16* down(PS_SPU* p){return &p->RDSB[0][0];}int16* up(PS_SPU* p){return &p->RUSB[0][0];}
void position(PS_SPU* p,uint32 cur,int pos){p->ReverbCur=cur;p->RvbResPos=pos;}
uint32 cursor(PS_SPU* p){return p->ReverbCur;}int phase(PS_SPU* p){return p->RvbResPos;}
}
'''.replace('FIELDS',fields)
    original=(directory/'spu.cpp').read_text()
    start=original.index('accum[lr] += ((reverb[lr] * ReverbVol[lr]) >> 15);')
    fragment=original[start:original.index('\n  }',start)]
    wrapper+='\nextern "C" int mix(int dry,int wet,int depth,uint16 master){\n'
    wrapper+='int32 accum[2]={dry,0},reverb[2]={wet,0},ReverbVol[2]={depth,0},output[2]={};unsigned lr=0;\n'
    wrapper+='struct Fixed{int16 value;int16 ReadVolume(){return value;}}; Fixed GlobalSweep[2]={{(int16)(master<<1)},{0}};\n'
    wrapper+=fragment+'\nreturn output[0];}\n'
    source=output/'reference.cpp';source.write_text(wrapper)
    library=output/'reference.so'
    compiler=['xcrun','clang++'] if sys.platform=='darwin' else ['clang++']
    subprocess.run(compiler+['-std=c++11','-O2','-shared','-fPIC','-I',str(directory),str(source),'-o',str(library)],check=True)
    lib=ctypes.CDLL(str(library));ptr=ctypes.c_void_p;i16=ctypes.POINTER(ctypes.c_int16)
    lib.make.argtypes=[i16,ctypes.c_uint16];lib.make.restype=ptr
    for name in ('ram','down','up'):
        getattr(lib,name).argtypes=[ptr];getattr(lib,name).restype=i16
    lib.discard.argtypes=[ptr];lib.process.argtypes=[ptr,ctypes.c_int,ctypes.c_int,ctypes.c_int,ctypes.POINTER(ctypes.c_int32)]
    lib.position.argtypes=[ptr,ctypes.c_uint32,ctypes.c_int];lib.cursor.argtypes=[ptr];lib.cursor.restype=ctypes.c_uint32
    lib.phase.argtypes=[ptr];lib.phase.restype=ctypes.c_int
    lib.mix.argtypes=[ctypes.c_int32,ctypes.c_int32,ctypes.c_int32,ctypes.c_uint16];lib.mix.restype=ctypes.c_int32
    return lib


def run(case,lib=None):
    registers,work=disc_preset(case['preset']);work=case.get('work',work)
    for index,value in case.get('overrides',{}).items():registers[int(index)]=value
    unit=Reverb(registers,work);seed_state(unit,case);native=None
    if lib:
        native=lib.make((ctypes.c_int16*32)(*registers),work)
        for name,values in (('ram',unit.ram),('down',[v for row in unit.down for v in row]),('up',[v for row in unit.up for v in row])):
            values=array('h',values);ctypes.memmove(getattr(lib,name)(native),values.tobytes(),2*len(values))
        lib.position(native,unit.cur,unit.pos)
    output=array('h');nonzero=0
    try:
        for index,(left,right,enabled) in enumerate(signal(case)):
            pair=unit.process(left,right,enabled);output.extend(pair);nonzero+=int(bool(pair[0] or pair[1]))
            if lib:
                expected=(ctypes.c_int32*2)();lib.process(native,left,right,enabled,expected)
                assert pair==tuple(expected),(case['name'],index,pair,tuple(expected))
        if lib:
            assert list(unit.ram)==list(lib.ram(native)[:0x40000]),case['name']+' RAM'
            assert [v for row in unit.down for v in row]==list(lib.down(native)[:256])
            assert [v for row in unit.up for v in row]==list(lib.up(native)[:128])
            assert (unit.cur,unit.pos)==(lib.cursor(native),lib.phase(native))
    finally:
        if lib:lib.discard(native)
    return dict(pcm_sha256=hashlib.sha256(little_bytes(output)).hexdigest(),state_sha256=state_hash(unit),nonzero_frames=nonzero)


def check_mix(lib):
    results=[]
    for dry,wet,depth,master in product((-786432,-32768,-1,0,1,32767,786432),
            (-32768,-1,0,1,32767),(0,0x2850,32767,32768,65535),(0,1,16383,16384,32767)):
        actual=mix_sample(dry,wet,depth,master)
        if lib:
            signed_depth=((depth+32768)&65535)-32768
            assert actual==lib.mix(dry,wet,signed_depth,master),(dry,wet,depth,master,actual)
        results.append(actual)
    return dict(cases=len(results),pcm_sha256=hashlib.sha256(little_bytes(results)).hexdigest())


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--reference-dir',type=Path)
    parser.add_argument('--write-vectors',action='store_true');args=parser.parse_args()
    if args.write_vectors and not args.reference_dir:parser.error('writing requires the independent C++ reference')
    with tempfile.TemporaryDirectory(prefix='suikoden-reverb-kernel-') as tmp:
        lib=reference(args.reference_dir,Path(tmp)) if args.reference_dir else None
        records=[dict(case=case,expected=run(case,lib)) for case in cases()]
        mix=check_mix(lib)
    fixture=dict(reference_commit=COMMIT,source_sha256=SOURCES,cases=records,mix=mix)
    if args.write_vectors:VECTORS.write_text(json.dumps(fixture,indent=2)+'\n')
    else:assert json.loads(VECTORS.read_text())==fixture,'frozen independent vectors differ'
    print(f'PASS: {len(records)} reverb cases / {sum(r["case"]["frames"] for r in records)} stereo frames plus {mix["cases"]} final-mix cases; PCM and full RAM/filter/cursor states'+(' independently agree with original C++' if lib else ' agree with frozen C++ vectors'))


if __name__=='__main__':main()
