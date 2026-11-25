#!/usr/bin/env python3
"""VRAM residency re-search, part 2c: STRIDED c-blob search, robust anchors.

Rows have low distinctness (max ~16 values/row for AIL), so: anchor on the
best row regardless, flood-cap with fallback to 2nd-best row, two-stage
verification (3 spread rows first, then full).
"""
import sys, os
sys.path.insert(0, '/home/hatch/workspace/suikoden/kit/tools')
from lzss import decode, LZSSError
from parse_04play import parse_04play

KIT = '/home/hatch/workspace/suikoden/kit'
PLAY = os.path.join(KIT, 'extracted/bin_overlays/DATA/04_PLAY')
vram = open(os.path.join(KIT, 'work/vram_raw.bin'), 'rb').read()
VW = 1024
FLOOD_CAP = 20000

def find_capped(hay, needle):
    hits, s = [], 0
    while True:
        i = hay.find(needle, s)
        if i < 0: return hits
        hits.append(i); s = i + 1
        if len(hits) >= FLOOD_CAP: return None

def nibble_swap(b):
    return bytes(((x & 0x0F) << 4) | ((x & 0xF0) >> 4) for x in b)

def xor_ff(b):
    return bytes(x ^ 0xFF for x in b)

def ranked_rows(buf, words_w, rows_h):
    rb = words_w * 2
    rows = [(len(set(buf[r*rb:(r+1)*rb])), r) for r in range(rows_h)]
    rows.sort(reverse=True)
    return rows  # [(distinct, r), ...]

def strided_search(buf, words_w, rows_h):
    """Returns 'HIT' list, 'ABSENT', or 'ANCHOR_FLOOD'."""
    rb = words_w * 2
    assert len(buf) == rb * rows_h
    for _, ar in ranked_rows(buf, words_w, rows_h)[:3]:
        anchor = buf[ar*rb:(ar+1)*rb]
        raw = find_capped(vram, anchor)
        if raw is None:
            continue  # flooded; try next-best row
        # stage 1: spread-row prefilter
        pre = [(ar + 43) % rows_h, (ar + 86) % rows_h]
        hits = []
        for f in raw:
            f0 = f - ar * 2048
            if f0 < 0 or f0 % 2: continue
            w0 = f0 // 2
            x0, y0 = w0 % VW, w0 // VW
            if x0 + words_w > VW or y0 + rows_h > 512: continue
            if any(vram[f0 + r*2048: f0 + r*2048 + rb] != buf[r*rb:(r+1)*rb] for r in pre):
                continue
            hits.append((x0, y0, f0))
        # stage 2: full verify survivors
        out = []
        for x0, y0, f0 in hits:
            if all(vram[f0 + r*2048: f0 + r*2048 + rb] == buf[r*rb:(r+1)*rb] for r in range(rows_h)):
                out.append((x0, y0))
        if out:
            return ('HIT', out)
        return ('ABSENT', [])  # anchor workable, nothing verified
    return ('ANCHOR_FLOOD', [])

RECTS = [(64, 128), (32, 256), (128, 64)]
PERMS = [('EXACT', lambda b: b), ('NIBBLE_SWAP', nibble_swap),
         ('REVERSED', lambda b: b[::-1]), ('XOR_FF', xor_ff)]

files = sorted(f for f in os.listdir(PLAY) if f.endswith('.BIN'))
results = []
n_blobs = 0
for fi, fn in enumerate(files):
    path = os.path.join(PLAY, fn)
    data = open(path, 'rb').read()
    r = parse_04play(path)
    for sname, sec in r['sections'].items():
        if not isinstance(sec, dict) or 'c' not in sec: continue
        for bi, e in enumerate(sec['c']['entries']):
            n_blobs += 1
            b = e['blob']
            comp = data[b['data_file_offset']: b['data_file_offset'] + b['data_len']]
            try:
                out, _ = decode(comp)
            except LZSSError as ex:
                results.append((fn, sname, bi, 'DECODE_ERROR', str(ex))); continue
            found = False
            notes = []
            for pname, pfn in PERMS:
                buf = pfn(out)
                for ww, hh in RECTS:
                    if len(buf) != ww * 2 * hh: continue
                    st, hits = strided_search(buf, ww, hh)
                    if st == 'HIT':
                        d = '; '.join(f'{pname} rect={ww}x{hh}w (x={x},y={y})' for x, y in hits)
                        results.append((fn, sname, bi, 'HIT', d))
                        found = True
                        break
                    notes.append(f'{pname}/{ww}x{hh}:{st}')
                if found: break
            if not found:
                # verified negative only if every combo returned ABSENT
                ver = all(n_.endswith(':ABSENT') for n_ in notes)
                results.append((fn, sname, bi, 'ABSENT' if ver else 'ABSENT*',
                    ' | '.join(notes)))
    print(f'[{fi+1}/{len(files)}] {fn}', flush=True)

print(f'blobs: {n_blobs}')
from collections import Counter
print(Counter(x[3] for x in results))
for x in results:
    if x[3] == 'HIT':
        print('HIT', x)
nf = [x for x in results if x[3] == 'ABSENT*']
print(f'partial ({len(nf)}): e.g.', nf[0] if nf else None)
import json
json.dump(results, open('/tmp/vram_residency_strided.json', 'w'))
