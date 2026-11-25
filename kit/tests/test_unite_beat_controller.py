"""Independent callback words, descriptor tables and frame clocks for Beat'em up."""
import copy
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import actor_script
import battle_unite_camera
import disc
import journey_battle
import unite_beat_controller as producer
import unite_reaction_assets


def raw_descriptor(source):
    raw=disc.extract(source['source']['lba'],source['source']['size'])
    table=struct.unpack_from('<I',raw,32)[0]
    start=struct.unpack_from('<I',raw,table+4*source['script'])[0]
    cursor=start; result=[]
    while True:
        op=struct.unpack_from('<h',raw,cursor)[0]
        words=2+struct.unpack_from('<h',raw,cursor+2)[0] if op==42 else actor_script.OP_LEN_HW[op]
        words=max(1,words)
        args=list(struct.unpack_from('<'+'h'*(words-1),raw,cursor+2))
        result.append(dict(op=op,args=args));cursor+=2*words
        if op in (0,1,2):break
    return start,cursor-start,result


def animation(raw,index):
    section=struct.unpack_from('<I',raw,36)[0]
    table=struct.unpack_from('<I',raw,section+20)[0]
    start=struct.unpack_from('<I',raw,table+4*index)[0]
    count,flags=raw[start:start+2]
    frames=[dict(pose=raw[start+4+2*i],updates=raw[start+5+2*i] or 256) for i in range(count)]
    return flags,frames


