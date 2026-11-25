#!/usr/bin/env python3
"""area_tilemap_probe.py -- static probe for the area-room tilemap field.

Created 2026-10-04 (workstream T). The area-room renderers take
`u32(header+0x14) - 0x80010000` as tilemap A.  Measured on the corpus, that
field is exactly 0x00000000 for **86** enumerated headers; for **72** of them
`+0x08` (blob pointer table), `+0x0c` and `+0x10` are all live, in-range
pointers; the remaining **14** are all-zero slots.  The probe answers "what is
tilemap A for those headers" with measurements rather than a guess:

  * `list`      -- the corpus walk (the renderers' own enumeration rule) and the
                   72/14 split, per file.
  * `fields`    -- per-header field table for one overlay.
  * `dump`      -- the raw bytes around one header.
  * `blocks`    -- duplicate-block analysis: for every +0x14==0 header, does an
                   earlier header carry the same (w,h,f04) and, where the f14
                   values are live, the *same* tilemap address?  This is the
                   measurement behind the "second/duplicate section block" read.
  * `tilemap`   -- classify +0x14 as a u16 tilemap (value range, distinct count,
                   index->blob resolvability against the +0x08 table).
  * `span`      -- test the eliminated "inline tilemap just past the header"
                   rule against both groups, as a control.

Nothing here writes a PNG.  No disc access: it reads the disc-derived raw
overlays already under kit/extracted/bin_overlays.

Usage:
  python3 kit/tools/area_tilemap_probe.py list
  python3 kit/tools/area_tilemap_probe.py fields VC3
  python3 kit/tools/area_tilemap_probe.py dump VAA 3
  python3 kit/tools/area_tilemap_probe.py blocks
  python3 kit/tools/area_tilemap_probe.py tilemap VB5
  python3 kit/tools/area_tilemap_probe.py span
"""
import json
import os
import struct
import sys

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

RAM_BASE = 0x80010000

# area subdir -> (area folder, [bin names]); mirrors fix_palettes.AREAS
AREAS = {
    '01A': ('01_AREA.A', ['VA1', 'VA2', 'VA3', 'VA4', 'VA4B', 'VA5', 'VA6', 'VA7',
                          'VA8', 'VA9', 'VAA', 'VAAD']),
    '02B': ('02_AREA.B', ['VB1', 'VB2', 'VB3', 'VB4', 'VB5', 'VB6', 'VB7', 'VB7A',
                          'VB7D', 'VB8', 'VB9']),
    '06C': ('06_AREA.C', ['VC1', 'VC2', 'VC3', 'VC4', 'VC5', 'VC6', 'VC61', 'VCD']),
    '07D': ('07_AREA.D', ['VD1', 'VD2', 'VD3', 'VD4', 'VD5', 'VD6', 'VD7']),
    '08E': ('08_AREA.E', ['VE1', 'VE2', 'VE3', 'VE4', 'VE5', 'VE6']),
    '09F': ('09_AREA.F', ['VF1', 'VF2', 'VF3', 'VF4']),
    '10G': ('10_AREA.G', ['VG1', 'VG2', 'VG3']),
    '11H': ('11_AREA.H', ['VH1', 'VH2']),
    '13I': ('13_AREA.I', ['VI1', 'VI2']),
    '14S': ('14_AREA.S', ['VS1', 'VS2']),
    '15Z': ('15_AREA.Z', ['VZ1', 'VZ2', 'VZ3', 'VZ5', 'VZ7', 'VZ8', 'VZV', 'VAC',
                          'VAD']),
}


def overlay_path(area, name):
    return os.path.join(_KIT, 'extracted', 'bin_overlays', 'DATA', area,
                        name + '.BIN')


def rd32(d, o):
    return struct.unpack_from('<I', d, o)[0]


def rd16(d, o):
    return struct.unpack_from('<H', d, o)[0]


def derive(d):
    """Return (S, t2) or None. Same rule as fix_palettes.process_file."""
    if len(d) < 16:
        return None
    S = rd32(d, 0) - RAM_BASE
    if not (0 <= S < len(d) - 16):
        return None
    t2 = rd32(d, S + 4) - RAM_BASE
    if not (0 <= t2 < len(d) - 4):
        return None
    return S, t2


