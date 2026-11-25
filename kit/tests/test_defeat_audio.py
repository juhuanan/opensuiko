#!/usr/bin/env python3
"""Static game-over request chain and candidate PCM/provenance checks."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from export_first_room import source
import export_defeat_audio as exporter
import maindec
from disc import MODE2_SYNC, ShortReadError


class DefeatAudio(unittest.TestCase):
    def test_initializer_descriptor_and_stop_policy_are_independently_pinned(self):
        raw, _ = source('/GAMEOVER.BIN')
        self.assertEqual(hashlib.sha256(raw[0x14C0:0x1720]).hexdigest(),
                         '0e3fb2bda3e910da38e516fc6d4ab15470fea86d2abf26a97a68c761b0db86f2')
        main, _ = source('MAIN.EXE')
        base, size = struct.unpack_from('<II', main, 0x18)
        body = main[2048:2048+size]
        self.assertEqual(hashlib.sha256(body[0x800C6374-base:0x800C6440-base]).hexdigest(),
                         '0e2273a2ced33aed78b7ee1fd8e1080f26f1119b6b6198d986409477189fd916')
        self.assertEqual(body[0x80164E48-base:0x80164E50-base], bytes.fromhex('1250000000030010'))
        plan = exporter.contract()
        self.assertEqual((plan['command'], plan['lba'], plan['file_number'], plan['channel'], plan['volume'],
                          plan['timeout_ticks'], plan['repeat']), (0x303, 52109, 1, 2, 80, 768, False))
        self.assertEqual(plan['file'], 'DATA/01_AREA.A/XA1.')
        # Flagged duration takes the no-repeat branch and queues CD fade/stop action5.
        for pc, word in ((0x800C65D4, 0x00621024), (0x800C65D8, 0x14400008),
                         (0x800C6600, 0x00621024), (0x800C6610, 0xA0209BED),
                         (0x800C8CF4, 0x14400021), (0x800C8D70, 0x34040005)):
            self.assertEqual(struct.unpack_from('<I', body, pc-base)[0], word)

    def test_complete_candidate_has_correct_wav_and_source_extent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            packet = exporter.export(root)
            proof = json.loads((root/'defeat_provenance.json').read_text())
            self.assertEqual(packet, json.loads((root/'defeat.json').read_text()))
            self.assertEqual(packet, json.loads((ROOT/'game/tests/fixtures/defeat_audio.json').read_text()))
            exporter.validate(root, packet)
            self.assertEqual((packet['sample_rate'], packet['frames'], packet['repeat'], packet['volume']),
                             (37800, 477792, False, 80))
            self.assertEqual(proof['source_sectors'], list(range(2, 1891, 8)))
            self.assertEqual(proof['decoder'], 'xa-stereo-4bit-v2')
            with wave.open(str(root/'defeat.wav'), 'rb') as wav:
                self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getnframes()), (2, 2, 477792))
                pcm = wav.readframes(wav.getnframes())
            self.assertEqual(hashlib.sha256(pcm).hexdigest(), proof['pcm_sha256'])
            self.assertEqual(hashlib.sha256((root/'defeat.wav').read_bytes()).hexdigest(), packet['sha256'])

    def test_packaging_requires_complete_verified_optional_defeat_group(self):
        import bundle_macos as bundle
        import check_journey_package as checker
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            errors = []
            checker.check_defeat_audio(root, errors)
            self.assertEqual(errors, [])
            packet = exporter.export(root/'audio')
            for name in bundle.FILES:
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'{"rooms":[]}' if name == 'room.json' else name.encode())
            files = {name: bundle.digest(root/name) for name in bundle.FILES | bundle.DEFEAT_AUDIO_FILES}
            manifest = dict(schema='suikoden-journey-manifest/1', files=files)
            (root/'manifest.json').write_text(json.dumps(manifest))
            self.assertEqual(bundle.checked_content(root), manifest)
            checker.check_defeat_audio(root, errors)
            self.assertEqual(errors, [])
            del files['audio/defeat_provenance.json']
            (root/'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, 'incomplete'):
                bundle.checked_content(root)
            (root/'audio/defeat_provenance.json').unlink()
            checker.check_defeat_audio(root, errors)
            self.assertIn('incomplete', errors[0])
            for field, value in (('path', '../defeat.wav'), ('repeat', True), ('volume', None), ('sha256', '0'*64), ('frames', 1)):
                invalid = dict(packet, **{field: value})
                with self.assertRaises(ValueError):
                    exporter.validate(root/'audio', invalid)

    def test_corrupt_or_incomplete_sectors_never_publish_a_candidate(self):
        payload = (bytes([12])*16+bytes([0x21])*112)*18+bytes(20)
        raw = MODE2_SYNC+bytes([0, 0, 0, 2])+bytes([1, 0, 0x64, 1])*2+payload+bytes(4)
        wrong_coding = bytearray(raw)
        wrong_coding[19] = wrong_coding[23] = 0x11
        plan = dict(lba=0, source_bytes=2048, file_number=1, channel=0, volume=80)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root/'source.bin'
            for data, error in ((raw[:-1], ShortReadError), (wrong_coding, ValueError), (raw, ValueError)):
                image.write_bytes(data)
                with patch.object(exporter, 'contract', return_value=plan), patch.object(exporter, 'resolve_raw', return_value=(str(image), 2352, 24)):
                    with self.assertRaises(error):
                        exporter.export(root/'candidate')
                self.assertFalse((root/'candidate').exists())

    def test_rejects_source_changes_and_accepted_output(self):
        with self.assertRaisesRegex(ValueError, 'accepted staging'):
            exporter.export(ROOT/'kit/work/accepted/audio')
        read = maindec.mword
        with patch.object(maindec, 'mword', side_effect=lambda pc: 0 if pc == 0x800C65D0 else read(pc)):
            with self.assertRaisesRegex(ValueError, 'consumer changed'):
                exporter.contract()


if __name__ == '__main__':
    unittest.main()
