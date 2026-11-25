#!/usr/bin/env python3
"""Extract PS1 VAG samples from a VAB (VA+VB) pair, correctly.

Corrected 2026-10-14: sample extents come from the version-6 VAB size
 table. The former flag splitter mistook 0x04/0x06 loop starts for endings,
 creating two 140-sample fragments despite producing the expected sample count.
 PCM decoding delegates to the canonical existing SPU decoder.

VAGs play at the SPU's 44100 Hz, so WAVs are written at 44100.
"""
import struct, wave, os, sys

# Use the existing SPU decoder; keep this historical command's block-list API.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'seq'))
from render_seq import decode_adpcm


def decode_vag(blocks):
    return decode_adpcm(b''.join(blocks))[0]


def split_vb(va_data, vb_data):
    """Split from the version-6 VAB size table, never from ADPCM loop flags."""
    if va_data[:4] != b'pBAV' or struct.unpack_from('<I', va_data, 4)[0] != 6:
        raise ValueError('expected version-6 pBAV header')
    ps, _, vs = struct.unpack_from('<HHH', va_data, 0x12)
    # MAIN scans 128 program slots; ps counts occupied 512-byte tone blocks.
    offset = 0x20 + 128 * 16 + ps * 512
    units = struct.unpack_from('<' + str(vs + 1) + 'H', va_data, offset)
    if units[0] != 0 or sum(units) * 8 != len(vb_data):
        raise ValueError('VAB size table does not consume the body exactly')
    parts, cursor = [], 0
    for size in units[1:]:
        size *= 8
        if not size or size % 16:
            raise ValueError('VAG extent is empty or not ADPCM-block aligned')
        parts.append([vb_data[k:k + 16] for k in range(cursor, cursor + size, 16)])
        cursor += size
    return parts


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    work = os.path.normpath(os.path.join(here, '..', 'work'))
    pairs = [('ORCH.VA', 'ORCH.VB', 'orch'),
             ('HNK1.VA', 'HNK1.VB', 'hnk1'),
             ('HNK2.VA', 'HNK2.VB', 'hnk2')]
    for va_n, vb_n, bank in pairs:
        with open(os.path.join(work, va_n), 'rb') as fh:
            va = fh.read()
        with open(os.path.join(work, vb_n), 'rb') as fh:
            vb = fh.read()
        vs = struct.unpack_from('<H', va, 0x16)[0]
        vags = split_vb(va, vb)
        print('%s: VA vs=%d, VB -> %d VAGs' % (bank, vs, len(vags)))
        assert len(vags) == vs, 'VAG count mismatch!'
        outdir = os.path.join(work, 'assets_zig', 'audio', 'samples', bank)
        os.makedirs(outdir, exist_ok=True)
        for idx, blocks in enumerate(vags):
            pcm = decode_vag(blocks)
            # sanity: clipping should be ~0 now
            clip = sum(1 for v in pcm if abs(v) == 32767)
            peak = max(abs(v) for v in pcm)
            print('  vag %2d: %6d blocks %7d samples clip=%d peak=%d' %
                  (idx, len(blocks), len(pcm), clip, peak))
            path = os.path.join(outdir, 'sample%02d.wav' % idx)
            w = wave.open(path, 'wb')
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(struct.pack('<%dh' % len(pcm), *pcm))
            w.close()
        print('  wrote', outdir)

if __name__ == '__main__':
    main()