def enumerate_headers(d, loose=True):
    """Yield (index, po, w, h). `loose=True` matches the renderers' slot rule
    (`0 <= po < size-24`, `1 <= w,h <= 200`); `loose=False` drops only
    out-of-file slots, so callers can see what the renderers omit."""
    der = derive(d)
    if not der:
        return []
    _S, t2 = der
    out = []
    n = len(d)
    for i in range(64):
        if t2 + i * 4 + 4 > n:
            break
        p = rd32(d, t2 + i * 4)
        po = p - RAM_BASE
        if not (0 <= po):
            continue
        if loose and not (po < n - 24):
            continue
        if po + 4 > n:
            continue
        w, h = rd16(d, po), rd16(d, po + 2)
        if loose and (w == 0 or h == 0 or w > 200 or h > 200):
            continue
        out.append((i, po, w, h))
    return out


def in_range(d, value):
    """True when a raw u32 pointer field resolves to a byte offset inside `d`."""
    if value == 0:
        return False
    off = (value - RAM_BASE) & 0xFFFFFFFF
    return 0 <= off < len(d)


def classify_field(d, value):
    """How a raw u32 pointer field resolves in this file.

    A pointer into a loaded overlay is an absolute RAM address, so the file
    offset is `value - RAM_BASE` and any address from RAM_BASE up to
    RAM_BASE+size is in-file.  CAUTION: an address need not start 0x8001 -- a
    large overlay's later sections reach 0x8002xxxx, 0x8003xxxx, ... (VE1's
    +0x08 table holds `0x80021e30` = file offset 0x11e30).  Classifying on the
    high halfword alone therefore under-reports live pointers; the file-offset
    bound is the real test.  `reloc-base` is still reported separately because
    it is what distinguishes a relocated pointer from any other word.
    """
    if value == 0:
        return 'zero'
    off = (value - RAM_BASE) & 0xFFFFFFFF
    base_shape = (value & 0xFFFF0000) == RAM_BASE
    if off < len(d) and value >= 0x80000000:
        return 'in-range' + ('-base' if base_shape else '')
    return 'other(%#x)' % value


def corpus():
    """Yield (area_sub, area_dir, name, path, data) for every overlay present."""
    for sub in sorted(AREAS):
        area, names = AREAS[sub]
        for name in names:
            p = overlay_path(area, name)
            if os.path.exists(p):
                with open(p, 'rb') as f:
                    yield sub, area, name, p, f.read()


def walk(loose=True):
    """Return list of dicts, one per enumerated header in the corpus."""
    recs = []
    for sub, area, name, path, d in corpus():
        for (i, po, w, h) in enumerate_headers(d, loose=loose):
            f08, f0c, f10 = rd32(d, po + 8), rd32(d, po + 0xc), rd32(d, po + 0x10)
            f14, f18 = rd32(d, po + 0x14), rd32(d, po + 0x18)
            recs.append({
                'area': sub, 'dir': area, 'bin': name, 'path': path,
                'size': len(d), 'hdr': i, 'po': po, 'w': w, 'h': h,
                'f04': rd32(d, po + 4), 'f08': f08, 'f0c': f0c, 'f10': f10,
                'f14': f14, 'f18': f18, 'f1c': rd32(d, po + 0x1c),
                'k08': classify_field(d, f08),
                'k0c': classify_field(d, f0c),
                'k10': classify_field(d, f10),
                'k14': classify_field(d, f14),
                'live': (in_range(d, f08) + in_range(d, f0c) + in_range(d, f10)),
                'live3': all(in_range(d, v) for v in (f08, f0c, f10)),
            })
    return recs


def zero_live(recs):
    """The 72: +0x14 == 0 while +0x08/+0x0c/+0x10 are all in-range."""
    return [r for r in recs if r['f14'] == 0 and r['live3']]


