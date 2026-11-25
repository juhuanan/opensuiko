#!/usr/bin/env python3
"""Static passive-rune contracts; native Zig tests own behavioral execution."""
from pathlib import Path
import hashlib
import itertools
import json
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import maindec

WINDOWS = (
    (0x800f4a74, 0x800f4ad0, '8e65573ecf179cb3d9750d43af99bf4fdba44d727c76d6d9de117d175c755491'),
    (0x800f8578, 0x800f8604, '91fc061e7151a0c12309f594d5a5beb24b9e4fac514463d0c541091aa32c4e78'),
    (0x800f3e98, 0x800f3fec, 'dce65403528616b74ce35a3f635f39f31fadf9e480b56992ec1b11288ae6b0f7'),
    (0x800f7c58, 0x800f7d5c, '279c1390f47e29d48031e94739ef8f0f04b04f7363025eef2c1c790629bc3ace'),
    (0x800f7d5c, 0x800f7e90, 'f8633a0377c7ff4d4e6c9bd0538835521cef6d3d95b22c9bc882ea84d58c96f8'),
    (0x800f835c, 0x800f8464, 'b531ce780676dcbe4bbd285c7b445ecc75f14d5a20d1f03641f8b0306d9430c2'),
    (0x800f5cd0, 0x800f5db4, 'd2d57199dfcdb4c0657b05d1e26ead50d03a32099a6d5efeea46107ea96cfe53'),
    (0x800e4fd8, 0x800e5070, '264f5dd04876603b0dbd4f8a15f3b2512373a286fb17856fc6e01dabf16198c2'),
    (0x800f5960, 0x800f5abc, '2771f25a7922a48e9c123054851c58b2c7f5760a0f81ecf827bf2d57f34f91c5'),
    (0x800f491c, 0x800f4d5c, '4cc14fed993b896003f4dc8f5f6388439bcb104636bbe210eed07778692523a9'),
    (0x800f4e64, 0x800f4fec, '377727c64d7d2d61c2ac70d2ddf89665a2c350265f08f9256c86ca30af89cc77'),
    (0x800f5abc, 0x800f5c1c, '0ecf1756e867628d12a71f3b1697404f4dcbe7b3c8a452b017a10e6a7c241120'),
    (0x800f4834, 0x800f48d0, 'e425fae9faf81acb5c7c470ab9a0db504155138a22a156851c9308359049ef8c'),
    (0x800d4efc, 0x800d4f1c, '45ff623b52f199e58ca7c12f59be62b339f98a0aba068016a8d94d08d88ad6ad'),
    (0x800e98ec, 0x800e9924, '9f01b0fb09ae62d3a16593dce0ef2729db7b338974545411519da91cf660d2a5'),
    (0x800e9b90, 0x800e9c04, 'f4cefde2ac6b870d75e7328d105a21ff59478b3c3210f8e1617ee0e5c3ce8667'),
    (0x800f7124, 0x800f725c, 'e902e835f9ced55d23c1d190d6c0c124d053531180f6f3d6c20bf4db14c40fc4'),
    (0x800e6ab8, 0x800e6d38, '4c431d4adb9b245748d2810d83f7f9e6eccf1613b4ba87e39512502ca3f5957f'),
)


