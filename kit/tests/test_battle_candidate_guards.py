"""Windowless admission checks; no disc access or original-code execution."""
from pathlib import Path
import sys
import struct
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_battle_sprite_sections as sprites
import export_party_action_programs as actions


class CandidateGuards(unittest.TestCase):
    def test_unhandled_script_control_flow_is_refused(self):
        data = bytearray(32)
        struct.pack_into('<I', data, 4, 16)
        struct.pack_into('<H', data, 16, 36)
        with self.assertRaises(sprites.SectionError) as caught:
            sprites._resolve_script_animations(bytes(data), 4, 'candidate')
        self.assertEqual(caught.exception.code, 'unsupported_script_control_flow')
        with self.assertRaises(actions.ProgramError) as caught:
            actions._script(bytes(data), 4, 0, 'candidate')
        self.assertEqual(caught.exception.code, 'unsupported_script_operation')

    def test_unknown_motion_mode_is_refused(self):
        data = bytearray(40)
        struct.pack_into('<I', data, 4, 16)
        struct.pack_into('<6H', data, 16, 33, 9, 1, 0, 0, 0)
        with self.assertRaises(actions.ProgramError) as caught:
            actions._compile_track('attack', bytes(data), 4, 0, 0, 'candidate')
        self.assertEqual(caught.exception.code, 'unsupported_motion_mode')

    def test_missing_adjacent_page_is_refused(self):
        page = sprites.Page(index=0, slot=0, source_offset=0, comp_len=0,
                            raw=bytes(16384), raw_sha256='', vram_x_words=0, vram_y=0)
        with self.assertRaises(sprites.SectionError) as caught:
            sprites._sample_pixel((page,), 0, 128, 0)
        self.assertEqual(caught.exception.code, 'unavailable_adjacent_page')
        self.assertEqual(sprites._sample_pixel((page, page), 0, 128, 0), (1, 0, False))

    def test_any_unresolved_pose_blocks_compatibility_adapter(self):
        for name, animation, pose in [('cleo', 22, 16), ('juppo', 22, 15),
                                      ('sydonia', 21, 13), ('ted', 18, 11), ('odessa', 18, 11)]:
            candidate = SimpleNamespace(animations=(SimpleNamespace(index=animation,
                missing_poses=(pose,), used_by_scripts=()),), poses=())
            summary = sprites._section_summary(candidate)
            self.assertEqual(summary['status'], 'incomplete', name)
            self.assertTrue(summary['unresolved'][0]['required'])
            with patch.object(sprites, 'decode_section', return_value=candidate):
                with self.assertRaises(sprites.SectionError) as caught:
                    sprites.section_art_compatible(b'', 0)
            self.assertEqual(caught.exception.code, 'unresolved_animation_pose')
        self.assertEqual(sprites._section_summary(SimpleNamespace(animations=()))['status'], 'incomplete')
        with patch.object(sprites, 'decode_section', return_value=SimpleNamespace(animations=())):
            with self.assertRaises(sprites.SectionError) as caught:
                sprites.section_art_compatible(b'', 0)
        self.assertEqual(caught.exception.code, 'section_not_admitted')

    def test_auxiliary_and_return_effects_are_required(self):
        attack = actions.Track('attack', 'dispatch', 0, (), external_calls=(1295,))
        auxiliary = actions.Track('auxiliary', 'auxiliary_spawn', 0, (), external_calls=(1296,))
        back = actions.Track('return', 'owner_ready', 0, (), external_calls=(1294,))
        attack.auxiliary = {'slot': 11, 'graphic': 17, 'script': 9, 'offset': {}, 'spawn_tick': 0}
        program = actions.Program('kirkis', 'stationary_auxiliary', attack, auxiliary, back,
            13, 20, 0, 13, 15, 40, None, {})
        bounds = {'auxiliary_spawn': {}, 'auxiliary_contact': {}, 'auxiliary_release': {},
                  'target_reaction': None}
        row = actions._program_json(program, bounds, {'resource': 'KIR.BIN', 'resource_sha256': 'x'})
        calls = {(x['track'], x['reference']) for x in row['unresolved'] if x['kind'] == 'external_effect'}
        self.assertEqual(calls, {('attack', 'call_1295'), ('auxiliary', 'call_1296'), ('return', 'call_1294')})
        self.assertTrue(all(x['required'] for x in row['unresolved']))
        with self.assertRaises(actions.ProgramError) as caught:
            actions.require_runtime_admission(row)
        self.assertEqual(caught.exception.code, 'unresolved_runtime_dependencies')
        self.assertIn('auxiliary:call_1296', caught.exception.detail)
        self.assertIn('target_release_timing', caught.exception.detail)

    def test_legacy_zero_timing_and_unlisted_auxiliary_calls_are_refused(self):
        row = {'id': 'legacy', 'boundaries': {'target_reaction': {'ticks': 0}},
               'auxiliary': {'graphic': 19}, 'unresolved': [],
               'tracks': {'attack': {'events': [], 'external_calls': []},
                          'auxiliary': {'events': [], 'external_calls': [1296]},
                          'return': {'events': [], 'external_calls': []}}}
        with self.assertRaises(actions.ProgramError) as caught:
            actions.require_runtime_admission(row)
        self.assertIn('target_release_timing', caught.exception.detail)
        self.assertIn('auxiliary_graphic_19', caught.exception.detail)
        self.assertIn('auxiliary:call_1296', caught.exception.detail)

    def test_unresolved_free_data_still_needs_a_runtime_adapter(self):
        row = {'id': 'candidate', 'boundaries': {'target_reaction': {'ticks': 36}},
               'auxiliary': None, 'unresolved': [],
               'tracks': {'attack': {'events': []}, 'return': {'events': []}}}
        with self.assertRaises(actions.ProgramError) as caught:
            actions.require_runtime_admission(row)
        self.assertEqual(caught.exception.code, 'runtime_adapter_unavailable')


if __name__ == '__main__':
    unittest.main()
