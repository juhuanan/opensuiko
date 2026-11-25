#!/usr/bin/env python3
"""Disc VAB extents: structural loader formula vs independent tail extraction."""
import json
from pathlib import Path
import struct
import sys
import tempfile

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
from disc import extract
import vag_extract as V
import render_seq as R


def check():
    main = extract(17976, 757760)[2048:]
    anchors = {
        0x8015AEC8: 0x34020080, 0x8015AF08: 0x00031100,
        0x8015AF0C: 0x02623021, 0x8015AF24: 0x90620000,
        0x8015AF30: 0xAC700008, 0x8015AF34: 0x26100001,
        0x8015AF44: 0x24630010, 0x8015AF6C: 0x94820012,
        0x8015AF74: 0x00021240, 0x8015AF78: 0x00C23021,
        0x8015AF94: 0x94C30000, 0x8015AFA4: 0x000310C0,
        0x8015AFB4: 0x02028021, 0x8015AFC4: 0x24C60002,
        0x8015B0A8: 0x8C820000, 0x8015B0B0: 0x02028021,
        0x8015B0DC: 0xA462000C, 0x8015B0F8: 0xA462000E,
        0x80158A10: 0x94440016, 0x80158A90: 0x10800009,
    }
    for va, word in anchors.items():
        assert struct.unpack_from('<I', main, va - 0x800C0800)[0] == word, hex(va)
    files = json.loads((KIT / 'extracted/iso_files.json').read_text())
    for bank in ('ORCH', 'HNK1', 'HNK2'):
        blobs = []
        for ext in ('VA', 'VB'):
            rec = next(r for r in files if r['path'].endswith('/' + bank + '.' + ext))
            blobs.append(extract(rec['lba'], rec['size']))
        va, vb = blobs
        parts = V.split_vb(va, vb)
        vs = int.from_bytes(va[22:24], 'little')
        # Independent tail anchor, not the loader's active-program formula.
        end = max(i for i, byte in enumerate(va) if byte) + 1
        sizes = [int.from_bytes(va[end - vs*2 + i*2:end - vs*2 + i*2 + 2], 'little')*8
                 for i in range(vs)]
        assert [len(p)*16 for p in parts] == sizes
        assert b''.join(b''.join(p) for p in parts) == vb
        with tempfile.TemporaryDirectory(prefix='suikoden-vag-extents-') as tmp:
            a, b = Path(tmp) / (bank + '.VA'), Path(tmp) / (bank + '.VB')
            a.write_bytes(va); b.write_bytes(vb)
            samples, _, loops = R.parse_vab(a, b)
            # Stored extents include padding after the first playback end.
            ends = [next((i + 1 for i, block in enumerate(p) if block[1] & 1), len(p))
                    for p in parts]
            assert [end*28 for end in ends] == [len(s) for s in samples]
            if bank != 'ORCH':
                index, tone_offset, note, expected_size = ((6, 0x1040, 65, 992) if bank == 'HNK1'
                                                         else (9, 0x1260, 67, 8672))
                tone = va[tone_offset:tone_offset+32]
                assert int.from_bytes(tone[20:22], 'little') == (5 if bank == 'HNK1' else 7)
                assert tone[6] <= note <= tone[7]
                assert int.from_bytes(tone[22:24], 'little') == index + 1
                assert sizes[index] == expected_size
                assert loops[index] == (28, (expected_size//16-1)*28, False)
                assert parts[index][1][1] == 4 and parts[index][-1][1] == 1
                # Preserve the historical failure as a counterexample.
                wrong, current = [], []
                for k in range(0, len(vb), 16):
                    current.append(vb[k:k+16])
                    if vb[k+1] in (4, 6):
                        wrong.append(current); current = []
                assert len(wrong) == vs and len(wrong[index])*28 == 140
        for bad_va, bad_vb in ((va, vb[:-16]), (b'xxxx' + va[4:], vb)):
            try:
                V.split_vb(bad_va, bad_vb)
            except ValueError:
                pass
            else:
                raise AssertionError('invalid bank accepted')
    for request in (0x21, 0x22, 0x23, 0x24, 0x4d):
        row = 0x80164834 - 0x800C0800 + 32 * (request - 0x21)
        _, _, va_size, va_lba, _, _, vb_size, vb_lba = struct.unpack_from('<8I', main, row)
        va, vb = extract(va_lba, va_size), extract(vb_lba, vb_size)
        parts = V.split_vb(va, vb)
        samples, _, loops = R.parse_vab_bytes(va, vb)
        assert len(parts) == len(samples) == 44
        for blocks, pcm, loop in zip(parts, samples, loops):
            end = next((i for i, block in enumerate(blocks) if block[1] & 1), None)
            played = blocks if end is None else blocks[:end + 1]
            starts = [i for i, block in enumerate(played) if block[1] & 4]
            assert len(pcm) == len(played) * 28
            assert loop == (starts[-1] * 28 if starts else None,
                            end * 28 if end is not None else None,
                            bool(blocks[end][1] & 2) if end is not None else False)
        # Sample 9 is used by an actor cue and ends before a false loop marker.
        assert parts[9][-2][1] == 1 and parts[9][-1][1] == 7
        assert loops[9][2] is False and len(samples[9]) == (len(parts[9]) - 1) * 28
    print('PASS: 20 loader anchors, all three banks fully consumed, two independent extent methods; '
          'both historical 140-sample fragments reproduced and corrected; '
          'five battle banks use their first playback end')


if __name__ == '__main__':
    check()
