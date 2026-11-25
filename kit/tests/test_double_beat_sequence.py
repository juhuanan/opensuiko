#!/usr/bin/env python3
"""Static source guards and integer motion references; no original CPU execution."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import disc
from export_world_travel import battle_export,party_attack_sequence,party_attack_timing

NAMES=('hero','gremio','pahn','yam_koo','tai_ho')
FIXTURE=ROOT/'game/tests/fixtures/double_beat_motion.json'


def divide(n,d):
    return (abs(n)//d)*(-1 if n<0 else 1)


def position(motion,origin,home,target,tick):
    """Integrate integer Q12 velocity/acceleration, independently of the float player."""
    contact=[target[i]+motion['approach']['offset'][axis] for i,axis in enumerate('xyz')]
    if tick<motion['approach_start']:return dict(zip('xyz',origin))
    if tick<motion['return_start']:
        first,last,leap,elapsed=origin,contact,motion['approach'],tick-motion['approach_start']
    else:
        first,last,leap,elapsed=contact,home,motion['retreat'],tick-motion['return_start']
    n=leap['ticks']
    if elapsed>=n:return dict(zip('xyz',last))
    result=[]
    for axis,start,finish in zip('xyz',first,last):
        value=round(start*4096);velocity=round(leap['velocity'][axis]*4096)
        acceleration=divide(round((finish-start)*4096)-velocity*n,n*(n-1)//2)
        for _ in range(elapsed):
            value+=velocity
            velocity+=acceleration
        result.append(value/4096)
    return dict(zip('xyz',result))


def reference():
    cases=[]
    for region,filename in (('b','world_b_party_art.json'),('c','world_c_party_art.json')):
        scene=json.loads((ROOT/'game/tests/fixtures'/filename).read_text())
        extra=scene['extra_party_attacks'] if region=='b' else scene['c_tracks']['extra_party_attacks']
        entries={row['id']:row['targets'] for row in extra}
        if region=='c':entries['hero']=scene['c_tracks']['hero_attacks']
        for actor,name in enumerate(['hero','gremio','pahn','viktor','yam_koo','tai_ho']):
            if name not in NAMES:continue
            timing=party_attack_sequence(name);motion=timing['motion']
            home=[scene['formation_slots'][actor][axis] for axis in 'xyz']
            for current,tracks in enumerate(entries[name]):
                target=[scene['enemy_positions'][current][axis] for axis in 'xyz'];target[2]=0
                # The retained, independently obtained source samples establish
                # first-approach and home-return clocks before changing its origin.
                for tick,sample in enumerate(tracks['unhurt'],1):
                    actual=position(motion,home,home,target,tick)
                    assert actual==sample['position'],(region,name,current,tick,actual,sample['position'])
                next_target=(current+1)%len(scene['enemy_positions'])
                destination=[scene['enemy_positions'][next_target][axis] for axis in 'xyz'];destination[2]=0
                origin=[tracks['unhurt'][timing['return_tick']-2]['position'][axis] for axis in 'xyz']
                cases.append(dict(region=region,actor=actor,current=current,target=next_target,
                    origin=dict(zip('xyz',origin)),positions=[position(motion,origin,home,destination,tick) for tick in range(timing['release_tick'])]))
    return dict(schema='suikoden-double-beat-motion-reference/1',
        provenance='Integer Q12 integration checked against retained world_b_party_art/world_c_party_art source witnesses; test-only geometry, not shipped art',cases=cases)


class DoubleBeatSequence(unittest.TestCase):
    def test_source_toggle_repeat_before_home_and_target_scan_words(self):
        raw=disc.extract(17976,757760)
        self.assertEqual(struct.unpack_from('<I',raw,24)[0],0x800C0800)
        body=raw[2048:]
        self.assertEqual(hashlib.sha256(body).hexdigest(),'e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa')
        words={0x800F4A80:0x3402000E,0x800F4A94:0x30624000,0x800F4A9C:0x3062BFFF,
            0x800F4AA0:0x34624000,0x800F4AA4:0xA602004A,0x800F5D10:0x30420004,
            0x800F5D20:0x0C03DF16,0x800F5D30:0x0C03D247,0x800F5D70:0x0C038E08,
            0x800F7CA8:0x30424000,0x800F7CC0:0x1202001E,0x800F7CF4:0x0C03E1A0,
            0x800F7D0C:0x1602FFEE,0x800F7D30:0xA0500049,
            0x800E3870:0xAC46000C,0x800E3894:0x00002821,0x800E38C8:0xA4510006}
        for pc,wanted in words.items():self.assertEqual(struct.unpack_from('<I',body,pc-0x800C0800)[0],wanted,hex(pc))

    def test_retained_target_scan_vectors_and_pending_gate(self):
        rows=json.loads((ROOT/'game/tests/fixtures/double_beat_targets.json').read_text())
        self.assertEqual(len(rows),410)
        for count,inactive,current,wanted in rows:
            if inactive==(1<<count)-1:
                self.assertIsNone(wanted)
                continue
            cursor=current+1;actual=None
            while cursor!=current:
                if cursor>=count:cursor=0
                if not inactive&(1<<cursor):actual=cursor;break
                cursor+=1
            self.assertEqual(actual,wanted,(count,inactive,current))

    def test_motion_agrees_with_retained_source_tracks_and_repeat_reference(self):
        actual=reference()
        self.assertEqual(len(actual['cases']),15)
        self.assertEqual(actual,json.loads(FIXTURE.read_text()))

    def test_export_schema_requires_motion_without_changing_existing_facts(self):
        for region,version in (('b',25),('c',30)):
            value=battle_export(region)
            self.assertEqual(value,json.loads((ROOT/f'game/assets/world_{region}_battle.json').read_text()))
            self.assertEqual(value['schema'],f'suikoden-world-battle/{version}')
            self.assertEqual([r['id'] for r in value['party_attacks']],list(NAMES))
            for timing in value['party_attacks']:
                self.assertEqual(timing['motion']['ready_tick'],timing['return_tick'])
                self.assertEqual(party_attack_timing(timing['id']),{k:v for k,v in timing.items() if k not in ('motion','impacts','critical_camera','dodge_start_tick')})


if __name__=='__main__':
    if '--write' in sys.argv:
        FIXTURE.write_text(json.dumps(reference(),separators=(',',':'))+'\n')
    else:unittest.main()
