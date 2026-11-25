"""Static source checks for VB6 room6's named ordinary predicate operands."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import area_scene
import export_field_predicates as export
from export_first_room import source
import maindec


class FieldPredicates(unittest.TestCase):
    def test_export_is_reproducible(self):
        for path, expected in export.outputs().items():
            self.assertEqual(path.read_text(), expected)

    def test_raw_predicates_and_consumers(self):
        raw, _ = source('/VB6.BIN')
        entities = area_scene.entities(raw, area_scene.room_record(raw, 6))
        expected = (
            bytes.fromhex('0b 01 01 0c 13 26 06'),
            bytes.fromhex('0b 2d 2d 06'),
            bytes.fromhex('0b 19 19 0c 2a 2a 04 00 06'),
            bytes.fromhex('0b 26 26 0c 13 13 04 00 06'),
            bytes.fromhex('0b 0e 0e 0c 15 15 04 00 06'),
        )
        for entity, data in zip(entities, expected, strict=False):
            offset = entity['stream_offsets'][1]
            self.assertEqual(raw[offset:offset + len(data)], data)
        for opcode, handler in ((4, 0x8013dd38), (11, 0x8013dce0), (12, 0x8013dd0c)):
            self.assertEqual(struct.unpack_from('<I', maindec.body(), 0x800c1a00-maindec.MBASE+4*opcode)[0], handler)
        self.assertEqual(maindec.mword(0x8013dcf4), 0x0062102b)
        self.assertEqual(maindec.mword(0x8013dd20), 0x0062102b)
        self.assertEqual(maindec.mword(0x8013dd60), 0x00621824)
        self.assertEqual(struct.unpack_from('<I', maindec.body(), 0x80171708-maindec.MBASE)[0], 0x1000)

    def test_all_room_coordinates_and_up_states_against_raw_source(self):
        raw, _ = source('/VB6.BIN')
        entities = area_scene.entities(raw, area_scene.room_record(raw, 6))
        document = json.loads((ROOT / 'game/assets/field_predicates.json').read_text())
        for entity, record in zip(entities[:5], document['records'], strict=True):
            for x in range(48):
                for y in range(48):
                    for up in (False, True):
                        cursor = entity['stream_offsets'][1]
                        source_result = True
                        while raw[cursor] != 6:
                            opcode = raw[cursor]
                            if opcode == 4:
                                self.assertEqual(raw[cursor + 1], 0)
                                result = up
                                cursor += 2
                            else:
                                self.assertIn(opcode, (11, 12))
                                value = x if opcode == 11 else y
                                result = raw[cursor + 1] <= value <= raw[cursor + 2]
                                cursor += 3
                            if not result:
                                source_result = False
                                break
                        named_result = True
                        for term in record['terms']:
                            value = x * 8 if term['kind'] == 'x_range' else y * 8
                            result = up if term['kind'] == 'up_input' else term['min_pixel'] <= value <= term['max_pixel']
                            if not result:
                                named_result = False
                                break
                        self.assertEqual(named_result, source_result, (entity['index'], x, y, up))
        e0 = document['records'][0]['terms']
        self.assertFalse(e0[0]['min_pixel'] <= 216 <= e0[0]['max_pixel'])
        self.assertTrue(e0[1]['min_pixel'] <= 200 <= e0[1]['max_pixel'])

    def test_input_and_caller_gate_source_writers(self):
        # The source predicate reads a bitmask; event-driven input can replace it.
        anchors = {
            0x800c2a30: 0xac28bdcc,  # sampled pad word
            0x8013e4f4: 0xac22bdcc,  # scripted input override
            0x8013dd44: 0x8c63bdcc,  # ordinary predicate reads that word
            0x8013dd60: 0x00621824,  # intersects the selected mask
            0x80131538: 0xac400498,  # initial callback clear
            0x8013153c: 0xac40049c,  # initial per-frame handler clear
            0x80139894: 0xaca20498,  # opcode43 can install callback
            0x80135878: 0xac62049c,  # opcode4f can install handler
            0x80132b8c: 0xac20dc4c,  # completion flag resets per event frame
            0x8013e12c: 0xac22dc4c,  # completed VM sets the flag
            0x80132c38: 0x3c018018,
            0x80132c3c: 0xac20dc4c,  # callback can reset it after VM completion
            0x80132c40: 0x0040f809,  # completion callback is indirect
            0x80132c68: 0xac22dc4c,  # callback clearing its slot restores it
            0x80132ca8: 0xac220000,  # free selector is installed
            0x80132cf0: 0x0c04c9b3,  # post-frame driver can replace it again
            0x80132bd0: 0x906204e0,  # menu/transition state diverts the owner
            0x80132948: 0x8c42bd74,  # free caller checks coordinate high bits
            0x8013295c: 0x0c04b30e,  # free caller checks event/encounter mode
            0x8013296c: 0x0c04b2c4,  # then checks the other mode gate
            0x8012cb24: 0x90420037,  # free caller reads area mode flags
            0x80139528: 0xa0620037,  # opcode47 can request a mode
            0x8013270c: 0xa0620037,  # post-frame driver can request a mode
        }
        for address, word in anchors.items():
            self.assertEqual(maindec.mword(address), word, hex(address))
        self.assertEqual(maindec.mword(0x8012c898), 0x10620018)  # 0x1000 selects this arm
        self.assertEqual(maindec.mword(0x8012c904), 0x0c04b6a3)
        self.assertEqual(maindec.mword(0x8012c908), 0x34050001)  # direction table index 1
        vector = maindec.mword(0x801715b0 + 4) - maindec.MBASE
        self.assertEqual(maindec.body()[vector:vector + 2], bytes((0, 255)))  # (0, -1)
        for other in (0, 0x2000, 0x4000, 0x8000, 0x6000):
            self.assertTrue((0x1000 | other) & 0x1000)

    def test_post_frame_mode_request_selector_and_consumption(self):
        # Opcode 42 delegates its operand to a source jump table.
        self.assertEqual(maindec.mword(0x80171718 + 4 * 0x42), 0x801398f8)
        self.assertEqual(maindec.mword(0x80139918), 0x0c050605)
        self.assertEqual(maindec.mword(0x800c1ac0 + 4 * 3), 0x801418e0)
        anchors = {
            0x801418e4: 0x9042159b,  # selector 3 reads the field mode byte
            0x801418ec: 0x34420002,  # requests the post-frame mode change
            0x801418f4: 0xa022159b,
            0x801326d0: 0x9042159b,
            0x801326e0: 0x30420002,  # post-frame handler tests the request
            0x801326e4: 0x10400026,  # no request skips the transition
            0x80132754: 0x38420002,  # taken path consumes the request
            0x8013275c: 0xa022159b,
            0x8013276c: 0x24422898,  # installs mode driver 0x80132898
            0x8013277c: 0xac220000,
        }
        for address, word in anchors.items():
            self.assertEqual(maindec.mword(address), word, hex(address))


if __name__ == '__main__':
    unittest.main()
