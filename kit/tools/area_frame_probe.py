#!/usr/bin/env python3
"""area_frame_probe.py -- measure whether an area room's awkward-looking tiles
are *animation-frame candidates* or genuine on-disc art.

Workstream U, 2026-10-04.  Static analysis only.  Nothing here is promoted and
nothing under kit/work/area_tiles/ is written; this tool only reads the disc
overlay and writes under the directory you pass with --outdir.

WHY THIS EXISTS
---------------
A room render can show a region that reads as speckle/noise under every CLUT of
the room's palette bank.  Two very different causes look identical in the PNG:

  (a) the 16x16 cell really is high-contrast art in the decoded blob, so the
      render is faithful; or
  (b) the tilemap holds a *placeholder* that the engine replaces at run time
      from an animation table, so the render shows a frame the game never shows.

Index-space statistics cannot separate them: a dither alternates indices and so
scores as "noisy" while rendering smoothly.  This tool therefore measures in
RENDERED COLOUR space and reports the evidence needed to tell the two apart:

  * `step`   -- mean |RGB(x) - RGB(x+1)| between horizontally adjacent rendered
                pixels of a 16x16 cell (CLUT entry 0).  Low = smooth texture,
                high = genuine speckle.  This is the metric the workstream M
                review asked for; run-count / index-entropy metrics are wrong.
  * `ladder` -- whether a code has a verified *frame partner*: another code used
                by the same tilemap that is adjacent in code space, samples
                largely the same palette indices, and whose pixel grid is close.
                Frame pairs of one animated surface look like this; unrelated
                art does not.  The pair test is the falsifiable one: a
                high-contrast code with NO ladder is on-disc art that the
                render draws faithfully, and the tool says so.

Every report line carries the raw numbers, so a reader can reject the tool's
classification without trusting it.

PROVENANCE
----------
Per room: `S = u32(BIN[0]) - 0x80010000`; `table2 = u32(S+4)`; room header
`po = u32(table2 + 4*i) - 0x80010000`; `w,h = u16(po),u16(po+2)`;
`tilemap A = u32(po+0x14) - 0x80010000`; `blob table = u32(po+0x08) - 0x80010000`;
`CLUT bank = u32(po+0x0c) - 0x80010000`, engine entry 0 = `u32(CLUT bank)`
(area_palette_selector.md).  Tile code -> art: `blob = code // 64`,
`subtile = code % 64`, 16x16 cell at `((si%8)*16, (si//8)*16)` of the 128x128
8-bit decoded blob (area_atlas_render.md).

The blob list is taken from the room's OWN blob table first (the engine's view);
`--blob-source global` reproduces the renderers' file-wide `find_blobs` list so
the two can be compared.  `--blob-source auto` (default) uses the room table and
records whether the file-wide list agrees for the blobs the room actually uses.

Usage
-----
    .venv/bin/python kit/tools/area_frame_probe.py VB5_h0 VB4_h0 --outdir DIR
    .venv/bin/python kit/tools/area_frame_probe.py VB4 --all-headers --outdir DIR
    .venv/bin/python kit/tools/area_frame_probe.py --list
"""
import argparse
import hashlib
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzss                                            # noqa: E402
from disc_iso import lzss_decode_16k                                                 # noqa: E402
from lzss import decode as lzss_decode, LZSSError                                    # noqa: E402
from psx_vram import rgb555_to_rgb888                  # noqa: E402

TOOL_NAME = 'area_frame_probe.py'
TOOL_REVISION = '2026-10-04.1'
SCHEMA = 'suikoden-area-frame-probe/1'

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)
RAM_BASE = 0x80010000