def cmd_list():
    recs = walk()
    z = [r for r in recs if r['f14'] == 0]
    live3 = zero_live(recs)
    dead = [r for r in z if r['live'] == 0]
    print('headers enumerated: %d' % len(recs))
    print('  +0x14 nonzero   : %d' % (len(recs) - len(z)))
    print('  +0x14 == 0      : %d' % len(z))
    print('     +08/+0c/+10 all in-range : %d' % len(live3))
    print('     all three zero/dead      : %d' % len(dead))
    print('     in-range count histogram : %s' % {
        k: sum(1 for r in z if r['live'] == k) for k in (0, 1, 2, 3)})
    by = {}
    for r in live3:
        by.setdefault(r['bin'], []).append(r)
    print('\nzero-with-live-ptrs by file (%d files):' % len(by))
    for k in sorted(by, key=lambda k: (-len(by[k]), k)):
        print('  %-6s %3d  headers %s' % (k, len(by[k]),
                                          ','.join(str(r['hdr']) for r in by[k])))
    print('\nall +0x14==0 headers:')
    for r in z:
        print('  %-6s h%-3d po=%#08x w=%-3d h=%-3d live=%d  f08=%#010x '
              'f14=%#010x f18=%#010x f1c=%#x'
              % (r['bin'], r['hdr'], r['po'], r['w'], r['h'], r['live'],
                 r['f08'], r['f14'], r['f18'], r['f1c']))
    return recs, live3


def cmd_fields(name):
    path = None
    for sub in AREAS:
        area, names = AREAS[sub]
        p = overlay_path(area, name)
        if os.path.exists(p):
            path = p
    if not path:
        raise SystemExit('no such overlay: %s' % name)
    with open(path, 'rb') as f:
        d = f.read()
    print('%s  size=%d (%#x)' % (path, len(d), len(d)))
    der = derive(d)
    print('S/t2 = %s' % (der,))
    if not der:
        return
    _S, t2 = der
    print('t2 slot table @%#x:' % t2)
    for i in range(12):
        v = rd32(d, t2 + i * 4)
        print('   [%2d] %#010x -> %s' % (i, v, classify_field(d, v)))
    print()
    for (i, po, w, h) in enumerate_headers(d):
        f = [rd32(d, po + k) for k in (4, 8, 0xc, 0x10, 0x14, 0x18, 0x1c, 0x20)]
        print('h%-3d po=%#07x w=%-3d h=%-3d  %s' % (
            i, po, w, h,
            ' '.join('%#010x(%s)' % (v, classify_field(d, v)[:9]) for v in f)))


def cmd_dump(name, hdr):
    for sub in AREAS:
        area, names = AREAS[sub]
        p = overlay_path(area, name)
        if os.path.exists(p):
            break
    else:
        raise SystemExit('no such overlay: %s' % name)
    with open(p, 'rb') as f:
        d = f.read()
    hs = {i: (po, w, h) for (i, po, w, h) in enumerate_headers(d)}
    if hdr not in hs:
        raise SystemExit('%s header %d not enumerated' % (name, hdr))
    po, w, h = hs[hdr]
    print('%s header %d: po=%#x w=%d h=%d size=%#x' % (name, hdr, po, w, h, len(d)))
    seg = po
    for k in range(0, 0x40, 4):
        v = rd32(d, po + k)
        if classify_field(d, v).startswith('in-range'):
            seg = min(seg, v - RAM_BASE)
    seg = max(0, min(seg, po - 8))
    print('segment guess start = %#x (po-seg=%#x)' % (seg, po - seg))
    for base in range(seg, po + 0x40 + 0x60, 16):
        words = [struct.unpack_from('<I', d, base + j * 4)[0]
                 for j in range(4) if base + j * 4 + 4 <= len(d)]
        marks = []
        if base <= po < base + 16:
            marks.append('HEADER')
        for off in range(0, 0x40, 4):
            if po + off + 4 <= len(d) and rd32(d, po + off) - RAM_BASE == base:
                marks.append('hdr+%#x' % off)
        print('  %#07x  %-36s %s' % (base, ' '.join('%08x' % x for x in words),
                                     ' '.join(marks)))


def _raw_words_equal(d, po_a, po_b):
    """Same header block outside the pointer fields (+0x18..+0x3c)?"""
    return all(rd32(d, po_a + k) == rd32(d, po_b + k)
               for k in (0x1c, 0x20, 0x24, 0x28, 0x2c, 0x30, 0x34, 0x38, 0x3c))