class BeatController(unittest.TestCase):
    def test_callback_words_and_descriptor_ownership(self):
        image=battle_unite_camera.Image()
        pins={0x800FD478:0x8E950004,0x800FD49C:0x96430042,0x800FD4A0:0x34020001,
              0x800FD4E0:0x34050012,0x800FD508:0xA0950004,0x800FD5B8:0x8E420008,
              0x800FD5C0:0x8C46002C,0x800FD5C8:0x0C038E08,0x800FD5D0:0x34020063,
              0x800FD5D4:0xA6420042,0x800FD634:0x8C460028,0x800FD638:0x0C038E08,
              0x800FD6AC:0x8C46003C,0x800FD6B0:0x0C038E08,
              0x800FD6E8:0x8E840004,0x800FD6F0:0x3406001E,0x800FD6F4:0x0C03E522,
              0x800FD730:0x30420004,0x800FD750:0x0C03E5C6,
              0x8016BAC4:0x800E39A0,0x800E39B4:0x10A00006,0x800E39C0:0x10A2000B,
              0x800E39EC:0xA0400002,0x800E3A08:0x0C038ACF,0x800E3A0C:0xA2000003,
              0x800E3A34:0x00001021,0x800E3A44:0x00001021}
        for address,word in pins.items():self.assertEqual(image.word(address),word,hex(address))
        data=producer.build()
        streams=[m['entry'] for m in data['members']]+[data['members'][1]['followup'],data['child']['script'],data['first_reaction']['script'],data['damage']['recipient']]
        for stream in streams:
            start,length,ops=raw_descriptor(stream)
            self.assertEqual((start,length),(stream['source_offset'],stream['byte_length']))
            self.assertEqual(ops,stream['operations'])
        self.assertEqual(data['child']['offset_q12'],[-40960,0,-81920])
        self.assertEqual(data,json.loads(producer.REPORT.read_text()))

    def test_source_clocks_use_each_members_frames_and_embedded_returns(self):
        data=producer.actor_programs()
        raw_pahn=disc.extract(data['source']['members'][0]['entry']['source']['lba'],data['source']['members'][0]['entry']['source']['size'])
        raw_bell=disc.extract(data['source']['members'][1]['entry']['source']['lba'],data['source']['members'][1]['entry']['source']['size'])
        p=lambda i:sum(f['updates'] for f in animation(raw_pahn,i)[1])
        b=lambda i:sum(f['updates'] for f in animation(raw_bell,i)[1])
        first=p(4)+p(6)+20+8+2
        transition=first+p(16)+30
        child=transition+8+1+b(16)
        damage=child+1+b(17)+18
        ready=transition+80
        self.assertEqual(data['expected'],dict(first_reaction=first,transition=transition,child=child,damage=damage,cleanup=max(ready,damage),child_hidden=child+91,child_retired=child+92,pahn_complete=ready+p(10)+20+p(12)))
        self.assertEqual(data['expected'],dict(first_reaction=61,transition=262,child=298,damage=329,cleanup=342,child_hidden=389,child_retired=390,pahn_complete=395))
        for resource,raw in zip(data['animations']['resources'],(raw_pahn,raw_bell),strict=True):
            for clip in resource['clips']:
                flags,frames=animation(raw,clip['id'])
                self.assertEqual([dict(pose=f['pose'],updates=f['updates']) for f in clip['frames']],frames)
                self.assertEqual(clip['advances'],bool(flags&1));self.assertEqual(clip['loop'],bool(flags&2))
        serialized=json.loads(json.dumps(data))
        self.assertEqual(serialized,json.loads(producer.ACTORS.read_text()))
        self.assertEqual(serialized,json.loads((ROOT/'game/tests/fixtures/beat_actors.json').read_text()))

    def test_recipient_prefix_holds_the_inherited_lock_until_bell_replaces_it(self):
        data=producer.recipient_programs()
        first,final=data['programs']
        self.assertEqual((first['variant'],first['duration'],len(first['sounds'])),(1,261,17))
        self.assertTrue(first['retain_lock']);self.assertNotIn('locks_target',first)
        self.assertEqual(first['signals'],[dict(at=260,bits=2,set=True)])
        original=next(r for r in unite_reaction_assets.reactions(battle_unite_camera.report(),include_sounds=True) if r['record']==27)
        self.assertEqual(final,original)
        self.assertEqual(data,json.loads(producer.RECIPIENTS.read_text()))
        self.assertEqual(data,json.loads((ROOT/'game/tests/fixtures/beat_recipients.json').read_text()))
        with self.assertRaisesRegex(ValueError,'Unbound inherited recipient lock'):
            unite_reaction_assets.reactions([],inherited_locks=((27,1),))
        with self.assertRaisesRegex(ValueError,'Unreleased recipient lock'):
            first_source=data['source'][0];prefix=first_source['operations'][:data['first_terminal']['operation']]
            source=dict(first_source,operations=prefix,local_timing=journey_battle.script_events([],[(o['op'],tuple(o['args'])) for o in prefix],initial_movement_wait=True))
            unite_reaction_assets.reactions([dict(index=27,variant=1,target_reaction=source)],lock_handoffs=((27,1,0),),inherited_locks=((27,1),))

    def test_batch_bundle_preserves_other_records_and_compiles_beat_stages(self):
        import export_unite_programs
        with tempfile.TemporaryDirectory() as directory:
            _,proof=export_unite_programs.export(directory,include_flash=True,include_master=True,include_couple=True,include_warriors=True,include_martial=True,include_beat=True)
            bundle=json.loads((Path(directory)/'unites.json').read_text())
        self.assertEqual(bundle,json.loads((ROOT/'game/tests/fixtures/beat_actor_library.json').read_text()))
        self.assertEqual(bundle['schema'],'suikoden-unite-actors/28')
        baseline=json.loads((ROOT/'game/tests/fixtures/martial_actor_library.json').read_text())
        self.assertEqual(bundle['unites'][:27]+bundle['unites'][28:],baseline['unites'][:27]+baseline['unites'][28:])
        binding=bundle['unites'][27];expected=producer.actor_programs()
        self.assertEqual(binding['beat_child'],expected['child'])
        self.assertEqual(binding['transition'],dict(trigger_member=0,signal=16,dispatches=[dict(member=1,program='ronnie/beat_followup')]))
        actual={p['id']:p for p in bundle['programs']['programs']}
        for program in expected['programs']['programs']:self.assertEqual(actual[program['id']],program)
        self.assertEqual(proof['beat_controller'],producer.build())
        for member,resource in zip(expected['source']['members'],expected['animations']['resources'],strict=True):
            exported=next(r for r in bundle['animations']['resources'] if r['id']==resource['id'])
            clips={c['id']:c for c in exported['clips']}
            for clip in resource['clips']:self.assertEqual(clips[clip['id']],clip)

    def test_recipient_export_preserves_raw_attachments_and_prior_spell_geometry(self):
        import export_spell_scenes
        actor_art=export_spell_scenes.actor_art
        encounters=export_spell_scenes.encounters
        packet,images,proof=export_spell_scenes.build(include_couple=True,include_warriors=True,include_martial=True,include_beat=True)
        self.assertEqual(packet['schema'],'suikoden-spell-scenes/50')
        self.assertEqual([r for r in packet['unite_reactions'] if r['record']==27],producer.recipient_programs()['programs'])
        raw,origin=actor_art.source('/A_DATA.BIN')
        _,_,directory,_=encounters.chain(raw)
        table=struct.unpack_from('<I',raw,directory+12-encounters.BASE)[0]
        for identifier,native in export_spell_scenes.ENEMY_IDS.items():
            record=struct.unpack_from('<I',raw,table+4*native-encounters.BASE)[0]-encounters.BASE
            section=struct.unpack_from('<I',raw,record+44)[0]-encounters.BASE
            ftable=struct.unpack_from('<I',raw,section+20)[0]-encounters.BASE
            f=struct.unpack_from('<I',raw,ftable+4)[0]-encounters.BASE
            pose=raw[f+4]
            etable=struct.unpack_from('<I',raw,section+16)[0]-encounters.BASE
            entry=struct.unpack_from('<I',raw,etable+4*pose)[0]-encounters.BASE
            expected=[raw[entry+6+i]-raw[entry+4+i] for i in range(2)]
            exported=next(p for p in packet['hurt_poses'] if p['id']==identifier)
            self.assertEqual(exported['source_attachment'],expected)
            self.assertEqual(exported['impact_offset'],[((v+128)%256)-128 for v in expected])
        baseline,previous,_=export_spell_scenes.build(include_couple=True,include_warriors=True,include_martial=True)
        self.assertEqual(packet['spells'],baseline['spells']);self.assertEqual(packet['entries'],baseline['entries'])
        self.assertEqual([{k:v for k,v in p.items() if k!='source_attachment'} for p in packet['hurt_poses']],baseline['hurt_poses'])
        self.assertEqual([r for r in packet['unite_reactions'] if r['record']!=27],[r for r in baseline['unite_reactions'] if r['record']!=27])
        self.assertEqual(len(images),len(previous))
        for current,old in zip(images,previous,strict=True):self.assertEqual((current.size,current.tobytes()),(old.size,old.tobytes()))

    def test_changed_callback_or_descriptor_refuses(self):
        image=battle_unite_camera.Image()
        for start,_,_ in producer.SPANS:
            changed=bytearray(image.data);changed[start-image.base]^=1
            with self.assertRaisesRegex(ValueError,'controller changed'):
                producer.build(battle_unite_camera.Image(bytes(changed),image.base))
        original=producer.source.field.source
        raw,origin=original('/PAN.BIN');changed=bytearray(raw)
        offset=struct.unpack_from('<I',raw,struct.unpack_from('<I',raw,32)[0]+4*15)[0]
        changed[offset+2]^=1
        with patch.object(producer.source.field,'source',return_value=(bytes(changed),origin)):
            with self.assertRaisesRegex(ValueError,'descriptor changed'):producer.descriptor('/PAN.BIN',15)


if __name__=='__main__':unittest.main()
