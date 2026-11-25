#!/usr/bin/env python3
"""Static instruction witnesses for spell packet geometry; no code execution."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import disc
import maindec


class BattleEffectVertexTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        raw = disc.extract(17976, 757760)
        cls.base, cls.size = struct.unpack_from('<II', raw, 0x18)
        cls.image = raw[2048:2048 + cls.size]

    def word(self, pc):
        return struct.unpack_from('<I', self.image, pc - self.base)[0]

    def check_asm(self, pc, *expected):
        # Independent extraction uses the EXE header, not maindec's fixed base.
        for i, asm in enumerate(expected):
            address = pc + 4*i
            self.assertEqual(self.word(address), maindec.mword(address))
            self.assertEqual(maindec.dis(address, 1)[0][2], asm, hex(address))

    def test_drops_five_phase_export_agrees_with_raw_dispatch_and_update_instructions(self):
        import spell_effect_sources
        facts = spell_effect_sources.drops_choreography()
        self.assertEqual([p['updates'] for p in facts['phases']], [64, 32, 90, 60, 60])
        self.assertEqual([p['start_update'] for p in facts['phases']], [0, 64, 96, 186, 246])
        self.assertEqual(facts['update_count'], 306)
        self.assertEqual(facts['target_objects']['count'], 6)
        self.assertEqual(facts['camera']['transition_updates'], 60)
        for pc, expected in {
            0x80105D08: 0x28420040, 0x80105D44: 0x28630020,
            0x80105DE0: 0x2863005A, 0x80105E38: 0x2842003C,
            0x80105EE4: 0x2863003C, 0x80105C88: 0x3405003C,
            0x80105CB4: 0x24420040, 0x80105D24: 0x24420080,
            0x80105A98: 0x2AA20006, 0x80106038: 0x24630020,
        }.items():
            self.assertEqual(self.word(pc), expected)
        self.assertEqual([self.word(0x800C151C + 4*i) for i in range(5)],
                         [0x80105C64, 0x80105D0C, 0x80105D68, 0x80105DF4, 0x80105E60])
        self.check_asm(0x80105DD8, 'addiu $v1,$v1,0x1', 'sw $v1,0x58($s1)')
        self.check_asm(0x80105F1C, 'jal 0x800e1654', 'subu $a1,$zero,$s2')
        self.check_asm(0x80105F44, 'sw $zero,0x1c($v0)')
        self.check_asm(0x80106014, 'jal 0x801207b4', 'addiu $a3,$s0,0x34')
        for pc, asm in {
            0x80105CC4: 'addiu $v0,$v0,0x2000',
            0x80105D34: 'addiu $v0,$v0,-0x4000',
            0x80105DC0: 'addiu $v0,$v0,0x1693',
            0x80105E8C: 'addiu $v0,$v0,-0x21dd',
            0x80105D74: 'lui $a2,0x2',
            0x80105DBC: 'ori $a2,$a2,0xd82d',
            0x80105EB0: 'lui $a1,0xfffb',
            0x80105EC8: 'ori $a1,$a1,0xbbbc',
            0x80105FAC: 'addiu $v0,$zero,-0x46',
            0x80105A00: 'sw $v0,0x14($sp)',
            0x80105A28: 'jal 0x80147e38',
            0x80105A6C: 'jal 0x80147e38',
        }.items():
            self.check_asm(pc, asm)
        self.assertFalse(facts['ready_for_runtime'])

    def test_wrapper_packs_anchor_then_calls_material_and_geometry_writers(self):
        self.check_asm(0x8012375C, 'lui $v0,0x8018', 'lw $v0,-0x41c4($v0)')
        self.assertEqual(0x80180000 - 0x41C4, 0x8017BE3C)
        self.check_asm(0x80123858, 'addu $v1,$v1,$s1', 'andi $v1,$v1,0x1fff',
                       'sll $v1,$v1,3', 'or $a0,$a0,$v1', 'sw $a0,0x8($s4)')
        self.check_asm(0x80123878, 'addu $v1,$v1,$s2', 'sll $v1,$v1,19',
                       'or $a0,$a0,$v1', 'sw $a0,0x8($s4)')
        self.check_asm(0x8012389C, 'jal 0x80123504')
        self.check_asm(0x801238B8, 'jal 0x800e256c', 'addu $a1,$s0,$zero')

    def test_corner_stores_and_packet_stride_from_raw_instruction_fields(self):
        expected = {
            0x800E270C: 8, 0x800E2710: 10, 0x800E2714: 16, 0x800E2718: 18,
            0x800E271C: 24, 0x800E2724: 26, 0x800E2728: 32, 0x800E2730: 34,
            0x800E2844: 8, 0x800E2854: 10, 0x800E28A4: 16, 0x800E28B4: 18,
            0x800E2908: 24, 0x800E2918: 26, 0x800E2974: 32, 0x800E2988: 34,
        }
        for pc, offset in expected.items():
            w = self.word(pc)
            self.assertEqual((w >> 26, (w >> 21) & 31, w & 65535),
                             (0x29, 17, offset), hex(pc))  # sh ...,offset(s1)
        self.check_asm(0x800E2610, 'sll $v0,$s6,2', 'addu $v0,$v0,$s6',
                       'sll $s7,$v0,3')
        self.check_asm(0x800E2A4C, 'sw $v0,0x0($s1)')

    def test_unrotated_offsets_subtract_pivot_and_use_signed_q12_scales(self):
        self.check_asm(0x800E2628, 'lbu $v0,0x0($s0)', 'lbu $v1,0x4($s3)',
                       'lh $t1,0xe($s2)', 'subu $v0,$v0,$v1', 'mult $v0,$t1')
        self.check_asm(0x800E2674, 'lbu $v0,0x1($s0)', 'lbu $v1,0x5($s3)',
                       'lh $t0,0x10($s2)', 'subu $v0,$v0,$v1', 'mult $v0,$t0')
        self.check_asm(0x800E2670, 'addiu $a0,$a0,0xfff')
        self.check_asm(0x800E2688, 'sra $v0,$a0,12')
        self.check_asm(0x800E26A4, 'lbu $v0,0x4($s0)', 'nop', 'mult $v0,$t1')
        self.check_asm(0x800E26C8, 'lbu $v0,0x5($s0)', 'nop', 'mult $v0,$t0')

    def test_constructor_forces_rotated_branch_with_z_angle_one(self):
        self.check_asm(0x80123410, 'ori $a1,$zero,0x1')
        self.check_asm(0x80123440, 'sh $a1,0x1c($v1)')
        self.check_asm(0x800E26EC, 'lw $v0,0x18($s2)', 'nop',
                       'bne $v0,$zero,0x800e2734')
        self.check_asm(0x800E26FC, 'lh $v0,0x1c($s2)', 'nop',
                       'bne $v0,$zero,0x800e2734')

    def test_rotated_corners_use_plus_one_and_four_projection_calls(self):
        self.check_asm(0x800E2800, 'lbu $v0,0x0($s0)', 'lbu $v1,0x4($s3)')
        self.check_asm(0x800E2814, 'subu $v0,$v0,$v1', 'sh $v0,0x38($sp)')
        for pc in (0x800E2870, 0x800E28F0, 0x800E2934, 0x800E295C):
            self.check_asm(pc, 'addiu $v0,$v0,0x1')
        for pc in (0x800E2830, 0x800E2890, 0x800E28F4, 0x800E2960):
            self.check_asm(pc, 'jal 0x8014f5c4')
        # GTE RTPS and SXY2 output, checked as raw coprocessor encodings.
        self.assertEqual(self.word(0x8014F5D0), 0x4A180001)
        self.assertEqual(self.word(0x8014F5D4), 0xE8AE0000)

    def test_rotated_scale_is_scene_times_node_not_wrapper_scale(self):
        self.check_asm(0x800E2760, 'lw $v1,0x1288($v1)', 'lw $v0,0x14($s2)',
                       'nop', 'mult $v1,$v0')
        self.check_asm(0x800E278C, 'sra $v0,$v1,12', 'sw $v0,0x30($sp)',
                       'sw $v0,0x2c($sp)', 'jal 0x8014ea50', 'sw $v0,0x28($sp)')
        self.check_asm(0x800E27B8, 'ori $v0,$zero,0x400', 'sw $v0,0x18($sp)')
        self.check_asm(0x801237B0, 'jal 0x8014f3ec', 'addiu $a1,$s3,0x34')


if __name__ == '__main__':
    unittest.main()
