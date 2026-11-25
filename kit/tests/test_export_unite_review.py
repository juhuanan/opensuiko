#!/usr/bin/env python3
"""Independent raster and package checks for the batched Unite review export."""
import hashlib
import json
import struct
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import disc
import export_battle_sprite_sections as reference
import export_unite_review as exporter
from psx_vram import PsxVram, rgb555_to_rgb888
from lzss import decode_strict


def vram_pose(raw, section, index, *, packet=False, white=False, base=0, piece_index=None, palette_row=None):
    """Independent uploader/consumer model for the new Elf body poses."""
    ne,nf,nc,flags=struct.unpack_from('<HHBB',raw,section)
    assert nc<=5 and raw[section+6:section+8]==bytes(2)
    ct,dt,et=[p-base for p in struct.unpack_from('<III',raw,section+8)]
    vram=PsxVram()
    for page in range(nc):
        blob=struct.unpack_from('<I',raw,ct+page*4)[0]-base
        size=struct.unpack_from('<I',raw,blob)[0]
        plane=decode_strict(raw[blob+4:blob+4+size])
        vram.upload_rect(320+64*page,0,64,128,plane)
    words=32 if flags&0xC0 else 256
    for palette in range(flags&63):
        start=struct.unpack_from('<I',raw,dt+palette*4)[0]-base
        vram.upload_rect(0,480+palette,words,1,raw[start:start+words*2])
    if white or palette_row is not None:
        import maindec
        start=0x8016B8A8-maindec.MBASE+64*(palette_row or 0)
        vram.upload_rect(0,480,32,1,maindec.body()[start:start+64])
    header=struct.unpack_from('<I',raw,et+index*4)[0]-base
    count,_,width,height,ax,ay=raw[header:header+6]
    pieces=[tuple(raw[header+8+k*8:header+16+k*8]) for k in range(count)]
    extra=0 if packet else 1
    width=max([width]+[p[0]+p[4]+extra for p in pieces]);height=max([height]+[p[1]+p[5]+extra for p in pieces])
    image=Image.new('RGBA',(width,height))
    for ordinal,(x,y,page,tile,wm,hm,palette,flip) in enumerate(pieces):
        part=Image.new('RGBA',(wm+extra,hm+extra))
        for py in range(hm+extra):
            for px in range(wm+extra):
                value=vram.sample_texel(128+(320+64*page)//64,(tile&15)*8+px,(tile>>4)*8+py)
                word=vram.get_word(value,480+palette)
                part.putpixel((px,py),(*rgb555_to_rgb888(word),255 if word else 0))
        if flip&2:part=part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if flip&1:part=part.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        if piece_index==ordinal:return part,ax-x,ay-y
        image.alpha_composite(part,(x,y))
    if piece_index is not None:raise ValueError('missing independent pose piece')
    return image,ax,ay


class ReviewBaseSafety(unittest.TestCase):
    def test_standalone_review_rejects_base_requiring_enemy_actor_library(self):
        with tempfile.TemporaryDirectory(prefix='unite-base-actors-') as temporary:
            base = Path(temporary)/'base'
            battle = base/'battle'
            battle.mkdir(parents=True)
            for policy in ('source_melee','source_commander','source_rabbit'):
                (battle/'trial.json').write_text(json.dumps(dict(enemies=[dict(id='bonbon', action_policy=policy)])))
                with self.assertRaisesRegex(ValueError, 'requires enemy actor bindings'):
                    exporter.export(Path(temporary)/'review', base=base, include_martial=True, scenario_records=(29,))

    def test_review_output_cannot_overlap_base_battle(self):
        with tempfile.TemporaryDirectory(prefix='unite-base-safety-') as temporary:
            base = Path(temporary) / 'episode'
            for output in (base, base / 'battle', base / 'battle' / 'review'):
                with self.assertRaisesRegex(ValueError, 'overlaps'):
                    exporter.export(output, base=base)
                self.assertFalse(output.exists())


class UniteReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='suikoden-unite-review-test-')
        cls.root = Path(cls.temp.name)
        cls.proof = exporter.export(cls.root)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_all_qualified_native_packages_and_source_member_bindings(self):
        self.assertEqual(json.loads((self.root/'record_05/trial.json').read_text()),json.loads((ROOT/'game/tests/fixtures/blacksmith_battle.json').read_text()))
        self.assertEqual([s['record'] for s in self.proof['scenarios']], [0,1,2,3,4,5,6,7,8,9,11,12,13,17,18,19,20,21,22,23,24,25,26,28,30])
        for scenario in self.proof['scenarios']:
            directory = self.root / scenario['directory']
            content = json.loads((directory / 'trial.json').read_text())
            actor_bundle = json.loads((directory / 'unites.json').read_text())
            self.assertEqual(len(actor_bundle['unites']),32)
            self.assertEqual(len(actor_bundle['programs']['programs']),84)
            self.assertEqual(len(actor_bundle['animations']['resources']),53)
            self.assertEqual(content['schema'], 'suikoden-battle-trial/33')
            self.assertEqual(content['initial_party'][:len(scenario['members'])], scenario['members'])
            self.assertEqual(len(content['initial_party']),6)
            self.assertEqual(len(set(content['initial_party'])),6)
            binding=next(u for u in actor_bundle['unites'] if u['record']==scenario['record'])
            self.assertIn(binding['name']+':', content['encounters'][0]['title'])
            self.assertEqual(len(content['party']), 44)
            for profile in content['party']:
                self.assertEqual(set(profile['revival_art']),{'down','recovery'})
                self.assertEqual(set(profile['item_art']),{'idle','prepare','hold','recover'})
            self.assertLessEqual((directory / 'trial.json').stat().st_size, 1024 * 1024)
            with Image.open(directory / 'actors.png') as atlas:
                for profile in content['party'] + content['enemies']:
                    poses = [profile['sprite']] + [f['pose'] for f in profile['attack'] + profile.get('cast', [])]
                    poses += [f['pose'] for clip in profile.get('revival_art',{}).values() for f in clip['frames']]
                    poses += [f['pose'] for clip in profile.get('item_art',{}).values() for f in clip['frames']]
                    poses += [f['pose'] for scene in profile.get('unite_scenes', []) for f in scene['track']['attack']]
                    poses += [pose for scene in profile.get('unite_scenes', []) for pose in scene['track'].get('trail', {}).get('poses', [])]
                    for pose in poses:
                        rect = pose['rect']
                        self.assertLessEqual(rect['x'] + rect['w'], atlas.width)
                        self.assertLessEqual(rect['y'] + rect['h'], atlas.height)
            for ordinal, identifier in enumerate(scenario['members']):
                profile = next(p for p in content['party'] if p['id'] == identifier)
                if scenario['record'] in (9,25):
                    self.assertTrue(next(g for g in content['unite_graphics'] if g['id']==identifier)['poses'])
                    self.assertEqual(actor_bundle['unites'][scenario['record']]['controller']['vfx'],'beauty')
                    continue
                if scenario['record']==13:
                    self.assertTrue(next(g for g in content['unite_graphics'] if g['id']==identifier)['poses'])
                    if identifier=='gen':self.assertTrue(any(s['record']==18 for s in profile['unite_scenes']))
                    else:self.assertIsNone(profile.get('motion'))
                    continue
                if scenario['record'] in (2,3,6,8,17,19,20,28,30):
                    self.assertFalse(profile.get('unite_scenes',[]))
                    self.assertIsNone(profile.get('motion'))
                    self.assertFalse(profile['attack'])
                    self.assertTrue(next(g for g in content['unite_graphics'] if g['id']==identifier)['poses'])
                    continue
                track = next(s['track'] for s in profile['unite_scenes'] if s['record'] == scenario['record'])
                if len(scenario['members'])==4:
                    self.assertEqual((track['trail']['start'], track['trail']['stop']), (14, 44))
                    self.assertEqual(track['screen_offsets'][0], dict(start=34, updates=10, target=True, value=[0, 0]))
                    self.assertEqual(track['screen_offsets'][1]['start'], track['motion']['return_start'])
                self.assertEqual(len(track['trail']['poses']), 8)
                self.assertEqual(track.get('start_after', 0), 45 * ordinal if len(scenario['members'])==4 else 0)
                self.assertEqual(track.get('reaction_on_hit', False),binding['members'][ordinal].get('reaction_on_hit',False))
                self.assertEqual(sum(f['ticks'] for f in track['attack']), track['motion']['duration'])
            for name, expected in scenario['files'].items():
                self.assertEqual(hashlib.sha256((directory / name).read_bytes()).hexdigest(), expected)

    def test_source_profiles_and_shared_script_union_are_source_derived(self):
        content=json.loads((self.root/'record_19/trial.json').read_text())
        for identifier,native in (('rubi',51),('krin',15),('humphrey',21),('gen',20),('kamandol',67),('cleo',1),('eileen',0),('valeria',36),('sonya',10)):
            profile=next(p for p in content['party'] if p['id']==identifier)
            origin=next(m for m in self.proof['members'] if m['id']==identifier)
            template=origin['template_source']
            raw=disc.extract(template['lba'],template['size'])
            offset=origin['template_file_offset']
            self.assertEqual(struct.unpack_from('<I',raw,offset)[0],native)
            self.assertEqual(profile['max_hp'],struct.unpack_from('<H',raw,offset+4)[0])
            self.assertEqual(profile['level'],raw[offset+13])
            self.assertEqual(profile['growth'],list(raw[offset+24:offset+30]))
            stats=[profile['stats'][key] for key in ('attack','skill','defense','speed','magic','luck')]
            stats[0]-=profile['weapon']['powers'][profile['weapon']['initial_level']-1]
            self.assertEqual(stats,list(raw[offset+16:offset+22]))
        for identifier in ('kirkis','sylvina','stallion'):
            member=next(m for m in self.proof['members'] if m['id']==identifier)
            self.assertEqual(member['primary_scripts'],[10,11])
            self.assertIn(12,member['selected_animations'])

    def test_real_member_pixels_and_anchors_match_independent_decoder(self):
        content = json.loads((self.root / 'record_05/trial.json').read_text())
        checked = set()
        with Image.open(self.root / 'shared/actors.png') as source_atlas:
            atlas = source_atlas.convert('RGBA')
        for member in self.proof['members']:
            origin = member['source']
            raw = disc.extract(origin['lba'], origin['size'])
            packet=member['art'].get('sampling')=='axis_aligned_packet'
            section = reference.decode_section(raw, member['art']['section'], character_id=member['id'],axis_aligned_packet=packet)
            profile = next(p for p in content['party'] if p['id'] == member['id'])
            table=struct.unpack_from('<I',raw,member['art']['section']+20)[0]
            animation=struct.unpack_from('<I',raw,table+5*4)[0]
            frozen_pose=raw[animation+4]
            for trail in member['trails']:
                self.assertEqual(trail['animation'], 11 if member['id']=='sydonia' else 5)
                trail_animation=struct.unpack_from('<I',raw,table+trail['animation']*4)[0]
                self.assertEqual(trail['pose'],raw[trail_animation+4])
            if member['id'] in {graphic['id'] for graphic in content['unite_graphics']}:
                graphic=next(g for g in content['unite_graphics'] if g['id']==member['id'])
                for entry in graphic['poses']:
                    child_poses={p['id'] for source in self.proof['child_graphics'] if source['id']==member['id'] for p in source['poses']}
                    if entry['id'] in child_poses:continue  # Child crops are independently checked below.
                    expected,ax,ay=vram_pose(raw,member['art']['section'],entry['id'],packet=packet)
                    r=entry['sprite']['rect']
                    self.assertEqual(atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),expected.tobytes())
                    self.assertEqual((entry['sprite']['anchor_x'],entry['sprite']['anchor_y']),(ax,ay))
                    if 'white' in entry:
                        expected_white,wx,wy=vram_pose(raw,member['art']['section'],entry['id'],packet=packet,white=True)
                        r=entry['white']['rect']
                        self.assertEqual(atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),expected_white.tobytes())
                        self.assertEqual((entry['white']['anchor_x'],entry['white']['anchor_y']),(wx,wy))
                    checked.add((member['id'],entry['id']))
                    for age,tint in enumerate(entry.get('trail',[])):
                        r=tint['rect'];actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
                        for y in range(expected.height):
                            for x in range(expected.width):
                                pixel=expected.getpixel((x,y));factors=[255*(7-age)//7]*2+[255]
                                values=[min(31,(pixel[i]//8)*factors[i]//128) for i in range(3)]
                                self.assertEqual(actual.getpixel((x,y)),(*[v*8+v//4 for v in values],pixel[3]))
            for scene in profile.get('unite_scenes',[]):
                for age, native_pose in enumerate(scene['track']['trail']['poses']):
                    rect = native_pose['rect']
                    actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                    source = section.poses[frozen_pose].image
                    self.assertEqual(actual.size, source.size)
                    self.assertEqual((native_pose['anchor_x'],native_pose['anchor_y']),(section.poses[frozen_pose].anchor_x,section.poses[frozen_pose].anchor_y))
                    for y in range(source.height):
                        for x in range(source.width):
                            pixel = source.getpixel((x, y))
                            factors = [255 * (7-age) // 7] * 2 + [255]
                            expected = [min(31, (pixel[i] // 8) * factors[i] // 128) for i in range(3)]
                            self.assertEqual(actual.getpixel((x, y)), (*[v*8+v//4 for v in expected], pixel[3]))
                for frame in scene['track']['attack']:
                    pose = section.poses[frame['source_pose']]
                    rect = frame['pose']['rect']
                    actual = atlas.crop((rect['x'], rect['y'], rect['x'] + rect['w'], rect['y'] + rect['h']))
                    self.assertEqual(actual.size, pose.image.size)
                    self.assertEqual(actual.tobytes(), pose.image.tobytes())
                    self.assertEqual((frame['pose']['anchor_x'], frame['pose']['anchor_y']), (pose.anchor_x, pose.anchor_y))
                    self.assertIsNotNone(actual.getchannel('A').getbbox())
                    checked.add((member['id'], pose.index))
        smiths={'maas','moose','meese','mace','mose'}
        expected_smiths=set()
        for member in self.proof['members']:
            if member['id'] not in smiths:continue
            raw=disc.extract(member['source']['lba'],member['source']['size'])
            table=struct.unpack_from('<I',raw,member['art']['section']+20)[0]
            for animation in member['selected_animations']:
                offset=struct.unpack_from('<I',raw,table+animation*4)[0]
                expected_smiths.update((member['id'],raw[offset+4+2*i]) for i in range(raw[offset] or 1))
        self.assertEqual({item for item in checked if item[0] in smiths},expected_smiths)
        self.assertEqual({id for id,_ in checked},{m['id'] for m in self.proof['members']})

    def test_child_graphics_match_independent_full_section_decoder(self):
        content=json.loads((self.root/'record_05/trial.json').read_text())
        expected={row['id'] for row in self.proof['members']} | {row['id'] for row in self.proof['child_graphics']}
        self.assertEqual({r['id'] for r in content['unite_graphics']},expected)
        with Image.open(self.root/'shared/actors.png') as atlas:
            for origin in self.proof['child_graphics']:
                raw=disc.extract(origin['source']['lba'],origin['source']['size'])
                section=reference.decode_section(raw,origin['section'],base=origin['pointer_base'],character_id=origin['id'])
                graphic=next(r for r in content['unite_graphics'] if r['id']==origin['id'])
                self.assertEqual({p['id'] for p in origin['poses']},{p for animation in origin['animations'] for p,t in section.animations[animation].pairs})
                for binding in origin['poses']:
                    entry=next(p for p in graphic['poses'] if p['id']==binding['id'])
                    decoded=section.poses[entry['id']]
                    self.assertEqual(len(decoded.pieces),1)
                    piece=decoded.pieces[0];sprite=entry['sprite'];r=sprite['rect']
                    expected_image=decoded.image.crop((piece.x,piece.y,piece.x+piece.width,piece.y+piece.height))
                    self.assertEqual(atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h'])).tobytes(),expected_image.tobytes())
                    self.assertEqual((sprite['anchor_x'],sprite['anchor_y']),(decoded.anchor_x-piece.x,decoded.anchor_y-piece.y))
                    self.assertIsNotNone(expected_image.getchannel('A').getbbox())

    def test_pending_beauty_inventory_matches_raw_pages_separately_from_live_scene_admission(self):
        self.assertEqual(len(self.proof['pending_controllers']),1)
        pending=self.proof['pending_controllers'][0]
        self.assertEqual(pending['records'],[9,25])
        self.assertFalse(pending['ready_for_runtime'])
        path=self.root/pending['path'];packet=json.loads(path.read_text())
        self.assertFalse(packet['ready_for_runtime'])
        self.assertEqual([v['record'] for v in packet['variants']],[9,25])
        self.assertEqual([v['members'][-1] for v in packet['variants']],[36,10])
        self.assertEqual([v['clocks'][-1]['events']['16'] for v in packet['variants']],[103,92])
        self.assertEqual([s['record'] for s in self.proof['scenarios'] if s['record'] in (9,25)],[9,25])
        origin=packet['source'];raw=disc.extract(origin['lba'],origin['size'])
        self.assertEqual(hashlib.sha256(raw).hexdigest(),origin['sha256'])
        def page(offset):
            size=struct.unpack_from('<I',raw,offset)[0]
            return decode_strict(raw[offset+4:offset+4+size])
        palette=page(origin['palette_page_offset'])
        with Image.open(path.parent/packet['atlas']) as opened:
            atlas=opened.convert('RGBA')
        expected_sources={}
        for animation in packet['animations']:
            section=struct.unpack_from('<I',raw,4*animation['section'])[0]-0x800AA000
            ct,_,et,ft=struct.unpack_from('<4I',raw,section+8)
            source=struct.unpack_from('<I',raw,ft-0x800AA000+4*animation['animation'])[0]-0x800AA000
            self.assertEqual(source,animation['source_offset'])
            for frame in range(raw[source]):
                pose=raw[source+4+2*frame]
                header=struct.unpack_from('<I',raw,et-0x800AA000+4*pose)[0]-0x800AA000
                for index in range(raw[header]):
                    offset=header+8+8*index;bank=raw[offset+2]
                    page_offset=struct.unpack_from('<I',raw,ct-0x800AA000+4*bank)[0]-0x800AA000
                    expected_sources[offset]=(header,page_offset)
        self.assertEqual({e['source_offset'] for e in packet['entries']},set(expected_sources))
        for entry in packet['entries']:
            offset=entry['source_offset'];x,y,bank,tile,wm,hm,clut,flags=raw[offset:offset+8]
            self.assertEqual(entry['source_entry'],[x,y,bank,tile,wm,hm,clut,flags])
            plane=page(entry['page_offset']);expected=Image.new('RGBA',(wm+1,hm+1))
            u=((tile&15)*8-(128 if flags&128 else 0))&255;v=(tile>>4)*8
            for py in range(hm+1):
                for px in range(wm+1):
                    sx=u+(wm-px if flags&2 else px);sy=v+(hm-py if flags&1 and not flags&2 else py)
                    byte=plane[sy*128+sx//2];index=(byte>>(4*(sx&1)))&15
                    if index:
                        colour=struct.unpack_from('<H',palette,128*(clut//2)+64+32*(clut%2)+2*index)[0]
                        expected.putpixel((px,py),(*(255*((colour>>shift)&31)//31 for shift in (0,5,10)),255))
            r=entry['rect'];actual=atlas.crop((r['x'],r['y'],r['x']+r['w'],r['y']+r['h']))
            self.assertEqual(actual.tobytes(),expected.tobytes())
            self.assertEqual(hashlib.sha256(actual.tobytes()).hexdigest(),entry['rgba_sha256'])
            header,page_offset=expected_sources[offset]
            self.assertEqual(page_offset,entry['page_offset'])
            self.assertEqual((entry['dx'],entry['dy']),(x-raw[header+4],y-raw[header+5]))
        for animation in packet['animations']:
            source=animation['source_offset'];count,flags=raw[source:source+2]
            self.assertEqual(flags,1)
            self.assertEqual([f['updates'] for f in animation['frames']],[raw[source+5+2*j] or 256 for j in range(count)])
            if animation['id']=='graphics':self.assertEqual(sum(f['updates'] for f in animation['frames']),47)
        for name,digest in pending['files'].items():self.assertEqual(hashlib.sha256((path.parent/name).read_bytes()).hexdigest(),digest)
        with self.assertRaises(ValueError):exporter.pending_controller_art(ROOT/'kit/work/accepted/beauty',exporter.battle_unite_camera.report())

    def test_candidate_provenance_and_accepted_tree_guard(self):
        sources = json.loads((self.root / 'shared/provenance.json').read_text())['scene_sources']
        self.assertEqual(len(sources['members']), 42)
        self.assertEqual(sources['review_overrides']['enemy_max_hp'], 5000)
        self.assertEqual(self.proof['status'], 'candidate')
        actor_origin = self.root / self.proof['actor_programs']['path']
        self.assertEqual(hashlib.sha256(actor_origin.read_bytes()).hexdigest(),self.proof['actor_programs']['sha256'])
        self.assertEqual(len(json.loads(actor_origin.read_text())['programs']),84)
        self.assertIn('premodulated RGB555', self.proof['trail_scope'])
        for controller in sources['controllers']:
            self.assertEqual(controller['schedule']['trail']['nodes'], 8)
            self.assertEqual(controller['schedule']['trail']['playback'], 'source_inventory_only')
            startup = controller['schedule']['startup']
            self.assertEqual((startup['selection'], startup['initializer'], startup['first_callback']), (0, 1, 2))
            self.assertEqual(startup['units'], 'primary_coordinator_updates')
            self.assertEqual(startup['native_mapping'], 'selection_clock_verified')
        self.assertIn('native VM startup mapping', self.proof['timing_scope'])
        with Image.open(self.root / 'shared/actors.png') as image:
            base = sources['base_atlas']
            prefix = image.convert('RGBA').crop((0, 0, base['width'], base['height']))
            self.assertEqual(hashlib.sha256(prefix.tobytes()).hexdigest(), base['rgba_sha256'])
        for member in sources['members']:
            self.assertEqual(member['decoder'], 'lzss.py v2.0.0')
            self.assertEqual(member['template_file_offset'], member['template_image_offset'] + 2048)
        content = json.loads((self.root / 'record_05/trial.json').read_text())
        offsets = sources['enemy_offsets']
        raw = disc.extract(offsets['source']['lba'], offsets['source']['size'])
        for row in offsets['records']:
            expected = list(struct.unpack_from('<hh', raw, row['source_offset']))
            self.assertEqual(row['value'], expected)
            self.assertEqual(next(e for e in content['enemies'] if e['id'] == row['id'])['effect_offset'], expected)
        self.assertEqual(next(e for e in content['enemies'] if e['id'] == 'wild_boar')['effect_offset'], [-10, 10])
        with self.assertRaises(ValueError):
            exporter.export(ROOT / 'kit/work/accepted/unite_review')


class MartialReviewTests(unittest.TestCase):
    def test_martial_package_matches_native_fixture_and_independent_strike_pixels(self):
        with tempfile.TemporaryDirectory(prefix='suikoden-martial-review-') as temporary:
            output = Path(temporary)
            proof = exporter.export(output, include_flash=True, include_master=True, include_couple=True,
                                    include_warriors=True, include_martial=True, scenario_records=(29,))
            scenario = output/'record_29'
            content = json.loads((scenario/'trial.json').read_text())
            bundle = json.loads((scenario/'unites.json').read_text())
            spells = json.loads((scenario/'spells.json').read_text())
            self.assertEqual(content, json.loads((ROOT/'game/tests/fixtures/martial_battle.json').read_text()))
            self.assertEqual(bundle, json.loads((ROOT/'game/tests/fixtures/martial_actor_library.json').read_text()))
            self.assertEqual([row['record'] for row in proof['scenarios']], [29])
            self.assertEqual(spells['schema'], 'suikoden-spell-scenes/49')
            expected = json.loads((ROOT/'game/tests/fixtures/martial_recipients.json').read_text())['programs']
            self.assertEqual([r for r in spells['unite_reactions'] if r['record']==29], expected)
            with Image.open(scenario/'actors.png') as atlas:
                for identifier in ('eikei','pahn','morgan'):
                    source = next(row for row in proof['members'] if row['id']==identifier)
                    raw = disc.extract(source['source']['lba'], source['source']['size'])
                    resource = next(row for row in bundle['animations']['resources'] if row['id']==identifier)
                    clip = next(row for row in resource['clips'] if row['id']==16)
                    graphics = next(row for row in content['unite_graphics'] if row['id']==identifier)
                    for pose in {frame['pose'] for frame in clip['frames']}:
                        expected_image, ax, ay = vram_pose(raw, source['art']['section'], pose,
                                                         packet=source['art'].get('sampling')=='axis_aligned_packet')
                        sprite = next(row for row in graphics['poses'] if row['id']==pose)['sprite']
                        x,y,w,h = (sprite['rect'][key] for key in ('x','y','w','h'))
                        self.assertEqual((sprite['anchor_x'],sprite['anchor_y']), (ax,ay))
                        self.assertEqual(atlas.crop((x,y,x+w,y+h)).tobytes(), expected_image.tobytes())


if __name__ == '__main__':
    unittest.main()
