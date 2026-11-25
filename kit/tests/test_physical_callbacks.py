#!/usr/bin/env python3
"""Static callback control-flow pins and independent Q12 motion references."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import maindec
from export_first_room import source
from journey_battle import script

FIXTURE=ROOT/'game/tests/fixtures/physical_callback_vectors.json'


def signed(value):return ((value+(1<<31))%(1<<32))-(1<<31)
def quotient(n,d):return (abs(n)//d)*(-1 if n<0 else 1)


def reference():
    rows=[]
    positions=[([-12345,76543,-640123],[25003,-54321,123]),
               ([520195,-190403,1007],[-252115,28490,-11111]),
               ([-2147483600,2147483500,-2147483000],[127,-211,-350])]
    for state in (5,7):
        for first,home in positions:
            divisor=3 if state==5 else 2
            last=[signed(p+quotient(signed(h-p),divisor)) for p,h in zip(first,home)]
            velocity=[16384,0,-12288]
            acceleration=[quotient(signed(signed(d-p)-v*20),20*19) for p,d,v in zip(first,last,velocity)]
            rows.append(dict(kind='airborne',state=state,first=first,home=home,owner=[0,0,0],attachment_x=0,
                             destination=last,velocity=velocity,acceleration=acceleration))
    for first,owner,x in (([-12285,245755,-2047991],[315409,-184308,900001],-7),
                          ([81579,-72003,-34167],[-45112,67343,19233],130)):
        last=[*owner[:2],x*4096];velocity=[0,0,-24576]
        acceleration=[quotient(signed(signed(d-p)-v*20),190) for p,d,v in zip(first,last,velocity)]
        rows.append(dict(kind='decoy',state=0,first=first,home=[0,0,0],owner=owner,attachment_x=x,
                         destination=last,velocity=velocity,acceleration=acceleration))
    for row in rows:
        p=row['first'].copy();v=row['velocity'].copy();samples=[]
        for tick in range(1,21):
            p=[signed(a+b) for a,b in zip(p,v)]
            v=[signed(a+b) for a,b in zip(v,row['acceleration'])]
            if tick==20:p=row['destination'].copy()
            samples.append(dict(position=p.copy(),velocity=v.copy()))
        row['samples']=samples
    raw,_=source('/JUP.BIN');section=struct.unpack_from('<I',raw,36)[0];table=struct.unpack_from('<I',raw,section+20)[0]
    f=struct.unpack_from('<I',raw,table+20*4)[0]
    duration=sum(raw[f+5+2*i] or 256 for i in range(max(1,raw[f])))
    return dict(schema='suikoden-physical-callback-vectors/1',motions=rows,
        shrike=dict(flip=61,pulse_positive=101,pulse_negative=103,contact=102,restore=132,complete=154,child_retired=123),
        trick=dict(animation20=duration,callback=32+duration,contact=53+duration,retired=164+duration,response_complete=89+duration))


class PhysicalCallbacks(unittest.TestCase):
    def test_callback_tables_and_complete_original_helpers_are_pinned(self):
        self.assertEqual(maindec.mword(0x8016BB90),0x800F3544)
        self.assertEqual(maindec.mword(0x8016BB98),0x800F387C)
        for first,last,digest in ((0x800F3544,0x800F387C,'8283a2379640247221b6d82b497a3363eabd41c65295394e56658d51429ea1d0'),
                                  (0x800F387C,0x800F3AA0,'85704a5ee002912a7a8e50bb92f6cdde2f2f4ed5959999d4f79c3c8c35637381')):
            self.assertEqual(hashlib.sha256(maindec.body()[first-maindec.MBASE:last-maindec.MBASE]).hexdigest(),digest)
        expected={0:0x800F35B0,1:0x800F35F0,2:0x800F3608,3:0x800F35F8,4:0x800F3868,
                  5:0x800F3634,6:0x800F3868,7:0x800F375C,8:0x800F3868,99:0x800F3830}
        for i,p in expected.items():self.assertEqual(maindec.mword(0x800C125C+4*i),p)
        # The airborne helper adds both i and i+1, then removes the final n.
        n=20;total=0
        for i in range(n):total+=i;total+=i+1
        total-=n
        self.assertEqual(total,380)
        for pc,w in {0x800F33AC:0x01034021,0x800F33BC:0x01034021,0x800F33C0:0x01034023,
                     0x800F35D8:0xA0430079,0x800F35E0:0xA4A3001C,0x800F35EC:0xA443001A,
                     0x800F35FC:0xAD0212FC,0x800F3604:0xA5021324,
                     0x800F3690:0xA6020010,0x800F3694:0x34024000,0x800F369C:0x2402D000,
                     0x800F3924:0x00025B00,0x800F3A10:0xA44A0010,0x800F39B0:0x2407A000}.items():
            self.assertEqual(maindec.mword(pc),w,hex(pc))

    def test_decoy_contact_keeps_variance_and_hurt_dispatch_but_auxiliary_hp_is_rejected(self):
        words={0x800F3A4C:0x30420002,0x800F3A58:0x0C03DFA4,0x800F3A5C:0x02402821,
               0x800F3A64:0x0C038595,0x800F3A68:0x00022840,
               0x800F3A74:0x24C6C448,0x800F3A78:0x0C038E08,0x800F3A80:0xAE200054,
               0x800E1694:0x8C430024,0x800E16A8:0x0076182A,0x800E16AC:0x1460001C,
               0x800E1720:0x080386D4,0x800E1724:0x2402FFFF}
        for pc,w in words.items():self.assertEqual(maindec.mword(pc),w,hex(pc))
        calls=[pc for pc,w,_ in maindec.dis(0x800F7E90,(0x800F8174-0x800F7E90)//4) if w==0x0C051F8E]
        self.assertEqual(calls,[0x800F7F10,0x800F7F3C])
        self.assertEqual(maindec.mword(0x800F7F08),0x1040000C)  # mutually exclusive variance arms

    def test_source_programs_drive_the_selected_callback_phases(self):
        raw,_=source('/KAS.BIN');rows=script(raw,14)
        self.assertIn((35,(0,8)),rows)
        self.assertEqual([args[0] for op,args in rows if op==30],[0,1,99])
        raw,_=source('/JUP.BIN');rows=script(raw,10)
        self.assertIn((35,(0,10)),rows)
        i=rows.index((35,(0,10)))
        self.assertEqual(rows[i+1:i+4],[(3,(1,)),(21,()),(26,(0,2))])
        self.assertEqual(reference(),json.loads(FIXTURE.read_text()))


if __name__=='__main__':
    if '--write' in sys.argv:FIXTURE.write_text(json.dumps(reference(),separators=(',',':'))+'\n')
    else:unittest.main()
