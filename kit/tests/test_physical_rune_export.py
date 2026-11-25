#!/usr/bin/env python3
"""Independent raw-script/F-table checks for the six-technique batch producer."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import actor_script
import character_table
from export_first_room import source
import export_physical_runes as exporter
import export_unite_programs
import journey_battle
import maindec


def independent_stream(raw,offset,table=None,base=0):
    rows=[];visited=set()
    while len(rows)<512:
        if offset in visited:raise AssertionError('source cycle')
        visited.add(offset)
        op=int.from_bytes(raw[offset:offset+2],'little')
        if op==36:
            slot=int.from_bytes(raw[offset+2:offset+4],'little',signed=True)
            offset=int.from_bytes(raw[table+slot*4:table+slot*4+4],'little')-base
            continue
        length=2+int.from_bytes(raw[offset+2:offset+4],'little',signed=True) if op==42 else 1 if op in (0,1,2) else actor_script.OP_LEN_HW[op]
        args=[int.from_bytes(raw[i:i+2],'little',signed=True) for i in range(offset+2,offset+length*2,2)]
        rows.append(dict(op=op,args=args));offset+=2*length
        if op in (0,1,2):return rows
    raise AssertionError('source budget')


class PhysicalRuneExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.packet,cls.proof=exporter.build()

    def test_every_owner_and_recipient_agrees_with_independent_original_script_walk(self):
        names={8:'PAN',9:'KAS',10:'VRE',11:'BEL',12:'JUP'}
        proofs={p['id']:p for p in self.proof['programs']}
        for technique,rune,_,_ in exporter.TECHNIQUES:
            if rune==13:
                raw=maindec.body();table=None;base=maindec.MBASE;offsets=[0x8016C83C-base,0x8016C908-base]
            else:
                raw,_=source('/'+names[rune]+'.BIN');base=0;table=struct.unpack_from('<I',raw,32)[0]
                offsets=[struct.unpack_from('<I',raw,table+4*i)[0] for i in (13,14)]
            for role,off in zip(('owner','recipient'),offsets,strict=True):
                expected=independent_stream(raw,off,table,base)
                self.assertEqual(proofs[f'physical/{technique}/{role}']['operations'],expected)
        self.assertEqual(len(proofs['physical/boar/recipient']['operations']),183)
        falcon=proofs['physical/falcon/owner']['spans']
        self.assertEqual(len(falcon),2)
        self.assertEqual(falcon[0]['tail_slot'],4)
        self.assertEqual(proofs['physical/falcon/owner']['operations'][-1]['op'],0)

    def test_falcon_releases_and_unlocks_before_its_final_return_animation_finishes(self):
        raw,_=source('/VRE.BIN')
        table=struct.unpack_from('<I',raw,32)[0]
        owner=independent_stream(raw,struct.unpack_from('<I',raw,table+13*4)[0],table)
        returning=independent_stream(raw,struct.unpack_from('<I',raw,table+4*4)[0],table)
        release=owner.index(dict(op=9,args=[0]))
        unlock=owner.index(dict(op=16,args=[0,8]))
        self.assertLess(release,unlock)
        self.assertEqual(owner[unlock+1:], [dict(op=4,args=[12]),dict(op=5,args=[]),dict(op=13,args=[2]),dict(op=0,args=[])])
        self.assertEqual(returning[-6:], [dict(op=16,args=[0,1]),dict(op=16,args=[0,8]),dict(op=4,args=[12]),dict(op=5,args=[]),dict(op=13,args=[2]),dict(op=0,args=[])])

    def test_each_provenance_span_is_contiguous_original_bytes(self):
        for program in [*self.proof['programs'],dict(spans=self.proof['callbacks'])]:
            for span in program.get('spans',[]):
                filename=span['source']['file'].split('/')[-1]
                raw,_=source('MAIN.EXE' if filename=='MAIN.EXE' else '/'+filename)
                off=span['source_offset'];end=off+span['byte_length']
                self.assertLessEqual(end,len(raw))
                self.assertEqual(hashlib.sha256(raw[off:end]).hexdigest(),span['sha256'])
        raw=bytearray(maindec.body());raw[0x800F3924-maindec.MBASE]^=1
        with self.assertRaisesRegex(ValueError,'callback source changed'):
            exporter.callback_proofs(raw,{})
        for pc,word in {0x800E5678:0x84630002,0x800E5684:0x00031880,
                        0x800E568C:0x8C660000,0x800E5690:0x0C038E08,
                        0x800F8730:0x30420002,0x800F877C:0x0C038E08,
                        0x800F8858:0x30420002,0x800F8864:0x0C03DFA4,
                        0x800F886C:0x3C038018,0x800F8870:0x8C63A008,0x800F8878:0x00430018,
                        0x800F88B4:0x0C038595,
                        0x800F8884:0x3402000A,0x800F88E0:0x3042FFFD}.items():
            self.assertEqual(maindec.mword(pc),word,hex(pc))

    def test_all_six_families_and_child_references_are_complete(self):
        self.assertEqual([t['id'] for t in self.packet['techniques']],['boar','shrike','falcon','hate','trick','clone'])
        self.assertEqual([t['numerator'] for t in self.packet['techniques']],[20,20,30,30,15,20])
        self.assertEqual([t['recovery_boundaries'] for t in self.packet['techniques']],[2,0,0,0,0,2])
        for technique,initializer in zip(self.packet['techniques'],self.proof['initializers'],strict=True):
            self.assertEqual(maindec.mword(initializer['descriptor']+28),initializer['callback'])
            self.assertEqual(maindec.mword(initializer['numerator_writer'])&65535,technique['numerator'])
            owner=next(p for p in self.proof['programs'] if p['id']==technique['owner_program'])
            self.assertEqual(any(op['op']==40 and op['args']==[7,100] for op in owner['operations']),technique['recovery_boundaries']==2)
        programs={p['id']:p for p in self.packet['programs']['programs']}
        resources={r['id']:r for r in self.packet['animations']['resources']}
        self.assertEqual((len(programs),len(resources)),(21,92))
        for technique in self.packet['techniques']:
            for key in ('owner_program','recipient_program'):self.assertIn(technique[key],programs)
            self.assertTrue(set(technique['members'])<=resources.keys())
        for program in programs.values():
            self.assertEqual(program['instructions'][-1],dict(halt={}))
            self.assertLessEqual(len(program['instructions']),512)
            for instruction in program['instructions']:
                child=instruction.get('command',{}).get('child')
                if not child:continue
                self.assertIn(child['program'],programs)
                self.assertIn(child['resource'],resources)
                self.assertIn(child['animation'],[c['id'] for c in resources[child['resource']]['clips']])
        self.assertEqual(self.packet['techniques'][-1]['members'],[__import__('preparation').stable_id(r['name']) for r in character_table.records()])
        effects={effect for p in self.proof['programs'] for effect in p.get('host_effects',[])}
        self.assertEqual(effects,{'blue_afterimages','palette_cycle','airborne_recipient','decoy_retaliation'})

    def test_recipient_resources_keep_area_local_identity_and_actual_hurt_frames(self):
        expected={'bonbon','mosquito','crow','wild_boar','red_soldier_ant','killer_rabbit','flying_squirrel',
                  'beast_commander','roc','kobold_type_1','kobold_type_2','kobold_type_3','strong_arm'}
        proofs=[p for p in self.proof['resources'] if p.get('role')=='recipient']
        self.assertEqual({p['id'] for p in proofs},expected)
        for proof in proofs:
            raw,_=source('/'+proof['source']['file'].split('/')[-1])
            self.assertEqual(struct.unpack_from('<I',raw,proof['record_source_offset']+44)[0]-0x80080000,proof['section_offset'])
            resource=next(r for r in self.packet['animations']['resources'] if r['id']==proof['id'])
            self.assertEqual([c['id'] for c in resource['clips']],[0,1])
            self.assertEqual(sum(f['updates'] for f in resource['clips'][1]['frames']),1)

    def test_combined_actor_bundle_preserves_unites_and_rejects_conflicting_clips(self):
        import copy
        unites=json.loads((ROOT/'game/tests/fixtures/unite_actor_library.json').read_text())
        before=copy.deepcopy(unites)
        combined=exporter.combine(unites,self.packet)
        self.assertEqual(unites,before)
        self.assertEqual(combined,json.loads((ROOT/'game/tests/fixtures/battle_actor_library.json').read_text()))
        self.assertEqual(combined['unites'],unites['unites'])
        self.assertEqual((len(combined['programs']['programs']),len(combined['animations']['resources'])),(105,92))
        bad=copy.deepcopy(self.packet)
        shared=next(r for r in bad['animations']['resources'] if r['id']=='shared_impacts')
        existing=next(r for r in unites['animations']['resources'] if r['id']=='shared_impacts')
        overlap=next(c for c in shared['clips'] if c['id']==existing['clips'][0]['id'])
        overlap['frames'][0]['updates']+=1
        with self.assertRaisesRegex(ValueError,'conflicting actor animation'):exporter.combine(unites,bad)

    def test_batch_body_child_and_frozen_blue_art_matches_independent_vram_sampling(self):
        from export_first_room import Atlas
        from test_export_unite_review import vram_pose
        identifiers={'hero','gremio','pahn','viktor','yam_koo','tai_ho','maas','kasumi','valeria','ronnie','juppo','bonbon','wild_boar','crow','red_soldier_ant'}
        atlas=Atlas();graphics,proof=exporter.graphics(self.packet,self.proof,atlas,identifiers)
        self.assertEqual({g['id'] for g in graphics},identifiers)
        def pixels(pose):
            r=pose['rect']
            return atlas.image.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
        count=trails=pieces=0;empty=[]
        for graphic,row in zip(graphics,proof,strict=True):
            raw,origin=source('/'+row['source']['file'].split('/')[-1])
            self.assertEqual(origin,row['source'])
            section=row['section_offset'];base=row['pointer_base']
            for pose in graphic['poses']:
                expected,ax,ay=vram_pose(raw,section,pose['id'],packet=True,base=base)
                actual=pixels(pose['sprite'])
                self.assertEqual((actual.size,pose['sprite']['anchor_x'],pose['sprite']['anchor_y']),(expected.size,ax,ay))
                self.assertEqual(actual.tobytes(),expected.tobytes())
                if actual.getchannel('A').getbbox() is None:empty.append((graphic['id'],pose['id']))
                count+=1
                for ordinal,piece in enumerate(pose.get('pieces',[])):
                    expected_piece,px,py=vram_pose(raw,section,pose['id'],base=base,piece_index=ordinal)
                    self.assertEqual((pixels(piece).size,piece['anchor_x'],piece['anchor_y']),(expected_piece.size,px,py))
                    self.assertEqual(pixels(piece).tobytes(),expected_piece.tobytes());pieces+=1
                for age,frozen in enumerate(pose.get('trail',[])):
                    factors=[255*(7-age)//7]*2+[255]
                    tinted=expected.copy()
                    tinted.putdata([(*[(min(31,(p[axis]>>3)*factors[axis]//128)*8+min(31,(p[axis]>>3)*factors[axis]//128)//4) for axis in range(3)],p[3]) for p in expected.get_flattened_data()])
                    self.assertEqual(pixels(frozen).tobytes(),tinted.tobytes());trails+=1
        self.assertEqual((count,trails,pieces),(120,23*8,4))
        self.assertEqual(empty,[('ronnie',13)])

    def test_graphic_requests_keep_source_frozen_pose_and_secondary_child_boundaries(self):
        requests=exporter.graphic_requests(self.packet,{'hero','pahn','kasumi','valeria','ronnie','juppo','bonbon'})
        for identifier in ('hero','pahn','kasumi','valeria','ronnie','juppo'):
            resource=next(r for r in self.packet['animations']['resources'] if r['id']==identifier)
            expected={next(c for c in resource['clips'] if c['id']==i)['frames'][0]['pose'] for i in (5,11)}
            if identifier=='ronnie':expected.add(next(c for c in resource['clips'] if c['id']==18)['frames'][0]['pose'])
            self.assertEqual(requests[identifier]['trails'],expected)
        self.assertEqual(requests['juppo']['secondary'],{12,13,14})
        self.assertEqual(requests['bonbon']['trails'],set())
        with self.assertRaisesRegex(ValueError,'unknown physical graphic'):exporter.graphic_requests(self.packet,{'unknown'})

    def test_all_character_and_recipient_animation_resources_agree_with_raw_f_tables(self):
        for proof in self.proof['resources']:
            source_row=proof['source'];raw,_=source('/'+source_row['file'].split('/')[-1])
            base=proof['pointer_base'];section=proof['section_offset']
            ptr=lambda off:struct.unpack_from('<I',raw,off)[0]-base
            ft=ptr(section+20);et=ptr(section+16)
            resource=next(r for r in self.packet['animations']['resources'] if r['id']==proof['id'])
            self.assertEqual(resource['pose_count'],int.from_bytes(raw[section:section+2],'little'))
            for clip in resource['clips']:
                p=ptr(ft+4*clip['id']);frames=[]
                for i in range(max(1,raw[p])):
                    e,t=raw[p+4+2*i:p+6+2*i];pose=ptr(et+4*e)
                    frames.append(dict(pose=e,updates=t or 256,attachment=[raw[pose+6]-raw[pose+4],raw[pose+7]-raw[pose+5]]))
                self.assertEqual(clip['frames'],frames,(resource['id'],clip['id']))
                self.assertEqual((clip['advances'],clip['loop'],clip['semitransparent']),tuple(bool(raw[p+1]&bit) for bit in (1,2,4)))

    def test_partial_camera_targets_and_hate_auxiliary_bindings_match_writers(self):
        values={t['id']:t for t in self.packet['techniques']}
        for identifier in ('boar','clone','falcon'):
            camera=values[identifier]['initial_camera']
            self.assertTrue(camera['preserve_translation'])
            self.assertEqual(camera['updates'],15)
            for key,pcs in (('angles_q12',(0x800F8948,0,0x800F8954)),('scale_q12',(0x800F895C,)*3)):
                for v,pc in zip(camera[key],pcs,strict=True):
                    word=maindec.mword(pc) if pc else 0
                    raw=(word&65535)<<16
                    self.assertEqual(v,raw-(1<<32) if raw&(1<<31) else raw)
        for identifier in ('shrike','trick'):self.assertIsNone(values[identifier]['initial_camera'])
        camera=values['hate']['initial_camera']
        self.assertEqual([camera[k] for k in ('position_q12','angles_q12','translation_q12','scale_q12')],
                         [list(v) for v in struct.iter_unpack('<3i',maindec.body()[0x8016C9DC-maindec.MBASE:0x8016CA0C-maindec.MBASE])])
        auxiliary=values['hate']['auxiliary']
        self.assertEqual((auxiliary['animation'],auxiliary['owner_value']),(18,1))
        self.assertEqual(auxiliary['position_offset_q12'],[-40960,0,-81920])
        self.assertEqual(auxiliary['attachment'],'recipient_current_pose')
        self.assertEqual(maindec.mword(0x800F8E58),0x34050012)

    def test_tail_dispatch_is_bounded_and_does_not_include_unreachable_bytes(self):
        raw=bytearray(64);struct.pack_into('<I',raw,4,16)
        struct.pack_into('<4h',raw,16,36,1,99,99)
        self.assertEqual(journey_battle.script_at(raw,16),[(36,(1,))])
        with self.assertRaisesRegex(ValueError,'cyclic'):exporter.stream(raw,{},16,0)
        with self.assertRaisesRegex(ValueError,'unbound'):exporter.stream(raw,{},16)
        struct.pack_into('<I',raw,4,32);struct.pack_into('<2h',raw,32,0,0)
        ops,proof=exporter.stream(raw,{},16,0)
        self.assertEqual(ops,[dict(op=0,args=[])])
        self.assertEqual([s['byte_length'] for s in proof],[4,2])

    def test_recipient_clocks_and_zero_wait_use_the_original_timer_poll(self):
        for name,filename,impact,release in (('boar','PAN',261,262),('clone',None,7,37),('falcon','VRE',95,128),('hate','BEL',1,34)):
            if filename:
                raw,_=source('/'+filename+'.BIN');table=struct.unpack_from('<I',raw,32)[0]
                off=struct.unpack_from('<I',raw,table+14*4)[0]
            else:raw=maindec.body();table=None;off=0x8016C908-maindec.MBASE
            rows=independent_stream(raw,off,table)
            clock=movement=0;actual_impact=actual_release=None
            for row in rows:
                op,args=row['op'],row['args']
                if op==3:clock+=max(1,args[0])
                elif op in (23,33):movement=clock+max(1,args[1])
                elif op==22:movement=clock+args[0]
                elif op==21:clock=max(clock,movement)
                elif op==30:clock+=1
                elif op==29:clock+=1  # HP callback clears its contact signal on the next update.
                elif op==26 and args==[0,2]:actual_impact=clock
                elif op==16 and args[0]==0 and args[1]&8:actual_release=clock
            self.assertEqual((actual_impact,actual_release),(impact,release),name)
        for pc,w in {0x800E394C:0xA4430012,0x800E3964:0x94820012,
                     0x800E396C:0x2442FFFF,0x800E3974:0x00021400,0x800E3978:0x1C400007}.items():
            self.assertEqual(maindec.mword(pc),w)
        self.assertEqual(journey_battle.script_events([],[(3,(0,)),(0,())])['duration'],1)

    def test_candidate_is_deterministic_and_preserves_unite_export(self):
        fixture=json.loads((ROOT/'game/tests/fixtures/physical_actor_library.json').read_text())
        self.assertEqual(self.packet,fixture)
        with tempfile.TemporaryDirectory(prefix='physical-rune-export-') as scratch:
            a,b=Path(scratch)/'one',Path(scratch)/'two'
            exporter.export(a);exporter.export(b)
            for name in ('physical_runes.json','provenance.json','battle_actors.json','battle_actors.provenance.json'):self.assertEqual((a/name).read_bytes(),(b/name).read_bytes())
            self.assertEqual(json.loads((a/'battle_actors.json').read_text()),json.loads((ROOT/'game/tests/fixtures/battle_actor_library.json').read_text()))
            export_unite_programs.export(Path(scratch)/'unites')
            self.assertEqual(json.loads((Path(scratch)/'unites/unites.json').read_text()),json.loads((ROOT/'game/tests/fixtures/unite_actor_library.json').read_text()))
        with self.assertRaisesRegex(ValueError,'candidates'):exporter.export(ROOT/'kit/work/accepted/physical')


if __name__=='__main__':unittest.main()
