#!/usr/bin/env python3
"""Canonical 04_PLAY character-sprite container parser.

Single source of truth for the container format shared by the 78 files in
DATA/04_PLAY/ (e.g. AIL.BIN). Replaces two contradictory tools:

- tools/sprite_04play_decode.py -- read the offset table at file+0x34 as
  17 x u16 (WRONG). The table holds 32-bit file offsets; the 16-bit read
  yields alternating offsets and zeros (0x0328, 0x0000, 0x0330, ...).
- tools/relocate_04play.py -- read the table correctly as u32, but at a
  FIXED file+0x34 instead of following the u32 pointer at file+0x20.
  Works for every file in the current disc revision (all 78 have the
  pointer = 0x34) only by coincidence.

This parser follows the u32 @0x20 pointer, reads 32-bit entries to a zero
terminator, reproduces the game's relocation semantics
(file_postload_relocate @0x800C49B8 + struct_ptr_relocate @0x800C473C,
verified against capstone disassembly of MAIN.EXE -- see
docs/decode_04play_relocated.md) as a PURE function returning a
structure, and validates every pointer. Malformed input produces explicit
errors, never silent garbage.

Container (all integers little-endian), verified on AIL.BIN (16,012 B):

    0x00: 32-byte file header (opaque)
    0x20: 5 x u32 -> [offset_table_ptr, S1, S2, S3, S4]
    offset_table_ptr: zero-terminated u32 file offsets (pointed-to tables'
                      contents are NOT relocated by the game)
    S1/S2: section header, then c/d/e/f pointer tables:
        +0x00 u16 a            -> e-table entry count (signed)
        +0x02 u16 b            -> f-table entry count (signed)
        +0x04 u8  c_count      -> c-table entry count
        +0x05 u8  d_flags      -> d-table count = flags & 0x3F;
                                  bit 7-6 set => 32-color CLUT upload path,
                                  clear => 256-color palette path
        +0x06 u8  return_value -> lbu(s1+6), returned by file_play_processor
        +0x07 u8  (unknown)
        +0x08 u32 c_table_ptr  -> LZSS-compressed graphics blobs
                                  ([u32 len][LZSS...]); the game LZSS-decodes
                                  each and LoadImages the result to VRAM.
                                  NOT descriptor-only.
        +0x0C u32 d_table_ptr  -> palette pointers (32 or 256 RGB555 words,
                                  raw, no length prefix)
        +0x10 u32 e_table_ptr  ->8-byte piece header + count*8-byte sub-pieces
        +0x14 u32 f_table_ptr  ->4-byte sequence header + count*2-byte timed pairs
    S3: u32 size + data (contents NOT relocated)
    S4: 256 x u16 RGB555 palette, 512 bytes (contents NOT relocated)

Game relocation semantics encoded here (the game MUTATES the loaded image;
this parser only REPORTS both values):
    header[0..4]                   : value += base  (become RAM pointers)
    offset-table entries           : each nonzero entry += base, to terminator
    section fields +8/+0xC/+0x10/+0x14 : += base; then each table entry += base

The c-blobs use canonical LZSS and128x128 index planes. The live S1 route
passes loaded-file+24 through800E1E3C/800E2044/800E211C; its countdown update
is800E2A9C. See play_s1_consumers.md. Legacy raw-prefix record keys remain
for callers; header/sub_pieces and sequence carry the interpreted structure.

Usage:
    parse_04play.py FILE.BIN [--base 0x...]   -> JSON on stdout
Exit: 0 = parsed clean, 2 = parsed with validation errors, 1 = usage/IO error.
"""

import struct
import sys
import os
import json
import hashlib

_TOOLS = os.path.dirname(os.path.abspath(__file__))
if _TOOLS not in sys.path:
    sys.path.insert(0, _TOOLS)
from psx_vram import rgb555_to_rgb888 as _psx_rgb555_to_rgb888  # noqa: E402

PARSER_VERSION = "1.1.0"

# Game-verified constants (do not "tune").
HEADER_OFF = 0x20
HEADER_SLOTS = ("offset_table_ptr", "S1", "S2", "S3", "S4")
# The character-container loader rebases all five header pointer slots.
HEADER_RELOCATED_BY_GAME = (True, True, True, True, True)
OFFSET_TABLE_ENTRY_CAP = 4096  # sane cap; error if no zero terminator by then
E_RECORD_SIZE = 16             # legacy prefix; full size is8+8*sub_piece_count
S4_PALETTE_WORDS = 256

