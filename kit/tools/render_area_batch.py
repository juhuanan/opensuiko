#!/usr/bin/env python3
"""Render area base layers with the engine's ordered atlas and tile palette tables.

Production reads header +08/+0c/+10/+14 (see area_tile_materials.py).
Legacy palette-scoring helpers remain available to historical probe tools;
production never falls back to appearance scoring when source data is invalid.
Invalid rooms produce a rejection sidecar, not a substitute image.
"""
import struct, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lzss
from disc_iso import lzss_decode_16k
from lzss import decode as lzss_decode, LZSSError
from PIL import Image
from area_tile_materials import load_room_materials, render_tilemap
from area_scene import compose_scene_image
from psx_vram import rgb555_to_rgb888

# --- status record (workstream M, 2026-10-04) ------------------------------
# Every room this tool processes gets a line in a sidecar JSONL, including the
# rooms it REJECTS, so a rejection is a recorded outcome rather than a missing
# file. `area_render_manifest.py` merges these sidecars into the manifest.
import hashlib, json

TOOL_NAME = 'render_area_batch.py'
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
    rec = {
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
    return rec


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
    """Scan for [u32 len][LZSS->16384B] streams. Returns list of (file_off, raw128)."""
    blobs = []
    n = len(data)
    off = 0
    while off < n - 8:
        clen = struct.unpack_from('<I', data, off)[0]
        # sanity: compressed len reasonable for 16KB output
        if 100 < clen < 16384 and off + 4 + clen <= n:
            raw = lzss_decode_16k(data[off+4:off+4+clen])
            if raw is not None:
                blobs.append((off, raw))
                off += 4 + clen
                # align to 4
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


def get_palette(data, ptab_off, f06):
    """Palette selection -- a HEURISTIC FALLBACK, not the engine's rule.

    Superseded 2026-10-04 by get_clut_palette(), which reads the selector the
    header actually carries. Retained for the case where that table is unusable,
    and because it is the record of what produced the pre-fix renders. Scores
    ptab entries 6-20 by (vivid, var) and prefers the f06-derived index only on a
    tie; it disagrees with the CLUT table in 734 of 760 rooms."""
    best = None
    best_score = (-1, -1)
    hint_idx = 12 + (f06 & 0xFF)
    if hint_idx < 6 or hint_idx > 20:
        hint_idx = None
    for i in range(6, 21):
        v = struct.unpack_from('<I', data, ptab_off + i*4)[0]
        po = v - RAM_BASE
        if not (0 <= po < len(data) - 512):
            continue
        colors = [struct.unpack_from('<H', data, po+j*2)[0] for j in range(256)]
        vivid = sum(1 for c in colors if c not in (0x0000, 0x8000))
        if vivid < 10:
            continue
        rs = [(c & 0x1F) for c in colors]
        gs = [((c>>5) & 0x1F) for c in colors]
        bs = [((c>>10) & 0x1F) for c in colors]
        var = (max(rs)-min(rs)) + (max(gs)-min(gs)) + (max(bs)-min(bs))
        # tie-break only: prefer the f06-derived index (a HYPOTHESIS)
        tie = 1 if i == hint_idx else 0
        score = (vivid, var, tie)
        if score > best_score:
            best_score = score
            pal = [rgb555_to_rgb888(c) for c in colors]
            best = (pal, po, i)
    if best:
        return best
    return None, None, None


def blob_spans(data, blobs):
    """(start, end) file spans of the [u32 comp_len][payload] of each blob."""
    spans = []
    for off, _raw in blobs:
        if off is None or off + 4 > len(data):
            continue
        clen = struct.unpack_from('<I', data, off)[0]
        spans.append((off, off + 4 + clen))
    return spans


def validate_tilemap(data, blobs, w, h, tm, size, check_blobs=True):
    """Reject a tilemap pointer/set that cannot name a real tilemap.

    Returns (ok, reason); reason is '' when ok. Rules:
      * halfword alignment (tile indices are u16);
      * the w*h*2-byte span fits inside the file;
      * the span must not overlap any compressed blob source span (tilemaps
        are stored uncompressed, so a pointer into LZSS payload is not one);
      * every tile index must resolve: index//64 < len(blobs). This is the
        n_blobs_needed check; without it a bogus pointer silently became a
        solid pal[0] image.
    """
    nbytes = w * h * 2
    if tm % 2:
        return False, 'tilemap pointer not halfword-aligned'
    if tm == -RAM_BASE:
        # The raw field was 0. Kept byte-identical to fix_palettes.py. This is
        # not a span problem: the header carries no tilemap A at all
        # (2026-10-04 -- duplicate/second-pass room records: f1c==1 for 70/72,
        # f04 & 0x1000==0 for 72/72). "span past end of file" sent readers after
        # a bounds bug that does not exist.
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

def render_room(data, blobs, pal, w, h, tm_off):
    """Legacy single-palette probe; production uses the per-tile table."""
    try:
        return render_tilemap(data, blobs, pal, w, h, tm_off)
    except IndexError as ex:
        raise ValueError(str(ex)) from ex


def process_file(path, outdir, area_key=None, records=None):
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
        print(f"  {base}: bad S pointer")
        rec(None, 'omitted', reason='bad S pointer')
        return 0
    t2 = struct.unpack_from('<I', data, S+4)[0] - RAM_BASE
    if not (0 <= t2 < size - 4):
        print(f"  {base}: bad table2 pointer")
        rec(None, 'omitted', reason='bad table2 pointer')
        return 0

    # Collect headers
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
            continue  # null/invalid entry
        w, h = struct.unpack_from('<HH', data, po)
        if w == 0 or h == 0 or w > 200 or h > 200:
            rec(i, 'omitted', reason='header slot with implausible w/h',
                raw_po=po, raw_w=w, raw_h=h)
            continue
        headers.append((i, po, w, h))

    if not headers:
        print(f"  {base}: no valid headers")
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
        out2 = os.path.join(outdir, f'{base}_h{i}_2x.png')
        img.save(out1)
        img.resize((img.width*2, img.height*2), Image.NEAREST).save(out2)
        print(f"    h{i} {w}x{h}: data-selected palettes {pal_rec['palette_offsets']} -> {out1}")
        rec(i, 'rendered', out1=out1, out2=out2, img=img, palette=pal_rec,
            composition=_composition_scope(scene_meta))
        count += 1
    return count

# (area folder, [bin names], output subdir) -- the tool's canonical target set.
TARGETS = [
    ('08_AREA.E', ['VE1','VE2','VE3','VE4','VE5','VE6'], '08E'),
    ('09_AREA.F', ['VF1','VF2','VF3','VF4'], '09F'),
    ('10_AREA.G', ['VG1','VG2','VG3'], '10G'),
    ('11_AREA.H', ['VH1','VH2'], '11H'),
    ('13_AREA.I', ['VI1','VI2'], '13I'),
    ('14_AREA.S', ['VS1','VS2'], '14S'),
    ('15_AREA.Z', ['VZ1','VZ2','VZ3','VZ5','VZ7','VZ8','VZV','VAC','VAD'], '15Z'),
]

DEFAULT_OUT_ROOT = os.path.join(BASE, 'work/area_tiles')


def _parse_args(argv):
    """--outdir ROOT   write renders under ROOT/<sub>/ (default: area_tiles)
       --sidecar PATH  status JSONL (default: ROOT/area_render_sidecar_<tool>)"""
    opts = {'outdir': DEFAULT_OUT_ROOT, 'sidecar': None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--scene':
            opts['scene'] = True; i += 1
        elif a == '--outdir' and i + 1 < len(argv):
            opts['outdir'] = argv[i+1]; i += 2
        elif a == '--sidecar' and i + 1 < len(argv):
            opts['sidecar'] = argv[i+1]; i += 2
        else:
            raise SystemExit('unknown argument: %s' % a)
    if opts['sidecar'] is None:
        opts['sidecar'] = os.path.join(
            opts['outdir'], 'area_render_sidecar_render_area_batch.jsonl')
    return opts


def main(argv=None):
    opts = _parse_args(list(sys.argv[1:] if argv is None else argv))
    files = TARGETS
    records = []
    total = 0
    for area, names, outsub in files:
        outdir = os.path.join(opts['outdir'], outsub)
        for name in names:
            path = os.path.join(BASE, 'extracted/bin_overlays/DATA', area, name + '.BIN')
            if not os.path.exists(path):
                print(f"{name}.BIN: MISSING")
                continue
            print(f"Processing {area}/{name}.BIN")
            total += process_file(path, outdir, area_key=outsub, records=records)
    _write_sidecar(opts['sidecar'], records)
    print(f"\nTOTAL: {total} rooms rendered. Status: {opts['sidecar']}")

if __name__ == '__main__':
    main()
