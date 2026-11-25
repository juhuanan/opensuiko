"""Area entity/spawn layer probe: do isolated blank cells mark placed objects?

Motivation
----------
`kit/docs/area_draw_coverage.md` rounds 14-15. Tile code 0 resolves to
atlas 0 / subtile 0, whose 256 indices are all zero -- a *solid* block of palette
index 0, which our renderer paints black. Corpus-wide, code-0 cells are dominated
by large connected blocks (the "empty space" pattern), but a minority are
isolated singletons. `VB6_h0` has four isolated singletons sitting in the middle
of a walkable field, which does not look like empty space.

This probe answers the open question with data rather than inference: **do
isolated-singleton code-0 cells coincide with entity spawn positions?**

Two things are deliberately separated:
  * `placed` entities -- the ones carrying a script pointer at +0x0c. Round 15
    observed that entries with coordinates are exactly the entries with a
    non-null +0x0c. That signature is asserted, not assumed, by
    `test_area_entity_probe.py`.
  * tile-0 singletons -- isolated code-0 cells.

Structures (see the door/entity chain in the corpus)
----------------------------------------------------
    S          = u32(data, 0)                 root pointer, RAM_BASE-relative
    table2     = u32(S + 4)                   section table, indexed by room +5
    room_table = u32(S + 8)                   16-byte room records
    record     = ent(u32 @+0) count(u16 @+4) section(u8 @+5) flags(u16 @+6)
    entity     = 24 bytes: X(u16 @+0) Y(u16 @+2) in HALF-TILES,
                 +4/+6 unknown, +0x0c/+0x10/+0x14 pointers

All offsets are file offsets into the area .BIN; RAM_BASE converts the on-disc
pointers, which are already absolute (0x80010000 + file_offset).

Static analysis only -- no emulator, no VRAM capture.
"""
import glob
import os
import struct
import sys

RAM_BASE = 0x80010000
RECORD_SIZE = 16
ENTITY_SIZE = 24
MAX_SANE_ENTITIES = 4096

# Entity class comes from the flags word, NOT from whether +0x0C is non-null.
# `sprite_placement.md` section 2.3 documents, with proving instructions:
#   +0x04 flags, +0x06 id, +0x0C -> 0x06-delimited byte-triple stream
#   flags & 0x60  -> walker entity
#   flags & 0x101 -> interaction/tile path (chests, doors, NPCs)
# The naive `+0x0C != 0` rule yielded 595,053 "placed" entities over 653 rooms
# (~911/room) and is refuted; flags is the documented discriminator.
FLAG_WALKER = 0x60
FLAG_INTERACT = 0x101

# `transition_triggers.md` section 2b: `tile_trigger_scan` range-checks the
# query point against the entry's coord bytes "with +/-1 tolerance windows".
# A trigger therefore covers a 3x3 TILE neighbourhood, so a singleton cell and a
# trigger one tile away are the same feature. 2 half-tiles == 1 tile.
TOLERANCE_TILES = 1
TOLERANCE_HALF = TOLERANCE_TILES * 2

# The room record's count is a u8 (lbu ...+4). Reading it as u16 produced the
# VB2.BIN record-8 anomaly of 0x1002 = 4098 -- the real count is 2.
MAX_ENTITIES = 255
MAX_CLASS_PER_ROOM = 64


def u16(data, off):
    return struct.unpack_from('<H', data, off)[0]


def u32(data, off):
    return struct.unpack_from('<I', data, off)[0]


def in_file(data, off, size=1):
    return 0 <= off and off + size <= len(data)


def to_file(data, ptr):
    """Absolute on-disc pointer -> file offset, or None if it is not in file."""
    if not (RAM_BASE <= ptr < RAM_BASE + len(data)):
        return None
    return ptr - RAM_BASE


def root(data):
    """File offset of the root structure, or None."""
    if not in_file(data, 0, 4):
        return None
    return to_file(data, u32(data, 0))


def table2(data):
    r = root(data)
    if r is None or not in_file(data, r + 4, 4):
        return None
    return to_file(data, u32(data, r + 4))


def room_table(data):
    r = root(data)
    if r is None or not in_file(data, r + 8, 4):
        return None
    return to_file(data, u32(data, r + 8))


def _valid_ptr(data, off):
    if not in_file(data, off, 4):
        return None
    return to_file(data, u32(data, off))


def section_off(data, index):
    """File offset of section `index`, or None if that slot is not populated.

    NOTE: these tables have *holes* -- VB5 populates slots 0, 14, 15, 16, 18, ...
    so a contiguous "count until the first null" is wrong and silently discards
    most of a file's rooms. Always test a slot for validity; never assume
    contiguity. This was a real bug in the first cut of this probe.
    """
    t2 = table2(data)
    if t2 is None or index < 0:
        return None
    return _valid_ptr(data, t2 + 4 * index)


def section_table_span(data, window=96):
    """Highest populated table2 slot + 1, scanning a bounded window."""
    t2 = table2(data)
    if t2 is None:
        return 0
    high = -1
    for i in range(window):
        if _valid_ptr(data, t2 + 4 * i) is not None:
            high = i
    return high + 1