# (area subdir, area folder, bin names) -- the renderers' own enumeration.
AREAS = {
    '01A': ('01_AREA.A', ['VA1', 'VA2', 'VA3', 'VA4', 'VA4B', 'VA5', 'VA6',
                          'VA7', 'VA8', 'VA9', 'VAA', 'VAAD']),
    '02B': ('02_AREA.B', ['VB1', 'VB2', 'VB3', 'VB4', 'VB5', 'VB6', 'VB7',
                          'VB7A', 'VB7D', 'VB8', 'VB9']),
    '06C': ('06_AREA.C', ['VC1', 'VC2', 'VC3', 'VC4', 'VC5', 'VC6', 'VC61',
                          'VCD']),
    '07D': ('07_AREA.D', ['VD1', 'VD2', 'VD3', 'VD4', 'VD5', 'VD6', 'VD7']),
    '08E': ('08_AREA.E', ['VE1', 'VE2', 'VE3', 'VE4', 'VE5', 'VE6']),
    '09F': ('09_AREA.F', ['VF1', 'VF2', 'VF3', 'VF4']),
    '10G': ('10_AREA.G', ['VG1', 'VG2', 'VG3']),
    '11H': ('11_AREA.H', ['VH1', 'VH2']),
    '13I': ('13_AREA.I', ['VI1', 'VI2']),
    '14S': ('14_AREA.S', ['VS1', 'VS2']),
    '15Z': ('15_AREA.Z', ['VZ1', 'VZ2', 'VZ3', 'VZ5', 'VZ7', 'VZ8', 'VZV',
                          'VAC', 'VAD']),
}
_BY_BIN = {}
for _sub, (_folder, _names) in AREAS.items():
    for _n in _names:
        _BY_BIN[_n] = (_sub, _folder, _n)


# --------------------------------------------------------------------------
# palette / blob primitives
# --------------------------------------------------------------------------
def find_blobs_global(data):
    """The renderers' file-wide list: scan, sort by file offset."""
    blobs = []
    n = len(data)
    off = 0
    while off < n - 8:
        clen = struct.unpack_from('<I', data, off)[0]
        if 100 < clen < 16384 and off + 4 + clen <= n:
            raw = lzss_decode_16k(data[off + 4:off + 4 + clen])
            if raw is not None:
                blobs.append((off, raw))
                off += 4 + clen
                off = (off + 3) & ~3
                continue
        off += 4
    return blobs


def room_blob_table(data, po):
    """The room header's own blob table (the engine's view).

    Returns ([(file_off, raw_or_None)], [raw_pointer words]).  Entries whose
    payload is not a 16 KB stream are returned with raw=None rather than being
    dropped, so the caller can see how many slots the header claims.
    """
    ptr = struct.unpack_from('<I', data, po + 0x08)[0]
    tbl = ptr - RAM_BASE
    out = []
    if not (0 <= tbl < len(data) - 8):
        return out, []
    for i in range(8):
        if tbl + 4 * i + 4 > len(data):
            break
        raw_ptr = struct.unpack_from('<I', data, tbl + 4 * i)[0]
        off = raw_ptr - RAM_BASE
        raw = None
        if 0 <= off < len(data) - 8:
            clen = struct.unpack_from('<I', data, off)[0]
            if 100 < clen < 16384 and off + 4 + clen <= len(data):
                raw = lzss_decode_16k(data[off + 4:off + 4 + clen])
        out.append((off, raw))
    return out, [struct.unpack_from('<I', data, tbl + 4 * i)[0]
                 for i in range(len(out))]


def clut_palettes(data, po, count=8):
    """Room palette bank: u32(po+0x0c) -> run of 512-byte RGB555 palettes."""
    tbl = struct.unpack_from('<I', data, po + 0x0c)[0] - RAM_BASE
    pals = []
    if not (0 <= tbl < len(data) - 4):
        return pals, None
    for i in range(count):
        if tbl + 4 * i + 4 > len(data):
            break
        off = struct.unpack_from('<I', data, tbl + 4 * i)[0] - RAM_BASE
        if not (0 <= off) or off + 512 > len(data):
            pals.append(None)
            continue
        cols = struct.unpack_from('<256H', data, off)
        # Degenerate runs (a 2-colour slot) are not usable palettes; treat them
        # as absent so a per-tile selector cannot "win" by flattening a tile.
        if len(set(cols)) < 10:
            pals.append(None)
            continue
        pals.append([rgb555_to_rgb888(c) for c in cols])
    return pals, tbl


