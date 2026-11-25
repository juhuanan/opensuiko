"""Independent Roc selector/contact/HP/status checks; no original execution."""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
from actor_script import OP_LEN_HW


class RocStatusContact(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw, cls.origin = source('MAIN.EXE')
        cls.base, size = struct.unpack_from('<II', raw, 0x18)
        cls.main = raw[2048:2048+size]
        cls.overlay, cls.overlay_origin = source('/B_DATA.BIN')

    def word(self, address):
        return struct.unpack_from('<I', self.main, address-self.base)[0]

    def test_roc_selector_checks_inactivity_row_and_lock_before_its_draw(self):
        block = self.overlay[0x6c:0x1e0]
        self.assertEqual(hashlib.sha256(block).hexdigest(), '0843b0bf74ffafadebb1e216277dd9c68d0ce0ce08b7bf16de25be176c715724')
        for offset, word in {0xb4:0x92020045, 0xc4:0x92020044,
                             0xd8:0x92620005, 0xf8:0x0040F809,
                             0x134:0x28630033, 0x1b0:0xA0540049}.items():
            self.assertEqual(struct.unpack_from('<I', self.overlay, offset)[0], word, hex(offset))
        loads = [w for (w,) in struct.iter_unpack('<I', block) if w >> 26 in (32,33,35,36,37)]
        self.assertFalse(any(w & 65535 == 0x4a for w in loads))

    def test_shared_hit_calls_damage_hp_then_the_attacker_recipient_script(self):
        spans = ((0x800f4d5c,0x800f4e64,'25d9bf6841a2dccfbfc234f95487ebcd905b4ae499d2312ffeaf6cba6e672cf2'),
                 (0x800f4e64,0x800f4fec,'377727c64d7d2d61c2ac70d2ddf89665a2c350265f08f9256c86ca30af89cc77'),
                 (0x800f5960,0x800f5abc,'2771f25a7922a48e9c123054851c58b2c7f5760a0f81ecf827bf2d57f34f91c5'),
                 (0x800e1654,0x800e1b80,'0de763aa8e86717e7487414279f8536c673c5861693526c91662a395566950f3'))
        for start,end,digest in spans:
            self.assertEqual(hashlib.sha256(self.main[start-self.base:end-self.base]).hexdigest(),digest)
        pins = {0x800f4f70:0x30420008, 0x800f4f7c:0x0C03D357,
                0x800f4e08:0x24635960, 0x800f59bc:0x0C03DFA4,
                0x800f59c8:0x0C038595, 0x800f5a64:0x8C460008,
                0x800f5a6c:0x0C038E08,
                0x800e16e0:0x9462004A, 0x800e16e8:0x30428000,
                0x800e16f4:0x00008021, 0x800e16f8:0x12000115,
                0x800e16fc:0x2402FFFF, 0x800e1b50:0x8FBF006C,
                0x800e176c:0x9462004E,
                0x800e177c:0xA462004E}
        for address,word in pins.items(): self.assertEqual(self.word(address),word,hex(address))
        hp_words = [w for (w,) in struct.iter_unpack('<I',self.main[0x800e1654-self.base:0x800e1b80-self.base])]
        self.assertFalse(any(w >> 26 in (40,41,43) and w & 65535 == 0x4a for w in hp_words))
        self.assertNotIn(0x0C0381DE,hp_words) # The explicit status-removal helper.

    def test_roc_recipient_retains_status_until_explicit_cure_or_knockout(self):
        offset = struct.unpack_from('<I', self.overlay, 0x236c8+8)[0]-0x80080000
        start = offset
        operations = []
        while True:
            opcode = struct.unpack_from('<H', self.overlay, offset)[0]
            length = max(1, OP_LEN_HW[opcode])
            operations.append(opcode)
            offset += length*2
            if opcode in (0,1,2): break
        self.assertEqual((start,offset),(0x2374c,0x237f8))
        self.assertEqual(hashlib.sha256(self.overlay[start:offset]).hexdigest(),'34f11f038fcec4eec4c4f408c7dbb5c663f8ea880097c1132d9690999867b7d8')
        self.assertEqual(set(operations),{0,3,4,16,21,22,24,25,26,27,34,38,39})
        child = self.word(0x8016c208)
        self.assertEqual(child,0x8016c1dc)
        child_bytes = self.main[child-self.base:child-self.base+12]
        self.assertEqual(struct.unpack('<6H',child_bytes),(25,2,0,0,5,2))
        # General cure explicitly removes Sleep class5; contact instead queues HP.
        self.assertEqual(self.word(0x80120508),0x0C0381DE)
        self.assertEqual(self.word(0x8012050c),0x34050005)


if __name__ == '__main__':
    unittest.main()
