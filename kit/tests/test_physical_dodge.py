#!/usr/bin/env python3
"""Independent static dodge clocks and integer trajectories; no original execution."""
from pathlib import Path
import json
import math
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import maindec
from actor_script import OP_LEN_HW
from export_first_room import source
from export_world_travel import battle_export,party_attack_sequence,enemy_dodge

FIXTURE=ROOT/'game/tests/fixtures/physical_dodge_vectors.json'
OWNERS=((0,'hero','SHU'),(1,'gremio','GRE'),(2,'pahn','PAN'),(4,'yam_koo','YAM'),(5,'tai_ho','TAI'))


def script(raw,table,index,base=0):
    pc=struct.unpack_from('<I',raw,table+4*index)[0]-base;rows=[]
    for _ in range(128):
        op=struct.unpack_from('<H',raw,pc)[0]
        if op in (0,1):return rows
        n=OP_LEN_HW[op];rows.append((op,struct.unpack_from('<'+'h'*(n-1),raw,pc+2)));pc+=2*n
    raise AssertionError('unterminated source script')


def owner_flags(raw):
    table=struct.unpack_from('<I',raw,32)[0];section=struct.unpack_from('<I',raw,36)[0]
    frames=struct.unpack_from('<I',raw,section+20)[0];clock=animation=movement=0;signals={}
    for op,args in script(raw,table,1):
        if op==4:
            p=struct.unpack_from('<I',raw,frames+4*args[0])[0]
            animation=clock+sum(raw[p+5+2*i] or 256 for i in range(raw[p]))
        elif op==5:clock=max(clock,animation)
        elif op==23:movement=clock+args[1]
        elif op==21:clock=max(clock,movement)
        elif op==3:clock+=args[0]
        elif op==26:signals[args[1]]=clock
    return signals


def jump(first,args,home,elapsed):
    mode,n,x,y,z,vx,vy,vz=args
    anchor=first if mode==1 else home
    end=[anchor[0]+x,anchor[1]+y,z]
    if elapsed>=n:return dict(zip('xyz',end))
    result=[]
    for start,finish,v in zip(first,end,(vx,vy,vz)):
        velocity=v*2048
        acceleration=math.trunc(((finish-start)*4096-velocity*n)/(n*(n-1)//2))
        value=round(start*4096)
        for _ in range(elapsed):value+=velocity;velocity+=acceleration
        result.append(value/4096)
    return dict(zip('xyz',result))


def reference():
    cases=[]
    for region in ('b','c'):
        scene=json.loads((ROOT/f'game/tests/fixtures/world_{region}_party_art.json').read_text())
        raw,_=source('/'+region.upper()+'_DATA.BIN');base=0x80080000
        ptr=lambda off:struct.unpack_from('<I',raw,off)[0]-base
        directory=ptr(ptr(ptr(0)+12));record=ptr(ptr(directory+12)+4*(4 if region=='b' else 2))
        table=ptr(record+40);section=ptr(record+44);frames=ptr(section+20)
        ops=script(raw,table,3,base)
        back,retreat=ops[2][1],ops[10][1]
        clips=[]
        for clip in (0,11):
            p=ptr(frames+4*clip)
            clips.append([(raw[p+4+2*i],raw[p+5+2*i] or 256) for i in range(raw[p])])
        def pose(clip,elapsed,loop):
            if loop:elapsed%=sum(t for _,t in clip)
            for e,t in clip:
                if elapsed<t:return e
                elapsed-=t
            return clip[-1][0]
        for actor,name,filename in OWNERS:
            member,_=source('/'+filename+'.BIN');flags=owner_flags(member);start=flags[1]+1
            # Later enemy slots observe the owner's signals in the same actor pass.
            returned=max(max(start+back[1],flags[2])+1,flags[4])+ops[9][1][0]
            release=returned+retreat[1]
            for target,position in enumerate(scene['enemy_positions']):
                home=[position[a] for a in 'xyz']
                for restored in ((False,True) if region=='b' else (False,)):
                    origin=[home[0],home[1],home[2] if restored else 0]
                    last=list(jump(origin,back,home,back[1]).values());samples=[]
                    for tick in range(start,release+32):
                        age=tick-start
                        point=jump(origin,back,home,age+1) if tick<returned else jump(last,retreat,home,tick-returned+1)
                        samples.append(dict(position=point,pose=pose(clips[1],age+1,False) if age<back[1] else pose(clips[0],age-back[1],True)))
                    cases.append(dict(region=region,actor=actor,target=target,restored=restored,start=start,retreat_start=returned,release=release,samples=samples))
    return dict(schema='suikoden-physical-dodge-vectors/1',provenance='Raw owner signal/F tables, enemy script3 and independent integer Q12 integration; static test vectors only',cases=cases)


class PhysicalDodge(unittest.TestCase):
    def test_miss_dispatch_skips_critical_and_variance_then_uses_slot3_and_common_return(self):
        words={0x800F4AE4:0x0C03DF57,0x800F4AEC:0x1440003A,0x800F4B74:0x30420004,
            0x800F4BC8:0x24635C1C,0x800F4BCC:0x0803D2F8,0x800F4BD8:0x0C03D20D,
            0x800F5C54:0x30420001,0x800F5C88:0x8C46000C,0x800F5C8C:0x0C038E08,
            0x800F5CB0:0x24635CD0,0x800F5D10:0x30420004,
            0x800E3894:0x00002821,0x800E394C:0xA4430012,0x800E396C:0x2442FFFF,
            0x800E3978:0x1C400007,0x800E45E4:0x84820010,0x800E45EC:0x1C400005}
        for pc,wanted in words.items():self.assertEqual(maindec.mword(pc),wanted,hex(pc))
        calls=[(word&0x3FFFFFF)<<2|0x80000000 for _,word,_ in maindec.dis(0x800F5C1C,45) if word>>26==3]
        self.assertEqual(calls,[0x800E3820])

    def test_three_defender_scripts_and_all_five_earlier_owner_signals(self):
        for region,table in (('b',0x20FD8),('b',0x236C8),('c',0x2289C)):
            raw,_=source('/'+region.upper()+'_DATA.BIN');spec=enemy_dodge(raw,table)
            rows=script(raw,table,3,0x80080000)
            self.assertEqual((spec['animation'],spec['ready_wait']),(11,10))
            self.assertEqual(rows[2],(23,(1,15,-32,0,0,0,0,-6)))
            self.assertEqual(rows[10],(23,(3,15,0,0,0,0,0,-6)))
            mutated=bytearray(raw);pc=struct.unpack_from('<I',raw,table+12)[0]-0x80080000
            struct.pack_into('<h',mutated,pc+2,1)
            with self.assertRaisesRegex(ValueError,'source changed'):enemy_dodge(mutated,table)
        for _,name,filename in OWNERS:
            raw,_=source('/'+filename+'.BIN');flags=owner_flags(raw);actual=party_attack_sequence(name)
            self.assertEqual((actual['dodge_start_tick'],actual['impact_tick'],actual['return_tick']),(flags[1]+1,flags[2]+1,flags[4]+1))

    def test_independent_vectors_and_regenerated_world_data(self):
        expected=reference();self.assertEqual(len(expected['cases']),20)
        self.assertEqual(expected,json.loads(FIXTURE.read_text()))
        for region in ('b','c'):
            self.assertEqual(battle_export(region),json.loads((ROOT/f'game/assets/world_{region}_battle.json').read_text()))


if __name__=='__main__':
    if '--write' in sys.argv:FIXTURE.write_text(json.dumps(reference(),separators=(',',':'))+'\n')
    else:unittest.main()
