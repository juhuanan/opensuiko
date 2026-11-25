#!/usr/bin/env python3
"""Render area base layers with the engine's ordered atlas and tile palette tables.

Production reads header +08/+0c/+10/+14 (see area_tile_materials.py).
Legacy palette-scoring helpers remain available to historical probe tools;
production never falls back to appearance scoring when source data is invalid.
Invalid rooms produce a rejection sidecar, not a substitute image.
"""
import glob
import struct, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzss
from disc_iso import lzss_decode_16k
from lzss import decode as lzss_decode, LZSSError
from PIL import Image
from area_tile_materials import load_room_materials, render_tilemap
from area_scene import compose_scene_image
from psx_vram import rgb555_to_rgb888
import colorsys

# --- status record (workstream M, 2026-10-04) ------------------------------
# Every room this tool processes gets a line in a sidecar JSONL, including the
# rooms it REJECTS, so a rejection is a recorded outcome rather than a missing
# file. `area_render_manifest.py` merges these sidecars into the manifest.
import hashlib, json

TOOL_NAME = 'fix_palettes.py'
TOOL_REVISION = '2026-10-04.3'        # tilemap bounds + status sidecar + scene composition
TILEMAP_RULES = 'area-tilemap-bounds/2026-10-04'
SIDECAR_SCHEMA = 'suikoden-area-render-sidecar/1'

# Scene composition is opt-in so existing base-only output stays byte-identical
# unless a caller asks for the full scene. `--scene` turns it on.
SCENE_COMPOSITION = False


def _composition_scope(scene_meta):
    """Composition status recorded SEPARATELY from the file render status.

    A written PNG does not prove that every layer was rendered, so this says
    exactly which layers composed and what stayed unresolved.
    """
    if not scene_meta:
        return {'composed': False, 'scope': 'base tilemap only'}
    if not scene_meta.get('composed'):
        out = {'composed': False, 'scope': 'base tilemap only',
               'reason': scene_meta.get('reason')}
        # a companion section is a room's secondary layer, not a failed room --
        # carry that through so review output can say which room it belongs to
        if scene_meta.get('companion_of'):
            out['companion_of'] = scene_meta['companion_of']
        return out
    return {
        'composed': True,
        'scope': 'primary + secondary + scenery' + (' + npc' if scene_meta.get('npc') else ''),
        'room': scene_meta.get('room'),
        'primary_tag': scene_meta['primary']['tag'],
        'secondary_tag': scene_meta['secondary']['tag'],
        'draw_mode': scene_meta['draw_mode'],
        'scenery_primitives': scene_meta['scenery']['primitives'],
        'npc_primitives': scene_meta['npc']['primitives'],
        'primitives_total': scene_meta['primitives_total'],
        'unresolved': (scene_meta['scenery']['unresolved']
                       + scene_meta['npc']['unresolved']
                       + (scene_meta['npc'].get('variants_dropped') or [])),
        'size': scene_meta['size'],
    }

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

# Back-compat alias: this tool used to define this from a hardcoded path.
BASE = _KIT


def _kit(*parts):
    return os.path.join(_KIT, *parts)


def _root(*parts):
    return os.path.join(_ROOT, *parts)


_KIT
RAM_BASE = 0x80010000


def _rel_to_root(path):
    """Deterministic POSIX path for a sidecar: never an absolute path.

    An isolated build (BUILD_ROOT set) writes outside the repo, where a
    repo-relative path still carries the build-root name -- `/tmp/b1/...` vs
    `/tmp/b2/...` -- so two isolated builds disagreed on 130 sidecar lines.
    When BUILD_ROOT is set and the path is under it, record it relative to the
    build root instead, so the artifact is comparable across builds.
    """
    ap = os.path.abspath(path)
    build_root = os.environ.get('BUILD_ROOT')
    if build_root:
        try:
            rel = os.path.relpath(ap, os.path.abspath(build_root))
        except ValueError:
            rel = None
        if rel is not None and not rel.startswith(os.pardir):
            return 'build/' + rel.replace(os.sep, '/')
    try:
        rel = os.path.relpath(ap, _ROOT)
    except ValueError:
        return ap.replace(os.sep, '/')
    return rel.replace(os.sep, '/')


