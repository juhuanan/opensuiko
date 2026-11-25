#!/usr/bin/env python3
"""area_clut_trace.py -- the area CLUT channel: where the primitive's CLUT field comes from.

Workstream V, 2026-10-04.  Static analysis only: this tool reads MAIN.EXE
(through ``kit/tools/maindec.py``, base 0x800C0800) and the per-area overlay
files under ``kit/extracted/bin_overlays/DATA/**``.  It never opens the disc,
never touches an emulator, and never writes outside the directory it is told to.

Why it exists
-------------
The area renderers pick ONE palette per room.  That is demonstrably incomplete:
in ``VB5_h0`` the 50ish cells whose tile codes are 202/203 render as yellow-green
speckle under the room header's CLUT entry 0 and as unambiguous blue water under
entry 2.  This tool answers the *mechanical* half of the question -- how the
engine's primitive CLUT field is produced -- and states the half it cannot.

What it does
------------
Three sub-commands:

``sites``
    Every main-loop code site that reads the section pointer global
    ``[0x8017AAE4]``, with the section field each site actually touches.  This
    is the exhaustive check of the standing negative: *no* MAIN.EXE code path
    reads ``section+0x14`` as a tilemap.  The one read of ``+0x14`` found
    (0x8013b918) is a text/script-stream walker (``0x8017AF84`` cursor ->
    ``0x8013b7a0``), not a tilemap reader.

``emit``
    The primitive emitter.  ``FUN_800c3ef0`` (sprite/tile packet builder) is
    decoded far enough to show that the primitive's CLUT attribute is written
    with ``(s4 & 0xff) + 0x1e0`` where
    ``s4 = descriptor[+6] + vertex[+2]`` and the descriptor comes from
    ``packet[+0x14] -> descriptor_table``.  ``+0x1e0`` is the first VRAM row the
    CLUT bank is uploaded to (``FUN_800c3c5c``), so the CLUT field is
    ``bank_base_row + palette_index`` and the palette index is a *data* value.

``room``
    For a named room, resolves the two chains end to end and prints them:
      * the section header (``*(S+4)[0]``): w/h, blob/palette tables, tilemap,
        entry table and packet context;
      * the object-type descriptor table reached from the packet context, and
        the ``+6`` palette-base byte of every descriptor.
    That ``+6`` byte is the per-object CLUT channel.  It is why a room can draw
    two surfaces from two palettes with one primitive builder.

Usage
-----
    .venv/bin/python kit/tools/area_clut_trace.py sites
    .venv/bin/python kit/tools/area_clut_trace.py emit
    .venv/bin/python kit/tools/area_clut_trace.py room VB5 VB5_h0
    .venv/bin/python kit/tools/area_clut_trace.py room VB4 VB4_h0
    .venv/bin/python kit/tools/area_clut_trace.py rooms          # every room, table

Nothing is promoted; the user remains the final gate for every image.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from mipsdec import dec  # noqa: E402

RAM_BASE = 0x80010000          # every area overlay loads here
SECTION_GLOBAL = 0x8017AAE4    # [0x8017AAE4] = the active section header
PKT_CTX_OFF = 0x20             # section+0x20 -> 0x34-byte packet context
ENTRY_TAB_OFF = 0x24           # section+0x24 = 24-byte entry count (the +0x20
                               #   field is not a pointer table: the runner
                               #   treats section+0x1c as a scale and the entry
                               #   array begins at section+0x28, which
                               #   struct_ptr_relocate @0x800c473c rebases)
CLUT_ROW0 = 0x1E0              # FUN_800c3c5c uploads palette k to VRAM y=0x1e0+k


def _repo_root() -> str:
    """<root> derived from __file__ -- repo/kit/tools/area_clut_trace.py."""
    return os.path.abspath(os.path.join(HERE, os.pardir, os.pardir))


def _overlay_path(fname: str) -> str:
    return os.path.join(_repo_root(), 'kit', 'extracted', 'bin_overlays',
                        'DATA', '02_AREA.B', fname + '.BIN')


class Overlay:
    """An area overlay file, addressed the way the engine addresses it."""

    def __init__(self, path: str):
        with open(path, 'rb') as fh:
            self.d = fh.read()
        self.path = path
        self.name = os.path.basename(path)[:-4]
        if len(self.d) < 8:
            raise ValueError('overlay too small: %s' % path)

    def __len__(self):
        return len(self.d)

    def off(self, va: int):
        """File offset for a RAM value, or None when it is outside this file."""
        if not (RAM_BASE <= va < RAM_BASE + len(self.d)):
            return None
        return va - RAM_BASE

    def u32(self, va: int):
        o = self.off(va)
        return None if o is None or o + 4 > len(self.d) else struct.unpack_from('<I', self.d, o)[0]

    def u16(self, va: int):
        o = self.off(va)
        return None if o is None or o + 2 > len(self.d) else struct.unpack_from('<H', self.d, o)[0]

    def byte(self, va: int):
        o = self.off(va)
        return None if o is None else self.d[o]

    def root(self) -> int:
        return struct.unpack_from('<I', self.d, 0)[0]

    def section_table(self):
        """(S_va, table2_va) or (None, None)."""
        s = self.root()
        t2 = self.u32(s + 4)
        return s, t2

    def sections(self, limit: int = 64):
        """Walk *(S+4)[i] the way the renderers do (1 <= w,h <= 200)."""
        _, t2 = self.section_table()
        out = []
        if t2 is None:
            return out
        for i in range(limit):
            v = self.u32(t2 + 4 * i)
            if v is None:
                continue
            w = self.u16(v)
            h = self.u16(v + 2)
            if w is None or h is None or not (1 <= w <= 200 and 1 <= h <= 200):
                continue
            out.append((i, v, w, h))
        return out


# --------------------------------------------------------------------------
# sites -- the exhaustive section-global reader/writer map
# --------------------------------------------------------------------------

def _main_insns():
    import maindec
    b = maindec.body()
    base = maindec.MBASE
    out = []
    for i in range(len(b) // 4):
        pc = base + i * 4
        w = struct.unpack_from('<I', b, i * 4)[0]
        s, f = dec(pc, w)
        f['s'] = s
        out.append(f)
    return base, out


def cmd_sites(_args):
    base, ins = _main_insns()
    n = len(ins)
    sites = []
    for i, f in enumerate(ins):
        if f['op'] != 0x0F:                       # lui
            continue
        hi = (f['uimm'] << 16) & 0xFFFFFFFF
        for j in range(i + 1, min(i + 5, n)):
            g = ins[j]
            if g['op'] in (0x20, 0x21, 0x23, 0x24, 0x25) and g['rs'] == f['rt']:
                if (hi + g['imm']) & 0xFFFFFFFF == SECTION_GLOBAL:
                    sites.append(j)
                break
            if g['op'] == 0x0F:
                continue
            break
    print('MAIN.EXE base %#x, body %d bytes' % (base, len(ins) * 4))
    print('xref sites onto [%#x] (the active section header): %d'
          % (SECTION_GLOBAL, len(sites)))
    seen_offsets = {}
    for j in sites:
        reg = {r: '?' for r in range(32)}
        reg[ins[j]['rt']] = 'S'
        reads, writes = [], []
        for k in range(j + 1, min(j + 90, n)):
            f = ins[k]
            op, rs, rt, rd = f['op'], f['rs'], f['rt'], f['rd']
            if op in (0x20, 0x21, 0x23, 0x24, 0x25) and reg[rs] == 'S':
                reads.append((f['pc'], f['imm'], f['s']))
                seen_offsets.setdefault(f['imm'], []).append(f['pc'])
            if op == 0x2B and reg[f['rs']] == 'S':
                writes.append((f['pc'], f['imm'], f['s']))
                seen_offsets.setdefault(f['imm'], []).append(f['pc'])
            if op == 0 and f.get('fn') == 0x21:            # addu rd,rs,rt
                if (reg[rs] == 'S' and rt == 0) or (reg[rt] == 'S' and rs == 0):
                    reg[rd] = 'S'
                else:
                    reg[rd] = '?'
            elif op in (0x20, 0x21, 0x23, 0x24, 0x25) and reg[rs] == 'S':
                reg[rt] = '[S+%#x]' % f['imm']
            elif op == 0:
                reg[rd] = '?'
            else:
                reg[rt] = '?'
            if op == 0 and f.get('fn') == 0x08 and k > j + 2:  # jr $ra
                break
        print('  site %#010x' % ins[j]['pc'])
        for pc, off, s in reads:
            print('      READ  S+%#04x  %#010x  %s' % (off, pc, s))
        for pc, off, s in writes:
            print('      WRITE S+%#04x  %#010x  %s' % (off, pc, s))
    print()
    print('section field offsets touched anywhere in MAIN.EXE by these sites:')
    for off in sorted(seen_offsets):
        pcs = seen_offsets[off]
        mark = '  <-- TILEMAP FIELD' if off == 0x14 else ''
        print('  +%#04x  %d site(s)%s' % (off, len(pcs), mark))
    print()
    print('NOTE: +0x14 IS reached (0x8013b918), but that walker is the script/')
    print('      text-stream reader (cursor 0x8017AF84 -> 0x8013b7a0), NOT a')
    print('      tilemap reader: it indexes the field as a table of tables.')
    return 0


# --------------------------------------------------------------------------
# emit -- the primitive CLUT field
# --------------------------------------------------------------------------

EMIT_FN = 0x800C3EF0


def cmd_emit(_args):
    base, ins = _main_insns()
    idx = {f['pc']: f for f in ins}
    lo, hi = EMIT_FN, EMIT_FN + 0x350
    print('primitive emitter FUNCTION %#x (sprite / tile packet builder)' % EMIT_FN)
    print()
    for pc in range(lo, hi, 4):
        f = idx.get(pc)
        if f is None:
            break
        if pc in (0x800C3FD8, 0x800C4058, 0x800C406C, 0x800C4110,
                  0x800C4114, 0x800C4118, 0x800C3F34, 0x800C3F40):
            print('  >> %#010x  %s' % (pc, f['s']))
        else:
            print('     %#010x  %s' % (pc, f['s']))
    print()
    print('Spec (verified against the words above and against FUN_800c3dac):')
    print('  s5 = pkt[+0x10]           vertex-array descriptor')
    print('  s1 = s5 + 8 + i*8         the i-th 8-byte vertex record')
    print('  t0 = pkt[+0x14]           descriptor table                        (0x800c3fd0)')
    print('  v1 = lbu t0[+6]           palette base byte 1                     (0x800c3fd8)')
    print('  v0 = lbu s1[+2]           per-vertex palette byte (feeds the UV math)')
    print('  v2 = lbu t0[+7]           palette base byte 2                    (0x800c4058)')
    print('  s4 = t0[+7] + s1[+6]      (+ the (row,col) vertex term above)      (0x800c4068/0x800c406c)')
    print('  sh (s4 & 0xff) + 0x1e0 -> primitive+0x22  (the CLUT attribute)        (0x800c4118)')
    print()
    print('  0x1e0 is exactly the first VRAM row FUN_800c3c5c uploads palette 0 to')
    print('  (FUN_800c3c5c: lbu slot counter; addiu v0,v0,0x1e0; LoadImage).  So')
    print('  primitive+0x22 = CLUT_ROW0 + palette_index, and the palette index is')
    print('  a DATA value: the descriptor byte plus the vertex byte.')
    print()
    print('  The descriptor table is supplied by the packet context, and the one')
    print('  MAIN.EXE function that turns it into a descriptor is obj_initializer')
    print('  @0x800c3dac:  pkt[+0x14] -> [+0x14] -> table[type] -> descriptor,')
    print('  descriptor[+0] -> pkt[+1], descriptor[+6] -> the CLUT base above.')
    return 0


# --------------------------------------------------------------------------
# room -- resolve both chains for one room
# --------------------------------------------------------------------------

def resolve_room(ov: Overlay, slot: int):
    """Resolve section header + packet-context descriptor chain for a slot."""
    secs = {i: (v, w, h) for i, v, w, h in ov.sections()}
    if slot not in secs:
        return None
    sva, w, h = secs[slot]
    rec = {
        'overlay': ov.name,
        'slot': slot,
        'section_va': sva,
        'section_file': ov.off(sva),
        'w': w,
        'h': h,
        'fields': {},
        'chain': [],
        'notes': [],
    }
    names = {0x00: ('w', 'half'), 0x02: ('h', 'half'),
             0x04: ('blob_count', 'byte'), 0x05: ('palette_count', 'byte'),
             0x06: ('byte6', 'byte'), 0x07: ('byte7', 'byte'),
             0x08: ('blob_table', 'word'), 0x0C: ('palette_table', 'word'),
             0x10: ('e_table', 'word'), 0x14: ('tilemap', 'word'),
             0x18: ('list_head', 'word'), 0x1A: ('word1a', 'half'),
             0x1C: ('scale', 'word'), 0x20: ('packet_context', 'word'),
             0x24: ('entry_count', 'word'), 0x28: ('blob_table_copy', 'word'),
             0x2C: ('gfx_atlas', 'word'), 0x30: ('gfx_atlas2', 'word'),
             0x34: ('word34', 'word'), 0x38: ('word38', 'word'),
             0x3C: ('word3c', 'word')}
    for off, (nm, kind) in sorted(names.items()):
        if kind == 'word':
            rec['fields'][nm] = ov.u32(sva + off)
        elif kind == 'half':
            rec['fields'][nm] = ov.u16(sva + off)
        else:
            rec['fields'][nm] = ov.byte(sva + off)
    tm = rec['fields']['tilemap']
    o = ov.off(tm) if tm else None
    if o is not None:
        span = w * h * 2
        rec['tilemap_file'] = o
        rec['tilemap_span_end_file'] = o + span
        if 0 <= o and o + span <= len(ov.d):
            vals = struct.unpack_from('<%dH' % (w * h), ov.d, o)
            rec['tilemap_distinct'] = len(set(vals))
            rec['tilemap_max'] = max(vals)
            # sanity: the u16 interpretation must be inside the blob/palette tables
            rec['notes'].append(
                'tilemap %d u16 at file %#x..%#x' % (w * h, o, o + span))
        else:
            rec['notes'].append(
                'tilemap span %#x..%#x runs past EOF (%#x) -- not a tilemap here'
                % (o, o + span, len(ov.d)))

    # packet context chain
    ctx = rec['fields'].get('packet_context')
    if ctx is None or ov.off(ctx) is None:
        rec['notes'].append('packet_context not inside this overlay')
        return rec
    pkt_ctx = ov.u32(ctx)
    rec['chain'].append(('section+0x20', ctx, ov.off(ctx)))
    if pkt_ctx is None or ov.off(pkt_ctx) is None:
        rec['notes'].append('*(section+0x20) not inside this overlay')
        return rec
    rec['chain'].append(('*(section+0x20)+0', pkt_ctx, ov.off(pkt_ctx)))
    dt = ov.u32(pkt_ctx + 0x14)
    rec['packet_ctx_file'] = ov.off(pkt_ctx)
    rec['descriptor_table'] = dt
    rec['descriptor_table_file'] = ov.off(dt) if dt else None
    rec['chain'].append(('packet_ctx+0x14', dt, ov.off(dt) if dt else None))
    if dt is None or ov.off(dt) is None:
        rec['notes'].append('packet_ctx+0x14 not inside this overlay')
        return rec
    dtab = []
    for t in range(8):
        d = ov.u32(dt + 4 * t)
        if d is None:
            break
        o = ov.off(d)
        entry = {'type': t, 'desc_va': d, 'desc_file': o}
        if o is not None and o + 8 <= len(ov.d):
            entry['bytes'] = ov.d[o:o + 8].hex(' ')
            entry['palette_base_byte'] = ov.d[o + 6]
            entry['clut_index'] = CLUT_ROW0 + ov.d[o + 6]
        dtab.append(entry)
    rec['descriptor_types'] = dtab
    return rec


def _print_room(rec):
    if rec is None:
        print('  (no such section slot)')
        return
    print('OVERLAY %s  section slot %d  va %#x  file %#x  %dx%d'
          % (rec['overlay'], rec['slot'], rec['section_va'],
             rec['section_file'], rec['w'], rec['h']))
    for k, v in rec['fields'].items():
        if v is None:
            continue
        if isinstance(v, int) and v >= RAM_BASE:
            print('    %-18s %#010x  (file %#x)' % (k, v, v - RAM_BASE))
        else:
            print('    %-18s %#06x  (%d)' % (k, v, v))
    for note in rec['notes']:
        print('    note: %s' % note)
    print('  pointer chain:')
    for nm, va, fo in rec['chain']:
        print('    %-18s %#010x%s' % (nm, va, '' if fo is None else '  (file %#x)' % fo))
    print('  object-type descriptor table:')
    if not rec.get('descriptor_types'):
        print('    (unresolved -- chain left this overlay)')
    for e in rec.get('descriptor_types', []):
        pb = e.get('palette_base_byte')
        print('    type %d  desc %#010x file %-9s bytes %-24s palette_base+6=%s%s'
              % (e['type'], e['desc_va'],
                 hex(e['desc_file']) if e['desc_file'] is not None else 'OOR',
                 e.get('bytes', '-'), hex(pb) if pb is not None else '-',
                 ('  -> CLUT row %#x' % e['clut_index']) if pb is not None else ''))


def cmd_room(args):
    ov = Overlay(_overlay_path(args.overlay))
    slots = [s for s, _v, _w, _h in ov.sections()]
    if args.room:
        # A render named hN is table2[N] only when *every* earlier slot is
        # live; VB5/VB4 have exactly one live slot, so hN == slot N there.
        want = None
        if args.room.startswith(ov.name + '_h'):
            try:
                want = int(args.room.split('_h')[1])
            except ValueError:
                want = None
        if want is None or want not in slots:
            print('room %r not addressable; live slots: %s' % (args.room, slots))
            print('(a render named hN is NOT automatically table2[N] -- see '
                  'area_missing_layer.md)')
            return 2
        rec = resolve_room(ov, want)
        _print_room(rec)
        if args.json:
            with open(args.json, 'w') as fh:
                json.dump(rec, fh, indent=2, sort_keys=True)
            print('wrote %s' % args.json)
        return 0
    for s in slots:
        _print_room(resolve_room(ov, s))
    return 0


def cmd_rooms(args):
    """Table of every room in 02_AREA.B: what palette-base bytes its types offer."""
    d = os.path.join(_repo_root(), 'kit', 'extracted', 'bin_overlays',
                     'DATA', '02_AREA.B')
    rows = []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith('.BIN'):
            continue
        try:
            ov = Overlay(os.path.join(d, fn))
            secs = ov.sections()
        except Exception as exc:                    # noqa: BLE001 - report, don't hide
            rows.append({'overlay': fn[:-4], 'error': '%s: %s' % (type(exc).__name__, exc)})
            continue
        for slot, va, w, h in secs:
            rec = resolve_room(ov, slot)
            if not rec or not rec.get('descriptor_types'):
                rows.append({'overlay': ov.name, 'slot': slot, 'w': w, 'h': h,
                             'palette_bases': None})
                continue
            rows.append({
                'overlay': ov.name, 'slot': slot, 'w': w, 'h': h,
                'palette_bases': [e.get('palette_base_byte')
                                  for e in rec['descriptor_types']],
                'resolved': [e['type'] for e in rec['descriptor_types']
                             if e.get('palette_base_byte') is not None],
            })
    hdr = '%-10s %5s %4s %4s  %s' % ('overlay', 'slot', 'w', 'h', 'type palette_base bytes')
    print(hdr)
    print('-' * len(hdr))
    for r in rows:
        if 'error' in r:
            print('%-10s ERROR %s' % (r['overlay'], r['error']))
            continue
        pb = r.get('palette_bases')
        print('%-10s %5d %4d %4d  %s' % (r['overlay'], r['slot'], r['w'], r['h'],
                                         pb if pb is not None else '(chain unresolved)'))
    if args.json:
        with open(args.json, 'w') as fh:
            json.dump(rows, fh, indent=2, sort_keys=True)
        print('wrote %s' % args.json)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('sites', help='section-global reader map')
    p.set_defaults(func=cmd_sites)
    p = sub.add_parser('emit', help='primitive CLUT field spec')
    p.set_defaults(func=cmd_emit)
    p = sub.add_parser('room', help='resolve one room')
    p.add_argument('overlay')
    p.add_argument('room', nargs='?')
    p.add_argument('--json')
    p.set_defaults(func=cmd_room)
    p = sub.add_parser('rooms', help='table over all 02_AREA.B rooms')
    p.add_argument('--json')
    p.set_defaults(func=cmd_rooms)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == '__main__':
    raise SystemExit(main())