def room_source_bound(data):
    """A following text-root object bounds candidates, not selectable rooms."""
    start = room_table(data)
    header = root(data)
    text = None
    if header is not None and header + 24 <= len(data):
        text = to_file(data, struct.unpack_from('<I', data, header + 20)[0])
    if text is not None and not in_file(data, text, 4):
        text = None
    end = text if start is not None and text is not None and text > start else None
    return {'start': start, 'upper_bound': end,
            'basis': 'following text-root object' if end is not None else 'unresolved'}


def room_records(data):
    """Yield dicts for room records whose section index is actually populated.

    A following text-root object supplies a physical upper bound. Otherwise
    the historical 64-record/section-validity probe remains heuristic; neither
    this cap nor a run of gaps proves the set of selectable rooms.
    """
    rt = room_table(data)
    if rt is None:
        return []
    out = []
    bound = room_source_bound(data)['upper_bound']
    gaps = 0
    for i in range(64):
        off = rt + i * RECORD_SIZE
        if bound is not None and off + RECORD_SIZE > bound:
            break
        if not in_file(data, off, RECORD_SIZE):
            break
        ent = u32(data, off)
        count = data[off + 4]              # u8 -- documented, see module docstring
        section = data[off + 5]
        flags = u16(data, off + 6)
        # Screen candidates using populated section slots. Sparse holes are
        # skipped; four gaps cannot terminate a known physical interval.
        if section_off(data, section) is None:
            gaps += 1
            if gaps >= 4 and bound is None:
                break
            continue
        gaps = 0
        out.append({
            'index': i, 'record_off': off, 'ent_ptr': ent,
            'ent_off': to_file(data, ent), 'count': count,
            'section': section, 'flags': flags,
        })
    return out


def room_dims(data, sec):
    """(w, h) in 16-pixel tiles."""
    if sec is None or not in_file(data, sec, 4):
        return None
    return u16(data, sec), u16(data, sec + 2)


def entities(data, rec):
    """Decode a room's entity array. Returns [] if the array is unusable."""
    off, count = rec['ent_off'], rec['count']
    if off is None or count > MAX_ENTITIES:
        return []
    out = []
    for k in range(count):
        o = off + k * ENTITY_SIZE
        if not in_file(data, o, ENTITY_SIZE):
            break
        ptrs = [u32(data, o + 0x0c), u32(data, o + 0x10), u32(data, o + 0x14)]
        flags = u16(data, o + 4)
        out.append({
            'index': k, 'off': o,
            'x_half': u16(data, o + 0), 'y_half': u16(data, o + 2),
            'flags': flags,
            'id': u16(data, o + 6),
            'stream_ptr': ptrs[0],
            'stream_off': to_file(data, ptrs[0]),
            'ptr_b': ptrs[1], 'ptr_c': ptrs[2],
            'walker': bool(flags & FLAG_WALKER),
            'interactive': bool(flags & FLAG_INTERACT),
        })
    return out


def entity_layer_ok(data, rec, dims=None):
    """Is this room's entity decode trustworthy enough to correlate?

    Two guards, both derived from measurements rather than assumption:
      * a room cannot hold more than MAX_PLACED_PER_ROOM placed entities;
      * a placed entity's half-tile coordinates should land inside the room
        (room is 2*w x 2*h half-tiles), so most placed entries must be in range.
    A room failing either is reported unusable instead of adding garbage.
    """
    ents = entities(data, rec)
    if not ents:
        return False, 'no entities'
    if len(ents) > MAX_ENTITIES:
        return False, 'entity count %d exceeds u8' % len(ents)
    live = [e for e in ents if e['walker'] or e['interactive']]
    if len(live) > MAX_CLASS_PER_ROOM:
        return False, 'implausible live count %d' % len(live)
    if not live:
        return True, 'no placed entities'
    if dims is None:
        return True, 'unbounded'
    w, h = dims
    inside = sum(1 for e in live
                 if 0 <= e['x_half'] <= 2 * w and 0 <= e['y_half'] <= 2 * h)
    if inside * 2 < len(live):
        return False, 'only %d/%d placed in room bounds' % (inside, len(live))
    return True, 'ok'


def tilemap_cells(data, sec):
    """The section's u16 tilemap as (w, h, tuple of codes), or None."""
    dims = room_dims(data, sec)
    if dims is None:
        return None
    w, h = dims
    if not (1 <= w <= 200 and 1 <= h <= 200):
        return None
    tm_ptr = u32(data, sec + 0x14)
    tm = to_file(data, tm_ptr)
    if tm is None or not in_file(data, tm, w * h * 2):
        return None
    return w, h, struct.unpack_from('<%dH' % (w * h), data, tm)


