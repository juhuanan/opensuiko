#!/usr/bin/env python3
"""Static source banks and actor sound requests reach reproducible candidate clips."""
import hashlib
import copy
import json
import struct
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import export_battle_sfx as sfx
import export_enemy_magic
import check_journey_package
import maindec
from disc import extract
import render_seq


class BattleSfx(unittest.TestCase):
    def test_recipient_sounds_select_common_candidate_clips(self):
        import unite_martial_controller
        reactions = unite_martial_controller.recipient_programs()['programs']
        actors = dict(programs=dict(programs=[]))
        self.assertEqual(sfx.cues(actors,reactions),[0x518,0x519,0x51a])
        with tempfile.TemporaryDirectory() as temporary:
            packet = sfx.export(actors,Path(temporary),reactions=reactions)
            self.assertEqual([row['id'] for row in packet['cues']],[0x518,0x519,0x51a])
            self.assertEqual(packet['unsupported'],[])
            sfx.validate(Path(temporary),packet)

    def test_controller_sound_requests_join_actor_cues(self):
        actors = {'programs': {'programs': []}, 'unites': [{'controller': {'orbit': {'sounds': [
            {'at': 1, 'id': 0x81f}, {'at': 65, 'id': 0x524}, {'at': 81, 'id': 0x521}]}}}]}
        self.assertEqual(sfx.cues(actors), [0x521, 0x524, 0x81f])
        actors['unites'][0]['controller']['orbit']['sounds'][0]['id'] = -1
        with self.assertRaises(ValueError):
            sfx.cues(actors)

    def test_source_requests_and_sound_files(self):
        actors = json.loads((ROOT / 'game/tests/fixtures/battle_actor_library.json').read_text())
        plan, _, _ = export_enemy_magic.build()
        actors['enemy_magic'] = export_enemy_magic.binding(plan)
        with tempfile.TemporaryDirectory(prefix='battle-sfx-') as tmp:
            folder = Path(tmp) / 'audio/sfx'
            packet = sfx.export(actors, folder)
            sfx.validate(folder, packet)
            errors = []
            check_journey_package.check_battle_sfx(Path(tmp), errors)
            self.assertEqual(errors, [])
            self.assertEqual(len(packet['cues']), 19)
            self.assertEqual(packet['unsupported'], [])
            self.assertEqual(packet['schema'], 'suikoden-battle-sfx/2')
            self.assertEqual({row['request'] for row in packet['sources']}, set(sfx.BANK_REQUESTS))
            for row in packet['cues']:
                path = folder / row['path']
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), row['sha256'])
                with wave.open(str(path), 'rb') as source:
                    self.assertEqual((source.getnchannels(), source.getsampwidth(), source.getframerate()), (2, 2, 44100))
                    self.assertEqual(source.getnframes(), row['frames'])
                    self.assertGreater(row['frames'], 0)
                    self.assertNotEqual(set(source.readframes(row['frames'])), {0})
            repeat = next(row for row in packet['cues'] if row['id'] == 0x521)
            self.assertFalse(repeat['retrigger'])
            self.assertTrue(repeat['reverb'])
            impact = next(row for row in packet['cues'] if row['id'] == 0x524)
            self.assertEqual((impact['bank'], impact['program'], impact['note'],
                              impact['table_level'], impact['sample'], impact['pitch']),
                             (0, 2, 28, 40, 32, 1183))
            bad = copy.deepcopy(packet)
            bad['cues'][0]['path'] = '../other.wav'
            with self.assertRaises(ValueError):
                sfx.validate(folder, bad)
            bad = copy.deepcopy(packet)
            bad['cues'].append(bad['cues'][0])
            with self.assertRaises(ValueError):
                sfx.validate(folder, bad)
            path = folder / packet['cues'][0]['path']
            path.write_bytes(path.read_bytes()[:-1])
            with self.assertRaises(ValueError):
                sfx.validate(folder, packet)
            check_journey_package.check_battle_sfx(Path(tmp), errors)
            self.assertEqual(len(errors), 1)

    def test_new_body_attack_cue_51e_has_an_independently_decoded_common_sample(self):
        from test_spu_adpcm import reference_decode
        banks=sfx.banks()
        cue,reason=sfx.resolve(0x51e,banks)
        self.assertIsNone(reason)
        packed,note,level=struct.unpack_from('<HBB',maindec.body(),sfx.SOUND_TABLE-maindec.MBASE+4*0x1e)
        self.assertEqual((cue['bank'],cue['program'],cue['note'],cue['table_level']),(packed>>8,packed&255,note,level))
        self.assertEqual(cue['bank'],0)
        for bank in banks:
            raw=bank['raw'][cue['sample']]
            self.assertEqual(hashlib.sha256(raw).hexdigest(),cue['sample_sha256'])
            end=next((i+16 for i in range(0,len(raw),16) if raw[i+1]&1),len(raw))
            self.assertEqual(bank['samples'][cue['sample']],reference_decode(raw[:end]))
        with tempfile.TemporaryDirectory(prefix='body-attack-cue-') as temporary:
            actors=dict(programs=dict(programs=[dict(instructions=[dict(command=dict(sound=0x51e))])]))
            packet=sfx.export(actors,Path(temporary))
            self.assertEqual([c['id'] for c in packet['cues']],[0x51e])
            self.assertEqual(packet['unsupported'],[])
            sfx.validate(Path(temporary),packet)

    def test_bank_dependent_and_other_classes_are_not_guessed(self):
        source_banks = sfx.banks()
        cue, reason = sfx.resolve(0x50c, source_banks)
        self.assertIsNone(reason)
        altered = [dict(bank) for bank in source_banks]
        altered[-1]['raw'] = list(altered[-1]['raw'])
        altered[-1]['raw'][cue['sample']] += b'\x00'
        self.assertEqual(sfx.resolve(0x50c, altered), (None, 'sample is bank-dependent'))
        self.assertEqual(sfx.resolve(0x800, source_banks), (None, 'unqualified timed sound request'))
        self.assertEqual(sfx.resolve(0x900, source_banks), (None, 'different sound-command class'))
        self.assertEqual(sfx.resolve(0x52a, source_banks), (None, 'sound request also changes stream volume'))

    def test_timed_cues_have_common_direct_tones(self):
        for pc, word in {0x800c5bcc: 0x00021080, 0x800c5ddc: 0xafa80010,
                         0x800c5e10: 0x0c056383, 0x80158fe0: 0x00031900,
                         0x80158ff0: 0x00021140, 0x800c8fa4: 0x0043102b,
                         0x800c92bc: 0x2463fe00}.items():
            self.assertEqual(maindec.mword(pc), word)
        source_banks = sfx.banks()
        for cue, expected, sample in ((0x819, bytes.fromhex('00 01 0f 3c 01 00 00 00 08 00 01 28'), 43),
                                      (0x81e, bytes.fromhex('00 01 06 0a 01 00 00 00 04 00 01 6b'), 21),
                                      (0x81b, bytes.fromhex('00 02 06 32 01 00 00 00 08 00 01 28'), 34),
                                      (0x81f, bytes.fromhex('00 00 0b 0a 01 00 00 00 04 00 01 6b'), 11)):
            offset = 0x8016546c - maindec.MBASE + 12 * (cue - 0x800)
            self.assertEqual(maindec.body()[offset:offset + 12], expected)
            bank, program, tone_index, note, period, delta, duration, mode, level = struct.unpack('<BBBBHHHBB', expected)
            self.assertEqual((bank, program, period, delta, mode), (0, {0x819:1, 0x81b:2, 0x81e:1, 0x81f:0}[cue], 1, 0, 1))
            self.assertEqual(duration, 8 if cue in (0x819, 0x81b) else 4)
            self.assertEqual(level, 40 if cue in (0x819, 0x81b) else 107)
            self.assertEqual(note, 60 if cue == 0x819 else 50 if cue == 0x81b else 10)
            tone = source_banks[0]['programs'][program][tone_index]
            self.assertEqual(tone['vag'], sample)
            for data in source_banks[1:]:
                self.assertEqual(data['programs'][program][tone_index], tone)
                self.assertEqual(data['raw'][sample], source_banks[0]['raw'][sample])

    def test_timed_voice_admission_pitch_and_release_match_static_source(self):
        body = maindec.body()
        for start, end, expected in (
            (0x800c5b5c, 0x800c5e60, '91f4dc9139312972a9a46efdcc4c326d95da8f5839ea26f14a4dfb036f11e915'),
            (0x800c8ed8, 0x800c9388, '62391184490911dc64b9851af7aa486bf09873ec3af56ddfa6e839163fd8a405')):
            self.assertEqual(hashlib.sha256(body[start-maindec.MBASE:end-maindec.MBASE]).hexdigest(), expected)
        self.assertEqual(list(body[0x80164e2c-maindec.MBASE:0x80164e2f-maindec.MBASE]), [19, 20, 21])
        self.assertEqual(maindec.mword(0x800c0d88), 0x800c9090)
        source_banks = sfx.banks()
        class VoiceSpy:
            def __init__(self, *args):
                self.step = args[4]
                self.env = self
                self.rows = []
                voices.append(self)
            def key_on(self):
                pass
            def render(self, fir, left, right, offset, count, rate):
                self.rows.append((self.step, self.vol_l, self.vol_r, offset, count, rate))
        for cue in sfx.TIMED_REQUESTS:
            entry, reason = sfx.resolve(cue, source_banks)
            self.assertIsNone(reason)
            voices = []
            with patch.object(sfx, 'Voice', VoiceSpy):
                pcm = sfx.render(entry, source_banks)
            self.assertEqual(entry['occupied_updates'], 11 if cue in (0x819, 0x81b) else 26)
            self.assertEqual(len(pcm), entry['occupied_updates']*735*4)
            expected_gain = ([1625]*8+[1113, 601, 89] if cue in (0x819, 0x81b)
                             else [11629]*4+[11629-512*i for i in range(1, 23)])
            self.assertEqual([round(row[1]*16384) for row in voices[0].rows], expected_gain)
            self.assertEqual([round(row[2]*16384) for row in voices[0].rows], expected_gain)
            self.assertEqual([row[0] for row in voices[0].rows], [entry['pitch']/4096]+[1.0]*(entry['occupied_updates']-1))
            self.assertEqual([row[3] for row in voices[0].rows], list(range(0, len(expected_gain)*735, 735)))
        altered = copy.deepcopy(source_banks)
        altered[-1]['programs'][1][15]['vol'] -= 1
        self.assertEqual(sfx.resolve(0x819, altered), (None, 'direct tone is bank-dependent'))

    def test_all_four_timed_candidates_validate_and_reject_invalid_lifetimes(self):
        actors = dict(programs=dict(programs=[dict(instructions=[dict(command=dict(sound=cue)) for cue in sfx.TIMED_REQUESTS])]))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            packet = sfx.export(actors, root)
            self.assertEqual(packet['schema'], 'suikoden-battle-sfx/2')
            self.assertEqual([row['id'] for row in packet['cues']], list(sfx.TIMED_REQUESTS))
            self.assertEqual(packet['unsupported'], [])
            sfx.validate(root, packet)
            for key, value in (('occupied_updates', 0), ('occupied_updates', 601), ('frames', 1), ('tone_index', 16), ('retrigger', True)):
                invalid = copy.deepcopy(packet)
                invalid['cues'][0][key] = value
                with self.assertRaises(ValueError):
                    sfx.validate(root, invalid)
            packet['schema'] = 'suikoden-battle-sfx/1'
            with self.assertRaises(ValueError):
                sfx.validate(root, packet)

    def test_slot_two_depends_on_loaded_bank(self):
        selections = []
        for request in (0x26, 0x33):
            offset = 0x80164834 - maindec.MBASE + 32 * (request - 0x21)
            self.assertEqual(maindec.body()[offset + 1], 2)
            _, _, va_size, va_lba, _, _, vb_size, vb_lba = struct.unpack_from('<8I', maindec.body(), offset)
            _, programs, _ = render_seq.parse_vab_bytes(extract(va_lba, va_size), extract(vb_lba, vb_size))
            selections.append([[tone for tone in programs[0] if tone['min'] <= note <= tone['max']]
                               for note in (24, 29)])
        self.assertEqual([len(row) for row in selections[0]], [1, 1])
        self.assertEqual([len(row) for row in selections[1]], [1, 0])
        self.assertNotEqual(selections[0][0], selections[1][0])


if __name__ == '__main__':
    unittest.main()
