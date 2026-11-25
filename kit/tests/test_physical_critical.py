#!/usr/bin/env python3
"""Static critical dispatch, bounded shared art and pre-integration impact vectors."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import actor_script
import battle_bin
import disc
import export_battle_trial
from export_first_room import source
from export_world_travel import party_attack_sequence,critical_camera

NAMES=['hero','gremio','pahn','viktor','yam_koo','tai_ho']
FILES=['SHU','GRE','PAN','VIC','YAM','TAI']
FIXTURE=ROOT/'game/tests/fixtures/physical_impact_vectors.json'


def operations(raw,index):
    table=struct.unpack_from('<I',raw,32)[0]
    pc=struct.unpack_from('<I',raw,table+4*index)[0];rows=[]
    for _ in range(128):
        op=struct.unpack_from('<H',raw,pc)[0]
        if op==0:return rows
        size=actor_script.OP_LEN_HW[op]
        rows.append((op,struct.unpack_from('<'+'h'*(size-1),raw,pc+2)))
        pc+=size*2
    raise AssertionError('unterminated source script')


def reference():
    cases=[]
    for region in ('b','c'):
        scene=json.loads((ROOT/f'game/tests/fixtures/world_{region}_party_art.json').read_text())
        entries=scene['extra_party_attacks'] if region=='b' else scene['c_tracks']['extra_party_attacks']
        reactions={r['id']:r['target_hurt'] for r in entries}
        if region=='c':reactions['hero']=[scene['actors'][6+i]['hurt'] for i in range(2)]
        for actor in (0,1,2,4,5):
            timing=party_attack_sequence(NAMES[actor])
            for target,track in enumerate(reactions[NAMES[actor]]):
                for critical in (False,True):
                    births=[]
                    for spawn in timing['impacts']['critical' if critical else 'ordinary']:
                        age=spawn['at'];point=track[age-1]['position'] if age else dict(scene['enemy_positions'][target],z=0)
                        pose=track[age]['pose']
                        births.append(dict(at=timing['impact_tick']+age,animation=spawn['animation'],
                            position_q12=[round(point[axis]*4096)+spawn['offset'][i]*4096 for i,axis in enumerate('xyz')],
                            center=scene['actors'][6+target]['impact_offsets'][pose]))
                    following=(target+1)%len(scene['enemy_positions'])
                    focus=track[timing['return_tick']-timing['impact_tick']]['position'] if following==target else scene['enemy_positions'][following]
                    cases.append(dict(region=region,actor=actor,target=target,critical=critical,spawns=births,
                        repeat_target=following,repeat_focus_q12=[round(focus['x']*4096),round(focus['y']*4096),-81920]))
    return dict(schema='suikoden-physical-impact-vectors/1',camera=critical_camera(),cases=cases)


class CriticalSource(unittest.TestCase):
    def test_dispatch_damage_reaction_slot_and_unbounded_pose_lookup_words(self):
        raw=disc.extract(17976,757760)[2048:]
        words={0x800F4864:0x0C03E0D7,0x800F4880:0x0C03D8B5,0x800F4884:0xAC620044,
            0x800DE0E0:0x0040F809,0x800DE1C8:0x0C03800D,
            0x800E003C:0x0C0383A8,0x800E0044:0x0C03826F,
            0x800F48A0:0x24635ABC,0x800F48F0:0x8C460004,0x800F48F8:0x0C038E08,
            0x800F5B18:0x0C03DFA4,0x800F5B24:0x00022840,0x800F5B28:0x0C038595,
            0x800F5B2C:0x00A22821,0x800F5BC4:0x8C460020,0x800F5BF0:0x24635CD0,
            0x800E2178:0x90440000,0x800E2188:0x8C620010,0x800E218C:0x00042080,
            0x800E2194:0x00822021,0x800E2198:0x8C820000,
            0x800E1E98:0x90550002,0x800E1EB0:0x001080C0,
            0x800F630C:0xAC830000,0x800F6320:0xAC22C7EC,0x800F6328:0xAC23C7E8,
            0x800F6330:0x34050014}
        for pc,wanted in words.items():self.assertEqual(struct.unpack_from('<I',raw,pc-0x800C0800)[0],wanted,hex(pc))
        self.assertEqual(critical_camera(),dict(updates=20,target=dict(position=[0,0,-81920],angles=[-3538944,0,2097152],c=[0,0,4194304],d=[40960000]*3)))

    def test_ordinary_and_critical_reaction_scripts_have_identical_body_motion(self):
        for name,filename in zip(NAMES,FILES):
            if name=='viktor':continue
            raw,_=source('/'+filename+'.BIN')
            normal,critical=operations(raw,2),operations(raw,8)
            self.assertEqual([(op,a) for op,a in normal if op!=24],[(op,a) for op,a in critical if op!=24])
            timing=party_attack_sequence(name)
            expected_ages=[0,15] if name=='pahn' else [2]
            self.assertEqual([s['at'] for s in timing['impacts']['critical']],expected_ages)
            self.assertEqual([s['animation'] for s in timing['impacts']['critical']], [0,0] if name=='pahn' else [19] if name in ('yam_koo','tai_ho') else [18])
            self.assertEqual(timing['impacts']['white'],[dict(at=0,enabled=True),dict(at=19,enabled=False)] if name=='pahn' else [dict(at=2,enabled=True),dict(at=6,enabled=False)])

    def test_shared_pose_table_extends_to_first_animation_and_allocations_fit(self):
        lba,size=battle_bin.battle_bin_lba();raw=disc.extract(lba,size);base=0x800AA000
        ptr=lambda off:struct.unpack_from('<I',raw,off)[0]-base
        section=ptr(0);ne,nf=struct.unpack_from('<HH',raw,section);et,ft=ptr(section+16),ptr(section+20)
        end=min(ptr(ft+4*i) for i in range(nf))
        self.assertEqual((ne,nf,et,end),(82,23,2076,2468))
        for i in range(98):
            off=ptr(et+4*i)
            self.assertLess(off,et)
            self.assertLessEqual(off+8+raw[off]*8,et)
        for index in (18,19):
            frame=ptr(ft+4*index)
            for i in range(raw[frame]):
                pose=raw[frame+4+2*i]
                self.assertLess(pose,98)
                self.assertLessEqual(raw[ptr(et+4*pose)],raw[frame+2])
        with self.assertRaisesRegex(ValueError,'missing pose'):
            export_battle_trial.section_art(raw,section,base,animation_indices=(18,19))
        poses,_,proof=export_battle_trial.section_art(raw,section,base,animation_indices=(18,19),pose_table_end=end)
        self.assertEqual((len(poses),proof['declared_pose_count']),(98,82))
        for bad in (end+1,et+4*81):
            with self.assertRaisesRegex(ValueError,'proven pose table extent'):
                export_battle_trial.section_art(raw,section,base,animation_indices=(18,19),pose_table_end=bad)

    def test_all_actor_hotpoints_agree_with_raw_draw_headers(self):
        for region in ('b','c'):
            scene=json.loads((ROOT/f'game/tests/fixtures/world_{region}_party_art.json').read_text())
            for i,actor in enumerate(scene['actors']):
                if i<6:
                    raw,_=source('/'+FILES[i]+'.BIN');base=0;section=struct.unpack_from('<I',raw,36)[0]
                else:
                    raw,_=source('/'+region.upper()+'_DATA.BIN');base=0x80080000
                    ptr=lambda off:struct.unpack_from('<I',raw,off)[0]-base
                    directory=ptr(ptr(ptr(0)+12));table=ptr(directory+12)
                    record=ptr(table+4*(4 if region=='b' else 2));section=ptr(record+44)
                ptr=lambda off:struct.unpack_from('<I',raw,off)[0]-base
                table=ptr(section+16);count=struct.unpack_from('<H',raw,section)[0]
                expected=[]
                for pose in range(count):
                    off=ptr(table+4*pose)
                    expected.append([((raw[off+6+k]-raw[off+4+k]+128)%256)-128 for k in range(2)])
                self.assertEqual(actor['impact_offsets'],expected,(region,actor['id']))

    def test_pre_integration_birth_vectors_are_current(self):
        result=reference();self.assertEqual(len(result['cases']),30)
        self.assertEqual(result,json.loads(FIXTURE.read_text()))

    def test_world_white_pixels_match_independent_vram_sampling(self):
        import export_spell_scenes
        from test_export_unite_review import vram_pose
        packet,images,proof=export_spell_scenes.build()
        self.assertEqual({p['id'] for p in packet['physical_white_poses']},{'roc','kobold_type_2'})
        self.assertTrue({'roc','kobold_type_2'}.isdisjoint(p['id'] for p in packet['hurt_poses']))
        for row in proof['physical_hurt_sources']:
            raw=disc.extract(row['source']['lba'],row['source']['size']);base=0x80080000;section=row['section']
            ne,nf,nc,flags=struct.unpack_from('<HHBB',raw,section)
            tables=[struct.unpack_from('<I',raw,section+k)[0]-base for k in (8,12,16,20)]
            rebased=bytearray(raw)
            for slot,table,count in zip((8,12,16,20),tables,(nc,flags&63,ne,nf)):
                struct.pack_into('<I',rebased,section+slot,table)
                for i in range(count):struct.pack_into('<I',rebased,table+4*i,struct.unpack_from('<I',raw,table+4*i)[0]-base)
            expected,ax,ay=vram_pose(rebased,section,row['source_pose'],white=True)
            entry=packet['entries'][row['entry']];actual=images[entry['bitmap']]
            self.assertEqual((actual.size,entry['dx'],entry['dy']),(expected.size,-ax,-ay))
            self.assertEqual(actual.tobytes(),expected.tobytes(),row['id'])


if __name__=='__main__':
    if '--write' in sys.argv:FIXTURE.write_text(json.dumps(reference(),separators=(',',':'))+'\n')
    else:unittest.main()