def list_headers(data):
    """The renderers' slot enumeration, with the same validity filters."""
    size = len(data)
    if size < 16:
        return []
    S = struct.unpack_from('<I', data, 0)[0] - RAM_BASE
    if not (0 <= S < size - 16):
        return []
    t2 = struct.unpack_from('<I', data, S + 4)[0] - RAM_BASE
    if not (0 <= t2 < size - 4):
        return []
    out = []
    for i in range(64):
        if t2 + 4 * i + 4 > size:
            break
        p = struct.unpack_from('<I', data, t2 + 4 * i)[0]
        po = p - RAM_BASE
        if not (0 <= po < size - 0x40):
            continue
        w, h = struct.unpack_from('<HH', data, po)
        if w == 0 or h == 0 or w > 200 or h > 200:
            continue
        out.append((i, po, w, h))
    return out


# --------------------------------------------------------------------------
# pure analysis helpers (unit-tested)
# --------------------------------------------------------------------------
def cell_of(blob, code):
    """16x16 bytearray for `code` = blob*64 + subtile within a 128x128 blob."""
    bi, si = code // 64, code % 64
    b = blob[bi]
    if b is None:
        return None
    sx, sy = (si % 8) * 16, (si // 8) * 16
    out = bytearray(256)
    for y in range(16):
        o = (sy + y) * 128 + sx
        out[y * 16:(y + 1) * 16] = b[o:o + 16]
    return bytes(out)


def colour_step(cell, pal):
    """Mean |RGB(x)-RGB(x+1)| over a 16x16 index cell under `pal`."""
    tot = 0
    n = 0
    for y in range(16):
        row = cell[y * 16:(y + 1) * 16]
        for x in range(15):
            a, b = pal[row[x]], pal[row[x + 1]]
            tot += (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])) / 3.0
            n += 1
    return tot / n if n else 0.0


def pair_similarity(cell_a, cell_b):
    """(jaccard of palette-index sets, fraction of equal pixels, mean |dindex|)."""
    sa, sb = set(cell_a), set(cell_b)
    inter = len(sa & sb)
    union = len(sa | sb)
    jac = inter / union if union else 0.0
    eq = sum(1 for x, y in zip(cell_a, cell_b) if x == y) / len(cell_a)
    mad = sum(abs(x - y) for x, y in zip(cell_a, cell_b)) / len(cell_a)
    return jac, eq, mad


def ladder_pairs(codes, cells, steps, jac_min=0.5, mad_max=40.0,
                 step_ratio=1.5):
    """Candidate frame ladders among the codes a room uses.

    A pair (a, a+1) is a *frame candidate* when the two cells share most of
    their palette indices, their pixel grids are close, and the pair stands out
    against the room's own colour-step distribution.  `codes`/`cells`/`steps`
    are mappings code -> value.  Returns a deterministic list of dicts with the
    numbers that justified (or would have rejected) each pair.
    """
    usable = sorted(c for c in codes if cells.get(c) is not None)
    med = _median([steps[c] for c in usable])
    out = []
    for a in usable:
        b = a + 1
        if b not in cells or cells[b] is None:
            continue
        jac, eq, mad = pair_similarity(cells[a], cells[b])
        hot = max(steps[a], steps[b]) >= step_ratio * med if med > 0 else False
        out.append({
            'code_a': a, 'code_b': b,
            'jaccard': round(jac, 4), 'equal_fraction': round(eq, 4),
            'mean_abs_index_diff': round(mad, 2),
            'step_a': round(steps[a], 2), 'step_b': round(steps[b], 2),
            'room_median_step': round(med, 2),
            'high_contrast': bool(hot),
            'is_frame_candidate': bool(jac >= jac_min and mad <= mad_max
                                       and hot),
        })
    return out, med


