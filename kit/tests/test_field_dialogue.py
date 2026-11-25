#!/usr/bin/env python3
"""Static room 6 dialogue source and retained per-update fixture checks."""
from hashlib import sha256
from itertools import product
import json
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import area_scene as scene
import event_script_decode
import export_field_dialogue as export
import export_field_party_queue as party
from export_first_room import source
from lzss import decode_container
import maindec as M
import war_text
from test_canonical_start import assert_main_words
from test_field_party_queue import DIRECTIONS, get_tracks, movement_vectors


def read_json(path):
    return json.loads((ROOT/path).read_text())


def fixture(name):
    return read_json(f'game/tests/fixtures/{name}.json')


def check_source_paths():
    spans = (
        (0x8013AFA0, 0x8013B0C8, '0d81862b1b4d35f0214cf75c8da9ca07a8acb5d1520a9d98b440a76a398c5f89'),
        (0x8013B0C8, 0x8013B2F4, '17368fcf12587a1bc4a9b1828d5321c21d885c64fdc7bff2be687adf813a6608'),
        (0x8013B2F4, 0x8013B404, '8f70ea58a0cae5a36529fe475ac46907d6985137e0fc0689edb220a8acab634a'),
        (0x8013B404, 0x8013B490, '5bb3e2defd03bbdba43efeb826c4a6ba9e3b4946f67ed2e9f8daf13754db6395'),
        (0x8013B490, 0x8013B51C, '0bd9c1c142111315e3709bfd87491c906d0edccaf408726d804de3e941546599'),
        (0x80145194, 0x80145324, 'a817596b69d76df86c8ceed168ab32353f6cae986b20faa2ae4d8be30359c337'),
        (0x80145A1C, 0x80145DB8, '9f989ab7bb33188890bf9dc2135b83e0d309d5a3658f7bded8c236eef0397c54'),
        (0x80147568, 0x801479A0, '26f92d0f8df30fdc732503d5ddd56e18b4109351bd9a9ebe71170fd6e3a7e6a5'),
        (0x8014695C, 0x80146BB4, 'b9922ba2711474c09092b2f731ce7529057be8002ce8fd663b19e1608cf25eb9'),
        (0x80146BB4, 0x80146F20, 'b90bc799a05621e98b0f2b42856350f2e0ed22d485ac0682186ad4dbc9ab3d27'),
        (0x8013F0C0, 0x8013F110, 'a9382e450a3e44eacbfe7b78cf42f42a7dc07104913fe80eb5014dfd4767780c'),
        (0x8013F110, 0x8013F1BC, '71c3da06f74e7412d7be12b5917dd714746475abb245cfb204fcb170981b0dcc'),
        (0x8013B7A0, 0x8013B8CC, 'e102cb42275a1270fa7e1c619de3a50ea53f301b3ba208c4c2b77d941aca7f31'),
        (0x8013B8CC, 0x8013B9C8, 'e8e42f6b7d2507f18e53f73135b49ae54dbc3ca08b1316b0c6860d373c77f235'),
        (0x8013F6F8, 0x8013F888, '2022c9400ee162a1ddb87bfefb72b9e9d7764c041dceba8ba074709c36897ae4'),
        (0x8013F888, 0x8013F9B0, '0344e768089144fa39dc4f4923438ecb09ecbc7b1506aa3d10288a84a01c6c55'),
        (0x8013F9B0, 0x8013FA40, 'e9212df10eecfca6dde7ec0c750f5732af445d5ee99654afe45d454dd59a0738'),
        (0x8013CE08, 0x8013CE68, '59fe00c918c4034a10f40b0303ebedd9eeefe1a2e833d5509ac6e9a0b233b05f'),
        (0x8013CCF0, 0x8013CE08, 'ac42e3088a2ea4f08b1728552d84e08d460e96f4ca9c05f2f5461b46ca90cd64'),
        (0x8013AE80, 0x8013AFA0, '93e9c10937f173fbf6a833a25b19be3f3cf84a2cc756eb69b4c2931468aa2b69'),
        (0x8013F4B8, 0x8013F584, 'dc96df69d8de987123e6a0418a944f186104f689568a1023381e337100362441'),
        (0x8013F584, 0x8013F6F8, 'd4f1da619eeeb50e34198cab343a024e93d59055b58f847ea7bd8bc43fd36038'),
        (0x8013FA40, 0x8013FB58, '673aae9b31e1a0c8ea85035f8a220cbddbce10c840f370d89f29229144113b4c'),
        (0x8013FB58, 0x8013FC00, '07c1480d7e851bfc2ae4a3d13a60a9f7b2061b09985288da63d22a15140d66eb'),
    )
    for start, end, digest in spans:
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        0x80171718+4*0x02: (0x8013AE14,),
        0x80171718+4*0x0B: (0x8013B490, 0x8013B3C4),
        0x80171718+4*0x11: (0x8013CE08, 0x8013AE80),
        0x80171718+4*0x17: (0x8013B404, 0x8013B3E4),
        0x80171718+4*0x1C: (0x8013B8CC,),
        # Temporary anchor is (cell x + 1, cell y - 3) × 8 before the camera subtraction.
        0x8013B034: (0x3082003F, 0x00021840, 0x3C048018, 0x8C84AF94,
                     0x00621821, 0x000318C0, 0x0804EC1B, 0x00643821),
        0x8013B080: (0x24420001, 0x000210C0, 0x00431023, 0x2442FF60),
        0x8013B0AC: (0x2442FFFD, 0x000210C0, 0x00431023, 0x2442FF88),
        0x8013B134: (0x0C03136D, 0x34060014),
        0x8013B360: (0x0C051591, 0x34050014),
        0x8013B424: (0x2442FFFF, 0x3C018018, 0xAC22AF84),
        0x8013B4B0: (0x2442FFFF, 0x3C018018, 0xAC22AF84),
        0x80145A70: (0x2442FFFF, 0x0C051D5A, 0xA2020001),
        0x80145AB4: (0x2442FFFF, 0x0C051D5A, 0xA2020001),
        0x801475B4: (0x00621821, 0x0064001A),
        # The VM runs before the glyph pass. The staging callback comes after it.
        0x8013F11C: (0x0C04FC30, 0x00008021, 0x14400004, 0,
                     0x0C04F80A, 0, 0x00408021, 0x0C04F888),
        0x8013F168: (0x0C04FE58,),
        0x8013F8CC: (0x0C05177A,),
        0x8013F8D8: (0x0C051A4D,),
        0x8013F930: (0x30420800, 0x14400003, 0x00001021, 0x0804FE53,
                     0x34020001, 0x3C018017, 0xA0201899),
        0x80146994: (0x8E050054, 0x0C051AED, 0x00003021),
        0x801469D8: (0x8E050054, 0x0C051AED, 0x34060001, 0x92030004, 0xAE020054, 0xA2030003),
        0x8013CE50: (0x0C04F33C,),
        0x80171B98: (1, 3, 0, 2),
        # The selected portrait streams through the decode and slot upload calls.
        0x8013F664: (0x90620000, 0, 0x14450008, 0x25080001, 0x8C64002C,
                     0x8C650030, 0x01203021, 0x0C04FD2E),
        0x8013F4E4: (0x0C030C51,),
        0x8013F4FC: (0x0C04FCDF,),
    })


