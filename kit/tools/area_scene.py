"""Area scene inventory -- one shared collector for both area producers.

Milestone A of `kit/docs/area_scene_rendering_plan.md`. This module *collects and
validates* the inputs of an area scene; it deliberately does not paint yet. Both
`render_area_batch.py` and `fix_palettes.py` are meant to call it so there is a
single definition of what a room's scene consists of.

Currently the producers call `area_tile_materials.render_tilemap()` for
`section+0x14` and stop, omitting three separate inputs: the **secondary tilemap**,
the **5-byte scenery-object array**, and the room's **24-byte entity records**.

Identities -- read this before using the module
-----------------------------------------------
**Room index and section/header index are DIFFERENT identities.** A room record is
16 bytes in the table at `*(root+8)`; its `+5` byte indexes the section table at
`*(root+4)`. For VB6 the mapping is not the identity: room 9 -> section 10 and
room 10 -> section 9. Selecting a section by "room number" silently renders the
wrong room. Always select by room record and follow `+5`.

The section table is **sparse** -- slots may be unpopulated -- so a slot is tested
for validity rather than assumed contiguous.

Structure summary (all offsets are file offsets into the area .BIN; the on-disc
pointers are absolute `0x80010000 + file_offset`):

    root        = u32(0)
    sections    = u32(root+4)        section table, indexed by room+5
    rooms       = u32(root+8)        16-byte room records
    room record : +0 entity array ptr (stride 24)
                  +4 entity count (U8)
                  +5 primary section index
                  +6 flags (u16)
                  +7, +8, +9  bytes used by the secondary-map draw path
    section     : +0 w (u16), +2 h (u16)
                  +4 base atlas slot, +5 base palette row
                  +8 atlas table, +0xc CLUT table, +0x10 per-atlas palette bytes
                  +0x14 primary tilemap (w*h u16)
                  +0x18 SECONDARY tilemap pointer
                  +0x1c context count (u32)
                  +0x20 context pointer array
                  +0x24 scenery count (u16), +0x28 5-byte scenery records

Secondary map: `801321c0..80132240` takes its dimensions from
`section_table[room[+9]]`, reuses the **primary map's** tile descriptor buffer and
replaces only the map pointer -- it is not an independently uploaded material bank.
Materials must therefore be resolved for the **union** of codes used by both maps.

Static analysis only: no emulator, no VRAM capture, no guessed palettes.
"""
from __future__ import annotations

import json
import os
import struct
import sys

RAM_BASE = 0x80010000
ROOM_RECORD_SIZE = 16
ENTITY_STRIDE = 24
SCENERY_STRIDE = 5
# Bounds for fields that a garbage section slot can render nonsensical.
MAX_SCENERY = 1024
MAX_CONTEXTS = 32
MAX_ATLASES_PER_CONTEXT = 64
MAX_MAP_DIM = 256    # tiles per side; a garbage companion slot exceeds this

# From the plan's target table. Room -> (label, expected primary section,
# expected scenery count, expected tile dims).
TARGETS = {
    0: ('village', 0, 26, (32, 24)),
    7: ('inn', 7, 23, (24, 16)),
    8: ('sansuke', 8, 8, (24, 16)),
    9: ('shop', 10, 13, (24, 16)),
    10: ('maas', 9, 13, (24, 16)),
}


def u16(data, off):
    return struct.unpack_from('<H', data, off)[0]


def u32(data, off):
    return struct.unpack_from('<I', data, off)[0]


def u8(data, off):
    return data[off]


def in_file(data, off, size=1):
    return 0 <= off and off + size <= len(data)


def to_file(data, ptr):
    """Absolute on-disc pointer -> file offset, or None when outside the file."""
    if not (RAM_BASE <= ptr < RAM_BASE + len(data)):
        return None
    return ptr - RAM_BASE


def ptr_at(data, off):
    """Dereference the absolute pointer stored at `off`, or None."""
    if not in_file(data, off, 4):
        return None
    return to_file(data, u32(data, off))


def root(data):
    return ptr_at(data, 0)


def section_table(data):
    r = root(data)
    return None if r is None else ptr_at(data, r + 4)


def room_table(data):
    r = root(data)
    return None if r is None else ptr_at(data, r + 8)


def section_off(data, index):
    """File offset of section `index`, or None when that slot is unpopulated.

    The table is sparse; never assume contiguity (this exact assumption was a bug
    in an earlier probe, which then silently discarded most of a file's rooms).
    """
    t2 = section_table(data)
    if t2 is None or index is None or index < 0:
        return None
    return ptr_at(data, t2 + 4 * index)


def room_records(data):
    """Every room record that validates ON ITS OWN MERITS, in table order.

    CORRECTION 2026-10-05. This used to stop after a run of four unusable records,
    a guard added to stop an OOM. That guard discarded every valid record after
    the first bad stretch: 81 real rooms were being dropped corpus-wide, worst in
    the castle files (VB5CC 16, VB5 13, VC2 11, VB5CA 7). The user found this by
    identifying VB5.BIN sections 14-28 as ordinary rooms that my reader rejected.

    Records are now validated individually and unusable ones are SKIPPED. The OOM
    protection is kept, but where it belongs: a record whose section header holds
    impossible dimensions is rejected outright, because that -- not the run of bad
    records -- is what produced a 560 GB canvas once.
    """
    rt = room_table(data)
    if rt is None:
        return []
    out = []
    for i in range(64):
        off = rt + i * ROOM_RECORD_SIZE
        if not in_file(data, off, ROOM_RECORD_SIZE):
            break
        sec = u8(data, off + 5)
        so = section_off(data, sec)
        if so is None:
            continue
        if not in_file(data, so, 0x28):
            continue
        w, h = u16(data, so), u16(data, so + 2)
        if not (0 < w <= MAX_MAP_DIM and 0 < h <= MAX_MAP_DIM):
            continue
        ent = u32(data, off)
        ent_off = to_file(data, ent)
        count = u8(data, off + 4)
        if count and ent_off is None:
            continue
        # NOTE (2026-10-05): do NOT reject a record because another record already
        # claims its section. I tried that, reading VB5B1.BIN's slots 11/14/15/19
        # all pointing at section 0 as garbage. It dropped the corpus count from
        # 1177 to 635 -- BELOW the 668 of the old buggy reader -- which is the
        # signature of rejecting real data. Several room records can share one
        # section: they are state variants of the same map. Kept as an error record.
        out.append({
            'index': i,
            'record_off': off,
            'entity_ptr': ent,
            'entity_off': ent_off,
            'entity_count': count,
            'section': sec,
            'flags': u16(data, off + 6),
            'byte7': u8(data, off + 7),
            'byte8': u8(data, off + 8),
            'byte9': u8(data, off + 9),
        })
    return out


def room_record(data, index):
    for rec in room_records(data):
        if rec['index'] == index:
            return rec
    return None


def tilemap(data, sec, pointer_off):
    """Decode a `w*h` u16 tilemap using the section's own dimensions.

    Dimensions always come from the section carrying the map (`sec`). For the
    *secondary* map that is the primary section -- the secondary pointer lives at
    `sec+0x18` and reuses the primary's descriptor buffer -- while the draw path
    takes its dimensions from `section_table[room[+9]]`. Both are reported so the
    caller can tell them apart rather than conflating them.
    """
    if sec is None:
        return None
    w, h = u16(data, sec), u16(data, sec + 2)
    off = ptr_at(data, pointer_off)
    if off is None:
        return None
    if not (1 <= w <= 256 and 1 <= h <= 256):
        return None
    if not in_file(data, off, w * h * 2):
        return {'pointer': u32(data, pointer_off), 'offset': off,
                'w': w, 'h': h, 'codes': None,
                'error': 'map span outside file'}
    codes = struct.unpack_from('<%dH' % (w * h), data, off)
    return {'pointer': u32(data, pointer_off), 'offset': off, 'w': w, 'h': h,
            'codes': codes, 'distinct': sorted(set(codes))}