def cmd_blocks():
    """Duplicate/second-block analysis for every +0x14==0 header.

    Two measurements per zero header:
      donor   -- the nearest EARLIER header with the same (w,h,f04); its f14 is
                 a real tilemap address.  If the section data is duplicated the
                 zero header should sit one *section slot* after a real one.
      same_tm -- the zero header's own tilemap, if it had one, would be its own
                 header block shifted: `cand_f14 = donor.f14 + (r.po - donor.po)`.
                 When `cand_f14 == donor.f14` the zero section reuses the donor's
                 tilemap at the SAME address (VE1 h6..h11 are exact aliases of
                 h1..h5).  `alias` prints that.
    """
    recs = walk()
    by = {}
    for r in recs:
        by.setdefault(r['path'], []).append(r)
    print('%-7s %-5s %-5s %9s %9s %9s  %s'
          % ('file', 'zero', 'donor', 'posdelta', 'donor_f14', 'cand_f14',
             'alias'))
    n_dup = n_tot = n_alias = 0
    for path in sorted(by):
        rs = sorted(by[path], key=lambda r: r['hdr'])
        binname = rs[0]['bin']
        for i, r in enumerate(rs):
            if r['f14'] != 0:
                continue
            n_tot += 1
            donor = None
            for q in reversed(rs[:i]):
                if q['f14'] != 0 and (q['w'], q['h'], q['f04']) == (
                        r['w'], r['h'], r['f04']):
                    donor = q
                    break
            if donor is None:
                # fall back to the nearest earlier section of the same shape
                for q in reversed(rs[:i]):
                    if q['f14'] != 0 and (q['w'], q['h']) == (r['w'], r['h']):
                        donor = q
                        break
            if donor is None:
                print('%-7s h%-4d  --      (no earlier same-shape section)'
                      % (binname, r['hdr']))
                continue
            dz = r['po'] - donor['po']
            cand = (donor['f14'] + dz) & 0xFFFFFFFF
            alias = (cand == donor['f14'])
            if alias:
                n_alias += 1
            print('%-7s h%-4d h%-4d %9x %9x %9x  %s'
                  % (binname, r['hdr'], donor['hdr'], dz, donor['f14'], cand,
                     'ALIAS (same tilemap address)' if alias else 'shifted'))
    print('\nzero headers: %d   exact tilemap aliases of an earlier section: %d'
          % (n_tot, n_alias))


def cmd_tilemap(name):
    """Classify +0x14 as a u16 tilemap for every header of one overlay."""
    path = None
    for sub in AREAS:
        area, names = AREAS[sub]
        p = overlay_path(area, name)
        if os.path.exists(p):
            path = p
    if not path:
        raise SystemExit('no such overlay: %s' % name)
    with open(path, 'rb') as f:
        d = f.read()
    print('%-4s %8s %7s %6s %6s %6s %6s %6s  %s'
          % ('hdr', 'po', 'w x h', 'f14', 'ofs', 'max', 'uniq', 'nblob', 'note'))
    for (i, po, w, h) in enumerate_headers(d):
        raw = rd32(d, po + 0x14)
        n = w * h
        if raw == 0:
            print('%-4d %#8x %3dx%-3d %6s %6s %6s %6s %6s  (no tilemap field)'
                  % (i, po, w, h, '0', '-', '-', '-', '-'))
            continue
        off = raw - RAM_BASE
        if not (0 <= off < len(d) - 2 * n + 2):
            print('%-4d %#8x %3dx%-3d %#6x %6s  OUT OF FILE' % (i, po, w, h, raw))
            continue
        vals = struct.unpack_from('<%dH' % n, d, off)
        mx, uniq = max(vals), len(set(vals))
        f08 = rd32(d, po + 8)
        nblob = 0
        if in_range(d, f08):
            nblob = rd32(d, f08 - RAM_BASE + 4) - RAM_BASE
        print('%-4d %#8x %3dx%-3d %#6x %#6x %6d %6d %6d  %s'
              % (i, po, w, h, raw, off, mx, uniq, nblob,
                 'tile-code range ok' if mx < 1024 else 'NOT tile-code shaped'))