def text_prefixes(tokens):
    visible = ''
    for token in tokens:
        assert token['kind'] in ('glyph', 'newline')
        visible += '\n' if token['kind'] == 'newline' else token['text']
        yield '\n'.join(line.rstrip() for line in visible.split('\n')).rstrip()


def text_vectors(packet):
    result = []
    for index, text in enumerate(packet['texts']):
        prefixes = list(text_prefixes(text['tokens']))
        samples = [dict(visible=value, done=i+1 == len(prefixes), countdown=0, pace=0)
                   for i, value in enumerate(prefixes)]
        result.append(dict(text=index, samples=samples))
    return result


def body_queue_vectors(packet):
    raw, _ = source('/VB6.BIN')
    room = scene.room_record(raw, 6)
    entry = scene.entities(raw, room)[5]['stream_offsets'][2]
    start, _, operands, _ = next(row for row in event_script_decode.decode_stream(raw, entry, max_insns=8)
                                  if row[1] == 0x1C)
    assert operands == b'\0\0\x03'
    assert raw[start+4:start+6] == bytes((2, 12))  # Confirm wait precedes box close.
    tokens = packet['texts'][1]['tokens']
    assert all(token['kind'] == 'glyph' for token in tokens)
    visible = list(text_prefixes(tokens))
    result = []
    for speed, configuration in zip(('fast', 'normal', 'slow'), packet['configuration'], strict=True):
        pace, pressed_pace = configuration['normal_pace'], configuration['pressed_pace']
        for accelerated in (False, True):
            complete = 6 if accelerated else 1+(len(visible)-1)*(pace+1)
            samples = []
            for tick in range(complete+3):
                revealing = accelerated and tick == 5
                accepted = tick == complete+2
                text, countdown = '', 0
                if tick and (not accelerated or tick <= 5):
                    index, elapsed = divmod(min(tick, complete)-1, pace+1)
                    text, countdown = visible[index], pace-elapsed
                if accelerated and tick >= complete:
                    text, countdown = visible[-1], samples[5]['countdown']
                samples.append(dict(pressed=revealing or accepted, vm_ran=tick == 0 or tick > complete,
                    cursor=5 if accepted else 4, active=tick < complete, visible=text, done=tick >= complete,
                    countdown=countdown, pace=pace, fast=revealing,
                    current_pace=pressed_pace if revealing else pace))
            result.append(dict(speed=speed, accelerated=accelerated, samples=samples))
    return result