def _median(vals):
    vals = sorted(vals)
    if not vals:
        return 0.0
    n = len(vals)
    return vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2.0


# --------------------------------------------------------------------------
# room analysis
# --------------------------------------------------------------------------
def analyse_room(data, hdr_index, po, w, h, pal, blob_source='auto',
                 all_blobs=None, clut_index=0):
    raw_tm = struct.unpack_from('<I', data, po + 0x14)[0]
    tm = raw_tm - RAM_BASE
    report = {
        'header_index': hdr_index, 'po': hex(po), 'w': w, 'h': h,
        'tilemap_raw_u32': hex(raw_tm), 'tilemap_offset': None,
        'clut_entry': clut_index, 'clut_index_used': None,
        'blob_source': blob_source, 'blob_table': None,
        'blob_count_room_table': None, 'blob_count_global': None,
        'room_table_vs_global_agree': None,
        'codes_used': None, 'distinct_codes': None,
        'room_median_step': None, 'high_contrast_codes': None,
        'ladders': None, 'regions': None, 'verdict': None,
    }
    nbytes = w * h * 2
    if raw_tm == 0 or tm % 2 or tm < 0 or nbytes > len(data) - tm:
        report['verdict'] = 'tilemap unusable (raw %s)' % report['tilemap_raw_u32']
        return report, None
    report['tilemap_offset'] = hex(tm)

    # --- blob list ---------------------------------------------------------
    if all_blobs is None:
        all_blobs = find_blobs_global(data)
    room_tbl, raws = room_blob_table(data, po)
    global_offs = [o for o, _ in all_blobs]
    report['blob_count_global'] = len(all_blobs)
    report['blob_count_room_table'] = sum(1 for _, r in room_tbl if r is not None)
    report['blob_table'] = [{'file_offset': hex(o), 'decodes_16k': r is not None}
                            for o, r in room_tbl]

    if blob_source == 'global':
        blobs = [r for _, r in all_blobs]
    else:
        blobs = [r for _, r in room_tbl]

    tiles = list(struct.unpack_from('<%dH' % (w * h), data, tm))
    used = sorted(set(tiles))
    report['codes_used'] = used
    report['distinct_codes'] = len(used)

    # Does the global list agree with the room table for the blobs in use?
    max_bi = max(t // 64 for t in tiles)
    if blob_source != 'global':
        agree = True
        for bi in range(max_bi + 1):
            if bi >= len(room_tbl) or room_tbl[bi][1] is None:
                agree = False
                break
            if bi < len(global_offs) and global_offs[bi] != room_tbl[bi][0]:
                agree = False
                break
        report['room_table_vs_global_agree'] = bool(agree)

    cells, steps = {}, {}
    for c in used:
        cell = cell_of(blobs, c)
        cells[c] = cell
        steps[c] = colour_step(cell, pal) if cell is not None else 0.0

    ladders, med = ladder_pairs(set(used), cells, steps)
    report['room_median_step'] = round(med, 2)
    report['ladders'] = ladders
    hot = [c for c in used if steps.get(c, 0) > 1.5 * med and med > 0]
    report['high_contrast_codes'] = [{'code': c, 'step': round(steps[c], 2),
                                      'uses': tiles.count(c)} for c in hot]

    # --- region map --------------------------------------------------------
    hotset = set(hot)
    grid = []
    for ty in range(h):
        grid.append([1 if tiles[ty * w + tx] in hotset else 0
                     for tx in range(w)])
    report['regions'] = _region_boxes(grid, w, h)
    report['verdict'] = _verdict(report)
    return report, {'tiles': tiles, 'cells': cells, 'steps': steps,
                    'med': med, 'blobs': blobs, 'ladders': ladders,
                    'hot': hotset, 'grid': grid, 'w': w, 'h': h}


def _region_boxes(grid, w, h):
    """Bounding boxes of 4-connected high-contrast tile runs (deterministic)."""
    seen = [[False] * w for _ in range(h)]
    boxes = []
    for ty in range(h):
        for tx in range(w):
            if not grid[ty][tx] or seen[ty][tx]:
                continue
            stack = [(tx, ty)]
            seen[ty][tx] = True
            x0 = x1 = tx
            y0 = y1 = ty
            n = 0
            while stack:
                cx, cy = stack.pop()
                n += 1
                x0, x1 = min(x0, cx), max(x1, cx)
                y0, y1 = min(y0, cy), max(y1, cy)
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = cx + dx, cy + dy
                    if 0 <= nx < w and 0 <= ny < h and grid[ny][nx] \
                            and not seen[ny][nx]:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            boxes.append({'tiles_x': [x0, x1], 'tiles_y': [y0, y1],
                          'tile_count': n})
    boxes.sort(key=lambda b: (-b['tile_count'], b['tiles_y'][0],
                              b['tiles_x'][0]))
    return boxes[:12]


def _verdict(rep):
    lads = [l for l in (rep['ladders'] or []) if l['is_frame_candidate']]
    hot = rep['high_contrast_codes'] or []
    if not hot:
        return ('no high-contrast codes: the drawn tilemap has no speechle '
                'candidates under this CLUT')
    if lads:
        return ('%d verified frame candidate(s) among %d high-contrast codes: '
                'runtime rewrite plausible, animation table NOT located'
                % (len(lads), len(hot)))
    return ('%d high-contrast codes and NO verified frame partner: the on-disc '
            'cells are that art, so the render is faithful and a runtime '
            'overlay/rewrite is not demonstrated' % len(hot))


# --------------------------------------------------------------------------
# rendering (diagnostic only; never written into kit/work/area_tiles/)
# --------------------------------------------------------------------------
def render_tiles(tiles, w, h, blobs, pal, subst=None, scale=1, pals=None,
                 pal_map=None):
    """`pal_map` (code -> CLUT entry) applies a per-tile palette when `pals`
    (the room's whole palette bank) is supplied; otherwise `pal` is used."""
    from PIL import Image
    cache = {}

    def sub(bi, si):
        k = (bi, si)
        if k not in cache:
            b = blobs[bi]
            if b is None:
                cache[k] = None
            else:
                sx, sy = (si % 8) * 16, (si // 8) * 16
                out = bytearray(256)
                for y in range(16):
                    o = (sy + y) * 128 + sx
                    out[y * 16:(y + 1) * 16] = b[o:o + 16]
                cache[k] = bytes(out)
        return cache[k]

    img = Image.new('RGB', (w * 16, h * 16), (255, 0, 255))
    px = img.load()
    for ty in range(h):
        for tx in range(w):
            code = tiles[ty * w + tx]
            if subst:
                code = subst.get(code, code)
            bi, si = code // 64, code % 64
            cell = sub(bi, si) if bi < len(blobs) else None
            if cell is None:
                continue
            for y in range(16):
                for x in range(16):
                    if pals is not None and pal_map is not None:
                        e = pal_map.get(tiles[ty * w + tx], 0)
                        pl = pals[e] if 0 <= e < len(pals) and pals[e] else pal
                    else:
                        pl = pal
                    px[tx * 16 + x, ty * 16 + y] = pl[cell[y * 16 + x]]
    if scale != 1:
        img = img.resize((img.width * scale, img.height * scale),
                         Image.NEAREST)
    return img


def collapse_map(ladders):
    """Map every frame candidate onto one representative per connected group.

    A room can hold a ladder of more than two frames (VB4_h0's water is
    1-2-3-4), so substituting pair-by-pair would fight itself.  Each connected
    group collapses onto its lowest code, which is the deterministic choice.
    """
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for l in ladders:
        a, b = find(l['code_a']), find(l['code_b'])
        if a != b:
            parent[max(a, b)] = min(a, b)
    out = {}
    for l in ladders:
        for c in (l['code_a'], l['code_b']):
            r = find(c)
            if r != c:
                out[c] = r
    return out


def per_tile_clut(info, pals, base_entry=0, ratio=1.0):
    """Greedy per-tile CLUT assignment: for every tile code the room uses, pick
    the palette entry that minimises that code's rendered colour step, but keep
    the base entry unless another entry is better by more than `ratio`.

    This is a MEASUREMENT of which entry in the room's own palette bank makes
    each code's pixels smooth.  It is NOT the engine's selector: no static rule
    mapping code -> entry was located (see the workstream U document, S7).  The
    record therefore stores the full per-code table and the code that maps to
    each entry, so a reader can test the assignment independently.
    """
    steps = {}
    for c, cell in info['cells'].items():
        if cell is None:
            continue
        row = {}
        for e, pal in enumerate(pals):
            if pal is None:
                continue
            row[e] = colour_step(cell, pal)
        if row:
            steps[c] = row
    assign = {}
    for c, row in steps.items():
        base = row.get(base_entry)
        best_e = min(row, key=lambda e: (row[e], e))
        if base is None:
            assign[c] = best_e
        elif row[best_e] < base * ratio:
            assign[c] = best_e
        else:
            assign[c] = base_entry
    by_entry = {}
    for c, e in sorted(assign.items()):
        by_entry.setdefault(e, []).append(c)
    return {'base_entry': base_entry, 'ratio': ratio,
            'per_code': {str(c): e for c, e in sorted(assign.items())},
            'codes_by_entry': {str(e): cs for e, cs in sorted(by_entry.items())},
            'steps': {str(c): {str(e): round(v, 2) for e, v in sorted(row.items())}
                      for c, row in sorted(steps.items())}}


def _write_pair(room, data, info, outdir, pal, scale=1, pals=None,
                pal_map=None):
    """before = tilemap as stored; after = each connected group of verified
    frame candidates collapsed onto its lowest code (a diagnostic, not a
    claim)."""
    from PIL import Image, ImageDraw
    tiles, blobs = info['tiles'], info['blobs']
    lads = [l for l in info['ladders'] if l['is_frame_candidate']]
    subst = collapse_map(lads)
    info['collapse_map'] = {str(k): v for k, v in sorted(subst.items())}
    before = render_tiles(tiles, info['w'], info['h'], blobs, pal, scale=scale)
    after = render_tiles(tiles, info['w'], info['h'], blobs, pal, subst=subst,
                         scale=scale,
                         pals=pals if pal_map else None, pal_map=pal_map)
    gap = 8
    sheet = Image.new('RGB', (before.width * 2 + gap, before.height), (255, 0, 0))
    sheet.paste(before, (0, 0))
    sheet.paste(after, (before.width + gap, 0))
    d = ImageDraw.Draw(sheet)
    d.text((2, 2), 'BEFORE (tilemap as stored)', fill=(255, 255, 0))
    d.text((before.width + gap + 2, 2),
           'AFTER%s'
           % ((' + per-tile CLUT (%d codes moved off entry %s)'
               % (sum(1 for e in pal_map.values() if e != 0),
                  '0')) if pal_map else
              ' (frame candidates collapsed: %s)'
              % (', '.join('%d->%d' % (b, a) for b, a in sorted(subst.items()))
                 or 'none')), fill=(255, 255, 0))
    outs = {}
    for tag, im in (('before', before), ('after', after), ('compare', sheet)):
        p = os.path.join(outdir, '%s_%s.png' % (room, tag))
        im.save(p)
        rel = os.path.relpath(p, _ROOT)
        # A path outside the repo (e.g. /tmp) would make the record
        # non-deterministic; name the file instead of leaking an absolute path.
        outs[tag] = {'path': (rel.replace(os.sep, '/') if not rel.startswith('..')
                              else os.path.basename(p)),
                     'sha256': _sha256(p), 'bytes': os.path.getsize(p)}
    return outs


def _sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        h.update(f.read())
    return h.hexdigest()


# --------------------------------------------------------------------------
# driver
# --------------------------------------------------------------------------
def _bin_path(name):
    sub, folder, base = _BY_BIN[name]
    return os.path.join(_KIT, 'extracted/bin_overlays/DATA', folder,
                        base + '.BIN')


def parse_clut_override(spec):
    """'1,2,3,4,204,205=2' -> {1:2, 2:2, 3:2, 4:2, 204:2, 205:2}"""
    out = {}
    if not spec:
        return out
    for part in spec.split(';'):
        part = part.strip()
        if not part:
            continue
        codes, _, entry = part.partition('=')
        if not _:
            raise SystemExit('--clut-for-code needs CODES=ENTRY, got %r' % part)
        e = int(entry)
        for c in codes.split(','):
            out[int(c)] = e
    return out


def run(rooms, outdir, blob_source='auto', clut_index=0, scale=1,
        all_headers=False, list_only=False, per_tile=False, clut_ratio=1.0,
        clut_override=None):
    reports = []
    os.makedirs(outdir, exist_ok=True)
    for room in rooms:
        binname, _, hdr = room.partition('_h')
        if binname not in _BY_BIN:
            print('unknown room %r' % room)
            continue
        path = _bin_path(binname)
        if not os.path.exists(path):
            print('missing extraction for %s' % binname)
            continue
        with open(path, 'rb') as fh:
            data = fh.read()
        all_blobs = find_blobs_global(data)
        headers = list_headers(data)
        if list_only:
            print('%s: %d usable header slots (%s)'
                  % (binname, len(headers),
                     ', '.join('h%d %dx%d' % (i, w, h) for i, po, w, h in headers[:12])))
            continue
        want = headers if all_headers else [x for x in headers
                                            if str(x[0]) == (hdr or '0')]
        if not want:
            print('%s: no such header slot' % room)
            continue
        for (i, po, w, h) in want:
            pals, _tbl = clut_palettes(data, po)
            pal = pals[clut_index] if clut_index < len(pals) else None
            if pal is None:
                print('%s-h%d: no CLUT entry %d' % (binname, i, clut_index))
                continue
            rep, info = analyse_room(data, i, po, w, h, pal,
                                     blob_source=blob_source,
                                     all_blobs=all_blobs,
                                     clut_index=clut_index)
            rep['bin'] = binname + '.BIN'
            rep['room'] = '%s_h%d' % (binname, i)
            rep['source_path'] = os.path.relpath(path, _ROOT).replace(os.sep, '/')
            map_info = None
            if info and not list_only:
                info['w'], info['h'] = w, h
                pmap = dict(clut_override or {})
                if pmap:
                    moved = sum(1 for e in pmap.values() if e != clut_index)
                    rep['clut_override'] = {'base_entry': clut_index,
                                            'per_code': {str(c): e for c, e in
                                                         sorted(pmap.items())}}
                    print('   CLUT override: %d codes pinned to given entries '
                          '(%d off entry %d)'
                          % (len(pmap), moved, clut_index))
                if per_tile:
                    map_info = per_tile_clut(info, pals, base_entry=clut_index,
                                             ratio=clut_ratio)
                    pmap = {int(k): v
                            for k, v in map_info['per_code'].items()}
                    moved = sum(1 for e in pmap.values() if e != clut_index)
                    rep['per_tile_clut'] = map_info
                    rep['per_tile_clut_moved_codes'] = moved
                    print('   per-tile CLUT: %d of %d codes moved off entry %d: %s'
                          % (moved, len(pmap), clut_index,
                             {e: cs for e, cs in map_info['codes_by_entry'].items()
                              if str(e) != str(clut_index)}))
                rep['outputs'] = _write_pair(rep['room'], data, info, outdir,
                                             pal, scale=scale, pals=pals,
                                             pal_map=pmap)
            reports.append(rep)
            print('%s: verdict: %s' % (rep['room'], rep['verdict']))
            for l in rep['ladders'] or []:
                if l['is_frame_candidate']:
                    print('   frame candidate %d<->%d jaccard=%.2f mad=%.1f '
                          'step %.1f/%.1f (room median %.1f)'
                          % (l['code_a'], l['code_b'], l['jaccard'],
                             l['mean_abs_index_diff'], l['step_a'],
                             l['step_b'], l['room_median_step']))
            for c in rep['high_contrast_codes'] or []:
                print('   high-contrast code %d step=%.1f uses=%d'
                      % (c['code'], c['step'], c['uses']))
            for b in (rep['regions'] or [])[:4]:
                print('   region tiles x%s y%s (%d tiles)'
                      % (b['tiles_x'], b['tiles_y'], b['tile_count']))
    doc = {'schema': SCHEMA, 'tool': TOOL_NAME, 'tool_revision': TOOL_REVISION,
           'decoder': 'lzss.py %s' % getattr(lzss, '__version__', 'unknown'),
           'clut_index': clut_index, 'blob_source': blob_source,
           'rooms': reports}
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('rooms', nargs='*',
                    help='ROOM[ _hN ] e.g. VB4_h0, or a BIN name with '
                         '--all-headers (VB4)')
    ap.add_argument('--outdir', required=False,
                    default=os.path.join(_KIT, 'work/candidates/20261004/ws_u'))
    ap.add_argument('--json', default=None,
                    help='record path (default <outdir>/area_frame_probe.json)')
    ap.add_argument('--blob-source', choices=('auto', 'room', 'global'),
                    default='auto')
    ap.add_argument('--clut', type=int, default=0)
    ap.add_argument('--scale', type=int, default=1)
    ap.add_argument('--per-tile-clut', action='store_true', dest='per_tile',
                    help='render the AFTER image with a per-tile CLUT chosen '
                         'by minimising each code\'s rendered colour step '
                         '(a measurement, NOT a located engine rule)')
    ap.add_argument('--clut-for-code', default=None, dest='clut_for_code',
                    metavar='CODES=ENTRY',
                    help='pin tile codes to a CLUT entry, e.g. '
                         '"1,2,3,4,204,205=2;125=3"; other codes stay on '
                         '--clut')
    ap.add_argument('--clut-ratio', type=float, default=1.0,
                    help='with --per-tile-clut, switch a code only when the '
                         'alternative entry is below ratio*base_step '
                         '(1.0 = any strict improvement, 0.8 = >=20%%)')
    ap.add_argument('--all-headers', action='store_true')
    ap.add_argument('--list', action='store_true', dest='list_only',
                    help='list usable header slots and exit')
    a = ap.parse_args(argv)
    if not a.rooms:
        a.rooms = ['VB4_h0']
    doc = run(a.rooms, a.outdir, blob_source=a.blob_source, clut_index=a.clut,
              scale=a.scale, all_headers=a.all_headers, list_only=a.list_only,
              per_tile=a.per_tile, clut_ratio=a.clut_ratio,
              clut_override=parse_clut_override(a.clut_for_code))
    if doc is None:
        return 0
    jpath = a.json or os.path.join(a.outdir, 'area_frame_probe.json')
    os.makedirs(os.path.dirname(os.path.abspath(jpath)), exist_ok=True)
    with open(jpath, 'w') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')
    print('record: %s' % os.path.relpath(jpath, _ROOT).replace(os.sep, '/'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
