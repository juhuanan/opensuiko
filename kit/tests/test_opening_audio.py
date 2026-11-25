"""Palace cue routes and complete private stream exports, independent PCM oracle."""
from pathlib import Path
from array import array
import hashlib
import json
import sys
import tempfile
import unittest
import wave
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import export_opening_audio as export
import maindec as main
from disc import extract
from dot8_audio import channel_bytes, resources
from test_audio_fade_modes import check_dispatch, check_spans, check_words, jump_target
from test_spu_adpcm import reference_decode


class OpeningAudio(unittest.TestCase):
    def test_source_dispatch_and_palace_restore_for_opening_stream_states(self):
        check_dispatch()
        check_spans((
            (0x800C512C, 0x800C5530, 'f3f0f41b27f8c0d4879537144dacf3911bf74f44f29e175952fa4d4e630cf961'),
            (0x800C6FE8, 0x800C7064, '309a570028a7bc57749bbef93da1a0747859133e631e94d8675620b03b5fd380'),
        ))
        for cue, target in ((0x15, 0x800C5530), (0x81, 0x800C6FE8)):
            handler = main.mword(0x800C0888 + 4 * (cue - 1))
            self.assertEqual(jump_target(handler, 3), target)
        handler = main.mword(0x800C0800 + 4 * (0x422 >> 8))
        self.assertEqual(jump_target(handler + 4, 3), 0x800C7948)
        check_words({
            # Restore always queues 0x84 and 0x63. Active stream 4 or 70 takes the fade branch.
            0x800C6FF4: 0x34040084, 0x800C6FFC: 0x34040063,
            0x800C7004: 0x90429BF3, 0x800C700C: 0x34430400,
            0x800C7010: 0x34020446, 0x800C7014: 0x10620004,
            0x800C701C: 0x34020404, 0x800C7020: 0x1462000A,
            0x800C7044: 0x08031C15, 0x800C7050: 0x34040404,
        })
        for call in (0x800C6FF0, 0x800C6FF8, 0x800C704C):
            self.assertEqual(jump_target(call, 3), 0x800C4FE0)
        self.assertEqual(jump_target(0x800C7030, 3), 0x800C6A00)
        self.assertEqual([(0x400 | stream) in (0x404, 0x446) for stream in (0, 4, 34)], [False, True, False])
        rows={row['index']:row for row in resources()}
        self.assertTrue(rows[4]['path'].endswith('/SHIRO1.8'))
        self.assertTrue(rows[34]['path'].endswith('/EV1.8'))

    def test_complete_exports_match_independent_decoder_and_tracked_interface(self):
        rows={row['index']:row for row in resources()}
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp);document=export.export(output)
            self.assertEqual(document,json.loads((ROOT/'game/tests/fixtures/opening_audio.json').read_text()))
            proof=json.loads((output/'provenance.json').read_text())
            for track,index in zip(document['tracks'],(4,34),strict=True):
                row=rows[index];data=extract(row['lba'],row['end_sector']*2048)
                channels=[array('h',reference_decode(channel)) for channel in channel_bytes(data)]
                independent=array('h',(sample for pair in zip(*channels,strict=True) for sample in pair))
                if sys.byteorder!='little':independent.byteswap()
                with wave.open(str(output/track['path']),'rb') as audio:
                    self.assertEqual((audio.getnchannels(),audio.getsampwidth(),audio.getframerate(),audio.getnframes()),(2,2,track['sample_rate'],track['frames']))
                    self.assertEqual(audio.readframes(track['frames']),independent.tobytes())
                self.assertEqual(track['loop_start_frame'],row['loop_sector']//16*28672)
                self.assertEqual(track['volume'],row['volume'])
            for name,expected in proof['files'].items():self.assertEqual(hashlib.sha256((output/name).read_bytes()).hexdigest(),expected)
            self.assertEqual(len(proof['sources']),2)


if __name__=='__main__':unittest.main()
