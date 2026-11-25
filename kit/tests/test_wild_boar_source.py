#!/usr/bin/env python3
"""Dispatch identity and Wild boar's unbound commands, without original execution."""
from pathlib import Path
import hashlib
import json
import struct
import sys
import unittest
import tempfile
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import maindec
from export_first_room import source
from export_unite_programs import compile_operations
from test_physical_rune_export import independent_stream


class WildBoarSource(unittest.TestCase):
    def test_enemy_decision_and_items_share_the_source_dispatcher(self):
        raw, _ = source('/A_DATA.BIN')
        self.assertEqual(struct.unpack_from('<I', raw, 0x233dc+0x30)[0], 0x80080760)
        self.assertEqual(hashlib.sha256(raw[0x760:0x8d4]).hexdigest(),
                         '60a85edc4b1ab4ffb541d0e75bee5a650df4aaf9bd7ca0d72a354401ede40932')
        for pc, word in {0x800f41e4:0x8c820030, 0x800f41ec:0x0040f809,
                         0x800f41f0:0x00a02021, 0x800f41fc:0x1062000b,
                         0x800f422c:0x0c03d399, 0x800f423c:0xa2220046,
                         0x800f433c:0x0c03d414, 0x800f434c:0x10620013,
                         0x800f4354:0x1060001b, 0x800f439c:0x0c03d02e}.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))

    def test_package_gate_rejects_an_actor_without_its_shared_child_art(self):
        import check_journey_package
        actors = dict(programs=dict(programs=[dict(instructions=[dict(command=dict(child=dict(resource='shared_impacts',animation=13)))])]))
        with tempfile.TemporaryDirectory(prefix='boar-dependency-') as temporary:
            root = Path(temporary)
            errors = []
            check_journey_package.check_actor_impacts(root,actors,errors)
            self.assertEqual(errors,['missing spell art for shared actor animations'])
            (root/'battle').mkdir()
            path = root/'battle/spells.json'
            path.write_text(json.dumps(dict(unite_impacts=[dict(id=0)])))
            errors = [];check_journey_package.check_actor_impacts(root,actors,errors)
            self.assertEqual(errors,['missing shared actor animation 13'])
            path.write_text(json.dumps(dict(unite_impacts=[dict(id=0),dict(id=13)])))
            errors = [];check_journey_package.check_actor_impacts(root,actors,errors)
            self.assertEqual(errors,[])

    def test_dust_append_preserves_existing_pixels_and_matches_independent_vram(self):
        import export_spell_scenes
        from disc import extract
        import battle_bin
        from test_export_unite_review import vram_pose
        with tempfile.TemporaryDirectory(prefix='boar-dust-') as temporary:
            folder = Path(temporary)
            old = dict(schema='suikoden-spell-scenes/50', entries=[dict(x=0,y=0,w=1,h=1,dx=0,dy=0)],unite_impacts=[])
            (folder/'spells.json').write_text(json.dumps(old))
            image = Image.new('RGBA',(1024,8),(11,22,33,255));image.save(folder/'spell_effects.png')
            proof = export_spell_scenes.add_ordinary_dust(folder)
            actual = json.loads((folder/'spells.json').read_text())
            self.assertEqual(actual['schema'],'suikoden-spell-scenes/51')
            self.assertEqual(actual['entries'][:1],old['entries'])
            self.assertEqual([f['ticks'] for f in actual['unite_impacts'][0]['frames']],[4]*5)
            raw = extract(proof['source']['lba'],proof['source']['size'])
            self.assertEqual(hashlib.sha256(raw).hexdigest(),proof['source']['sha256'])
            with Image.open(folder/'spell_effects.png') as atlas:
                self.assertEqual(atlas.crop((0,0,1024,8)).tobytes(),image.tobytes())
                for row in proof['poses']:
                    expected, ax, ay = vram_pose(raw,proof['source']['section'],row['pose'],base=battle_bin.LOAD_BASE)
                    entry = actual['entries'][row['entry']]
                    crop = atlas.crop((entry['x'],entry['y'],entry['x']+entry['w'],entry['y']+entry['h']))
                    self.assertEqual((entry['dx'],entry['dy']),(-ax,-ay))
                    self.assertEqual(crop.tobytes(),expected.tobytes())
            with self.assertRaisesRegex(ValueError,'without animation13'):
                export_spell_scenes.add_ordinary_dust(folder)

    def test_counter_and_offsets_are_distinct_dispatch_entries(self):
        self.assertEqual(maindec.mword(0x8016babc+37*4), 0x800e56a8)
        self.assertEqual(maindec.mword(0x8016babc+43*4), 0x800e56ec)
        for start, end, digest in (
            (0x800e56a8, 0x800e56ec, '7546ffd3d0aa8438cb117869869dad42bff840b9be735370d81d05db69f62af2'),
            (0x800e56ec, 0x800e57ec, '075151f80aa6d232ccc5d8767c3879116bcb5731424d125bed5b50cdd4af6521'),
        ):
            self.assertEqual(hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest(), digest)
        for address, word in {0x800e56d4:0x84840002, 0x800e56d8:0x24630004,
                              0x800e56dc:0xac43000c, 0x800e56e0:0xa4440010,
                              0x800e3684:0x87020010, 0x800e368c:0x1840004d,
                              0x800e3774:0x2442ffff, 0x800e3778:0xa7020010,
                              0x800e378c:0x1440000d, 0x800e3794:0x8f040014,
                              0x800e5754:0x84a20074, 0x800e5758:0x84a30076}.items():
            self.assertEqual(maindec.mword(address), word, hex(address))

    def test_raw_attack_and_recipient_retain_their_qualified_operations(self):
        raw, origin = source('/A_DATA.BIN')
        self.assertEqual(origin['sha256'], '1739375bf8292fbfdbf0eba749035a772448dc060e68a1d102db2ec66d882045')
        base = 0x80080000
        table = struct.unpack_from('<I', raw, 0x233dc+40)[0]-base
        self.assertEqual(table, 0x2341c)
        for slot, offset, blocked in (
            (1, 0x23444, []),
            (2, 0x23660, [dict(operation=1, opcode=35, operands=[2,5])]),
            (4, 0x2359c, []),
        ):
            self.assertEqual(struct.unpack_from('<I', raw, table+slot*4)[0]-base, offset)
            operations = independent_stream(raw, offset, table, base)
            instructions, actual, _ = compile_operations(operations, 'melee/wild_boar')
            self.assertEqual(actual, blocked)
            if slot == 1:
                self.assertEqual([i['command']['resume_motion'] for i in instructions
                                  if 'resume_motion' in i.get('command', {})], [10])
        self.assertEqual(struct.unpack_from('<I', raw, table+5*4)[0], 0x800808d4)

    def test_recipient_callback_increments_draw_angle_then_resets_and_releases(self):
        self.assertEqual(maindec.mword(0x8016babc+35*4), 0x800e557c)
        for address, word in {0x800e55b0:0x90650004, 0x800e55c0:0x34020002,
                              0x800e55c4:0x10c20006, 0x800e55f8:0x8c450008,
                              0x800e5618:0x00081080, 0x800e5620:0x8c440000,
                              0x800e5630:0xac640054}.items():
            self.assertEqual(maindec.mword(address), word, hex(address))
        raw, _ = source('/A_DATA.BIN')
        self.assertEqual(hashlib.sha256(raw[0x8d4:0x950]).hexdigest(),
                         'b4b9c71324c3c6ddc80c253a424a4937a1822aa2b6c07715b0c67d87c983395d')
        for address, word in {0x800808f0:0x94830042, 0x800808f4:0x34020001,
                              0x800808f8:0x10620008, 0x80080908:0x34020002,
                              0x8008090c:0x1062000a, 0x8008091c:0x8c830084,
                              0x80080924:0x9462001a, 0x8008092c:0x24420100,
                              0x80080934:0xa462001a, 0x80080938:0x8c820084,
                              0x80080940:0xa440001a, 0x80080944:0xac800054}.items():
            self.assertEqual(struct.unpack_from('<I', raw, address-0x80080000)[0], word, hex(address))

    def test_qualified_owner_callback_lowers_without_changing_descriptor_order(self):
        raw, _ = source('/A_DATA.BIN')
        operations = independent_stream(raw, 0x23660, 0x2341c, 0x80080000)
        instructions, blocked, effects = compile_operations(operations, 'melee/wild_boar', {(2,5): 'recipient_spin'})
        self.assertEqual(blocked, [])
        self.assertEqual(effects, ['recipient_spin'])
        self.assertEqual(instructions[:2], [dict(command=dict(shared_value=0)),
            dict(command=dict(effect=dict(id='recipient_spin', binding='owner')))])


if __name__ == '__main__':
    unittest.main()