def _sha256(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def _sidecar_record(area, base, hdr, status, reason=None, out1=None, out2=None,
                    img=None, palette=None, source_path=None,
                    tilemap_ptr=None, raw_po=None, raw_w=None,
                    raw_h=None, composition=None):
    """One sidecar line for one processed room. `status` is 'rendered' when a
    PNG was written and 'rejected'/'omitted' when none was."""
    return {
        'schema': SIDECAR_SCHEMA,
        'tool': TOOL_NAME,
        'tool_revision': TOOL_REVISION,
        'decoder': 'lzss.py %s' % getattr(lzss, '__version__', 'unknown'),
        'validation_rules': TILEMAP_RULES,
        'area': area,
        'room': ('%s_h%d' % (base, hdr)) if hdr is not None else None,
        'bin': base,
        'header_index': hdr,
        'source_path': source_path,
        'status': status,
        'reason': reason,
        'output': _rel_to_root(out1) if out1 else None,
        'output_2x': _rel_to_root(out2) if out2 else None,
        'sha256': _sha256(out1) if out1 else None,
        'sha256_2x': _sha256(out2) if out2 else None,
        'bytes': os.path.getsize(out1) if out1 else None,
        'width': img.width if img is not None else None,
        'height': img.height if img is not None else None,
        'palette': palette,
        # Composition scope is recorded SEPARATELY from `status`: a written PNG
        # does not prove that every layer was rendered. Additive field.
        'composition': composition,
        # Recorded so a third party can check the rejection mechanism without
        # trusting this tool. Measured 2026-10-04: 86 of 91 rejected headers
        # carry a raw tilemap field of exactly 0x00000000 (an UNPOPULATED
        # field, not a half-populated 0x8001 word -- 0x8001 is the high half of
        # the ACCEPTED pointers, since RAM_BASE is 0x80010000). Independent
        # corroboration: orchestrator, 84 files / 991 headers / 88 rejections,
        # every rejected raw pointer 0x0.
        'tilemap_ptr': tilemap_ptr,
        'tilemap_ptr_raw_u32': (hex(tilemap_ptr) if tilemap_ptr is not None else None),
        'raw_po': raw_po, 'raw_w': raw_w, 'raw_h': raw_h,
        'tilemap_ptr_shape': (
            None if tilemap_ptr is None else
            'unpopulated_zero' if (tilemap_ptr & 0xFFFFFFFF) == 0 else
            'relocated' if (tilemap_ptr & 0xFFFF0000) == 0x80010000 else
            'other'),
    }


def _emit(records, rec):
    if records is not None:
        records.append(rec)
    return rec


def _write_sidecar(path, records):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'w') as f:
        for rec in records:
            f.write(json.dumps(rec, sort_keys=True) + '\n')


def find_blobs(data):
    blobs = []
    n = len(data)
    off = 0
    while off < n - 8:
        clen = struct.unpack_from('<I', data, off)[0]
        if 100 < clen < 16384 and off + 4 + clen <= n:
            raw = lzss_decode_16k(data[off+4:off+4+clen])
            if raw is not None:
                blobs.append((off, raw))
                off += 4 + clen
                off = (off + 3) & ~3
                continue
        off += 4
    return blobs

def get_clut_palette(data, po, min_uniq=10):
    """Return CLUT entry 0 for legacy single-palette probes, or None.

    Entry 0 alone is not the engine selector: production selects a palette
    per tile via header +0x10 (area_tile_materials.py).
    """
    if not (0 <= po) or po + 0x10 > len(data):
        return None
    tbl = struct.unpack_from('<I', data, po + 0x0c)[0] - RAM_BASE
    if not (0 <= tbl) or tbl + 4 > len(data):
        return None
    off = struct.unpack_from('<I', data, tbl)[0] - RAM_BASE
    if not (0 <= off) or off + 512 > len(data):
        return None
    colors = [struct.unpack_from('<H', data, off + j * 2)[0] for j in range(256)]
    if len(set(colors)) < min_uniq:
        return None
    return [rgb555_to_rgb888(c) for c in colors], off