def descriptor_vectors():
    mapping = tuple(M.mword(0x80171B98+4*i) for i in range(4))
    rows = []
    for count, follower, flags, direction in product((3, 6), (0, 1), range(4), mapping):
        after = (flags & 2, flags | 1, flags & 1, flags | 2)[direction]
        rows.append(dict(count=count, follower=follower, before=flags,
                         direction=DIRECTIONS[direction], after=after))
    return rows


def anchor_vectors():
    packet, report = party.export()
    tracks = get_tracks(report, packet)
    positions = {(r['count'], r['facing']): r['samples'][-1]['followers']
                 for r in movement_vectors(packet['anchor'], tracks) if r['phase'] == 'spread'}
    result = []
    for count, facing, slot in product((3, 6), range(4), (0, 1)):
        follower = 1-slot
        position = positions[count, DIRECTIONS[facing]][follower]
        anchor = dict(x=position['x']+8, y=position['y']-24)
        camera = dict(x=100, y=80)
        origin = {axis: anchor[axis]-camera[axis] for axis in camera}
        result.append(dict(count=count, facing=facing, slot=slot, follower=follower,
                           anchor=anchor, camera=camera, origin=origin))
    return result


def window_states(x, y):
    small = (x-160, y-120, 3, 3)
    full = (-124, 38, 240, 60)
    result = []
    for closing in (False, True):
        start, end = (full, small) if closing else (small, full)
        updates = []
        for remaining in range(19, -1, -1):
            numerators = [a*remaining + b*(20-remaining) for a, b in zip(start, end, strict=True)]
            left, top, width, height = [n//20 if n >= 0 else -(-n//20) for n in numerators]
            left, top = left+160, top+120
            right, bottom = left+width, top+height
            corners = ((left, top), (right, top), (right, bottom), (left, bottom), (left, top))
            lines = [dict(x1=x1, y1=y1, x2=x2, y2=y2)
                     for (x1, y1), (x2, y2) in zip(corners, corners[1:])]
            updates.append(dict(remaining=remaining, open=False, lines=lines))
        updates.append(dict(remaining=0, open=not closing, lines=[]))
        result.append(dict(closing=closing, updates=updates))
    return result


def matching_image_vector(packet):
    raw, _ = source('/04_PLAY/GRE.BIN')
    image, palette = struct.unpack_from('<II', raw, 44)
    plane, used = decode_container(raw, image)
    assert len(plane) == 64*64 and palette+512 <= len(raw)
    name = list(text_prefixes(packet['texts'][4]['tokens']))[-1]
    return dict(character=raw[0], box=packet['prefixes'][2]['box'], width=64, height=64,
                compressed_bytes=used-4, plane_sha256=sha256(plane).hexdigest(),
                palette_sha256=sha256(raw[palette:palette+512]).hexdigest(), name=name)


class FieldDialogue(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        check_source_paths()
        cls.packet, cls.proof = export.export()

    def test_open_close_and_coordinate_consumer(self):
        self.assertEqual(anchor_vectors(), fixture('field_dialogue'))

    def test_existing_box_helper_contract(self):
        rows = fixture('opening_windows')
        self.assertEqual(len(rows), 8)
        for row in rows:
            x, y = row['actor_x']+8-row['camera_x'], row['actor_y']-24-row['camera_y']
            self.assertEqual(row['origin'], dict(x=x, y=y))
            self.assertEqual(row['states'], window_states(x, y))

    def test_export_current(self):
        self.assertEqual(self.packet, read_json('game/assets/field_dialogue.json'))
        self.assertEqual(self.proof, read_json('kit/data/reports/field_dialogue.json'))

    def test_name_text_and_missing_image(self):
        ids = bytes((8, 2, 6, 35, 32, 38))
        raw, _ = source('/VB6.BIN')
        section = scene.section_off(raw, scene.room_record(raw, 6)['section'])
        custom = scene.ptr_at(raw, section+0x34)
        for slot in range(128):
            pointer = scene.ptr_at(raw, custom+slot*4)
            if pointer is None:
                break
            self.assertNotEqual(scene.u32(raw, pointer), 4)
        else:
            self.fail('unterminated room image table')
        self.assertNotIn(4, ids)
        for index, character in ((0, 4), (4, 2)):
            image = M.body()
            rank_table = 0x80170095-M.MBASE
            rank = image[rank_table:rank_table+109].index(character)+1
            address = M.mword(0x80170588+rank*4)-M.MBASE
            end = image.index(0, address)
            self.assertEqual([*text_prefixes(self.packet['texts'][index]['tokens'])][-1],
                             ''.join(war_text.SUBST[byte] for byte in image[address:end]))
        self.assertEqual(text_vectors(self.packet), fixture('field_text'))

    def test_body_queue_timing(self):
        self.assertEqual(body_queue_vectors(self.packet), fixture('field_body_queue'))

    def test_temporary_descriptor_changes(self):
        self.assertEqual(descriptor_vectors(), fixture('field_descriptor_changes'))

    def test_matching_image_and_name(self):
        expected = fixture('field_matching_image')
        self.assertTrue(expected.pop('source_decode_agrees'))  # Historical decoder comparison.
        actual = matching_image_vector(self.packet)
        self.assertEqual(actual, expected)
        resource = self.packet['images'][0]
        for key in ('character', 'width', 'height', 'plane_sha256', 'palette_sha256'):
            self.assertEqual(resource[key], actual[key])

    def test_art_manifest_matches_source_contracts(self):
        with patch.object(export, 'export', side_effect=AssertionError('entered candidate generation')):
            with self.assertRaises(ValueError):
                export.export_art(ROOT/'kit/work/accepted/field-ui')
        art = fixture('field_dialogue_art')
        self.assertEqual(art['content_sha256'], self.packet['content_sha256'])
        self.assertEqual(art['atlas'], 'atlas.png')
        glyphs = [(code, name) for code, name in war_text.SUBST.items() if len(name) == 1]
        self.assertEqual(len(art['glyphs']), len(glyphs))
        for (code, name), glyph in zip(glyphs, art['glyphs'], strict=True):
            trim = M.body()[0x80171F5C-M.MBASE+code-17] if 17 <= code < 43 else 0
            self.assertEqual((glyph['character'], glyph['advance']), (name, 8-trim))
            rect = glyph['rect']
            if code == 16:
                self.assertIsNone(rect)
            else:
                self.assertEqual((rect['w'], rect['h']), (8, 12))
        roles = ('center', 'top_left', 'top_right', 'bottom_left', 'bottom_right',
                 'top', 'bottom', 'left', 'right')
        self.assertEqual(tuple(entry['role'] for entry in art['window']), roles)
        self.assertTrue(all((entry['rect']['w'], entry['rect']['h']) == (12, 12) for entry in art['window']))
        portrait, = art['portraits']
        resource = self.packet['images'][0]
        self.assertEqual(portrait['image'], 0)
        self.assertEqual((portrait['rect']['w'], portrait['rect']['h']), (64, 64))
        for key in ('id', 'plane_sha256', 'palette_sha256'):
            self.assertEqual(portrait[key], resource[key])
        graphics, _ = party.graphics()
        for actor, source_actor in zip(art['followers'], graphics['resources'], strict=True):
            self.assertEqual((actor['character'], actor['id']), (source_actor['character'], source_actor['id']))
            self.assertEqual(actor['content_sha256'], graphics['content_sha256'])
            for i, (clip, reference) in enumerate(zip(actor['clips'], source_actor['clips'], strict=True)):
                self.assertEqual((clip['direction'], clip['idle_frame']), (DIRECTIONS[i], 1))
                self.assertEqual([frame['ticks'] for frame in clip['frames']], reference['ticks'])
                self.assertEqual([(frame['rect']['w'], frame['rect']['h']) for frame in clip['frames']],
                                 [(size['width'], size['height']) for size in reference['bounds']])


if __name__ == '__main__':
    unittest.main()