# Historical record of failed pixel-codec attempts (kept so future sprite
# work does not repeat them). Full detail: docs/sprite_codec_04play.md.
FAILED_CODEC_ATTEMPTS = [
    "FACE-LZSS (MSB flags, 1=literal, 4K zero window, absolute offsets)",
    "text_lzss (LSB flags, hpos=0x3DE, abs+rel matches+RLE) -- degenerate zeros",
    "LZSS sweep: MSB/LSB x lit=0/1 x 256-4K windows x 4/4,8/4,12/4,7/5,11/5 tokens",
    "LZSS with absolute (non-relative) match offsets",
    "LZSS with palette-prefilled history",
    "RLE (98.5% singletons -- not RLE)",
    "raw 8bpp / 4bpp / 16bpp-555 renders at multiple widths",
    "signed/unsigned delta decoding",
    "XOR 0xFF/0xAA/0x55, nibble-swap, bit-reverse",
    "16-bit word / (x,y) coordinate-pair interpretations",
    "PS1 GPU command-stream hypothesis",
]


class ParseError(Exception):
    """Raised for malformed input. Message goes into validation.errors."""


def _hex(v):
    return "0x%08x" % (v & 0xFFFFFFFF)


class Parser:
    """Strict, read-only 04_PLAY parser. Accumulates errors/warnings."""

    def __init__(self, data, base):
        self.d = data
        self.n = len(data)
        self.base = base
        self.errors = []
        self.warnings = []
        self._regions = []  # (start, end, description) for overlap detection

    # -- low-level strict readers --------------------------------------
    def _need(self, off, size, what):
        if off < 0 or off + size > self.n:
            raise ParseError(
                "%s at file+0x%x (+%d) overruns file (%d bytes)"
                % (what, off, size, self.n))

    def u32(self, off, what="u32"):
        self._need(off, 4, what)
        return struct.unpack("<I", self.d[off:off + 4])[0]

    def u16(self, off, what="u16"):
        self._need(off, 2, what)
        return struct.unpack("<H", self.d[off:off + 2])[0]

    def i16(self, off, what="i16"):
        self._need(off, 2, what)
        return struct.unpack("<h", self.d[off:off + 2])[0]

    def ptr(self, field_off, raw, relocated_by_game, desc):
        """A relocated pointer: original file offset AND resolved value."""
        if raw >= self.n:
            raise ParseError(
                "%s: pointer value 0x%x at file+0x%x out of bounds "
                "(file size %d)" % (desc, raw, field_off, self.n))
        return {
            "field_file_offset": field_off,
            "raw_file_offset": raw,
            "relocated": _hex(self.base + raw),
            "relocated_by_game": relocated_by_game,
            "description": desc,
        }

    def warn(self, kind, message, **kw):
        w = {"kind": kind, "message": message}
        w.update(kw)
        self.warnings.append(w)

    def region(self, start, end, desc):
        self._regions.append((start, end, desc))

    # -- header ---------------------------------------------------------
    def parse_header(self):
        if self.n < HEADER_OFF + 20:
            raise ParseError(
                "file too small for 04_PLAY header: %d bytes (need >= 0x34)"
                % self.n)
        slots = []
        raw_vals = []
        for i, name in enumerate(HEADER_SLOTS):
            foff = HEADER_OFF + i * 4
            raw = self.u32(foff, "header slot %s" % name)
            raw_vals.append(raw)
            slots.append(dict(
                self.ptr(foff, raw, HEADER_RELOCATED_BY_GAME[i],
                         "header[%d] %s" % (i, name)),
                name=name))
        return {"field_offset": HEADER_OFF, "slots": slots,
                "raw_values": raw_vals}

    # -- offset table ---------------------------------------------------
    def parse_offset_table(self, table_ptr):
        if table_ptr >= self.n:
            raise ParseError(
                "offset table pointer 0x%x out of bounds (file size %d)"
                % (table_ptr, self.n))
        entries = []
        off = table_ptr
        while True:
            idx = len(entries)
            if idx >= OFFSET_TABLE_ENTRY_CAP:
                raise ParseError(
                    "offset table at file+0x%x has no zero terminator "
                    "within %d entries -- refusing to read further"
                    % (table_ptr, OFFSET_TABLE_ENTRY_CAP))
            v = self.u32(off, "offset table entry %d" % idx)
            if v == 0:
                break
            e = dict(self.ptr(off, v, True,
                              "offset_table[%d]" % idx),
                       index=idx, target_file_offset=v)
            entries.append(e)
            off += 4
        self.region(table_ptr, off + 4, "offset_table[%d entries]" % len(entries))
        return {
            "table_file_offset": table_ptr,
            "count": len(entries),
            "terminator_file_offset": off,
            "entries": entries,
        }

    # -- section (S1/S2) -------------------------------------------------
    def parse_section(self, name, sec_off):
        if sec_off >= self.n:
            raise ParseError(
                "%s section offset 0x%x out of bounds (file size %d)"
                % (name, sec_off, self.n))
        self._need(sec_off, 0x18, "%s section header" % name)
        a = self.i16(sec_off, "%s.a" % name)
        b = self.i16(sec_off + 2, "%s.b" % name)
        c_count = self.d[sec_off + 4]
        d_flags = self.d[sec_off + 5]
        ret_val = self.d[sec_off + 6]
        unk7 = self.d[sec_off + 7]
        d_count = d_flags & 0x3F
        # Bit 7-6 of d_flags select the CLUT upload path (see
        # file_play_processor @0x800C3810): set -> 32-color, clear -> 256-color.
        palette_words = 32 if (d_flags & 0xC0) else 256

        def cnt(v, what):
            if v < 0:
                self.warn("negative_count",
                          "%s %s count %d < 0; clamped to 0" % (name, what, v),
                          section=name, field=what, raw=v)
                return 0
            return v

        a, b = cnt(a, "a(e)"), cnt(b, "b(f)")

        c_tab = self.u32(sec_off + 8, "%s.c_table_ptr" % name)
        d_tab = self.u32(sec_off + 0x0C, "%s.d_table_ptr" % name)
        e_tab = self.u32(sec_off + 0x10, "%s.e_table_ptr" % name)
        f_tab = self.u32(sec_off + 0x14, "%s.f_table_ptr" % name)

        header = {
            "a_e_count": a, "b_f_count": b,
            "c_count": c_count, "d_flags": "0x%02x" % d_flags,
            "d_count": d_count, "return_value_u8": ret_val,
            "unknown_u8_7": "0x%02x" % unk7,
            "palette_words": palette_words,
            "palette_path": ("32-color CLUT" if (d_flags & 0xC0)
                             else "256-color palette"),
            "c_table": self.ptr(sec_off + 8, c_tab, True, name + ".c_table"),
            "d_table": self.ptr(sec_off + 0x0C, d_tab, True, name + ".d_table"),
            "e_table": self.ptr(sec_off + 0x10, e_tab, True, name + ".e_table"),
            "f_table": self.ptr(sec_off + 0x14, f_tab, True, name + ".f_table"),
        }

        c = self._parse_c_table(name, c_tab, c_count)
        dtab = self._parse_d_table(name, d_tab, d_count, palette_words)
        e = self._parse_e_table(name, e_tab, a)
        f = self._parse_f_table(name, f_tab, b)

        return {"name": name, "file_offset": sec_off,
                "header": header, "c": c, "d": dtab, "e": e, "f": f}

    def _parse_ptr_table(self, name, tab, count, table_kind):
        """Shared: validate a u32 pointer table, return entry targets."""
        if count == 0:
            return []
        if tab >= self.n:
            raise ParseError(
                "%s %s table pointer 0x%x out of bounds" % (name, table_kind, tab))
        self._need(tab, 4 * count, "%s %s table" % (name, table_kind))
        self.region(tab, tab + 4 * count,
                    "%s.%s_table[%d]" % (name, table_kind, count))
        entries = []
        for k in range(count):
            foff = tab + k * 4
            raw = self.u32(foff, "%s.%s[%d]" % (name, table_kind, k))
            entries.append(dict(
                self.ptr(foff, raw, True,
                         "%s.%s[%d]" % (name, table_kind, k)),
                index=k, target_file_offset=raw))
        # aliasing: two entries -> same target
        seen = {}
        for e in entries:
            t = e["target_file_offset"]
            if t in seen:
                self.warn("aliased_target",
                          "%s: table entries %d and %d both point at "
                          "file+0x%x" % (table_kind, seen[t], e["index"], t),
                          section=name, table=table_kind,
                          indices=[seen[t], e["index"]], target=t)
            else:
                seen[t] = e["index"]
        return entries

    def _parse_c_table(self, name, tab, count):
        entries = self._parse_ptr_table(name, tab, count, "c")
        for e in entries:
            t = e["target_file_offset"]
            self._need(t, 4, "%s.c[%d] length field" % (name, e["index"]))
            (ln,) = struct.unpack("<I", self.d[t:t + 4])
            if ln == 0:
                self.warn("zero_length_blob",
                          "%s.c[%d] at file+0x%x has zero length field"
                          % (name, e["index"], t),
                          section=name, index=e["index"], target=t)
            if t + 4 + ln > self.n:
                raise ParseError(
                    "%s.c[%d]: LZSS blob at file+0x%x claims len %d, "
                    "overruns file (%d bytes)"
                    % (name, e["index"], t, ln, self.n))
            e["blob"] = {
                "len_field": ln,
                "data_file_offset": t + 4,
                "data_len": ln,
                "end_file_offset": t + 4 + ln,
                "note": "LZSS-compressed graphics block; game decodes via "
                        "text_decode_stream @0x800C3144 and LoadImages the "
                        "result to VRAM (NOT descriptor-only)",
            }
            self.region(t + 4, t + 4 + ln,
                        "%s.c[%d]_blob" % (name, e["index"]))
        return {"table_file_offset": tab, "count": count, "entries": entries}

    def _parse_d_table(self, name, tab, count, palette_words):
        entries = self._parse_ptr_table(name, tab, count, "d")
        for e in entries:
            t = e["target_file_offset"]
            size = 2 * palette_words
            self._need(t, size, "%s.d[%d] palette" % (name, e["index"]))
            words = struct.unpack("<%dH" % palette_words, self.d[t:t + size])
            e["palette"] = {
                "words": palette_words,
                "byte_size": size,
                "rgb555": ["0x%04x" % w for w in words],
                "rgb888": [rgb555_to_rgb888(w) for w in words],
            }
            self.region(t, t + size, "%s.d[%d]_palette" % (name, e["index"]))
        return {"table_file_offset": tab, "count": count,
                "palette_words": palette_words, "entries": entries}

    def _parse_e_table(self, name, tab, count):
        entries = self._parse_ptr_table(name, tab, count, "e")
        for e in entries:
            t = e["target_file_offset"]
            self._need(t, E_RECORD_SIZE, "%s.e[%d] record" % (name, e["index"]))
            rec = self.d[t:t + E_RECORD_SIZE]
            u, v, w, h = rec[0], rec[1], rec[2], rec[3]
            texpage, clut = struct.unpack("<HH", rec[4:8])
            src, reserved = struct.unpack("<II", rec[8:16])
            e["record"] = {
                "u": u, "v": v, "w": w, "h": h,
                "texpage": "0x%04x" % texpage,
                "clut": "0x%04x" % clut,
                "src": "0x%08x" % src,
                "src_note": "legacy packed first-sub-piece bytes0..3, not a pixel offset; "
                            "800E211C walks8-byte sub-pieces after the8-byte header",
                "legacy_field_note": "u/v/texpage/clut/reserved are retained raw-prefix "
                                     "keys; use header_hex/sub_pieces for the actual structure",
                "header_hex": rec[:8].hex(),
                "sub_piece_count": rec[0],
                "reserved": "0x%08x" % reserved,
                "raw_hex": rec.hex(),
            }
            size = 8 + 8 * rec[0]
            self._need(t, size, "%s.e[%d] sub-pieces" % (name, e["index"]))
            e["record"]["sub_pieces"] = [dict(zip(
                ("x_offset", "y_offset", "slot_delta", "tile", "width_minus_one",
                 "height_minus_one", "palette_delta", "flags"),
                self.d[t+8+8*k:t+16+8*k])) for k in range(rec[0])]
            self.region(t, t + size,
                        "%s.e[%d]_record" % (name, e["index"]))
        return {"table_file_offset": tab, "count": count,
                "record_size": E_RECORD_SIZE,
                "record_size_note": "legacy prefix only; full records are8+8*count bytes",
                "entries": entries}

    def _parse_f_table(self, name, tab, count):
        entries = self._parse_ptr_table(name, tab, count, "f")
        spacings = {entries[i+1]["target_file_offset"]-entries[i]["target_file_offset"]
                    for i in range(len(entries)-1)}
        rec_size = next(iter(spacings)) if len(spacings)==1 else None
        if rec_size is not None and rec_size<=0:
            rec_size=None
        # Keep the spacing-model keys for callers; lengths come from the header.
        model = "fixed_records" if rec_size is not None else "stream_offsets"
        for e in entries:
            t=e["target_file_offset"]
            self._need(t,4,"%s.f[%d] header" % (name,e["index"]))
            n,flags,capacity,reserved=self.d[t:t+4]
            size=4+2*n
            self._need(t,size,"%s.f[%d] pairs" % (name,e["index"]))
            e["raw_hex"]=self.d[t:t+size].hex()
            e["sequence"]={"frame_count":n,"flags":flags,
                           "draw_capacity":capacity,"reserved":reserved,
                           "pairs":[list(self.d[t+4+2*k:t+6+2*k]) for k in range(n)]}
            self.region(t,t+size,"%s.f[%d]_record" % (name,e["index"]))
        offsets=[e["target_file_offset"] for e in entries]
        end=max((e["target_file_offset"]+len(bytes.fromhex(e["raw_hex"]))
                 for e in entries),default=None)
        return {"table_file_offset":tab,"count":count,"model":model,
                "stream_start_file_offset":min(offsets) if offsets else None,
                "last_entry_file_offset":max(offsets) if offsets else None,
                "stream_end_file_offset":end,"record_size":rec_size,
                "record_size_source":"entry_spacing" if rec_size is not None else None,
                "record_size_note":"physical spacing only; sequences are4-byte headers "
                                   "followed by frame_count*(draw index,duration) pairs",
                "sequence_layout":"counted_pairs","entries":entries}

    # -- S3 / S4 ----------------------------------------------------------
    def parse_s3(self, s3_off):
        if s3_off >= self.n:
            raise ParseError("S3 offset 0x%x out of bounds" % s3_off)
        self._need(s3_off, 4, "S3 size field")
        (size,) = struct.unpack("<I", self.d[s3_off:s3_off + 4])
        if s3_off + 4 + size > self.n:
            raise ParseError(
                "S3 at file+0x%x claims size %d, overruns file (%d bytes)"
                % (s3_off, size, self.n))
        self.region(s3_off + 4, s3_off + 4 + size, "S3_data")
        return {"file_offset": s3_off, "relocated": _hex(self.base + s3_off),
                "size_field": size,
                "data_file_offset": s3_off + 4, "data_len": size,
                "note": "contents NOT relocated by the game"}

    def parse_s4(self, s4_off):
        size = 2 * S4_PALETTE_WORDS
        if s4_off >= self.n:
            raise ParseError("S4 offset 0x%x out of bounds" % s4_off)
        self._need(s4_off, size, "S4 palette")
        words = struct.unpack("<%dH" % S4_PALETTE_WORDS,
                              self.d[s4_off:s4_off + size])
        self.region(s4_off, s4_off + size, "S4_palette")
        return {"file_offset": s4_off, "relocated": _hex(self.base + s4_off),
                "length": size, "palette_words": S4_PALETTE_WORDS,
                "rgb555": ["0x%04x" % w for w in words],
                "rgb888": [rgb555_to_rgb888(w) for w in words],
                "note": "256-color RGB555 palette; contents NOT relocated "
                        "by the game. Use this (or the d-table palettes), "
                        "not the heuristic palette scan."}

    # -- overlap detection -------------------------------------------------
    def check_overlaps(self):
        regs = sorted(self._regions)
        for i in range(len(regs)):
            for j in range(i + 1, len(regs)):
                a0, a1, ad = regs[i]
                b0, b1, bd = regs[j]
                if b0 >= a1:
                    break
                if b0 < a1 and b1 > a0 and ad != bd:
                    self.warn("data_overlap",
                              "regions overlap: '%s' [0x%x,0x%x) vs '%s' "
                              "[0x%x,0x%x)" % (ad, a0, a1, bd, b0, b1),
                              a={"desc": ad, "start": a0, "end": a1},
                              b={"desc": bd, "start": b0, "end": b1})

    # -- region labels for offset-table targets -----------------------------
    def region_of(self, t, bounds):
        # bounds: sorted list of (offset, label); label = latest boundary <= t
        label = "file_header"
        for off, name in bounds:
            if t >= off:
                label = name
            else:
                break
        return label