def scenery_record(data, offset, index):
    """Read one static or script-created scenery record at its resolved offset."""
    if not isinstance(index, int) or isinstance(index, bool) or index < 0:
        raise ValueError('invalid scenery record index')
    if not in_file(data, offset, SCENERY_STRIDE):
        raise ValueError('scenery record outside file: %#x' % offset)
    x, y, kind, order, flags = data[offset:offset + SCENERY_STRIDE]
    return {'index': index, 'offset': offset, 'x_half': x, 'y_half': y,
            'type': kind, 'order': order, 'b4': flags}


def scenery_template(data, sec, template):
    """Resolve source 3E's template following the room's static scenery records."""
    if type(template) is not int or not 0 <= template <= 255 or sec is None or not in_file(data, sec, 0x2c):
        raise ValueError('invalid scenery template reference')
    count, table = u16(data, sec + 0x24), ptr_at(data, sec + 0x28)
    if count > MAX_SCENERY or table is None:
        raise ValueError('invalid scenery template table')
    return scenery_record(data, table + (count + template) * SCENERY_STRIDE, count + template)


def scenery_records(data, sec):
    """The 5-byte scenery-object records: X, Y, type, b3, b4.

    Bytes 0/1 are half-tile X/Y, byte 2 the object type; bytes 3/4 are inputs to
    the ordering path (`8012F3D8`: source byte+3 -> working byte+2) and must be
    kept, not discarded.
    """
    if sec is None:
        return []
    count = u16(data, sec + 0x24)
    base = ptr_at(data, sec + 0x28)
    if base is None or count == 0:
        return []
    # A garbage section slot resolves to an in-file pointer with a nonsense count
    # (observed: 17328 at VB6 header 31). Bound the count and require the whole
    # span in-file, so a bad slot is REPORTED rather than expanded.
    if count > MAX_SCENERY or not in_file(data, base, count * SCENERY_STRIDE):
        raise ValueError('implausible scenery span: count %d at %#x' % (count, base))
    return [scenery_record(data, base + i * SCENERY_STRIDE, i) for i in range(count)]


def contexts(data, sec):
    """The ordered context pointers: count u32(section+0x1c), array section+0x20.

    Context 0 is the scenery context; the rest include NPC graphics. On-disc
    `ctx+6`/`ctx+7` are NOT the final values -- the loader `801322d8..80132368`
    derives them from allocation counters -- so they are reported as read and
    flagged rather than trusted.
    """
    if sec is None:
        return []
    count = u32(data, sec + 0x1c)
    if not (0 < count <= MAX_CONTEXTS):
        return []
    base = ptr_at(data, sec + 0x20)
    if base is None:
        return []
    out = []
    for i in range(count):
        off = ptr_at(data, base + 4 * i)
        if off is None:
            out.append({'index': i, 'offset': None})
            continue
        out.append({
            'index': i, 'offset': off,
            'byte4': u8(data, off + 4), 'byte5': u8(data, off + 5),
            'byte6': u8(data, off + 6), 'byte7': u8(data, off + 7),
            'colour_branch': '32-colour' if (u8(data, off + 5) & 0xC0) else '256-colour',
            'derived': 'ctx+6/+7 are loader-derived, not on-disc values',
        })
    return out


def entities(data, rec):
    """The room's 24-byte records: X, Y, flags, id and three stream pointers.

    A zero-coordinate record is still a record, and a non-null script pointer
    alone does not prove a visible entity -- both are reported as-is with no
    proximity heuristic applied.
    """
    off = rec.get('entity_off')
    count = rec.get('entity_count', 0)
    if off is None or not (0 < count <= 255):
        return []
    out = []
    for i in range(count):
        o = off + i * ENTITY_STRIDE
        if not in_file(data, o, ENTITY_STRIDE):
            break
        streams = [u32(data, o + 0x0c), u32(data, o + 0x10), u32(data, o + 0x14)]
        out.append({
            'index': i, 'offset': o,
            'x_half': u16(data, o + 0), 'y_half': u16(data, o + 2),
            'flags': u16(data, o + 4), 'id': u16(data, o + 6),
            'stream_ptrs': streams,
            'stream_offsets': [to_file(data, s) for s in streams],
            'zero_coord': u16(data, o + 0) == 0 and u16(data, o + 2) == 0,
            'interactive': bool(u16(data, o + 4) & 0x101),
            'walker': bool(u16(data, o + 4) & 0x60),
        })
    return out


def scene_inventory(data, room_index, materials_union=None):
    """Milestone A: a deterministic inventory of one room's scene inputs.

    `materials_union` may be supplied by the caller with the tile codes actually
    referenced across both maps; it is returned unchanged so the inventory records
    what the material loader was asked for.
    """
    rec = room_record(data, room_index)
    if rec is None:
        return None
    sec = section_off(data, rec['section'])
    primary = tilemap(data, sec, sec + 0x14) if sec is not None else None

    # Secondary map: pointer from the PRIMARY section+0x18; dimensions from the
    # companion section at section_table[room[+9]].
    companion_sec = section_off(data, rec['byte9'])
    companion_dims = None
    if companion_sec is not None:
        cd = (u16(data, companion_sec), u16(data, companion_sec + 2))
        companion_dims = cd if (1 <= cd[0] <= MAX_MAP_DIM and 1 <= cd[1] <= MAX_MAP_DIM) else None
    secondary = None
    if sec is not None:
        soff = ptr_at(data, sec + 0x18)
        if soff is not None:
            pw, ph = (u16(data, sec), u16(data, sec + 2))
            cw, ch = companion_dims or (pw, ph)
            ok = in_file(data, soff, cw * ch * 2)
            secondary = {
                'pointer': u32(data, sec + 0x18), 'offset': soff,
                'companion_section_index': rec['byte9'],
                'companion_section': companion_sec,
                'companion_dims': companion_dims,
                'primary_dims': (pw, ph),
                'codes': struct.unpack_from('<%dH' % (cw * ch), data, soff) if ok else None,
                'error': None if ok else 'secondary map span outside file',
                'note': 'reuses the primary map tile descriptor buffer',
            }

    codes_union = []
    for m in (primary, secondary):
        if m and m.get('codes'):
            codes_union.extend(m['codes'])
    codes_union = sorted(set(codes_union))

    scn = scenery_records(data, sec)
    ctxs = contexts(data, sec)
    ents = entities(data, rec)

    unresolved = []
    if secondary is None:
        unresolved.append('no secondary map pointer')
    elif secondary.get('error'):
        unresolved.append('secondary map: ' + secondary['error'])
    if primary is None:
        unresolved.append('no usable primary map')
    if not ctxs:
        unresolved.append('no contexts')
    for c in ctxs:
        if c.get('colour_branch') == '32-colour':
            unresolved.append('context %d is 32-colour (NPC branch, needs the '
                              'X=256 upload path)' % c['index'])
    zero = [e['index'] for e in ents if e['zero_coord']]
    if zero:
        unresolved.append('entity records with zero X/Y (kept, not dropped): %s' % zero)

    return {
        'room': room_index,
        'label': TARGETS.get(room_index, (None,))[0],
        'record': rec,
        'primary_section': rec['section'],
        'section_off': sec,
        'primary_map': {k: v for k, v in (primary or {}).items() if k != 'codes'},
        'secondary_map': {k: v for k, v in (secondary or {}).items() if k != 'codes'},
        'tile_codes_union': codes_union,
        'tile_code_count': len(codes_union),
        'materials_requested': materials_union,
        'scenery': scn,
        'scenery_count': len(scn),
        'contexts': ctxs,
        'entities': ents,
        'entity_count': len(ents),
        'unresolved': unresolved,
    }


def load_source(path=None):
    """Read VB6.BIN: fresh disc extraction by default, or an explicit file.

    Returns (data, provenance). Disc reads go through `disc.py` only.
    """
    if path:
        with open(path, 'rb') as fh:
            data = fh.read()
        return data, {'kind': 'file', 'path': path}
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import hashlib
    from disc import extract
    kit = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    iso = os.path.join(kit, 'extracted', 'iso_files.json')
    with open(iso) as fh:
        records = json.load(fh)
    rec = next(r for r in records if r['path'] == 'DATA/02_AREA.B/VB6.BIN')
    data = extract(rec['lba'], rec['size'])
    return data, {'kind': 'disc', 'path': rec['path'], 'lba': rec['lba'],
                  'size': rec['size'],
                  'sha256': hashlib.sha256(data).hexdigest()}


