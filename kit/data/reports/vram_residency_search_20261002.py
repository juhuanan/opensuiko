#!/usr/bin/env python3
"""VRAM residency re-search with the TRUE codec (2026-10-02).

Decodes every c-blob of all 78 DATA/04_PLAY files with kit/tools/lzss.py
v2.0.0 and byte-searches each 16384-byte decode in work/vram_raw.bin.
Falls back to bounded permutations (nibble-swap, byte-reverse, XOR 0xFF).
Also searches S4 (256-word) and d-blob palettes against the VRAM CLUT region.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))
from lzss import decode, LZSSError
from parse_04play import parse_04play

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))) if '__file__' in dir() else os.getcwd()
# work dir layout: this script lives in kit/work/
KIT = '/home/hatch/workspace/suikoden/kit'
PLAY = os.path.join(KIT, 'extracted/bin_overlays/DATA/04_PLAY')
vram = open(os.path.join(KIT, 'work/vram_raw.bin'), 'rb').read()
W = 1024  # VRAM width in 16-bit words

def xy(off):
    w = off // 2
    return (w % W, w // W)

def find_all(hay, needle):
    hits, s = [], 0
    while True:
        i = hay.find(needle, s)
        if i < 0: return hits
        hits.append(i); s = i + 1

def nibble_swap(b):
    return bytes(((x & 0x0F) << 4) | ((x & 0xF0) >> 4) for x in b)

def xor_ff(b):
    return bytes(x ^ 0xFF for x in b)

files = sorted(f for f in os.listdir(PLAY) if f.endswith('.BIN'))
print(f'files: {len(files)}, vram: {len(vram)} bytes')

results = []   # (file, section, blob_idx, status, detail)
pal_results = []
n_blobs = 0
for fn in files:
    path = os.path.join(PLAY, fn)
    data = open(path, 'rb').read()
    try:
        r = parse_04play(path)
    except Exception as e:
        results.append((fn, '-', -1, 'PARSE_ERROR', str(e)))
        continue
    secs = r['sections']
    # --- c-blob residency ---
    for sname, sec in secs.items():
        if not isinstance(sec, dict) or 'c' not in sec: continue
        c = sec['c']
        for bi, e in enumerate(c['entries']):
            n_blobs += 1
            b = e['blob']
            comp = data[b['data_file_offset']: b['data_file_offset'] + b['data_len']]
            try:
                out, consumed = decode(comp)
            except LZSSError as ex:
                results.append((fn, sname, bi, 'DECODE_ERROR', str(ex)))
                continue
            assert len(out) == 16384, (fn, sname, bi, len(out))
            hits = find_all(vram, out)
            if hits:
                results.append((fn, sname, bi, 'EXACT',
                    '; '.join(f'file+{h} (x={x},y={y}){" ODD" if h%2 else ""}' for h in hits for x, y in [xy(h)])))
                continue
            # bounded permutations
            ph = find_all(vram, nibble_swap(out))
            if ph:
                results.append((fn, sname, bi, 'NIBBLE_SWAP',
                    '; '.join(f'(x={x},y={y})' for h in ph for x, y in [xy(h)])))
                continue
            ph = find_all(vram, out[::-1])
            if ph:
                results.append((fn, sname, bi, 'REVERSED',
                    '; '.join(f'(x={x},y={y})' for h in ph for x, y in [xy(h)])))
                continue
            ph = find_all(vram, xor_ff(out))
            if ph:
                results.append((fn, sname, bi, 'XOR_FF',
                    '; '.join(f'(x={x},y={y})' for h in ph for x, y in [xy(h)])))
                continue
            results.append((fn, sname, bi, 'ABSENT', 'no exact/perm hit'))
    # --- palette residency ---
    if 'S4' in secs and isinstance(secs['S4'], dict):
        s4 = secs['S4']
        raw = data[s4['file_offset']: s4['file_offset'] + s4['length']]
        hits = find_all(vram, raw)
        tag = []
        for h in hits:
            x, y = xy(h)
            in_clut = 0x1DC <= y <= 0x200
            tag.append(f'(x={x},y={hex(y)})' + (' CLUT-REGION' if in_clut else ''))
        pal_results.append((fn, 'S4', 256, 'HIT' if hits else 'ABSENT', '; '.join(tag)))
    for sname, sec in secs.items():
        if not isinstance(sec, dict) or 'd' not in sec: continue
        for di, e in enumerate(sec['d']['entries']):
            words = [int(x, 16) for x in e['palette']['rgb555']]
            raw = b''.join(w.to_bytes(2, 'little') for w in words)
            hits = find_all(vram, raw)
            tag = []
            for h in hits:
                x, y = xy(h)
                in_clut = 0x1DC <= y <= 0x200
                tag.append(f'(x={x},y={hex(y)})' + (' CLUT-REGION' if in_clut else ''))
            if hits:
                pal_results.append((fn, f'{sname}.d[{di}]', len(words), 'HIT', '; '.join(tag)))

print(f'total c-blobs decoded: {n_blobs}')
from collections import Counter
print('blob status counts:', Counter(r[3] for r in results))
print('palette: total checked S4+d =', len(pal_results) + sum(1 for _ in []),
      'hits =', sum(1 for p in pal_results if p[3] == 'HIT'))

import json
json.dump({'blobs': results, 'palettes': pal_results},
          open('/tmp/vram_residency_raw.json', 'w'))

# console summary of anything interesting
for r_ in results:
    if r_[3] != 'ABSENT':
        print('BLOB', r_)
for p in pal_results:
    if p[3] == 'HIT':
        print('PAL ', p)