def rgb555_to_rgb888(w):
    return list(_psx_rgb555_to_rgb888(w))


def parse_04play(path, base=0xB0000000):
    """Parse a 04_PLAY file. Returns the canonical structure dict.

    Raises ParseError on malformed input (also recorded in
    validation.errors when called via main()).
    """
    with open(path, "rb") as f:
        data = f.read()
    p = Parser(data, base)
    header = p.parse_header()
    raw = header["raw_values"]
    table_ptr, s1_off, s2_off, s3_off, s4_off = raw

    offset_table = p.parse_offset_table(table_ptr)
    s1 = p.parse_section("S1", s1_off)
    s2 = p.parse_section("S2", s2_off)
    s3 = p.parse_s3(s3_off)
    s4 = p.parse_s4(s4_off)

    # label offset-table targets with approximate regions
    bounds = sorted([
        (table_ptr, "offset_table"),
        (offset_table["terminator_file_offset"] + 4, "post_table"),
        (s1_off, "S1"), (s2_off, "S2"), (s3_off, "S3"), (s4_off, "S4"),
    ])
    for e in offset_table["entries"]:
        e["approx_region"] = p.region_of(e["target_file_offset"], bounds)

    p.check_overlaps()

    return {
        "provenance": {
            "parser": "parse_04play",
            "parser_version": PARSER_VERSION,
            "source_path": os.path.abspath(path),
            "source_sha256": hashlib.sha256(data).hexdigest(),
            "source_size": len(data),
            "load_base": _hex(base),
        },
        "header": header,
        "offset_table": offset_table,
        "sections": {"S1": s1, "S2": s2, "S3": s3, "S4": s4},
        "relocation_model": {
            "note": "file_postload_relocate @0x800C49B8 + struct_ptr_relocate "
                    "@0x800C473C, verified against capstone disassembly",
            "header_slots_relocated_by_game": dict(
                zip(HEADER_SLOTS, HEADER_RELOCATED_BY_GAME)),
            "offset_table_entries_relocated": True,
            "pointed_to_table_contents_relocated": False,
            "section_contents_relocated": "c/d/e/f table FIELDS and ENTRIES "
                                          "only; blob/record/palette bytes untouched",
        },
        "validation": {"errors": p.errors, "warnings": p.warnings},
    }


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(
        description="Canonical 04_PLAY container parser -> JSON.")
    ap.add_argument("file", help="04_PLAY .BIN file")
    ap.add_argument("--base", default="0xB0000000",
                    help="simulated load base (default 0xB0000000)")
    args = ap.parse_args(argv)
    try:
        base = int(args.base, 0)
    except ValueError:
        print(json.dumps({"fatal": "bad --base value: %r" % args.base}))
        return 1
    if not os.path.isfile(args.file):
        print(json.dumps({"fatal": "not a file: %s" % args.file}))
        return 1
    try:
        result = parse_04play(args.file, base)
    except ParseError as e:
        # Malformed input: explicit error object, never silent garbage.
        with open(args.file, "rb") as f:
            data = f.read()
        result = {
            "provenance": {
                "parser": "parse_04play",
                "parser_version": PARSER_VERSION,
                "source_path": os.path.abspath(args.file),
                "source_sha256": hashlib.sha256(data).hexdigest(),
                "source_size": len(data),
                "load_base": _hex(base),
            },
            "fatal_parse_error": str(e),
            "validation": {"errors": [{"kind": "fatal",
                                       "message": str(e)}],
                           "warnings": []},
        }
        print(json.dumps(result, indent=2))
        return 2
    print(json.dumps(result, indent=2))
    return 2 if result["validation"]["errors"] else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