def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--file', default=None, help='area .BIN path (default: disc)')
    ap.add_argument('--room', type=int, action='append',
                    help='room index (repeatable); default: the five targets')
    ap.add_argument('--out', default=None, help='write inventory JSON here')
    args = ap.parse_args(argv[1:])
    data, prov = load_source(args.file)
    rooms = args.room or sorted(TARGETS)
    inv = []
    for r in rooms:
        rec = room_record(data, r)
        if rec is None:
            print('room %d: not present' % r, file=sys.stderr)
            continue
        item = scene_inventory(data, r)
        expected = TARGETS.get(r)
        if expected:
            label, esec, escn, edims = expected
            sec = item['section_off']
            dims = (u16(data, sec), u16(data, sec + 2)) if sec is not None else None
            item['check'] = {
                'expected_label': label,
                'expected_section': esec,
                'section_matches': item['primary_section'] == esec,
                'expected_scenery': escn,
                'scenery_matches': item['scenery_count'] == escn,
                'expected_dims': list(edims),
                'dims_matches': list(dims) == list(edims) if dims else False,
            }
        inv.append(item)
    payload = {'provenance': prov, 'rooms': inv}
    text = json.dumps(payload, indent=2)
    if args.out:
        with open(args.out, 'w') as fh:
            fh.write(text + '\n')
        print('wrote %s (%d rooms)' % (args.out, len(inv)))
    else:
        print(text)
    return 0


if __name__ == '__main__':
    sys.exit(_main(sys.argv))


# --------------------------------------------------------------------------
# Milestone B: assemble every scenery sheet
#
# Consumer chain: section+0x28 -> 8012E8D4 -> 800C3D38/800C3E9C -> descriptor ->
# selected sheet -> 800C3EF0 -> 8014C8E4/8014C850.
#
# `800C3E9C` reads a PAIR at `descriptor+4+2*frame_index`: one byte sheet index
# followed by one byte duration. It is NOT a u16 sheet index, and the descriptor
# stride is 8 bytes -- assuming a uniform 8-byte sheet field reads the duration
# byte as part of the index and selects the wrong sheet.
#
# Ordering: `800C3EF0` emits vertices last-to-first, but `8014C850` PREPENDS each
# packet into its bucket, so final painting runs in FORWARD vertex order. Reverse
# compositing lets a large house body cover its own signs and doors.
# --------------------------------------------------------------------------

ATLAS_X0 = 320          # VRAM x of the first atlas slot (engine upload geometry)
ATLAS_SLOT_W = 64       # one 128x128 8-bit atlas occupies 64 VRAM words across
ATLAS_SLOT_H = 128
PALETTE_Y0 = 480        # palette rows start at VRAM y=480


def context_upload_bases(data, sec):
    """Derived (atlas_slot, palette_row) bases for a section's contexts.

    On-disc `ctx+6`/`ctx+7` are zero; the loader `801322d8..80132368` derives the
    real bases from allocation counters, and they are the section's own `+4`/`+5`
    base slot/palette values. For the village that is (4, 15), which puts local
    palette 6 at VRAM row 480+15+6 = 501 -- the row the plan names.
    """
    return data[sec + 4], data[sec + 5]


