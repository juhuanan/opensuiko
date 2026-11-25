#!/usr/bin/env python3
"""Static physical-rune setup/dispatch/contact contracts; no original execution.

Native behavior: game/tests/battle_physical.zig and
game/tests/battle_systems/runes.zig cover live clocks, costs, scaling and one-shot
acknowledgement. This gate independently checks their original source contract.
"""
import hashlib
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
from test_physical_rune_export import independent_stream


class PhysicalRuneTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw, cls.origin = source('MAIN.EXE')
        cls.base, size = struct.unpack_from('<II', raw, 0x18)
        cls.body = raw[2048:2048+size]

    def word(self, address):
        return struct.unpack_from('<I', self.body, address-self.base)[0]

    def words(self, expected):
        for address, word in expected.items():
            self.assertEqual(self.word(address), word, hex(address))

    def span(self, start, end, digest):
        self.assertEqual(hashlib.sha256(self.body[start-self.base:end-self.base]).hexdigest(), digest)

    def test_boar_and_clone_setup_share_double_damage_and_recovery_status(self):
        for native,callback in ((1,0x800F8A9C),(6,0x800F8B78)):
            descriptor = self.word(0x8016A630+4*native)
            self.assertEqual(self.word(descriptor+28), callback)
            flags = struct.unpack_from('<H', self.body, descriptor-self.base+22)[0]
            self.assertEqual(flags&3, 3)
        self.span(0x800F8A9C,0x800F8B78,'592bfcaed729ed7369c3b35bb6ad357568c18fc86ceec897293d064392f4b7ce')
        self.span(0x800F8B78,0x800F8C24,'afe81a157dd53ecdf22cd1e377cbc898c4417319d771eecef22b7c15f13f22cd')
        self.words({0x800F8B08:0x8C460034, 0x800F8B10:0x0C038E08,
                    0x800F8B1C:0x3C028010, 0x800F8B20:0x2442881C,
                    0x800F8B28:0xAC22A000, 0x800F8B2C:0x34020014,
                    0x800F8BBC:0x3C068017, 0x800F8BC0:0x24C6C83C,
                    0x800F8BC4:0x0C038E08, 0x800F8BDC:0x3C028010,
                    0x800F8BE0:0x2442881C, 0x800F8BE8:0xAC22A000,
                    0x800F8BEC:0x34020014})
        pahn,_ = source('/PAN.BIN')
        table = struct.unpack_from('<I', pahn, 32)[0]
        offset = struct.unpack_from('<I', pahn, table+4*13)[0]
        boar = independent_stream(pahn,offset,table)
        clone = independent_stream(self.body,0x8016C83C-self.base,base=self.base)
        for operations in (boar,clone):
            self.assertIn(dict(op=40,args=[7,100]),operations)

    def test_dispatch_skips_magic_charge_service_for_physical_runes(self):
        self.span(0x800F5500,0x800F5790,'8ffe0d15902a74d1921784518ff719449ef4fccc8fc15cbd3c487a670e11a7f4')
        self.words({0x800F5550:0x9042004C, 0x800F5560:0x2421A0E0,
                    0x800F55DC:0x92430016, 0x800F55EC:0x1062000A,
                    0x800F5604:0x2421D33C, 0x800F561C:0x2421A630,
                    0x800F56E8:0x92420016, 0x800F56F0:0x1440000A,
                    0x800F56FC:0x0C03D4D1, 0x800F5700:0x02602821,
                    0x800F575C:0x8E83001C, 0x800F5764:0xAC830014})
        for rune,tier,kind,ordinal,callback in ((8,0,1,1,0x800F8A9C),
                                               (13,0,1,6,0x800F8B78),
                                               (2,1,0,1,0x800FEAEC)):
            record = self.word(0x8016A0E0+4*rune)-self.base
            self.assertEqual(self.body[record+0x16],kind)
            self.assertEqual(self.body[record+0x1a+tier],ordinal)
            descriptor = self.word((0x8016D33C if kind==0 else 0x8016A630)+4*ordinal)
            self.assertEqual(self.word(descriptor+28),callback)
        # The nonzero-class branch crosses the sole charge-service call.
        branch = self.word(0x800F56F0)
        self.assertEqual(0x800F56F4+struct.unpack('<h',struct.pack('<H',branch&65535))[0]*4,0x800F571C)

    def test_damage_updater_doubles_one_exact_target_then_clears_impact_latch(self):
        self.span(0x800F881C,0x800F8904,'ebca83d6208462c0246931b86bde67b88956d36f090f381990b3db0d8a4b622a')
        self.words({0x800F8830:0x00A08021, 0x800F8854:0x92230004,
                    0x800F8858:0x30420002, 0x800F885C:0x10400022,
                    0x800F8864:0x0C03DFA4, 0x800F8868:0x00602021,
                    0x800F886C:0x3C038018, 0x800F8870:0x8C63A008,
                    0x800F8878:0x00430018, 0x800F8884:0x3402000A,
                    0x800F8888:0x00A2001A, 0x800F88B4:0x0C038595,
                    0x800F88B8:0x02002021, 0x800F88D4:0xAC400050,
                    0x800F88E0:0x3042FFFD, 0x800F88E4:0xA6220040})
        words = struct.unpack('<58I',self.body[0x800F881C-self.base:0x800F8904-self.base])
        self.assertEqual(words.count(0x0C03DFA4),1)
        self.assertEqual(words.count(0x0C038595),1)
        branch = self.word(0x800F885C)
        self.assertEqual(0x800F8860+struct.unpack('<h',struct.pack('<H',branch&65535))[0]*4,0x800F88E8)


if __name__ == '__main__':
    unittest.main()
