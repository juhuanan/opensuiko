#!/usr/bin/env python3
"""Independent static source, pixel and event checks; no original CPU execution."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import battle_bin
import character_table
import export_enemy_magic as exporter
import maindec
import preparation
from export_first_room import source
from lzss import decode_strict

FIXTURE = ROOT/'game/tests/fixtures/kobold_magic_scene.json'


def word32(value):
    return struct.unpack('<i', struct.pack('<I', value & 0xffffffff))[0]


def trunc(value, divisor):
    return (abs(value)//divisor)*(-1 if value < 0 else 1)


class EnemyMagicExport(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.plan, cls.atlas, cls.proof = exporter.build()
        cls.raw, cls.origin = source('/C_DATA.BIN')

    def test_original_dispatch_constructor_damage_and_cleanup_are_independently_pinned(self):
        raw = self.raw
        w = lambda pc: struct.unpack_from('<I', raw, pc-0x80080000)[0]
        for pc, expected in {
            0x800803C0: 0x34020014, 0x80080420: 0x24420770, 0x80080558: 0x28630033,
            0x80080638: 0x28630033, 0x80080648: 0x2442067C, 0x80080700: 0x24C63E84,
            0x800807AC: 0x8E52A004, 0x80080828: 0x2442084C, 0x800808B4: 0x244208D4,
            0x80080960: 0x34170555, 0x80080964: 0x34120010, 0x8008099C: 0x3405000B,
            0x800809AC: 0x26520008, 0x800809BC: 0x2A020006, 0x800809E4: 0x34050001,
            0x80080A40: 0x34050006, 0x80080A98: 0x24420AD4, 0x80080B90: 0x3C08FFFE,
            0x80080B94: 0x3508C000, 0x80080C64: 0x34060030, 0x80080CBC: 0x284200B4,
            0x80080CC0: 0x14400030, 0x80080CC4: 0x00008821, 0x80080CD0: 0x8C420158,
            0x80080CDC: 0x34060001, 0x80080CE8: 0x8C630010, 0x80080D18: 0x8C4200A8,
            0x80080D30: 0x8C4200A8, 0x80080D48: 0x8C4200A8, 0x80080D6C: 0x8C420018,
            0x80080D7C: 0xAE400010, 0x80080EEC: 0x24420001, 0x80080EE0: 0x2484001F,
            0x80080F54: 0x24420080, 0x80080F64: 0x28420020, 0x80080F70: 0xAE00001C,
            0x80080FB4: 0x24C610CC, 0x80080FC0: 0x34025000,
        }.items():
            self.assertEqual(w(pc), expected, hex(pc))
        self.assertEqual(w(0x800A3E7C), 0x80080300)
        self.assertEqual(self.plan['effect']['damage_update'], 180)
        self.assertEqual(self.plan['effect']['cleanup_update'], 181)
        self.assertEqual(self.plan['effect']['art_prepare_updates'], 10)
        self.assertEqual(self.plan['effect']['sounds'], [dict(update=1, id=0x81e)]+
            [dict(update=17+8*i, id=0x524) for i in range(6)])
        # Counter, selector and result are separate source instructions.
        for pc, expected in {0x800F81DC: 0x9465002C, 0x800F81E4: 0x9442002C,
                             0x800F8314: 0x10430003, 0x800F831C: 0x14620004,
                             0x80120814: 0x28420021, 0x80120830: 0x24420200,
                             0x80120844: 0x2442FF00, 0x800C3540: 0x18400014,
                             0x800C358C: 0x1440FFF0, 0x800C33D0: 0x14400003,
                             0x800C33DC: 0x00001021, 0x800C34A8: 0x2402FFFF}.items():
            self.assertEqual(maindec.mword(pc), expected)

    def test_selected_recipient_survives_the_party_lock_scan(self):
        w = lambda pc: struct.unpack_from('<I', self.raw, pc-0x80080000)[0]
        # Store the recipient; the later scan skips inactive members before locks,
        # starts the owner script and applies damage to the retained recipient.
        for pc, expected in {
            0x800805BC: 0xAE54125C, 0x800805D4: 0xA0540049,
            0x800806C0: 0x90C20045, 0x800806C8: 0x14400005,
            0x800806D0: 0x90620005, 0x800806D8: 0x14400010,
            0x800806F8: 0x8C420004, 0x80080700: 0x24C63E84,
            0x80080704: 0x0040F809, 0x80080B44: 0x80750B89,
            0x80080CD0: 0x8C420158,
            0x80080CD4: 0x02A02821, 0x80080CD8: 0x0040F809,
            0x80080CE8: 0x8C630010, 0x80080CEC: 0x02A02021,
            0x80080CF0: 0x0060F809, 0x80080FB4: 0x24C610CC,
        }.items():
            self.assertEqual(w(pc), expected, hex(pc))
        # The party driver updates its script before skipping inactive actors;
        # the shared script setter installs the reaction on the target actor.
        for pc, expected in {0x800E0A7C: 0x0C038D63, 0x800E0A84: 0x92620045,
                             0x800E0A8C: 0x14400031, 0x800E386C: 0xA0450004,
                             0x800E3870: 0xAC46000C}.items():
            self.assertEqual(maindec.mword(pc), expected, hex(pc))

    def test_shared_vm_receives_owner_wait_and_actual_recipient_palette_jiggle_programs(self):
        self.assertEqual(self.plan, json.loads(FIXTURE.read_text()))
        self.assertEqual(self.plan['programs']['schema'], 'suikoden-actor-programs/7')
        owner, recipient = self.plan['programs']['programs']
        commands = [row['command'] for row in owner['instructions'] if 'command' in row]
        self.assertEqual([c['animation'] for c in commands if 'animation' in c], [13, 14, 15])
        self.assertIn(dict(effect=dict(id='kobold_magic', binding='self')), commands)
        self.assertIn(dict(wait=dict(shared_value=99)), owner['instructions'])
        self.assertIn(dict(delay=1), owner['instructions'])
        self.assertEqual(owner['instructions'][-2:], [dict(command=dict(release_actor=True)), dict(halt={})])
        commands = [row['command'] for row in recipient['instructions'] if 'command' in row]
        self.assertIn(dict(palette_cycle=dict(variants=[1, 2, 3], updates=4)), commands)
        self.assertEqual([c['offsets']['value'] for c in commands if 'offsets' in c], [[-5, 0], [0, 5]]*3)
        self.assertEqual([row['delay'] for row in recipient['instructions'] if 'delay' in row], [2, 5, 5, 5, 5, 5, 5])
        self.assertEqual([f['updates'] for c in self.plan['resource']['clips'] if c['id'] == 14 for f in c['frames']], [1])

    def test_every_magic_pixel_matches_independent_nibble_and_packed_clut_sampling(self):
        _, _, _, bank = battle_bin.parse()
        cache = {}
        def page(offset):
            if offset not in cache:
                length = struct.unpack_from('<I', bank, offset)[0]
                cache[offset] = decode_strict(bank[offset+4:offset+4+length])
                self.assertEqual(len(cache[offset]), 16384)
            return cache[offset]
        palette = page(self.proof['bank']['palette_blob'])
        self.assertEqual(len(self.plan['pieces']), 9)
        for piece, evidence in zip(self.plan['pieces'], self.proof['bank']['entries'], strict=True):
            entry = bank[evidence['source_offset']+8:evidence['source_offset']+16]
            u = ((entry[3] & 15)*8-(128 if entry[7] & 128 else 0)) & 255
            v = (entry[3] >> 4)*8
            raster = np.frombuffer(page(evidence['blob_offset']), dtype=np.uint8).reshape(128, 128)
            pixels = np.empty((entry[5]+1, entry[4]+1, 4), dtype=np.uint8)
            start = 128*(entry[6]//2)+64+32*(entry[6] % 2)
            words = np.frombuffer(palette[start:start+32], dtype='<u2')
            for y in range(len(pixels)):
                for x in range(len(pixels[0])):
                    sx = u+x; byte = int(raster[v+y, sx//2]); index = (byte >> (4*(sx & 1))) & 15
                    color = int(words[index])
                    pixels[y, x] = [(color >> shift & 31)*255//31 for shift in (0, 5, 10)]+[255 if index else 0]
                    if not index:
                        pixels[y, x] = [0, 0, 0, 0]
            rect = piece['rect']; actual = self.atlas.image.crop((rect['x'], rect['y'], rect['x']+rect['w'], rect['y']+rect['h']))
            self.assertTrue(np.array_equal(np.asarray(actual), pixels), piece['id'])
            self.assertEqual(piece['width']+1, rect['w'])
            self.assertEqual(piece['height']+1, rect['h'])

    def test_all_eighteen_graphics_follow_independent_step_integrated_source_clocks(self):
        for owner, recipient in (([0, 0, 0], [-205000, 203003, -15000]),
                                 ([12285, -8195, 4097], [-200003, 35005, -120001]),
                                 ([0, 0, 0], [100000000, -100000000, 80000000]),
                                 ([2147483000, -2147483500, 8191], [-2147483200, 2147483000, -127])):
            projectiles = [dict(delay=16+8*i, active=False, step=0, size=0x555, position=[0]*3) for i in range(6)]
            impacts = [None]*6
            flares = [dict(delay=8*i, active=False, remaining=0, size=1) for i in range(6)]
            delta = [word32(recipient[0]-0x14000-owner[0]), word32(recipient[1]-owner[1]), word32(recipient[2]-owner[2])]
            root = [owner[0]//4096+20, owner[1]//4096, owner[2]//4096-10]
            contacts = []; damage_updates = []
            for update in range(1, 183):
                counter = update-1; expected = []
                if update == 180:
                    damage_updates.append(update)
                if update <= 180:
                    for i, p in enumerate(projectiles):
                        if counter == p['delay']:
                            p.update(active=True, step=0)
                    for i, p in enumerate(flares):
                        if counter == p['delay'] and not p['active']:
                            p.update(active=True, remaining=48)
                    for i, impact in enumerate(impacts):
                        if impact is not None:
                            impact['age'] += 1
                            if impact['age'] < 30:
                                expected.append(dict(kind='impact', index=i, clip='impact', animation_updates=impact['age'],
                                    position_q12=impact['position'].copy(), root=root, size=4096))
                    for i, p in enumerate(flares):
                        if not p['active']:
                            continue
                        p['size'] += 512 if p['remaining'] > 32 else -256
                        p['remaining'] -= 1
                        if p['remaining'] == 0:
                            p['active'] = False
                        else:
                            expected.append(dict(kind='flare', index=i, clip='flare', animation_updates=0,
                                position_q12=[0, 0, 0], root=root, size=p['size']))
                    for i, p in enumerate(projectiles):
                        if not p['active']:
                            continue
                        p['step'] += 1; p['size'] += 128
                        p['position'] = [trunc(word32(p['step']*d), 32) for d in delta]
                        if p['step'] == 32:
                            p['active'] = False; impacts[i] = dict(age=0, position=p['position'].copy()); contacts.append(update)
                        else:
                            expected.append(dict(kind='projectile', index=i, clip='projectile', animation_updates=p['step'],
                                position_q12=p['position'], root=root, size=p['size']))
                key = lambda row: (row['kind'], row['index'])
                self.assertEqual(sorted(exporter.frame(self.plan, update, owner, recipient), key=key),
                                 sorted(expected, key=key), (owner, update))
            self.assertEqual(contacts, [48, 56, 64, 72, 80, 88])
            self.assertEqual(damage_updates, [180])

    def test_all_rune_bytes_use_this_callers_proven_zero_fallback_and_one_variance_draw(self):
        selector = {1: 7, 2: 1, 3: 2, 4: 5, 5: 4, 6: 3, 7: 6, 27: 1, 28: 2, 29: 5, 30: 3, 31: 4}
        for attacker, defender in ((0, 65535), (10, 1), (11, 1), (111, 1), (65535, 0)):
            for rune in range(256):
                for draw in (0, 1, 3, 4, 50, 99, 100, 32767):
                    d = attacker-defender
                    d += 1-draw % 4 if d < 10 else trunc(trunc(d, 2)-draw % d, 5)
                    if selector.get(rune, 0) in (1, 7):
                        d = trunc(d, 2)
                    self.assertEqual(exporter.magic_damage(self.plan, attacker, defender, rune, draw), max(1, d))
        self.assertEqual(self.plan['damage']['variance_draws'], 1)
        self.assertFalse(self.plan['damage']['defend_halves'])
        for invalid in (-1, 256):
            with self.assertRaises(ValueError):
                exporter.magic_damage(self.plan, 10, 1, invalid, 0)

    def test_changed_source_is_refused_and_candidate_manifest_reproduces(self):
        changed = bytearray(self.raw); changed[0xCC4] ^= 1
        with patch.object(exporter, 'source', return_value=(bytes(changed), self.origin)):
            with self.assertRaisesRegex(ValueError, 'callback changed'):
                exporter.build()
        with tempfile.TemporaryDirectory(prefix='suikoden-enemy-magic-') as directory:
            first = Path(directory)/'one'; second = Path(directory)/'two'
            exporter.export(first); exporter.export(second)
            self.assertEqual((first/'manifest.json').read_bytes(), (second/'manifest.json').read_bytes())
            manifest = json.loads((first/'manifest.json').read_text())
            for name, digest in manifest['files'].items():
                self.assertEqual(hashlib.sha256((first/name).read_bytes()).hexdigest(), digest)
        with self.assertRaisesRegex(ValueError, 'candidate'):
            exporter.export(ROOT/'kit/work/accepted/enemy_magic')

    def test_all_recipient_pose_centers_use_the_original_header_and_first_piece(self):
        anchors = {row['id']: row['centers_x'] for row in self.plan['impact_anchors']}
        self.assertEqual(len(anchors), 78)
        count = 0; composed_differences = 0
        for character in character_table.records():
            raw, _ = source('/'+character['sprite_file'])
            section = struct.unpack_from('<I', raw, 36)[0]
            length = struct.unpack_from('<H', raw, section)[0]
            table = struct.unpack_from('<I', raw, section+16)[0]
            expected = []
            for index in range(length):
                pose = struct.unpack_from('<I', raw, table+4*index)[0]
                header = struct.unpack_from('<8B', raw, pose)
                entry_x = raw[pose+8]
                expected.append((header[2] >> 1)-(header[4]-entry_x))
                width = max([header[2]]+[raw[pose+8+8*i]+raw[pose+12+8*i]+1 for i in range(header[0])])
                composed_differences += width != header[2] or entry_x != 0
                count += 1
            self.assertEqual(expected, anchors[preparation.stable_id(character['name'])])
        self.assertEqual(count, 947)
        self.assertEqual(composed_differences, 321)

    def test_native_bundle_merges_only_this_callback_resource_and_binding(self):
        baseline = json.loads((ROOT/'game/tests/fixtures/battle_parry_library.json').read_text())
        combined = exporter.combine(baseline, self.plan)
        self.assertEqual(combined, json.loads((ROOT/'game/tests/fixtures/enemy_magic_actor_library.json').read_text()))
        self.assertEqual(combined['schema'], 'suikoden-unite-actors/15')
        self.assertEqual(combined['enemy_magic']['selection_delay'], 30)
        self.assertEqual(combined['enemy_magic'], exporter.binding(self.plan))
        for key in ('unites', 'physical', 'counter'):
            self.assertEqual(combined[key], baseline[key])
        before = {r['id']: r for r in baseline['animations']['resources']}
        for resource in combined['animations']['resources']:
            if resource['id'] != 'kobold_type_3':
                self.assertEqual(resource, before[resource['id']])
            else:
                clips = {c['id']: c for c in resource['clips']}
                for clip in before[resource['id']]['clips']:
                    self.assertEqual(clip, clips[clip['id']])


if __name__ == '__main__':
    if '--write' in sys.argv:
        FIXTURE.write_text(json.dumps(exporter.build()[0], separators=(',', ':'))+'\n')
    else:
        unittest.main()