class PassiveRuneTests(unittest.TestCase):
    def pins(self, expected):
        for address, word in expected.items():
            self.assertEqual(maindec.mword(address), word, hex(address))

    def test_complete_source_windows(self):
        for start, end, digest in WINDOWS:
            self.assertEqual(hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest(), digest)

    def test_offensive_semantic_vectors_and_threshold_order(self):
        rows = json.loads((ROOT/'game/tests/fixtures/passive_offense.json').read_text())
        hits = []
        for skill, target_skill, hazy, roll in itertools.product((0,20,200), (0,20,200), (0,1), (0,29,30,48,49,59,60,98,99,32767)):
            threshold = max(60, min(99, skill-target_skill+80))
            if hazy:
                threshold //= 2
            hits.append([skill,target_skill,hazy,roll,int(roll%100<threshold)])
        critical = []
        for skill, luck, killer, roll in itertools.product((0,1,100,255), (0,1,100,255), (0,1), (0,2,3,5,6,24,25,49,50,99,32767)):
            threshold = max(3, min(25, (skill+luck)//8))*(2 if killer else 1)
            critical.append([skill,luck,killer,roll,int(roll%100<threshold)])
        self.assertEqual(rows, dict(hits=hits, critical=critical))
        self.pins({0x800f7db8:0x2a02003c, 0x800f7dc4:0x3410003c,
                   0x800f7dc8:0x2a020064, 0x800f7dd4:0x34100063,
                   0x800f7e0c:0x34020012, 0x800f7e28:0x30420010,
                   0x800f7e38:0x00108043, 0x800f7e48:0x0043001a,
                   0x800f7e70:0x00001010, 0x800f7e78:0x0050102a,
                   0x800f83a8:0x001080c3, 0x800f83ac:0x2a02001a,
                   0x800f83b8:0x34100019, 0x800f83c8:0x34100003,
                   0x800f8400:0x3402000f, 0x800f840c:0x00108040})

    def test_double_beat_semantic_vectors_and_return_before_home(self):
        expected = []
        for count in (1,3,6):
            for mask in range(1<<count):
                for current in range(count):
                    target = next(((current+step)%count for step in range(1,count+int(current==0))
                                   if not mask & (1<<((current+step)%count))), None)
                    expected.append([count,mask,current,target])
        self.assertEqual(len(expected), 410)
        self.assertEqual(json.loads((ROOT/'game/tests/fixtures/double_beat_targets.json').read_text()), expected)
        self.pins({0x800f4a80:0x3402000e, 0x800f4a94:0x30624000,
                   0x800f4a9c:0x3062bfff, 0x800f4aa0:0x34624000,
                   0x800f7ca8:0x30424000, 0x800f7cbc:0x24500001,
                   0x800f7cdc:0x0050102a, 0x800f7cf0:0x24500001,
                   0x800f7d0c:0x1602ffee, 0x800f5d20:0x0c03df16,
                   0x800f5d28:0x10400008, 0x800f5d30:0x0c03d247,
                   0x800e5004:0x94480004, 0x800e5050:0x01031825,
                   0x800e5054:0xa4a30040, 0x800f59a8:0x30420002})

    def test_spark_and_physical_dispatch_call_order(self):
        self.pins({0x800f4ab4:0x34020011, 0x800f4acc:0xac620048,
                   0x800f3ec0:0x0c03d1a6, 0x800f3f28:0x0c03e15e,
                   0x800f859c:0x90a20046, 0x800f85ac:0x90c20005,
                   0x800f85b8:0x34070001, 0x800f85c0:0xac833420,
                   0x800f85e4:0x14e00005, 0x800f85f8:0xac400048,
                   0x800f4ae4:0x0c03df57, 0x800f4bd8:0x0c03d20d,
                   0x800f4b74:0x30420004, 0x800f4f70:0x30420008,
                   0x800f4864:0x0c03e0d7, 0x800f4f04:0x0c03df57,
                   0x800f5b18:0x0c03dfa4, 0x800f5b24:0x00022840,
                   0x800f5b28:0x0c038595, 0x800f5b2c:0x00a22821})
        calls = [0x80000000|((maindec.mword(a)&0x3ffffff)<<2)
                 for a in range(0x800f4e64,0x800f4fec,4) if maindec.mword(a)>>26==3]
        self.assertEqual(calls, [0x800f7d5c,0x800f78e4,0x800e3820,0x800f4d5c,0x800e3820])

    def test_turtle_gate_precedes_party_status_draw(self):
        self.pins({0x800e6bc8:0x9043004c, 0x800e6bcc:0x34020019,
                   0x800e6bd0:0x10620049, 0x800e6bd8:0x0c051f8e,
                   0x800e6cec:0x0c038137})

    def test_reward_speed_and_round_hp_consumers(self):
        self.pins({0x800d4f00:0x34020013, 0x800d4f14:0x00021040,
                   0x800e98d4:0x28420005, 0x800e98dc:0x34020005,
                   0x800e98e0:0xace20010,
                   0x800e98f0:0x34020016, 0x800e9904:0x00021040,
                   0x800e9bac:0x34060017, 0x800e9bd0:0x9042004c,
                   0x800e9be8:0x00021040, 0x800e9bec:0xac82224c,
                   0x800e9bfc:0x1040fff0,
                   0x800f71f8:0x24a50005, 0x800f7204:0x30420001,
                   0x800f7218:0x0052001a, 0x800f7248:0x00a22823,
                   0x800f7254:0x0c038595, 0x800f7258:0x00052823})


if __name__ == '__main__':
    unittest.main()