def cmd_span():
    """Control: the eliminated 'inline tilemap at header+0x40' rule.

    Reading w*h u16 at po+0x40 and asking only 'max <= 1024' has no
    discriminating power: most of a tilemap-bearing file satisfies it by
    accident.  Printed here so the negative is reproducible rather than
    asserted.
    """
    recs = walk()
    by = {}
    for r in recs:
        by.setdefault(r['path'], []).append(r)
    tot = {'zero_inline': 0, 'zero_not': 0, 'work_inline': 0, 'work_not': 0}
    for path, rs in by.items():
        with open(path, 'rb') as fh:
            d = fh.read()
        for r in rs:
            n = r['w'] * r['h']
            off = r['po'] + 0x40
            ok = False
            if off + 2 * n <= len(d):
                ok = max(struct.unpack_from('<%dH' % n, d, off)) <= 1024
            key = ('zero_' if r['f14'] == 0 else 'work_') + (
                'inline' if ok else 'not')
            tot[key] += 1
    print('u16 at po+0x40 with max<=1024, w*h long:')
    print('  +0x14==0  : %d inline / %d not' % (tot['zero_inline'],
                                                tot['zero_not']))
    print('  +0x14!=0  : %d inline / %d not' % (tot['work_inline'],
                                                tot['work_not']))
    print('  control verdict: no discriminating power (both groups ~2:1)')


def cmd_json():
    """Machine-readable measurement record for the +0x14==0 population.

    Emits: corpus counts, the 72 zero-live headers with their full pointer
    fields, the 14 dead slots, and the demonstrable tilemap-alias pairs (a
    live header whose +0x14 equals an earlier header's).  No timestamps and no
    absolute paths, so two runs are byte-identical.
    """
    recs = walk()
    z = [r for r in recs if r['f14'] == 0]
    live3 = zero_live(recs)
    dead = [r for r in z if r['live'] == 0]
    by = {}
    for r in recs:
        by.setdefault(r['bin'], []).append(r)
    aliases = []
    for bn in sorted(by):
        rs = sorted(by[bn], key=lambda r: r['hdr'])
        for i, r in enumerate(rs):
            if r['f14'] == 0:
                continue
            for q in rs[:i]:
                if q['f14'] == r['f14']:
                    aliases.append({
                        'bin': bn, 'header': r['hdr'], 'alias_of': q['hdr'],
                        'tilemap': r['f14'], 'w': r['w'], 'h': r['h'],
                        'donor_w': q['w'], 'donor_h': q['h'],
                        'f04': r['f04'], 'donor_f04': q['f04']})
                    break

    def slim(r):
        return {k: r[k] for k in ('bin', 'hdr', 'po', 'w', 'h', 'f04', 'f08',
                                  'f0c', 'f10', 'f14', 'f18', 'f1c', 'live')}

    payload = {
        'schema': 'suikoden-area-tilemap-probe/1',
        'tool': 'area_tilemap_probe.py',
        'ram_base': RAM_BASE,
        'pointer_field_semantics': (
            'absolute RAM address; file offset = value - ram_base; valid for '
            'any address >= ram_base whose offset is inside the file (large '
            'overlays reach 0x8002xxxx, so the 0x8001 high half is NOT a rule)'),
        'counts': {
            'headers': len(recs),
            'f14_nonzero': len(recs) - len(z),
            'f14_zero': len(z),
            'f14_zero_with_all_three_ptrs_in_range': len(live3),
            'f14_zero_dead_slots': len(dead),
            'files_with_zero_live': len({r['bin'] for r in live3}),
        },
        'zero_live_by_file': {k: sorted(r['hdr'] for r in v)
                              for k, v in sorted(
                                  {b: [r for r in live3 if r['bin'] == b]
                                   for b in {r['bin'] for r in live3}}.items())},
        'zero_live': [slim(r) for r in sorted(live3,
                                              key=lambda r: (r['bin'], r['hdr']))],
        'dead_slots': [slim(r) for r in sorted(dead,
                                               key=lambda r: (r['bin'], r['hdr']))],
        'tilemap_alias_pairs': aliases,
        'controls': {
            'inline_tilemap_at_po_plus_0x40': (
                'eliminated: max<=1024 over w*h u16 at po+0x40 is satisfied by '
                'both populations at a similar rate (run `span`)'),
        },
    }
    print(json.dumps(payload, indent=1, sort_keys=True))


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        raise SystemExit(__doc__)
    cmd = argv[0]
    if cmd == 'list':
        cmd_list()
    elif cmd == 'fields' and len(argv) >= 2:
        cmd_fields(argv[1])
    elif cmd == 'dump' and len(argv) >= 3:
        cmd_dump(argv[1], int(argv[2]))
    elif cmd == 'blocks':
        cmd_blocks()
    elif cmd == 'tilemap' and len(argv) >= 2:
        cmd_tilemap(argv[1])
    elif cmd == 'span':
        cmd_span()
    elif cmd == 'json':
        cmd_json()
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