def components(cells):
    """Connected components (4-neighbour) of a set of (col,row). Sizes, desc."""
    cells = set(cells)
    seen, comps = set(), []
    for cell in sorted(cells):
        if cell in seen:
            continue
        stack, comp = [cell], []
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            comp.append(cur)
            c, r = cur
            for nb in ((c + 1, r), (c - 1, r), (c, r + 1), (c, r - 1)):
                if nb in cells and nb not in seen:
                    stack.append(nb)
        comps.append(comp)
    return comps


def code0_singletons(data, sec):
    """Isolated (col,row) cells whose tile code is 0, plus room dims."""
    got = tilemap_cells(data, sec)
    if got is None:
        return None
    w, h, tiles = got
    zero = [(k % w, k // w) for k, t in enumerate(tiles) if t == 0]
    if not zero:
        return {'w': w, 'h': h, 'zero': 0, 'singletons': [], 'components': []}
    comps = components(zero)
    singles = [c[0] for c in comps if len(c) == 1]
    return {'w': w, 'h': h, 'zero': len(zero), 'singletons': singles,
            'components': [len(c) for c in comps]}


def correlate_room(data, rec, tolerance_tiles=TOLERANCE_TILES):
    """Match a room's interactive triggers against its isolated code-0 cells.

    Matching uses the documented +/-1 tile tolerance window, so a trigger one
    tile from a cell counts as the same feature; `hits_strict` also reports the
    stricter same-cell reading for contrast. Rooms whose trigger layer fails
    `entity_layer_ok` report `layer_ok: False` and contribute no hits -- a broken
    decode must not masquerade as a negative result.
    """
    sec = section_off(data, rec['section'])
    dims = room_dims(data, sec)
    info = code0_singletons(data, sec)
    ok, why = entity_layer_ok(data, rec, dims)
    if info is None:
        return None
    ents = entities(data, rec)
    tol = tolerance_tiles * 2
    placed = [e for e in ents if (e['walker'] or e['interactive']) and ok]
    hits, misses = [], []
    strict = 0
    for cell in info['singletons']:
        c, r = cell
        cx, cy = c * 2 + 1, r * 2 + 1
        within = [e for e in placed
                  if abs(e['x_half'] - cx) <= tol and abs(e['y_half'] - cy) <= tol]
        inside = [e for e in within
                  if c * 2 <= e['x_half'] < c * 2 + 2 and r * 2 <= e['y_half'] < r * 2 + 2]
        if inside:
            strict += 1
        (hits if within else misses).append((cell, within))
    return {
        'section': rec['section'], 'w': info['w'], 'h': info['h'],
        'zero': info['zero'], 'singletons': len(info['singletons']),
        'layer_ok': ok, 'layer_note': why,
        'placed': len(placed), 'entities': len(ents),
        'hits': len(hits), 'hits_strict': strict, 'misses': len(misses),
        'tolerance_tiles': tolerance_tiles,
        'detail': [(c, [(e['id'], e['x_half'], e['y_half']) for e in f]) for c, f in hits],
        'miss_detail': [c for c, _ in misses],
    }


def probe_file(path, only_room=None):
    with open(path, 'rb') as fh:
        data = fh.read()
    out = []
    for rec in room_records(data):
        if only_room is not None and rec['index'] != only_room:
            continue
        r = correlate_room(data, rec)
        if r is not None:
            r['file'] = os.path.basename(path)
            out.append(r)
    return out


def default_files():
    here = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(os.path.dirname(here))
    return sorted(glob.glob(os.path.join(
        root_dir, 'kit', 'extracted', 'bin_overlays', 'DATA', '*', 'V*.BIN')))


def _main(argv):
    import json
    if len(argv) >= 2 and argv[1] == 'room':
        path = argv[2]
        only = int(argv[3]) if len(argv) > 3 else None
        for r in probe_file(path, only):
            print(json.dumps(r, indent=2))
        return 0
    if len(argv) >= 2 and argv[1] == 'correlate':
        files = argv[2:] or default_files()
        rooms = rooms_with_sing = usable = unusable = 0
        tot_s = tot_hit = 0
        s_usable = hit_usable = 0
        for path in files:
            for r in probe_file(path):
                rooms += 1
                if r['layer_ok']:
                    usable += 1
                else:
                    unusable += 1
                if r['singletons']:
                    rooms_with_sing += 1
                    tot_s += r['singletons']
                    tot_hit += r['hits']
                    if r['layer_ok']:
                        s_usable += r['singletons']
                        hit_usable += r['hits']
        print('rooms probed                  : %d' % rooms)
        print('  entity layer usable         : %d' % usable)
        print('  entity layer UNUSABLE       : %d  (decode rejected, not counted)' % unusable)
        print('rooms with singleton cells    : %d' % rooms_with_sing)
        print('singleton code-0 cells (all)  : %d' % tot_s)
        print('  matched by a placed entity  : %d (%.1f%%)'
              % (tot_hit, 100.0 * tot_hit / max(1, tot_s)))
        print('singleton cells in USABLE rooms: %d' % s_usable)
        print('  matched within +/-1 tile    : %d (%.1f%%)  <-- documented window'
              % (hit_usable, 100.0 * hit_usable / max(1, s_usable)))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(_main(sys.argv))