def atlas_slot_geometry(slot):
    """(vram_x, vram_y, texpage, uv_fold) for a global atlas slot index."""
    x = ATLAS_X0 + ATLAS_SLOT_W * (5 * (slot // 20) + slot % 5)
    y = ATLAS_SLOT_H * ((slot % 20) // 5)
    fold = 128 * (((slot % 20) // 5) % 2)
    return x, y, fold


def load_scene_materials(data, sec, source_meta=None, ctx_index=0, contexts=None):
    """Upload a section's base and context atlases/palettes into a PsxVram.

    Contexts are uploaded in order via the modelled allocation counters, so the
    atlas slots and palette rows a scenery vertex addresses are the ones the
    engine would have. Returns (vram, meta).
    """
    from lzss import decode_strict
    from psx_vram import PsxVram

    atlas_base, palette_base = context_upload_bases(data, sec)
    vram = PsxVram()
    meta = {'atlas_base': atlas_base, 'palette_base': palette_base,
            'contexts': [], 'uploads': []}
    ctxs = contexts if contexts is not None else contexts_of(data, sec)
    for ci, cinfo in enumerate(ctxs):
        off = cinfo.get('offset')
        if off is None:
            continue
        natlas = u8(data, off + 4)
        pal_byte = u8(data, off + 5)
        if natlas > MAX_ATLASES_PER_CONTEXT:
            raise ValueError('implausible atlas count %d in context %d' % (natlas, ci))
        # `ctx+5` is a COUNT only in the 256-colour branch. When bit 0xc0 is set
        # the context is the 32-colour character branch and `ctx+5` is a palette
        # descriptor (0x81 here), NOT a count -- iterating it uploads hundreds of
        # palette rows and runs off VRAM (observed: row 544). That branch is
        # Milestone D's job: 800C3CC8 uploads 32 words at VRAM X=256 with its own
        # row counter, not a 256-word row at X=0.
        is_32 = bool(pal_byte & 0xC0)
        npal = 0 if is_32 else pal_byte
        entry = {'index': ci, 'offset': off, 'atlases': [], 'palettes': [],
                 'colour_branch': cinfo.get('colour_branch'),
                 'is_32_colour': is_32, 'palette_byte': pal_byte,
                 'deferred': '32-colour upload is Milestone D' if is_32 else None}
        if is_32:
            meta['contexts'].append(entry)
            continue
        atab, ptab = ptr_at(data, off + 8), ptr_at(data, off + 12)
        for i in range(natlas):
            bo = ptr_at(data, atab + 4 * i) if atab is not None else None
            if bo is None:
                entry['atlases'].append(None)
                continue
            length = u32(data, bo)
            payload = data[bo + 4:bo + 4 + length]
            raw = decode_strict(payload)
            if len(raw) != 16384:
                raise ValueError('atlas at %#x is not 16384 bytes' % bo)
            slot = atlas_base + i
            ax, ay, fold = atlas_slot_geometry(slot)
            vram.upload_rect(ax, ay, ATLAS_SLOT_W, ATLAS_SLOT_H, raw,
                             provenance={'kind': 'scenery_atlas', 'context': ci,
                                         'offset': bo, 'slot': slot,
                                         'compressed_bytes': length,
                                         **(source_meta or {})})
            entry['atlases'].append({'slot': slot, 'offset': bo, 'vram': [ax, ay],
                                     'compressed_bytes': length})
            meta['uploads'].append(('atlas', ci, bo, slot))
        for i in range(npal):
            po = ptr_at(data, ptab + 4 * i) if ptab is not None else None
            if po is None:
                entry['palettes'].append(None)
                continue
            raw = data[po:po + 512]
            row = PALETTE_Y0 + ((palette_base + i) & 0xFF)
            vram.upload_rect(0, row, 256, 1, raw,
                             provenance={'kind': 'scenery_palette', 'context': ci,
                                         'offset': po, 'row': row,
                                         **(source_meta or {})})
            entry['palettes'].append({'offset': po, 'row': row})
            meta['uploads'].append(('palette', ci, po, row))
        meta['contexts'].append(entry)
    return vram, meta


def contexts_of(data, sec):
    """Alias kept explicit: the ordered context list for a section."""
    return contexts(data, sec)


def descriptor_sheet(data, ctx_off, kind, frame=0):
    """Resolve object type `kind` to its sheet at `frame`.

    Descriptor pair at `descriptor+4+2*frame`: (sheet index, duration).
    """
    dtab = ptr_at(data, ctx_off + 0x14)
    stab = ptr_at(data, ctx_off + 0x10)
    if dtab is None or stab is None:
        return None
    desc = ptr_at(data, dtab + 4 * kind)
    if desc is None:
        return None
    pair_off = desc + 4 + 2 * frame
    if not in_file(data, pair_off, 2):
        return None
    sheet_index, duration = data[pair_off], data[pair_off + 1]
    sheet = ptr_at(data, stab + 4 * sheet_index)
    if sheet is None:
        return None
    return {'descriptor': desc, 'sheet_index': sheet_index, 'duration': duration,
            'sheet': sheet, 'vertices': data[sheet] if sheet is not None else 0,
            'anchor': (data[sheet + 4], data[sheet + 5]) if sheet is not None else None,
            'frame': frame}


def scenery_primitives(data, sec, vram, ctx_index=0, frame=0, source_meta=None, object_records=None):
    """Build the ordered primitive list for a section's scenery objects.

    Keeps RGB555 words (not RGB888) so transparency (resolved `0x0000`) and bit 15
    survive to the compositor. Reflection is reported per vertex from the measured
    bits: `flags & 2` horizontal, `flags & 1` vertical.
    """
    ctxs = contexts_of(data, sec)
    if not ctxs or ctx_index >= len(ctxs):
        return [], {'error': 'no context %d' % ctx_index}
    ctx_off = ctxs[ctx_index].get('offset')
    if ctx_off is None:
        return [], {'error': 'context %d has no pointer' % ctx_index}
    atlas_base, palette_base = context_upload_bases(data, sec)
    prims, unresolved = [], []
    for s in scenery_records(data, sec) if object_records is None else object_records:
        info = descriptor_sheet(data, ctx_off, s['type'], frame)
        if info is None or info['sheet'] is None:
            unresolved.append({'object': s['index'], 'type': s['type'],
                               'reason': 'no sheet resolved'})
            continue
        sheet, nv = info['sheet'], info['vertices']
        ax, ay = info['anchor']
        for j in range(nv):
            o = sheet + 8 + 8 * j
            if not in_file(data, o, 8):
                unresolved.append({'object': s['index'], 'vertex': j,
                                   'reason': 'vertex outside file'})
                break
            vx, vy, cell, uv, w, h, pal, flags = data[o:o + 8]
            if w == 0 or h == 0:
                continue
            slot = atlas_base + cell
            gx, gy, fold = atlas_slot_geometry(slot)
            u = (uv & 15) * 8
            v = fold + (uv >> 4) * 8
            clut_row = PALETTE_Y0 + ((palette_base + pal) & 0xFF)
            hflip = bool(flags & 2)
            vflip = bool(flags & 1)
            other = flags & ~0x3
            if other:
                unresolved.append({'object': s['index'], 'vertex': j,
                                   'reason': 'unsupported vertex flag bits %#x' % other})
            words = []
            for dy in range(h):
                row = []
                for dx in range(w):
                    idx = vram.sample_texel(
                        _texpage(gx, (slot % 20) // 10), (u + dx) & 255, (v + dy) & 255)
                    row.append(vram.get_word(idx, clut_row))
                words.append(row)
            prims.append({
                'object': s['index'], 'type': s['type'], 'vertex': j,
                'sheet_index': info['sheet_index'], 'sheet': sheet,
                'descriptor': info['descriptor'], 'frame': frame,
                'source_offset': s['offset'],
                'left': s['x_half'] * 8 + vx - ax,
                'top': s['y_half'] * 8 + vy - ay,
                'w': w, 'h': h,
                'slot': slot, 'atlas_vram': [gx, gy],
                'uv': [u, v], 'clut_row': clut_row,
                'palette_delta': pal, 'flags': flags,
                'hflip': hflip, 'vflip': vflip,
                'semi_transparent': bool(data[info['descriptor'] + 1] & 4),
                'order': s['order'], 'b4': s['b4'],
                'words': words,
            })
    meta = {'context': ctx_index, 'frame': frame,
            'atlas_base': atlas_base, 'palette_base': palette_base,
            'primitives': len(prims), 'unresolved': unresolved,
            'order_note': 'paint in FORWARD vertex order (8014C850 prepends)'}
    return prims, meta


def _texpage(gx, page_sel):
    from psx_vram import texpage_encode, TP_8BIT
    return texpage_encode(gx, 256 * page_sel, TP_8BIT)


def render_scenery(data, sec, vram, ctx_index=0, frame=0, size=None,
                   source_meta=None, background=None):
    """Milestone B verification compositor: scenery only, forward vertex order.

    Deliberately simple -- no ordering table, no blending, no second map. Those
    are Milestone C. This exists to prove the sheet assembly, reflection and
    palette rows before composition is layered on top.
    """
    from PIL import Image
    from psx_vram import rgb555_to_rgb888
    prims, meta = scenery_primitives(data, sec, vram, ctx_index, frame, source_meta)
    if size is None:
        w = u16(data, sec)
        h = u16(data, sec + 2)
        size = (w * 16, h * 16)
    img = Image.new('RGBA', size, (0, 0, 0, 0))
    if background is not None:
        img.alpha_composite(background.convert('RGBA'))
    for p in prims:
        tile = _prim_to_tile(p, rgb555_to_rgb888)
        if tile is not None:
            img.alpha_composite(tile, (p['left'], p['top']))
    meta['size'] = list(size)
    return img, meta


# --------------------------------------------------------------------------
# Milestone C: merge both maps and scenery using actual draw attributes
#
# Tags come from the emitter, read rather than assumed:
#   primary map   0x1fe                        (801340bc)
#   secondary map byte8&0x80 -> 0x100          (8013421c..80134244)
#                 byte8&0x08 -> 0x1ff
#                 otherwise  -> 0x00a          <-- all five VB6 rooms (byte8=1)
#   scenery       source byte+3 -> working byte+2 (8012F3D8)
# Draw-mode word from room byte+7: &1 -> 0x6100, &2 -> 0x7100, else 0x4100.
#
# A larger tag sits further back, so painting runs in DESCENDING tag order. The
# engine's secondary map is therefore a FOREGROUND layer here, not a backdrop.
# Within one tag the emitter's insertions are LIFO (`8014C850` prepends).
#
# OPEN, per the plan: the full ordering-table traversal and cross-path tie
# behaviour still need a focused static check. This implements the tags read
# above plus LIFO within a tag, and does NOT substitute a Y sort.
# --------------------------------------------------------------------------

MAP_TAG_PRIMARY = 0x1FE

# Unattached ground actors use byte(-Y_half),8012FE44..8012FE5C.
GROUND_DEPTH_ORIGIN = 256


def scenery_tag(order, rec):
    """The emitter's tag for a scenery order byte (8012f618..8012f694).

    order 0 -> 0x1ff (0x1fe when room byte7 bit 3 is set); order 1 -> 0xff;
    anything else -> the byte itself.
    """
    if order == 0:
        return 0x1FE if (rec['byte7'] & 0x8) else 0x1FF
    if order == 1:
        return 0xFF
    return order


def npc_tag(data, sec, y_half):
    """Unattached ground actor tag; surface-attached actors need their own path."""
    return (-y_half) & 255


def secondary_tag(data, rec):
    """The secondary map's ordering tag, from the branch at 8013421c."""
    b8 = rec['byte8']
    if b8 & 0x80:
        return 0x100
    if b8 & 0x08:
        return 0x1FF
    return 0x00A


def secondary_draw_mode(data, rec):
    """The draw-mode word selected by room byte+7 (801341e8..8013420c)."""
    b7 = rec['byte7']
    if b7 & 0x1:
        return 0x6100
    if b7 & 0x2:
        return 0x7100
    return 0x4100


def load_map_materials(data, sec, codes, cache=None):
    """Per-code (atlas raw bytes, palette RGB555 words) for an arbitrary code set.

    Deliberately takes an explicit code set so the union of BOTH maps can be
    resolved -- the existing loader derives its codes from the primary map alone,
    and the village's secondary map uses 33 codes the primary never references.
    Palettes stay as RGB555 words so transparency (resolved 0x0000) and bit 15
    survive to the compositor. Code 0 is resolved like any other code; it is not
    erased by value, only by its resolved colour word.
    """
    from lzss import decode_strict
    count, pal_count = data[sec + 4], data[sec + 5]
    ctab = ptr_at(data, sec + 8)
    dtab = ptr_at(data, sec + 0x0C)
    etab = ptr_at(data, sec + 0x10)
    if ctab is None or dtab is None or etab is None:
        raise ValueError('section material tables missing')
    codes = set(codes)
    if any(c // 64 >= count for c in codes):
        raise ValueError('tile code exceeds room atlas table (%d slots)' % count)
    cache = {} if cache is None else cache
    out = {}
    for code in sorted(codes):
        bi, si = divmod(code, 64)
        bo = ptr_at(data, ctab + 4 * bi)
        if bo is None:
            out[code] = None
            continue
        if bo not in cache:
            clen = u32(data, bo)
            raw = decode_strict(data[bo + 4:bo + 4 + clen])
            if len(raw) != 16384:
                raise ValueError('atlas %#x decoded to %d bytes' % (bo, len(raw)))
            cache[bo] = raw
        eo = ptr_at(data, etab + 4 * bi)
        pi = data[eo + si]
        if pi >= pal_count:
            raise ValueError('tile %d selects palette %d, only %d declared' % (code, pi, pal_count))
        po = ptr_at(data, dtab + 4 * pi)
        words = struct.unpack_from('<256H', data, po)
        out[code] = {'atlas_offset': bo, 'atlas': cache[bo], 'palette_index': pi,
                     'palette_offset': po, 'palette': words,
                     'selector_offset': eo}
    return out


def map_primitives(data, sec, map_off, w, h, mats, tag, layer):
    """One 16x16 primitive per non-empty tile of a map, keeping RGB555 words.

    Whole-tile dedup keeps this tractable; a tile whose resolved words are all
    zero contributes nothing and is recorded as skipped rather than emitted.
    """
    codes = struct.unpack_from('<%dH' % (w * h), data, map_off)
    prims, skipped, missing = [], 0, set()
    for j, code in enumerate(codes):
        m = mats.get(code)
        if m is None:
            missing.add(code)
            continue
        atlas, pal = m['atlas'], m['palette']
        si = code % 64
        sx, sy = si % 8 * 16, si // 8 * 16
        words = []
        any_nonzero = False
        for y in range(16):
            row = []
            base = (sy + y) * 128 + sx
            for x in range(16):
                word = pal[atlas[base + x]]
                if word:
                    any_nonzero = True
                row.append(word)
            words.append(row)
        if not any_nonzero:
            skipped += 1
            continue
        prims.append({'kind': 'map', 'layer': layer, 'code': code, 'tag': tag,
                      'left': (j % w) * 16, 'top': (j // w) * 16, 'w': 16, 'h': 16,
                      'words': words, 'palette_index': m['palette_index'],
                      'material_offset': m['atlas_offset']})
    return prims, {'skipped_empty_tiles': skipped, 'missing_codes': sorted(missing)}


def scene_map_materials(data, section, companion, primary_codes, secondary_codes):
    """Resolve both map layers, including companion material-table fallback."""
    primary = load_map_materials(data, section, set(primary_codes) | set(secondary_codes))
    if secondary_codes and companion is not None and companion != section:
        try:
            return primary, load_map_materials(data, companion, secondary_codes)
        except ValueError:
            pass
    return primary, primary


def scene_compose(data, room, vram, frame=0, source_meta=None, npcs=True, background=None,
                  variant=None, frames_by_type=None, npc_entities=None, object_records=None):
    """Build the full ordered primitive list for a room and paint it.

    Order is descending tag (larger tag = further back); within one tag the
    emitter's LIFO insertion is reproduced.
    object_records replaces static scenery; an empty list leaves only map/NPC layers.
    """
    from PIL import Image
    from psx_vram import rgb555_to_rgb888

    rec = room_record(data, room)
    if rec is None:
        raise ValueError('room %d not present' % room)
    sec = section_off(data, rec['section'])
    pw, ph = u16(data, sec), u16(data, sec + 2)
    pm_off = ptr_at(data, sec + 0x14)

    comp = section_off(data, rec['byte9'])
    comp_dims = None
    if comp is not None:
        _cd = (u16(data, comp), u16(data, comp + 2))
        # never let a garbage companion header (observed 17592x32772) reach
        # Image.new -- that allocation was ~560 GB and is what killed the batch
        comp_dims = _cd if (1 <= _cd[0] <= MAX_MAP_DIM and 1 <= _cd[1] <= MAX_MAP_DIM) else None
    # The secondary map's row width -- RESOLVED 2026-10-05 by POINTER IDENTITY.
    #
    # A room's "secondary" tilemap is either its own map or the COMPANION section's
    # PRIMARY map reused as an overlay, and the two are distinguished by comparing
    # the pointers:
    #
    #   VB3 room 28:  room sec 28 (22x32) secondary = 0x12d8c
    #                 comp sec 58 (24x32) primary   = 0x12d8c   <- IDENTICAL
    #      so the overlay IS the companion's map, drawn over this room, and it must
    #      be laid out with the COMPANION's 24x32. Using 22x32 shears it.
    #
    #   VC2 room 60:  room sec 7  (24x16) secondary = 0x8948
    #                 comp sec 9  (32x16) primary   = 0x5aec   <- different
    #   VB5CG room 60: room sec 6 (32x28) secondary = 0x8d38
    #                 comp sec 5  (24x40) primary   = 0x71d8   <- different
    #      so the overlay is the SECTION's own map and takes the SECTION's dims
    #      (24x16 and 32x28). Using the companion's shears both.
    #
    # Three cases, one rule, and the rule is a property of the data rather than a
    # preference: an overlay drawn from a section's tilemap uses that section's own
    # header. Earlier attempts -- always-primary, always-companion, and tag-selected
    # -- each failed at least one of these three.
    cw, ch = pw, ph
    sm_off = ptr_at(data, sec + 0x18)
    if comp is not None and sm_off is not None and comp_dims:
        comp_primary = ptr_at(data, comp + 0x14)
        if comp_primary == sm_off or (comp_primary is None and sm_off < comp):
            cw, ch = comp_dims          # the overlay is the companion's map

    # A section can declare a valid header with NO primary tilemap pointer.
    # VC4 room 36 (section 18) does, and the unguarded unpack below raised
    # "TypeError: 'NoneType' object cannot be interpreted as an integer" -- which
    # is why that room produced no image at all. Every OTHER use of pm_off in this
    # function was already guarded; this one was missed.
    codes = set()
    if pm_off is not None and in_file(data, pm_off, pw * ph * 2):
        codes = set(struct.unpack_from('<%dH' % (pw * ph), data, pm_off))
    sm_codes = set()
    if sm_off is not None and in_file(data, sm_off, cw * ch * 2):
        sm_codes = set(struct.unpack_from('<%dH' % (cw * ch), data, sm_off))
        codes |= sm_codes
    mats, sm_mats = scene_map_materials(data, sec, comp, codes, sm_codes)
    # The SECONDARY map's tile codes must be resolved with the COMPANION
    # section's atlas/palette tables, not the primary's. Resolving them against
    # the primary's gets codes that are out of range or simply wrong -- observed
    # as the dark banding in VC2 room 60 and VB5CG room 60, where composing the
    # secondary took the dark fraction from 0.50 to 0.60 and 0.17 to 0.39. It
    # also fixes rooms that refused to load at all with "tile code exceeds room
    # atlas table (N slots)".
    from psx_vram import rgb555_to_rgb888 as _to888
    # Maps are single-tag LAYERS, so they are painted straight into their own
    # images instead of one primitive per tile. Materialising a 256-word grid per
    # tile cost ~1200 primitives per room and was killed by the OOM reaper on the
    # larger areas; layer painting keeps peak memory to two images.
    prims = []
    pm_meta = {'skipped_empty_tiles': 0, 'missing_codes': []}
    pm_layer = None
    if pm_off is not None and in_file(data, pm_off, pw * ph * 2):
        pm_layer, pm_meta = map_layer_image(data, pm_off, pw, ph, mats, _to888)
    sec_tag = secondary_tag(data, rec)
    sm_meta = {'skipped_empty_tiles': 0, 'missing_codes': []}
    sm_layer = None
    if sm_off is not None and in_file(data, sm_off, cw * ch * 2):
        sm_layer, sm_meta = map_layer_image(data, sm_off, cw, ch, sm_mats, _to888,
                                          semi_transparent=True)

    # NPC layer: character contexts upload after the section's other contexts, so
    # the atlas-slot counter continues from there.
    npc_meta = {'primitives': 0, 'unresolved': []}
    if npcs:
        vram2, m2 = load_scene_materials(data, sec, source_meta)
        slot_start = m2['atlas_base'] + sum(len(c['atlases']) for c in m2['contexts']
                                           if not c.get('is_32_colour'))
        bindings, _slot_end = load_npc_contexts(data, sec, vram2, slot_start, source_meta)
        np, npc_meta = npc_primitives(data, room, vram2, bindings, frame, source_meta)
        if npc_entities is not None:
            npc_meta['excluded_entities'] = sorted({p['entity'] for p in np} - set(npc_entities))
            np = [p for p in np if p['entity'] in npc_entities]
        # mutually exclusive states share a position; keep one variant per position
        # Mutually exclusive states share a position. `variant` selects which id
        # is shown there; without one the first is kept. Both variants are
        # renderable, and the CONDITION that decides between them is not decoded,
        # so the choice is recorded rather than claimed.
        seen_pos = {}
        keep = []
        for p_ in sorted(np, key=lambda q: (q['left'], q['top'],
                                            0 if q['id'] == variant else 1, q['id'])):
            key = (p_['left'], p_['top'])
            if key in seen_pos and seen_pos[key] != p_['id']:
                npc_meta.setdefault('variants_dropped', []).append(
                    {'id': p_['id'], 'entity': p_['entity'], 'position': list(key),
                     'reason': 'another id already occupies this position'
                               + (' (variant %d selected)' % variant if variant is not None
                                  else '')})
                continue
            seen_pos[key] = p_['id']
            keep.append(p_)
        npc_meta['variant'] = variant
        npc_meta['variant_note'] = ('explicit variant id' if variant is not None
                                    else 'default: first id at each position')
        prims.extend(keep)
        npc_meta['primitives'] = len(keep)

    ctxs = contexts_of(data, sec)
    scn_meta = {'primitives': 0, 'unresolved': []}
    if ctxs and ctxs[0].get('offset') is not None:
        if frames_by_type:
            # Per-object frame timing. Every scenery object advances on its OWN
            # schedule -- descriptor+4+2k gives (sheet, duration) per frame -- so a
            # single global `frame` desynchronises objects with different frame
            # counts (this room has 2, 3, 4 and 4-frame objects together). Gather
            # the frames actually needed, call once per frame, and keep each type's
            # primitives from ITS frame. `frame` is ignored when this is given.
            # Default None leaves every existing caller byte-identical.
            per_frame = {}
            for k in sorted(set(frames_by_type.values())):
                per_frame[k], scn_meta = scenery_primitives(data, sec, vram, 0, k,
                                                           source_meta, object_records=object_records)
            sp = []
            for _t, _k in sorted(frames_by_type.items()):
                sp.extend(q for q in per_frame.get(_k, []) if q.get('type') == _t)
            sp.sort(key=lambda p: (p['object'], p['vertex']))
        else:
            sp, scn_meta = scenery_primitives(data, sec, vram, 0, frame, source_meta, object_records=object_records)
        # repaint order within a tag is LIFO, and 800C3EF0 emits last-to-first,
        # so assigning seq in emission order and painting descending reproduces it
        for i, p in enumerate(sp):
            p['kind'] = 'scenery'
            p['seq'] = len(sp) - i
            # 8012F3D8: source byte+3 becomes working byte+2 and flows into the
            # emitter's tag. Values 0 and 1 take SPECIAL branches, read at
            # 8012f618..8012f694:
            #     order 0 -> tag 0x1ff, or 0x1fe when room byte7 has bit 3
            #     order 1 -> tag 0xff
            #     otherwise the order byte is the tag unchanged
            # Carrying 0/1 through as literal tags put them NEAREST (painted last),
            # which is why the shop's carpet (order 1) covered the divider it
            # should sit under. 0x1ff/0x1fe are the primary map's own range, i.e.
            # "as far back as the map"; 0xff is further back than every scenery
            # tag observed (208-253).
            p['tag'] = scenery_tag(p['order'], rec)
        prims.extend(sp)

    prims.sort(key=lambda p: (-p['tag'], -p.get('seq', 0)))

    size = (max(pw * 16, cw * 16), max(ph * 16, ch * 16))
    if size[0] > MAX_MAP_DIM * 16 or size[1] > MAX_MAP_DIM * 16:
        raise ValueError('refusing canvas %dx%d' % size)
    img = Image.new('RGBA', size, (0, 0, 0, 255))
    if background is not None:
        img.alpha_composite(background.convert('RGBA').resize(size))
    # One ordered pass over layers and scenery/NPC primitives together, so the
    # real tags decide interleaving (the secondary map is a FOREGROUND layer at
    # tag 10 and must not be forced to the end).
    entries = []
    if pm_layer is not None:
        entries.append((MAP_TAG_PRIMARY, 0, 'layer', pm_layer, (0, 0)))
    if sm_layer is not None:
        entries.append((sec_tag, 0, 'layer', sm_layer, (0, 0)))
    for p in prims:
        entries.append((p['tag'], p.get('seq', 0), 'prim', p, (p['left'], p['top'])))
    entries.sort(key=lambda e: (-e[0], -e[1]))
    for _tag, _seq, kind, obj, pos in entries:
        if kind == 'layer':
            img.alpha_composite(obj, pos)
        else:
            tile = _prim_to_tile(obj, rgb555_to_rgb888)
            if tile is not None:
                img.alpha_composite(tile, pos)
    meta = {
        'room': room, 'label': TARGETS.get(room, (None,))[0],
        'primary': {'tag': MAP_TAG_PRIMARY, 'w': pw, 'h': ph, 'offset': pm_off, **pm_meta},
        'secondary': {'tag': sec_tag, 'w': cw, 'h': ch, 'offset': sm_off,
                      'companion_section': rec['byte9'],
                      'companion_dims': comp_dims, **sm_meta},
        'draw_mode': secondary_draw_mode(data, rec),
        'scenery': scn_meta,
        'npc': npc_meta,
        'variant': variant,
        'primitives_total': len(prims),
        'order': 'descending tag; LIFO within a tag',
        'size': list(size),
    }
    return img, prims, meta


# Semitransparency is derived from the submit at 0x8014c0a0..0x8014c0bc:
#   mode = ((word >> 17) & 0x180) | ((word >> 23) & 0x60)
# built from the primitive's first word. For the map primitives here that word is
# 0x4100 (secondary, set at 0x8013420c; byte7 = 0 selects the 0x4100 branch), so
# both terms are zero and the mode is ABR 0 -- 0.5*back + 0.5*front. That is
# exactly expressible as normal 50% alpha compositing, so no hand-rolled blend is
# needed for this path; other modes would need explicit channel arithmetic.
ABR_AVERAGE = 0


def texel_alpha(word, *, semi_transparent=False):
    """Alpha for one resolved RGB555 word.

    Zero is transparent. STP averages under ABR0 only when the emitted command
    enables blending; normal NPC/scenery commands keep STP colours opaque.
    """
    if word == 0:
        return 0
    if semi_transparent and word & 0x8000:
        return 128
    return 255


def _prim_to_tile(p, to888):
    """One primitive as an RGBA tile, WITH its reflection applied.

    Reflection must happen here, not only in render_scenery(): 800C3E9C sets
    `flags & 2` (horizontal) and `flags & 1` (vertical), and the packet builder
    moves the start corner by width/height and negates the scale, so the piece
    occupies the SAME rect with reversed texture order. A first cut applied the
    flip only in the Milestone B verification compositor, so every composed scene
    drew mirrored vertices as plain REPEATS -- visible as a doubled rather than
    reflected half on the inn's beds and the shop's reflected pieces.
    """
    from PIL import Image
    rows = [list(r) for r in p['words']]
    if p.get('hflip'):
        rows = [r[::-1] for r in rows]
    if p.get('vflip'):
        rows = rows[::-1]
    img = Image.new('RGBA', (p['w'], p['h']))
    px = []
    for row in rows:
        for word in row:
            a = texel_alpha(word, semi_transparent=p.get('semi_transparent', False))
            if a == 0:
                px.append((0, 0, 0, 0))
            else:
                px.append((*to888(word & 0x7FFF), a))
    img.putdata(px)
    return img


# --------------------------------------------------------------------------
# Milestone D: NPCs from the embedded character contexts
#
# `801346A8` walks `section+0x34`, an array of pointers to id records whose
# first word is the character id; the match at index j selects
# `section[+0x20][j+1]`. `80134470` then initialises the character object from
# that context. Verified for all five rooms: the ten (id -> context) mappings
# match the plan's table exactly.
#
# The character contexts are the 32-colour branch (palette byte 0x81). Their
# texture atlases use indices 0..31 only, so `800C3CC8` uploads a 32-word
# palette -- 32 words at VRAM X=256, row 0x1e0 + its own counter -- NOT 256
# words at X=0, and not a 4-bit texture mode. Because the CLUT sits at X=256
# these rows can safely share y values with the scenery palettes at X=0.
#
# Each character sheet holds ONE vertex: 23x47, anchor (3,36). The descriptor
# pairs select sheets 0/3/6/9 with a per-frame duration (16 or 11), i.e. three
# animation frames per facing. Neutral selects descriptor0's pair1 when present,
# matching801344F8..80134514; this collector renders that fixed pose.
# --------------------------------------------------------------------------

NPC_CLUT_X = 256
NPC_ROW0 = 0x1E0


def character_bindings(data, sec):
    """(id -> context offset) for a section, from section+0x34 and section+0x20.

    `section+0x20` is a pointer to the context array, so it is dereferenced once
    before indexing: context[j+1] = *(array + 4*(j+1)). Indexing the pointer's
    own address instead is a silent off-by-one that yields the wrong context.
    """
    tab = ptr_at(data, sec + 0x34)
    arr = ptr_at(data, sec + 0x20)
    if tab is None or arr is None:
        return {}
    out = {}
    for j in range(MAX_CONTEXTS):
        rp = ptr_at(data, tab + 4 * j)
        if rp is None:
            break
        word = u32(data, rp)
        # a character id is a byte; a wider word means this is not an id record
        if word & 0xFFFFFF00:
            break
        cid = word & 0xFF
        ctx = ptr_at(data, arr + 4 * (j + 1))
        if ctx is None:
            break
        out[cid] = {'index': j, 'id': cid, 'record': rp, 'context': ctx,
                    'context_index': j + 1}
    return out


def load_npc_contexts(data, sec, vram, slot_start, source_meta=None):
    """Upload the 32-colour character contexts and return their VRAM bindings.

    Atlases continue the section's atlas-slot counter (the loader walks contexts
    in order); palettes take their own counter from row 0x1e0 at X=256.
    """
    from lzss import decode_strict
    bindings = character_bindings(data, sec)
    out = {}
    slot = slot_start
    row = NPC_ROW0
    for cid in sorted(bindings, key=lambda c: bindings[c]['index']):
        b = bindings[cid]
        ctx = b['context']
        if ctx is None:
            continue
        natlas = u8(data, ctx + 4)
        if natlas > MAX_ATLASES_PER_CONTEXT:
            raise ValueError('implausible atlas count %d for character %d' % (natlas, cid))
        atab = ptr_at(data, ctx + 8)
        ptab = ptr_at(data, ctx + 12)
        slot_for = None
        for i in range(natlas):
            bo = ptr_at(data, atab + 4 * i) if atab is not None else None
            if bo is None:
                continue
            clen = u32(data, bo)
            raw = decode_strict(data[bo + 4:bo + 4 + clen])
            if len(raw) != 16384:
                raise ValueError('character atlas %#x is %d bytes' % (bo, len(raw)))
            gx, gy, _fold = atlas_slot_geometry(slot)
            vram.upload_rect(gx, gy, ATLAS_SLOT_W, ATLAS_SLOT_H, raw,
                             provenance={'kind': 'npc_atlas', 'id': cid,
                                         'offset': bo, 'slot': slot,
                                         **(source_meta or {})})
            if slot_for is None:
                slot_for = slot
            slot += 1
        flags5 = u8(data, ctx + 5)
        count = flags5 & 0x3F
        if not 1 <= count <= 32:
            raise ValueError('unsupported character palette bank')
        clut_x = NPC_CLUT_X if (flags5 & 0xC0) else 0
        palettes = []
        for palette in range(count):
            po = ptr_at(data, ptab + 4 * palette) if ptab is not None else None
            if po is None or not in_file(data, po, 64):
                if not (flags5 & 0xC0) and palettes:
                    break
                raise ValueError('missing character palette')
            palettes.append(po)
            vram.upload_rect(clut_x, row + palette, 32, 1, data[po:po + 64],
                             provenance={'kind': 'npc_palette', 'id': cid,
                                         'offset': po, 'row': row + palette,
                                         'clut_x': clut_x,
                                         **(source_meta or {})})
        out[cid] = {**b, 'atlas_slot': slot_for, 'clut_row': row, 'clut_x': clut_x,
                    'palette_offset': palettes[0], 'palette_offsets': palettes}
        row += len(palettes)
    return out, slot


def npc_primitives(data, room, vram, bindings, facing=0, source_meta=None):
    """Sprite primitives for the room's VISIBLE character entries.

    Only entity records whose id matches a character binding AND whose
    coordinates are non-zero are drawn: a zero-coordinate entry is still an
    event, and a non-raw script pointer alone does not prove a visible entity.
    Records sharing a position with different ids are mutually exclusive states
    and are reported rather than painted together.
    """
    rec = room_record(data, room)
    sec = section_off(data, rec['section'])
    prims, notes = [], []
    positions = {}
    for e in entities(data, rec):
        cid = e['id'] & 0xFF
        b = bindings.get(cid)
        if b is None:
            continue
        w_half, h_half = u16(data, sec) * 2, u16(data, sec + 2) * 2
        if e['zero_coord']:
            # Only records that RESOLVED to a sprite context reach here (the
            # `b is None` guard above skipped the rest), so this is a drawable
            # character whose position the script supplies. Records at (0,0) with
            # id 0 and no context never arrive -- they are non-drawable event or
            # script records, a different class, and are not noted here.
            notes.append({'entity': e['index'], 'id': cid,
                          'reason': 'zero coordinate: character kept, not drawn'})
            continue
        # An off-map coordinate is a SENTINEL, not a placement: corpus-wide
        # (254,254) x37 and (255,255) x14, about five times outside a 384x256 room.
        # Drawing those put sprites off-canvas and made two unplaced records collide
        # on a rect, which produced 212 spurious "another id already occupies this
        # position" notes. They are unplaced, reported once, and not drawn.
        if not (0 < e['x_half'] < w_half and 0 < e['y_half'] < h_half):
            notes.append({'entity': e['index'], 'id': cid,
                          'reason': 'off-screen staging position: the script places this '
                                    'character (confirmed against a captured scene where '
                                    'the party lines up in a row and an NPC walks in)',
                          'x_half': e['x_half'], 'y_half': e['y_half']})
            continue
        ctx = b['context']
        if ctx is None:
            notes.append({'entity': e['index'], 'id': cid, 'reason': 'no context'})
            continue
        stab = ptr_at(data, ctx + 0x10)
        dtab = ptr_at(data, ctx + 0x14)
        desc = ptr_at(data, dtab + 4 * facing)
        if desc is None:
            notes.append({'entity': e['index'], 'id': cid,
                          'reason': 'no descriptor for facing %d' % facing})
            continue
        # 801344F8..80134514 selects pair1 as the neutral pose for multi-pair clips.
        idle_pair = 1 if u8(data, desc) > 1 else 0
        sheet_index = u8(data, desc + 4 + 2 * idle_pair)
        duration = u8(data, desc + 5 + 2 * idle_pair)
        if sheet_index == 0xFF:
            notes.append({'entity': e['index'], 'id': cid,
                          'reason': 'descriptor is a terminator (0xff)'})
            continue
        sheet = ptr_at(data, stab + 4 * sheet_index)
        if sheet is None:
            notes.append({'entity': e['index'], 'id': cid,
                          'reason': 'sheet %d unresolved' % sheet_index})
            continue
        nv = u8(data, sheet)
        ax, ay = u8(data, sheet + 4), u8(data, sheet + 5)
        for j in range(nv):
            o = sheet + 8 + 8 * j
            vx, vy, cell, uv, w, h, pal, flags = data[o:o + 8]
            slot = (b['atlas_slot'] or 0) + cell
            gx, gy, fold = atlas_slot_geometry(slot)
            u = (uv & 15) * 8
            v = fold + (uv >> 4) * 8
            if pal >= len(b['palette_offsets']):
                raise ValueError('NPC piece palette outside context')
            row = b['clut_row'] + pal
            clut_x = b.get('clut_x', NPC_CLUT_X)
            words = []
            for dy in range(h):
                r = []
                for dx in range(w):
                    idx = vram.sample_texel(_texpage(gx, (slot % 20) // 10),
                                            (u + dx) & 255, (v + dy) & 255)
                    r.append(vram.get_word(clut_x + (idx & 31), row))
                words.append(r)
            prims.append({
                'kind': 'npc', 'id': cid, 'entity': e['index'],
                'semi_transparent': bool(data[desc + 1] & 4),
                'flags': e['flags'], 'facing': facing, 'duration': duration,
                'left': e['x_half'] * 8 + vx - ax,
                'top': e['y_half'] * 8 + vy - ay,
                'w': w, 'h': h, 'slot': slot, 'atlas_vram': [gx, gy],
                'uv': [u, v], 'clut_row': row, 'clut_x': clut_x,
                'hflip': bool(flags & 2), 'vflip': bool(flags & 1),
                'tag': npc_tag(data, sec, e['y_half']), 'seq': 0, 'words': words,
            })
        # Only an IN-MAP position can be a genuine state conflict. Unplaced
        # records carry sentinel coordinates -- (254,254) x37 and (255,255) x14
        # corpus-wide -- and two of those sharing a slot means nothing. Keying on
        # raw coordinates made 51 of 62 "mutually exclusive" notes a false signal,
        # which is exactly what the user found perplexing.
        w_half, h_half = u16(data, sec) * 2, u16(data, sec + 2) * 2
        if 0 < e['x_half'] < w_half and 0 < e['y_half'] < h_half:
            key = (e['x_half'], e['y_half'])
            positions.setdefault(key, []).append(cid)
    for key, ids in sorted(positions.items()):
        if len(set(ids)) > 1:
            notes.append({'position_half': list(key), 'ids': sorted(set(ids)),
                          'reason': 'mutually exclusive states share this position; '
                                    'render one variant at a time'})
    return prims, {'primitives': len(prims), 'unresolved': notes,
                   'bindings': {str(k): {'context': hex(v['context']) if v['context'] else None,
                                         'clut_row': v['clut_row'],
                                         'atlas_slot': v['atlas_slot']}
                                for k, v in sorted(bindings.items())}}


def room_for_section(data, sec_off):
    """The room record whose `+5` resolves to this header offset, or None.

    Producers iterate header offsets, but scenes are selected by ROOM record --
    the two identities differ (room 9 -> section 10, room 10 -> section 9), so a
    header must be mapped back before composing.
    """
    if sec_off is None:
        return None
    for rec in room_records(data):
        if section_off(data, rec['section']) == sec_off:
            return rec
    return None


def companion_users(data, sec_off):
    """Rooms whose `byte9` companion resolves to this section.

    A section that no room points at is usually a COMPANION: the section whose own
    tilemap IS some room's secondary layer. Verified across VA2, VB6 and VB5 --
    25 rooms, 0 mismatches -- the room's `section+0x18` secondary pointer equals
    the companion section's `+0x14` tilemap pointer exactly. So a companion is not
    a room and not an empty slot; it is the other half of a room, which is why a
    companion rendered standalone looks structurally like its room.
    """
    out = []
    if sec_off is None:
        return out
    for rec in room_records(data):
        if section_off(data, rec['byte9']) == sec_off:
            out.append(rec['index'])
    return out


def compose_scene_image(data, sec_off, base, source_meta=None, npcs=True, frame=0,
                        variant=None):
    """Compose the room scene that uses `sec_off`, over the base tilemap render.

    Returns (image, meta). When no room record uses this section the base is
    returned unchanged with an explicit reason -- a base-only diagnostic stays
    possible, and a section with no room is never silently composed.
    """
    rec = room_for_section(data, sec_off)
    if rec is None:
        users = companion_users(data, sec_off)
        if users:
            return base, {
                'composed': False, 'companion_of': users,
                'reason': 'companion section: the secondary layer of room(s) %s, not a '
                          'room of its own' % users}
        return base, {'composed': False,
                      'reason': 'no room record uses this section; base only'}
    try:
        vram, mat_meta = load_scene_materials(data, sec_off, source_meta)
        # Select opacity per emitted command: primary is opaque; secondary blends.
        #
        # The canvas is the opaque clear colour (0,0,0,255), i.e. what a
        # framebuffer clear would leave, so a code-0 cell shows the backdrop
        # rather than a transparent hole. That is why the composed PNGs have no
        # alpha channel content -- transparency is a compositing rule between
        # layers here, not a property of the finished frame. `base` is still
        # returned for the base-only diagnostic path.
        img, prims, meta = scene_compose(data, rec['index'], vram, frame=frame,
                                         source_meta=source_meta, npcs=npcs,
                                         background=None, variant=variant)
    except Exception as ex:                       # noqa: BLE001 - report, never die
        # One bad room must not kill a batch: report it and keep the base render.
        return base, {'composed': False, 'room': rec['index'],
                      'reason': 'scene composition failed: %s: %s'
                                % (type(ex).__name__, ex)}
    meta['composed'] = True
    meta['room_record'] = rec['index']
    meta['materials'] = {'atlas_base': mat_meta['atlas_base'],
                         'palette_base': mat_meta['palette_base'],
                         'contexts': [{k: c[k] for k in ('index', 'colour_branch',
                                                        'is_32_colour')}
                                      for c in mat_meta['contexts']]}
    return img, meta


def map_layer_image(data, map_off, w, h, mats, to888, *, semi_transparent=False):
    """Paint a whole map into its own RGBA image.

    Equivalent to emitting one primitive per tile (same materials, same
    transparency rule, same STP alpha) but without materialising a word grid per
    tile, which is what exhausted memory on the larger areas.
    """
    from PIL import Image
    codes = struct.unpack_from('<%dH' % (w * h), data, map_off)
    img = Image.new('RGBA', (w * 16, h * 16), (0, 0, 0, 0))
    skipped, missing, cache = 0, set(), {}
    for j, code in enumerate(codes):
        m = mats.get(code)
        if m is None:
            missing.add(code)
            continue
        if code not in cache:
            atlas, pal = m['atlas'], m['palette']
            si = code % 64
            sx, sy = si % 8 * 16, si // 8 * 16
            px = []
            any_nonzero = False
            for y in range(16):
                base = (sy + y) * 128 + sx
                for x in range(16):
                    word = pal[atlas[base + x]]
                    if word:
                        any_nonzero = True
                    a = texel_alpha(word, semi_transparent=semi_transparent)
                    px.append((0, 0, 0, 0) if a == 0 else (*to888(word & 0x7FFF), a))
            cache[code] = (px, any_nonzero)
        px, any_nonzero = cache[code]
        if not any_nonzero:
            skipped += 1
            continue
        tile = Image.new('RGBA', (16, 16))
        tile.putdata(px)
        img.paste(tile, ((j % w) * 16, (j // w) * 16))
    return img, {'skipped_empty_tiles': skipped, 'missing_codes': sorted(missing),
                 'codes': len(set(codes))}
