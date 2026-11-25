#!/usr/bin/env python3
"""Static source contracts and retained semantic vectors; native Zig owns execution."""
from pathlib import Path
import hashlib
import itertools
import json
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import maindec as M

CONTEXT,TABLE,RECORD=0x80710000,0x80720000,0x80730000


# Retired execution helpers remain import-compatible for legacy gates not run by this check.
def invoke(c,pc):
    c.r[31]=0xFFFFFFFC
    return c.run(pc)

def until(c,pc,end):
    for _ in range(20000):
        if pc==end:return
        if c.external_call(pc):pc=c.r[31];continue
        target=c.basic(pc)
        if target is None:pc+=4
        else:assert c.basic(pc+4) is None;pc=target
    raise AssertionError('bounded instruction path did not reach endpoint')

class JourneySource(unittest.TestCase):
    def pins(self, expected):
        for address, word in expected.items():
            self.assertEqual(M.mword(address), word, hex(address))

    def test_complete_consumer_windows(self):
        for start, end, digest in (
            (0x80125b28, 0x80125c94, 'e6f9d7fe36ede9ef681cfef158fda258378879f2ad34c970220f0a15026a5063'),
            (0x800e6ab8, 0x800e6d38, '4c431d4adb9b245748d2810d83f7f9e6eccf1613b4ba87e39512502ca3f5957f'),
            (0x800f6f58, 0x800f6fd8, '1a1c66c856dc4ad0e57cc9c92d79cdc3a9411c714e6ff41f223a5a713e30ef67'),
            (0x800f657c, 0x800f65b8, '3c02c915171edc326ab1b1f711c36ab13b493b58c82948b688c58b7a737b9e0e'),
            (0x801204ec, 0x8012055c, 'ec24462758e14c310cb1e433dab9bb635fa2e5d4f1b81990198bc69e74371e45'),
            (0x80105bc8, 0x801060e8, 'a8401a7b416dbf317c51dbc9996cc9bdcb70b1cf9c9291635633c7ca7397d6b2'),
            (0x8010a024, 0x8010a5ec, '12b682b0b18869a0c4c9685a8a6b7be190c3114843098bd5a64afe697bef0929'),
            (0x80106e94, 0x80106ef8, 'f06239f1e46b23f584d1b6d4dfebaaba602735dbb69d9976eb0ffcccf3a79d73'),
            (0x8010867c, 0x801086e0, 'c76f35dbdc4383e0aedd4023491710d22b31815ce672cd6849a128f7f7ef27df')):
            self.assertEqual(hashlib.sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest(), digest)

    def test_elemental_arithmetic_and_retained_vectors(self):
        self.pins({0x80125b84:0x94630b6c, 0x80125b90:0x00031842,
                   0x80125b94:0x02238821, 0x80125c14:0x90430020,
                   0x80125c1c:0x1062000f, 0x80125c40:0x10620008,
                   0x80125c4c:0x10620008, 0x80125c60:0x00111040,
                   0x80125c6c:0x00111043, 0x80125c70:0x00001021})
        rows = json.loads((Path(__file__).resolve().parents[2]/'game/tests/fixtures/journey_rules.json').read_text())
        expected = []
        for power, magic, affinity in itertools.product([100,150], [0,1,17,65,255], range(4)):
            base = power + magic//2
            expected.append(dict(power=power, magic=magic,
                affinity=['neutral','weak','resistant','immune'][affinity],
                damage=[base,base*2,base//2,0][affinity]))
        self.assertEqual(rows['damage'], expected)
        expected = [dict(roll=r, sleep=(r*100//32767)%100>=30,
                         recover=r*100//32767<50)
                    for r in [0,1,9502,9830,9831,16383,16384,32766,32767]]
        self.assertEqual(rows['status'], expected)

    def test_spell_callback_selection_and_healing_consumers(self):
        for spell, callback, flags in [(1,0x800feaec,3),(2,0x800ff428,1),
                (9,0x801058ac,10),(11,0x801068cc,8),(30,0x80107fb4,8),
                (15,0x80109d98,10),(13,0x80108b58,1)]:
            pointer = M.mword(0x8016d33c+4*spell)
            self.assertEqual(M.mword(pointer+28), callback)
            self.assertEqual(M.body()[pointer-M.MBASE+22], flags)
        self.pins({0x800ff160:0x34020064, 0x800ff174:0x0c0496ca,
                   0x800ffca8:0x34020096, 0x800ffcbc:0x0c0496ca,
                   0x80105c28:0x84640b50, 0x80105c2c:0x84620b52,
                   0x80105c34:0x00829023,
                   0x80105f0c:0x90620b85, 0x80105f14:0x14400005,
                   0x80105f1c:0x0c038595, 0x80105f20:0x00122823,
                   0x80105f24:0x0c04813b, 0x8010a400:0x0c038595,
                   0x8010a404:0x00142823, 0x8010a408:0x0c04813b,
                   0x80106eb0:0x90420b85, 0x80106eb8:0x1440000b,
                   0x80106ed8:0x0c038595, 0x80106edc:0x2405fed4,
                   0x80106ee0:0x0c04813b,
                   0x801086ac:0x84430b50, 0x801086b0:0x84450b52,
                   0x801086b8:0xa0400b85, 0x801086c0:0x0c038595,
                   0x801086c4:0x00a32823, 0x801086c8:0x0c04813b})
        calls = [(address, M.mword(address+4)) for address in range(0x801204ec,0x8012055c,4)
                 if M.mword(address)==0x0c0381de]
        self.assertEqual([word for _, word in calls],
                         [0x34050000+i for i in range(6,0,-1)]+[0x00002821])

    def test_status_probability_and_recovery_boundary(self):
        self.pins({0x8016ded0:0x00050028, 0x8016d284:0x00070028,
                   0x800e6b30:0x34027fff, 0x800e6b34:0x0062001a,
                   0x800e6b60:0x34020064, 0x800e6b64:0x0062001a,
                   0x800e6b8c:0x00001010, 0x800e6b94:0x0052102a,
                   0x800e6b98:0x14400057, 0x800e6cec:0x0c038137,
                   0x800f6f88:0x34027fff, 0x800f6f8c:0x0062001a,
                   0x800f6fbc:0x28630032, 0x800f6fd0:0x3042ffdf,
                   0x800f6584:0x30420040, 0x800f6590:0x9202004d,
                   0x800f6598:0x14400003, 0x800f65a0:0x0c0381de,
                   0x800f65a4:0x34050007, 0x800f65b0:0x2442ffff})
        self.assertEqual(struct.unpack_from('<h', M.body(), 0x8016ded4-M.MBASE)[0], 30)
        self.assertEqual(struct.unpack_from('<h', M.body(), 0x8016d288-M.MBASE)[0], 100)


if __name__ == '__main__':
    unittest.main()
