#!/usr/bin/env python3
"""XA layout, predictor continuity and independent FFmpeg PCM agreement."""
from array import array
from pathlib import Path
import random
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
from xa_decode import XADecoder
from disc import resolve_raw, MODE2_SYNC
from dot8_probe import _iso_listing


def interleave(channels):
    samples = array('h', (s for pair in zip(*channels, strict=True) for s in pair))
    if sys.byteorder != 'little':
        samples.byteswap()
    return samples.tobytes()


def ffmpeg(raw):
    executable = shutil.which('ffmpeg')
    if executable is None:
        raise RuntimeError('FFmpeg is required for independent XA verification')
    result = subprocess.run([executable, '-hide_banner', '-loglevel', 'error', '-f', 'psxstr',
                             '-i', 'pipe:0', '-map', '0:a:0', '-c:a', 'pcm_s16le',
                             '-f', 's16le', 'pipe:1'], input=raw, capture_output=True, check=True)
    return result.stdout


def sector(payload):
    return MODE2_SYNC + bytes([0, 0, 0, 2]) + bytes([1, 0, 0x64, 1])*2 + payload + bytes(4)


class XADecode(unittest.TestCase):
    def test_independent_predictor_free_columns_and_signed_nibbles(self):
        group = bytes([12])*16 + bytes.fromhex('21436507')*28
        left, right = XADecoder().decode_group(group)
        self.assertEqual(left, [1]*28+[3]*28+[5]*28+[7]*28)
        self.assertEqual(right, [2]*28+[4]*28+[6]*28+[0]*28)
        left, right = XADecoder().decode_group(bytes([12])*16 + bytes([0x8f])*112)
        self.assertEqual((left, right), ([-1]*112, [-8]*112))

    def test_ffmpeg_predictor_rounding_clamping_and_history_across_sectors(self):
        rng = random.Random(43)
        groups = []
        for i in range(36):
            params = bytes(((i+j) % 5)*16 + (i*3+j) % 13 for j in range(8))
            header = params[:4]*2+params[4:]*2
            groups.append(header + rng.randbytes(112))
        payloads = [b''.join(groups[start:start+18])+bytes(20) for start in (0, 18)]
        decoder = XADecoder()
        actual = b''.join(interleave(decoder.decode_sector(p)) for p in payloads)
        self.assertEqual(len(actual), 2*2016*4)
        self.assertEqual(actual, ffmpeg(b''.join(sector(p) for p in payloads)))

    def test_rejects_bad_dimensions_parameters_and_rolls_back_a_bad_sector(self):
        decoder = XADecoder()
        valid = bytes([12])*16 + bytes([0x21])*112
        for group in (valid[:-1], bytes([0xff])*16+valid[16:], bytes([0x0d])*16+valid[16:], bytes([0])+valid[1:]):
            with self.assertRaises(ValueError):
                decoder.decode_group(group)
            self.assertEqual(decoder.s, [0]*4)
        decoder.decode_group(valid)
        before = decoder.s[:]
        for payload in (bytes(2323), valid*17+bytes([0xff])*128+bytes(20)):
            with self.assertRaises(ValueError):
                decoder.decode_sector(payload)
            self.assertEqual(decoder.s, before)

    def test_source_gameover_channel_agrees_with_ffmpeg_for_every_sample(self):
        entry = next(row for row in _iso_listing() if row['path'] == 'DATA/01_AREA.A/XA1.')
        path, stride, _ = resolve_raw()
        with Path(path).open('rb') as stream:
            stream.seek(entry['lba']*stride)
            raw = stream.read(entry['size']//2048*stride)
        selected = [raw[i:i+stride] for i in range(0, len(raw), stride)
                    if raw[i+16:i+18] == bytes([1, 2]) and raw[i+18] & 0x64 == 0x64]
        self.assertEqual(len(selected), 237)
        self.assertTrue(selected[-1][18] & 0x80)
        decoder = XADecoder()
        actual = bytearray()
        for data in selected:
            self.assertEqual(data[16:20], data[20:24])
            self.assertEqual(data[19], 1)
            actual.extend(interleave(decoder.decode_sector(data[24:2348])))
        self.assertEqual(len(actual), 237*2016*4)
        self.assertEqual(bytes(actual), ffmpeg(b''.join(selected)))


if __name__ == '__main__':
    unittest.main()
