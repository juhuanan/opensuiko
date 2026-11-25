#!/usr/bin/env python3
"""
Extract per-area 0x18-byte tile entries from Suikoden PS1 area overlays
and run the builder logic (area_tile_table_builder @ 0x8012ed84).

Chain (verified by disassembly):
  overlay binary
    -> first word = root pointer (into overlay, base 0x80010000)
    -> root+8 = pointer to 16-byte slot table
    -> slot[N] = table + N*16, N = byte1 of *(0x8017DB24) [runtime]
    -> *(slot) = 0x18-byte tile entries array
    -> byte4 of slot = entry count (lbu 4(*(0x8017BFC0)))

0x18-byte entry layout (from builder disassembly):
  +0:  u16 x-coord        (to tile_query_xy_layer, descriptor byte0 = low byte)
  +2:  u16 y-coord        (descriptor byte1 = low byte)
  +4:  u16 filter bits    (count: &0x181; fill: &0x101)
  +6:  u16 type/variant   (to 0x801346a8 -> descriptor+8/+0xC/+0x10)
  +8:  u32 (overwritten by builder with tile index or 0xFF)
  +12: u32 condition bytecode ptr (to classifier 0x8013d8e0; 0 = skip)
  +16: u32 data pointer A
  +20: u32 data pointer B

Usage:
  python3 extract_area_tiles.py OVERLAY.BIN [--slot N] [--map-out PNG]
"""
import struct, sys, os

BASE = 0x80010000

def u32(d, off): return struct.unpack_from('<I', d, off)[0]
def u16(d, off): return struct.unpack_from('<H', d, off)[0]

def find_slots(path):
    """Return (root_ptr, table_ptr, [(slot_n, entries_off, count), ...])."""
    with open(path, 'rb') as fh:
        d = fh.read()
    root = u32(d, 0)
    roff = root - BASE
    if not (0 <= roff < len(d)):
        raise ValueError(f'root 0x{root:08X} outside file')
    tptr = u32(d, roff + 8)
    toff = tptr - BASE
    if not (0 <= toff < len(d)):
        raise ValueError(f'table 0x{tptr:08X} outside file')
    slots = []
    for n in range(16):
        soff = toff + n * 16
        if soff + 16 > len(d):
            break
        eptr = u32(d, soff)
        eoff = eptr - BASE
        cnt = d[soff + 4]
        if eptr != 0 and 0 <= eoff < len(d) and cnt > 0 and cnt < 500:
            slots.append((n, eoff, cnt))
        elif eptr == 0 and cnt == 0:
            # plausible end, but keep scanning a bit
            continue
    return d, root, tptr, slots

def get_entries(d, eoff, count):
    """Return list of 0x18-byte entries."""
    out = []
    for i in range(count):
        e = d[eoff + i * 0x18 : eoff + (i + 1) * 0x18]
        if len(e) < 0x18:
            break
        out.append(e)
    return out

def entry_info(e):
    """Decode the known fields of a 0x18-byte entry."""
    return {
        'x': u16(e, 0),
        'y': u16(e, 2),
        'filt': u16(e, 4),
        'variant': u16(e, 6),
        'cond': u32(e, 12),
        'ptrA': u32(e, 16),
        'ptrB': u32(e, 20),
        'filt_pass_fill': bool(u16(e, 4) & 0x101),
        'filt_pass_count': bool(u16(e, 4) & 0x181),
    }

def render_tile_map(entries, out_path, scale=8):
    """Render tile (x,y) positions as a map PNG."""
    from PIL import Image, ImageDraw
    infos = [entry_info(e) for e in entries]
    # Only entries with coordinates (filter-passing)
    pts = [(i['x'], i['y']) for i in infos if i['filt_pass_fill'] and (i['x'] or i['y'])]
    if not pts:
        print('  no positioned tiles to render')
        return
    maxx = max(x for x, y in pts) + 1
    maxy = max(y for x, y in pts) + 1
    W, H = maxx * scale + 20, maxy * scale + 20
    img = Image.new('RGB', (W, H), (16, 16, 24))
    dr = ImageDraw.Draw(img)
    for x, y in pts:
        dr.rectangle([10 + x * scale, 10 + y * scale,
                      10 + (x + 1) * scale - 1, 10 + (y + 1) * scale - 1],
                     fill=(90, 160, 220), outline=(200, 230, 255))
    img.save(out_path)
    print(f'  tile map -> {out_path} ({len(pts)} tiles, {maxx}x{maxy})')

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    slot_sel = None
    map_out = None
    args = sys.argv[2:]
    i = 0
    while i < len(args):
        if args[i] == '--slot':
            slot_sel = int(args[i + 1]); i += 2
        elif args[i] == '--map-out':
            map_out = args[i + 1]; i += 2
        else:
            i += 1
    d, root, tptr, slots = find_slots(path)
    print(f'{path}:')
    print(f'  root=0x{root:08X} table=0x{tptr:08X}')
    for n, eoff, cnt in slots:
        print(f'  slot {n}: entries fileoff=0x{eoff:X} count={cnt}')
    if slot_sel is not None:
        for n, eoff, cnt in slots:
            if n == slot_sel:
                entries = get_entries(d, eoff, cnt)
                print(f'  slot {n}: {len(entries)} entries extracted')
                if map_out:
                    render_tile_map(entries, map_out)
                # Summary
                infos = [entry_info(e) for e in entries]
                npass = sum(1 for x in infos if x['filt_pass_fill'])
                ncond = sum(1 for x in infos if x['cond'] != 0)
                print(f'  filter-pass(fill): {npass}/{len(entries)}, cond!=0: {ncond}')
                break
        else:
            print(f'  slot {slot_sel} not found/valid')

if __name__ == '__main__':
    main()
