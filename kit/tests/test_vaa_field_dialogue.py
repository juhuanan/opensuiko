"""Static VAA layout, custom portrait/name, and paged body consumers."""
from pathlib import Path
from hashlib import sha256
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene
import maindec
import opening_audience
import export_vaa_field_dialogue as export
from export_first_room import source
from lzss import decode_container
from test_canonical_start import assert_main_words
from test_field_dialogue import check_source_paths
from test_field_ordinary_track import source_path
from test_opening_audience import widget_samples


def anchored_box(x, y, cx, cy):
    return dict(actor=dict(x=x, y=y), camera=dict(x=cx, y=cy), anchor=dict(x=x + 8, y=y - 24))


def source_dialogue(raw):
    room = area_scene.room_record(raw, 2)
    section = area_scene.section_off(raw, room['section'])
    area_text = area_scene.ptr_at(raw, area_scene.ptr_at(raw, 0) + 20)
    room_text = area_scene.ptr_at(raw, room['record_off'] + 12)

    assert raw[0x50D89:0x50D8D] == bytes.fromhex('0b0c1200')
    character = raw[0x50D8D]
    actors = [entry for entry in area_scene.entities(raw, room)
              if entry['flags'] & 0x101 and entry['stream_offsets'][0] is not None]
    teo = actors[raw[0x50D8A]]
    assert teo['id'] == character == 110
    x, y = (teo[axis] * 8 for axis in ('x_half', 'y_half'))
    anchors = [anchored_box(x, y, 320, 512),
               anchored_box(x + 8, y + 8, 100, 80),
               anchored_box(x - 8, y - 8, 320, 472)]

    record = area_scene.character_bindings(raw, section)[character]['record']
    image, palette = (area_scene.ptr_at(raw, record + offset) for offset in (4, 8))
    plane, used = decode_container(raw, image)
    size, = struct.unpack_from('<I', raw, image)
    assert len(plane) == 4096 and used == size + 4 and palette + 512 <= len(raw)
    portrait = dict(plane_sha256=sha256(plane).hexdigest(),
                    palette_sha256=sha256(raw[palette:palette + 512]).hexdigest(), slot=0)
    text_start = maindec.mword(0x80170588 + 4 * character) - maindec.MBASE
    code = maindec.body()
    newline = maindec.mword(0x8013FB00) & 255
    name = opening_audience.war_text.decode(code, text_start)[0] + '\n'
    prefix = code[text_start:code.index(0, text_start)] + bytes((newline, 0))
    prefix_samples = [dict(visible=sample['visible'], done=sample['done'])
                      for sample in widget_samples(prefix, 0, 0, b'', 30, 5, lambda *_: False)]
    anchors[0].update(portrait=portrait, name=name, prefix_samples=prefix_samples)

    def messenger_anchor(offset, returning):
        assert raw[offset:offset + 2] == bytes((0x17, 10))
        pose = source_path(returning=returning)['samples'][-1]['after']
        camera_x = 72 if returning else 320
        return anchored_box(pose['x'], pose['y'], camera_x, 512)

    assert raw[0x50D8E:0x50D93] == bytes.fromhex('040000020c')
    assert raw[0x50D9D:0x50DA1] == bytes.fromhex('1c010000')
    assert raw[0x50DBF:0x50DC3] == bytes.fromhex('1c010001')
    assert raw[0x50DA1] == 0x0A
    duration = raw[0x50DA2] * 5
    delay = [dict(remaining=remaining, pending=remaining > 0, vm_ran=remaining == duration - 1)
             for remaining in range(duration - 1, -1, -1)]
    delay.append(dict(remaining=0, pending=False, vm_ran=True))

    index = raw[0x50D90]
    first_body = area_scene.ptr_at(raw, room_text + 4 * index)
    messenger_table = area_scene.ptr_at(raw, area_text + 4 * raw[0x50D9F])
    first_messenger = area_scene.ptr_at(raw, messenger_table + 4 * raw[0x50DA0])
    return_messenger = area_scene.ptr_at(raw, messenger_table + 4 * raw[0x50DC2])
    pace = code[0x80171889 - maindec.MBASE]
    name_bytes = bytes.fromhex('3e1922')  # Supplied player name in the retained samples.

    def delivery(start, wait_for_accept=False):
        result = []
        for accelerated in (False, True):
            samples = [dict(pressed=False, visible='', page_wait=False, done=False, countdown=0, pace=pace, fast=False)]

            def should_press(tick, was_waiting, _):
                tick += 1  # Opening the widget consumes the first update.
                return (accelerated and tick == 5) or (was_waiting and tick % 5 == 0)

            samples.extend(widget_samples(raw, start, pace, name_bytes, 30, 5, should_press))
            if wait_for_accept:
                samples.extend([samples[-1].copy(), dict(samples[-1], pressed=True)])
            result.append(dict(accelerated=accelerated, samples=samples))
        return result

    return dict(anchors=anchors, body=delivery(first_body, wait_for_accept=True),
                messenger_anchor=messenger_anchor(0x50D9B, False), messenger_body=delivery(first_messenger),
                delay=delay, return_anchor=messenger_anchor(0x50DBD, True), return_body=delivery(return_messenger))


class Dialogue(unittest.TestCase):
    def test_current_export(self):
        packet, proof = export.export()
        self.assertEqual(packet, json.loads((ROOT / 'game/assets/vaa_field_dialogue.json').read_text()))
        self.assertEqual(proof, json.loads((ROOT / 'kit/data/reports/vaa_field_dialogue.json').read_text()))

    def test_source_consumers(self):
        check_source_paths()
        assert_main_words({
            0x80171718 + 4 * 0x0A: (0x8013CCA8,),
            0x8013CCD8: (0x00031080, 0x00431021, 0x3C018018, 0xA422A138),
            0x8013FB00: (0x34020003,),
        })
        raw, _ = source('/VAA.BIN')
        expected = json.loads((ROOT / 'game/tests/fixtures/vaa_field_dialogue.json').read_text())
        for key, value in source_dialogue(raw).items():
            with self.subTest(key=key):
                self.assertEqual(value, expected[key])


if __name__ == '__main__':
    unittest.main()