def get_all_palettes(data, ptab_off):
    """Get all valid palette candidates from ptab entries 6-20."""
    cands = []
    for i in range(6, 21):
        if ptab_off + i*4 + 4 > len(data):
            continue
        v = struct.unpack_from('<I', data, ptab_off + i*4)[0]
        po = v - RAM_BASE
        if not (0 <= po < len(data) - 512):
            continue
        colors = [struct.unpack_from('<H', data, po+j*2)[0] for j in range(256)]
        # Skip degenerate (all same or near-empty)
        uniq = len(set(colors))
        if uniq < 10:
            continue
        pal = [rgb555_to_rgb888(c) for c in colors]
        cands.append((pal, po, i))
    return cands

def score_render(img):
    """Score a rendered thumbnail for naturalness -- a HEURISTIC, not proof.
    Returns higher = better. Penalizes all-black, neon, flat. The score
    encodes a guess about what "looks natural"; it does not establish that the
    winning palette is the one the engine used."""
    # Sample pixels
    w, h = img.size
    pixels = []
    for y in range(0, h, 4):
        for x in range(0, w, 4):
            pixels.append(img.getpixel((x, y)))

    if not pixels:
        return -1000

    # Brightness: mean value, penalize too dark (<30) or too bright (>220)
    brightness = sum(sum(p)//3 for p in pixels) / len(pixels)
    if brightness < 25:
        return -500 + brightness  # too dark
    if brightness > 225:
        return -500 + (255 - brightness)

    # Saturation: mean saturation in HSV, penalize neon (>0.85 avg)
    sats = []
    vals = []
    for r, g, b in pixels:
        hr, hg, hb = r/255, g/255, b/255
        h_, s, v = colorsys.rgb_to_hsv(hr, hg, hb)
        sats.append(s)
        vals.append(v)
    avg_sat = sum(sats) / len(sats)
    if avg_sat > 0.8:
        return -300  # neon/psychedelic

    # Color variety: count distinct hues
    hues = set()
    for r, g, b in pixels[::10]:  # sample
        hr, hg, hb = r/255, g/255, b/255
        h_, s, v = colorsys.rgb_to_hsv(hr, hg, hb)
        if s > 0.15 and 0.15 < v < 0.95:  # colorful, not black/white
            hues.add(int(h_ * 12))  # 12 hue buckets

    # Prefer moderate variety (3-8 hues), penalize 0-1 (flat) or 10+ (chaos)
    n_hues = len(hues)
    if n_hues <= 1:
        hue_score = -100
    elif n_hues <= 8:
        hue_score = n_hues * 20
    else:
        hue_score = 160 - (n_hues - 8) * 30

    # Combine: brightness in good range + saturation moderate + hue variety
    sat_score = 50 - abs(avg_sat - 0.35) * 100  # prefer ~0.35 saturation
    bright_score = 50 - abs(brightness - 110) * 0.3  # prefer ~110 brightness

    return hue_score + sat_score + bright_score

def blob_spans(data, blobs):
    """(start, end) file spans of the [u32 comp_len][payload] of each blob.

    Kept in sync with render_area_batch.py:blob_spans (both tools share the
    same pointer-validation rules as of 2026-10-04, workstream D)."""
    spans = []
    for off, _raw in blobs:
        if off is None or off + 4 > len(data):
            continue
        clen = struct.unpack_from('<I', data, off)[0]
        spans.append((off, off + 4 + clen))
    return spans


def validate_tilemap(data, blobs, w, h, tm, size, check_blobs=True):
    """Reject a tilemap pointer/set that cannot name a real tilemap.

    Kept in sync with render_area_batch.py:validate_tilemap. Returns
    (ok, reason). Rules: halfword alignment; the w*h*2-byte span fits; the
    span does not overlap a compressed blob source span; every tile index
    resolves to a decoded blob (index//64 < len(blobs)).
    """
    nbytes = w * h * 2
    if tm % 2:
        return False, 'tilemap pointer not halfword-aligned'
    if tm == -RAM_BASE:
        # The raw field was 0. This is not a span problem: the header carries no
        # tilemap A at all (2026-10-04 -- these are duplicate/second-pass room
        # records: f1c==1 for 70/72, f04 & 0x1000==0 for 72/72). Reporting it as
        # "span past end of file" sent readers after a bounds bug that does not
        # exist; the byte that is actually zero is the field.
        return False, 'tilemap pointer unpopulated (field is 0)'
    if tm < 0:
        return False, ('tilemap pointer below the file base (raw %#x)'
                       % (tm + RAM_BASE))
    if nbytes > size - tm:
        return False, 'tilemap span past end of file'
    for a, b in blob_spans(data, blobs):
        if tm < b and a < tm + nbytes:
            return False, 'tilemap span overlaps compressed blob at %#x' % a
    tiles = struct.unpack_from('<%dH' % (w * h), data, tm)
    n_blobs_needed = max(tiles) // 64 + 1
    if check_blobs and n_blobs_needed > len(blobs):
        return False, ('tile index references blob %d but only %d decoded'
                       % (n_blobs_needed - 1, len(blobs)))
    return True, ''


def render_thumbnail(data, blobs, pal, w, h, tm_off, scale=0.25):
    """Render small thumbnail for scoring.

    An out-of-range blob reference RAISES: it is never replaced with a solid
    pal[0] fill (the 2026-10-04 pal[0] laundering defect)."""
    tw, th = max(1, int(w*16*scale)), max(1, int(h*16*scale))
    img = Image.new('RGB', (w*16, h*16))
    px = img.load()

    tiles = struct.unpack_from(f'<{w*h}H', data, tm_off)
    if max(tiles) // 64 >= len(blobs):
        raise IndexError('tile index references blob %d but only %d decoded'
                         % (max(tiles) // 64, len(blobs)))
    blob_cache = {}
    def get_subtile(bi, si):
        key = (bi, si)
        if key not in blob_cache:
            if bi >= len(blobs):
                raise IndexError(
                    'tile references blob %d but only %d decoded'
                    % (bi, len(blobs)))
            raw = blobs[bi][1]
            sx = (si % 8) * 16
            sy = (si // 8) * 16
            pxb = bytearray(256)
            for y in range(16):
                src_off = (sy + y) * 128 + sx
                pxb[y*16:(y+1)*16] = raw[src_off:src_off+16]
            blob_cache[key] = bytes(pxb)
        return blob_cache[key]

    for ty in range(h):
        for tx in range(w):
            idx = tiles[ty*w + tx]
            bi = idx // 64
            si = idx % 64
            sub = get_subtile(bi, si)
            for y in range(16):
                for x in range(16):
                    ci = sub[y*16 + x]
                    px[tx*16+x, ty*16+y] = pal[ci]
    return img.resize((tw, th), Image.BILINEAR)

def render_full(data, blobs, pal, w, h, tm_off):
    """Legacy single-palette probe; production uses the per-tile table."""
    return render_tilemap(data, blobs, pal, w, h, tm_off)


def process_file(path, outdir, log, area_key=None, records=None):
    with open(path, 'rb') as f:
        data = f.read()
    size = len(data)
    base = os.path.basename(path).replace('.BIN', '')
    src = _rel_to_root(path)

    def rec(hdr, status, **kw):
        return _emit(records, _sidecar_record(area_key, base, hdr, status,
                                              source_path=src, **kw))

    ptr0 = struct.unpack_from('<I', data, 0)[0]
    S = ptr0 - RAM_BASE
    if not (0 <= S < size - 16):
        rec(None, 'omitted', reason='bad S pointer')
        return 0
    t2 = struct.unpack_from('<I', data, S+4)[0] - RAM_BASE
    if not (0 <= t2 < size - 4):
        rec(None, 'omitted', reason='bad table2 pointer')
        return 0

    headers = []
    for i in range(64):
        if t2 + i*4 + 4 > size: break
        p = struct.unpack_from('<I', data, t2+i*4)[0]
        po = p - RAM_BASE
        if not (0 <= po < size - 24):
            # A considered-and-not-rendered slot must still be RECORDED, or it
            # is a silent drop of exactly the kind this manifest exists to
            # remove. `tilemap_ptr` here is the header pointer field itself.
            rec(i, 'omitted', reason='header slot out of range (po)',
                tilemap_ptr=p, raw_po=po)
            continue
        w, h = struct.unpack_from('<HH', data, po)
        if w == 0 or h == 0 or w > 200 or h > 200:
            rec(i, 'omitted', reason='header slot with implausible w/h',
                raw_po=po, raw_w=w, raw_h=h)
            continue
        headers.append((i, po, w, h))
    if not headers:
        rec(None, 'omitted', reason='no valid headers')
        return 0

    decode_cache = {}

    os.makedirs(outdir, exist_ok=True)
    count = 0
    for (i, po, w, h) in headers:
        raw_tm = struct.unpack_from('<I', data, po+0x14)[0]
        tm = raw_tm - RAM_BASE
        # Preserve the precise absent-pointer/bounds reason before decoding.
        ok, why = validate_tilemap(data, [], w, h, tm, size, check_blobs=False)
        if not ok:
            rec(i, 'rejected', reason=why, tilemap_ptr=raw_tm)
            continue
        try:
            blobs, tile_palettes, pal_rec = load_room_materials(data, po, decode_cache)
            ok, why = validate_tilemap(data, blobs, w, h, tm, size)
            if not ok:
                raise ValueError(why)
            img = render_tilemap(data, blobs, None, w, h, tm, tile_palettes)
            scene_meta = None
            if SCENE_COMPOSITION:
                img, scene_meta = compose_scene_image(
                    data, po, img, {'file': os.path.basename(path)})
        except (IndexError, struct.error, ValueError, LZSSError) as ex:
            rec(i, 'rejected', reason='area materials: %s: %s' % (type(ex).__name__, ex),
                tilemap_ptr=raw_tm)
            continue

        out1 = os.path.join(outdir, f'{base}_h{i}.png')
        # The 2x nearest-neighbour copies were pure redundancy: same pixels, double
        # the disk, and no review could use them that the plain PNG did not serve.
        # They accounted for ~175 MB of a 399 MB output tree. Dropped.
        img.save(out1)
        out2 = None
        log.write(f"{base}_h{i}: data-selected palettes {pal_rec['palette_offsets']}\n")
        rec(i, 'rendered', out1=out1, out2=None, img=img, palette=pal_rec,
            composition=_composition_scope(scene_meta))
        count += 1
    return count

# Map subdir -> (area folder, [bin names])
AREAS = {
    '01A': ('01_AREA.A', ['VA1','VA2','VA3','VA4','VA4B','VA5','VA6','VA7','VA8','VA9','VAA','VAAD']),
    '02B': ('02_AREA.B', ['VB1','VB2','VB3','VB4','VB5','VB6','VB7','VB7A','VB7D','VB8','VB9']),
    '06C': ('06_AREA.C', ['VC1','VC2','VC3','VC4','VC5','VC6','VC61','VCD']),
    '07D': ('07_AREA.D', ['VD1','VD2','VD3','VD4','VD5','VD6','VD7']),
    '08E': ('08_AREA.E', ['VE1','VE2','VE3','VE4','VE5','VE6']),
    '09F': ('09_AREA.F', ['VF1','VF2','VF3','VF4']),
    '10G': ('10_AREA.G', ['VG1','VG2','VG3']),
    '11H': ('11_AREA.H', ['VH1','VH2']),
    '13I': ('13_AREA.I', ['VI1','VI2']),
    '14S': ('14_AREA.S', ['VS1','VS2']),
    '15Z': ('15_AREA.Z', ['VZ1','VZ2','VZ3','VZ5','VZ7','VZ8','VZV','VAC','VAD']),
}

DEFAULT_OUT_ROOT = os.path.join(BASE, 'work/area_tiles')


def _parse_args(argv):
    """[area_subdir ...]  --outdir ROOT  --sidecar PATH  --log PATH

    Defaults are unchanged: renders go under kit/work/area_tiles/<sub> and the
    rejection log is kit/work/area_tiles/palette_fix.log. `area_render_
    sidecar_fix_palettes.jsonl` is written beside them unless --sidecar says
    otherwise."""
    subs, opts = [], {'outdir': DEFAULT_OUT_ROOT, 'sidecar': None, 'log': None,
                      'scene': False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--scene':
            opts['scene'] = True; i += 1
        elif a == '--outdir' and i + 1 < len(argv):
            opts['outdir'] = argv[i+1]; i += 2
        elif a == '--sidecar' and i + 1 < len(argv):
            opts['sidecar'] = argv[i+1]; i += 2
        elif a == '--log' and i + 1 < len(argv):
            opts['log'] = argv[i+1]; i += 2
        elif a.startswith('--'):
            raise SystemExit('unknown argument: %s' % a)
        else:
            subs.append(a); i += 1
    if opts['sidecar'] is None:
        opts['sidecar'] = os.path.join(
            opts['outdir'], 'area_render_sidecar_fix_palettes.jsonl')
    if opts['log'] is None:
        opts['log'] = os.path.join(opts['outdir'], 'palette_fix.log')
    return subs, opts


def main(argv=None):
    global SCENE_COMPOSITION
    subs, opts = _parse_args(list(sys.argv[1:] if argv is None else argv))
    SCENE_COMPOSITION = bool(opts.get('scene'))
    # CORRECTION 2026-10-05. AREAS carried a hand-maintained filename list per
    # area, and it had gone badly stale: 02_AREA.B holds 39 .BIN files and only
    # 11 were listed, so the entire castle family (VB5A1, VB5AB, VB5B1..VB5CC,
    # VB5CG, VB5I0..VB5I4) was NEVER RENDERED. That -- not any renderer fault --
    # is why 262 perfectly good rooms had no image. The list is now derived from
    # the directory, so it cannot go stale again.
    # NOTE: this must run UNCONDITIONALLY. A first attempt put it inside the
    # `if not subs:` branch below, where it never executed when areas were named
    # on the command line -- which is how it is always invoked.
    for _k in list(AREAS.keys()):
        _folder = AREAS[_k][0]
        _found = sorted(os.path.basename(_f)[:-4] for _f in glob.glob(
            os.path.join(BASE, 'extracted/bin_overlays/DATA', _folder, '*.BIN')))
        if _found:
            AREAS[_k] = (_folder, _found)
    if not subs:
        subs = list(AREAS.keys())
    log_path = opts['log']
    records = []
    total = 0
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
    with open(log_path, 'w') as log:
        for sub in subs:
            if sub not in AREAS:
                print(f"Unknown: {sub}")
                continue
            area, names = AREAS[sub]
            outdir = os.path.join(opts['outdir'], sub)
            for name in names:
                path = os.path.join(BASE, 'extracted/bin_overlays/DATA', area, name + '.BIN')
                if not os.path.exists(path):
                    continue
                # A file too small to hold even the root pointer must be SKIPPED, not
                # allowed to abort the area. 13_AREA.I/I_DATA.BIN is a 2-byte stub and
                # its struct.error killed the whole 13I area, so VI1 and VI2 -- 171
                # rooms -- were never rendered. Discovered only because the
                # by-directory glob added that stub to the list; the old hand-written
                # list had contained just VI1 and VI2 and had hidden the crash.
                if os.path.getsize(path) < 16:
                    print(f"Skipping {area}/{name}.BIN (only {os.path.getsize(path)} bytes)")
                    continue
                print(f"Processing {area}/{name}.BIN ...")
                try:
                    n = process_file(path, outdir, log, area_key=sub, records=records)
                except Exception as ex:      # one bad file must not kill the area
                    print(f"  !! {type(ex).__name__}: {ex}")
                    continue
                print(f"  -> {n} rooms")
                total += n
    _write_sidecar(opts['sidecar'], records)
    print(f"\nTOTAL: {total} rooms re-rendered. Log: {log_path}")
    print(f"Status: {opts['sidecar']}")

if __name__ == '__main__':
    main()
