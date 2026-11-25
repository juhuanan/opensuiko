#!/usr/bin/env python3
"""Disc-derived .8 SPU stream candidates; never writes accepted staging.

MAIN.EXE 800C8140/81F0 uploads the first/second 16 KiB halves to voices
22/23. 800C7C94 pans those voices left/right; table80164E68+4 gives rate.
"""
from pathlib import Path
import argparse
from array import array
import json
import sys
import wave

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'seq'))
from render_seq import decode_adpcm
from disc import extract
from dot8_probe import _iso_listing, mainexe_body, MAIN_BASE, DOT8_TABLE_VA
import struct

CHUNK = 0x4000
VERSION = 'dot8-spu-v1/low-first'


def resources():
    body = mainexe_body()
    by_lba = {r['lba']: r for r in _iso_listing() if r['path'].endswith('.8')}
    rows = []
    # Requests 0x401..0x446 select indices1..70; index67 is unused.
    for index in range(1, 71):
        lba, rate, loop, end, volume = struct.unpack_from(
            '<I4H', body, DOT8_TABLE_VA - MAIN_BASE + index * 12)
        if not lba:
            continue
        entry = by_lba[lba]
        assert 0 <= loop < end <= entry['size'] // 2048
        assert loop % 16 == end % 16 == 0
        assert 0 < rate <= 44100 and volume <= 127
        rows.append(dict(entry, index=index, rate=rate,
                         loop_sector=loop, end_sector=end, volume=volume))
    assert len({r['path'] for r in rows}) == len(by_lba) == 67
    return rows


def channel_bytes(data):
    if not data or len(data) % (2 * CHUNK):
        raise ValueError('.8 stream must contain complete 32 KiB stereo chunks')
    return tuple(b''.join(data[p + channel * CHUNK:p + (channel + 1) * CHUNK]
                          for p in range(0, len(data), 2 * CHUNK))
                 for channel in range(2))


def pcm(data):
    # Concatenation preserves independent predictor histories across CD chunks.
    left, right = (decode_adpcm(channel)[0] for channel in channel_bytes(data))
    assert len(left) == len(right) == len(data) // 32 * 28
    out = array('h', (sample for pair in zip(left, right) for sample in pair))
    if sys.byteorder != 'little':
        out.byteswap()
    return out.tobytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('name', help='disc filename, e.g. BATTLE1.8')
    args = parser.parse_args()
    row = next(r for r in resources() if r['path'].split('/')[-1] == args.name)
    # Bounded opening excerpt. No loop/resampling/mixing or gain adjustment.
    pairs = min(row['end_sector'] // 16, 32)
    data = extract(row['lba'], pairs * 2 * CHUNK)
    output = HERE.parents[0] / 'work/candidates/dot8_audio'
    output.mkdir(parents=True, exist_ok=True)
    path = output / (args.name + '.wav')
    with wave.open(str(path), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(row['rate'])
        wav.writeframes(pcm(data))
    metadata = dict(row, decoder=VERSION, source_offset=0, source_bytes=len(data),
                    channels='16 KiB left, then 16 KiB right',
                    status='candidate: requires user listening approval',
                    sample_frames=pairs * CHUNK // 16 * 28)
    path.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(path)
    print(json.dumps(metadata))


if __name__ == '__main__':
    main()
