#!/usr/bin/env python3
"""
Suikoden PS1 Text Decoder

Decodes text from Suikoden's disc files using the reverse-engineered
text pipeline:

  [Stored bytes] → LZSS decompress → Byte translate → ASCII output
                   text_decode_stream  char_encoding_translate
                   (0x800C3144)        (0x80133BB4)

Status:
  - LZSS decompressor: FULLY REVERSE-ENGINEERED and implemented
  - Byte translation: MECHANISM known; TABLE IS RUNTIME-BUILT PER AREA
    (see build_translation_table(); docs/translation_table.md).
    The old "static 256x8 blob on disc" theory is refuted — the table is
    malloc(count*8), filled by area_tile_table_builder @ 0x8012ed84 from
    the area's tile/character source data. No static table exists to dump.
  - ASCII string tables: PROVEN (VZ8.BIN staff credits)

Usage:
  python3 suikoden_text_decode.py --credits    # Self-test: decode VZ8 staff credits
  python3 suikoden_text_decode.py --table-test # Self-test: table builder logic
  python3 suikoden_text_decode.py --lzss FILE OFFSET LENGTH  # Decompress LZSS blob

Author: Chummie (2026-10-01)
Method: Static disassembly only (no emulator)
"""

import sys
import os

# Import the LZSS decompressor
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from text_lzss import decompress as lzss_decompress


def extract_ascii_strings(data: bytes, min_len: int = 4):
    """
    Extract null-terminated ASCII strings from a binary blob.
    
    This handles the VZ8.BIN staff credits format:
    - Plain ASCII bytes
    - Null-terminated (0x00)
    - Padded to 4-byte alignment
    
    Returns: list of (offset, string) tuples
    """
    results = []
    i = 0
    while i < len(data):
        # Look for start of printable ASCII sequence
        if 32 <= data[i] < 127:
            start = i
            # Find null terminator or non-printable
            while i < len(data) and 32 <= data[i] < 127:
                i += 1
            # Check if null-terminated
            if i < len(data) and data[i] == 0:
                s = data[start:i].decode('ascii')
                if len(s) >= min_len:
                    results.append((start, s))
            # Skip nulls and padding
            while i < len(data) and data[i] == 0:
                i += 1
        else:
            i += 1
    return results


def decode_credits(filepath: str, offset: int = 0x1C14, max_len: int = 0x800):
    """
    Decode the staff credits from VZ8.BIN.
    
    These are stored as plain ASCII in a string table.
    This is the PROVEN text format (self-test target).
    """
    with open(filepath, 'rb') as f:
        f.seek(offset)
        data = f.read(max_len)
    
    strings = extract_ascii_strings(data, min_len=3)
    return strings


def lzss_decode_blob(filepath: str, offset: int, length: int):
    """
    Decompress an LZSS blob using text_decode_stream format.
    
    Format (from 0x800C3144 disassembly):
    - LSB-first flag bits
    - Flag 0 = literal, Flag 1 = control (match/RLE)
    - 1KB history buffer
    
    Returns: decompressed bytes
    """
    with open(filepath, 'rb') as f:
        f.seek(offset)
        data = f.read(length)
    
    return lzss_decompress(data)


# Translation table (char_encoding_translate @ 0x80133BB4)
#
# CORRECTION (2026-10-01): the table is NOT a static 256x8 blob on disc.
# It is built at runtime, per area load, by area_tile_table_builder @ 0x8012ed84:
#   - malloc(count*8) @ 0x8012ef00, stored at *(0x8017BE20)+0x484 @ 0x8012ef28
#     (the ONLY store to that slot in MAIN.EXE — verified by whole-binary scan)
#   - count = *(0x8017DBFC) = number of accepted 0x18-byte source entries
#   - source entries at *(0x8017BF98), from the area loader (runtime data)
#
# 8-byte entry layout (from the fill code):
#   byte 0 : tile/descriptor index (Path A) or 0xFF (Path B = invalid char)
#            -- this is the ONLY byte char_encoding_translate reads
#   byte 1 : flags = ((src_u16>>9)&1) | (0x20 if src_u16 & 0x400)  (Path A; 0 in Path B)
#   bytes 2-3 : NEVER WRITTEN (uninitialized malloc memory — mask off!)
#   bytes 4-7 : pointer to the 24-byte tile descriptor entry (Path A; 0 in Path B)
#
# Full story: kit/docs/translation_table.md
#
# Because the table is computed per area at runtime, there is no static
# translation_table.bin to ship. Instead, build_translation_table() below
# reimplements the fill logic: feed it real 0x18-byte source entries and it
# produces the exact table the game would build (descriptor pointers excepted —
# those are runtime RAM addresses, stored here as 0 and documented).

# Entry-field indices (byte offsets within each 8-byte entry)
ENTRY_TILE_INDEX = 0   # u8: descriptor index, or 0xFF if char invalid
ENTRY_FLAGS      = 1   # u8: bit0=(src_u16>>9)&1, bit5 set if src_u16&0x400
# bytes 2-3: unwritten (garbage in RAM; we emit 0x00)
ENTRY_DESC_PTR   = 4   # u32: runtime pointer to 24-byte descriptor (0 = unknown)

ENTRY_SIZE = 8
SRC_ENTRY_SIZE = 0x18


def build_translation_table(source_entries, classifier=None):
    """
    Reimplement area_tile_table_builder's table fill (0x8012ed84).

    source_entries: iterable of 24-byte (0x18) entries, as bytes.
        Only two fields matter:
          - u16 little-endian at +4 : filter/flag bits
          - u32 little-endian at +12: input to the classifier
    classifier: optional callable(u32_at_plus12) -> int.
        Reimplements 0x8013d8e0's low byte. If None, every entry whose
        filter passes takes Path A (the common case); entries failing the
        filter are skipped (they never occupy table slots).

    Returns: bytes — 8 bytes per ACCEPTED entry, in acceptance order.
        byte0 = sequential index (Path A) or 0xFF (Path B),
        byte1 = flags, bytes2-3 = 0x00, bytes4-7 = 0x00000000
        (real ROM build leaves 2-3 uninitialized and 4-7 = RAM pointer).

    Faithful to:
      Path A (0x8012f278/0x8012f28c/0x8012f2a8/0x8012f2d0):
        sb count,0(s3); sb flags,1(s3); sw desc_ptr,4(s3)
      Path B (0x8012f364/0x8012f368/0x8012f36c):
        sb 0xFF,0(s3); sb 0,1(s3); sw 0,4(s3)
    """
    import struct
    table = bytearray()
    count = 0
    for src in source_entries:
        if len(src) < SRC_ENTRY_SIZE:
            raise ValueError(f"source entry too short: {len(src)} < 24")
        filt = struct.unpack_from('<H', src, 4)[0]
        if (filt & 0x101) == 0:
            # Rejected: builder marks src byte0 = 0xFF and takes no table slot
            # (0x8012f394 path). No bytes emitted.
            continue
        word12 = struct.unpack_from('<I', src, 12)[0]
        v = (classifier(word12) & 0xFF) if classifier else 0
        entry = bytearray(ENTRY_SIZE)
        if v == 0:
            # Path A: valid char -> tile index
            entry[ENTRY_TILE_INDEX] = count & 0xFF
            flags = ((filt >> 9) & 1)
            if filt & 0x400:
                flags |= 0x20
            entry[ENTRY_FLAGS] = flags
            # bytes 2-3: left as 0x00 here (garbage in RAM)
            # bytes 4-7: runtime descriptor pointer; unknowable statically
            struct.pack_into('<I', entry, ENTRY_DESC_PTR, 0)
        else:
            # Path B: classifier nonzero -> invalid char marker
            entry[ENTRY_TILE_INDEX] = 0xFF
            entry[ENTRY_FLAGS] = 0
            struct.pack_into('<I', entry, ENTRY_DESC_PTR, 0)
        table += entry
        count += 1
    return bytes(table)


def translate_byte(raw: int, table: bytes | None) -> int:
    """
    Translate a raw text byte via a built translation table.

    From char_encoding_translate (0x80133BB4):
        table_ptr = *(*(0x8017BE20) + 1156)
        if table_ptr == NULL: return 0x80
        return table_ptr[(raw & 0xFF) * 8]   # byte 0 of the 8-byte entry

    table: bytes produced by build_translation_table(), or None for NULL.
    NOTE: the real table has `count` entries (per-area), NOT always 256.
    Indexing beyond len(table) is out-of-bounds in the real game too.
    """
    if table is None:
        return 0x80
    raw &= 0xFF
    off = raw * ENTRY_SIZE
    if off >= len(table):
        raise IndexError(
            f"byte 0x{raw:02X} indexes past {len(table)//ENTRY_SIZE}-entry table "
            f"(per-area table, not 256 entries)"
        )
    return table[off + ENTRY_TILE_INDEX]


def self_test():
    """
    Self-test: Decode the VZ8.BIN staff credits.
    
    This proves the ASCII string table extraction works on real game data.
    Expected output includes "GENSO SUIKODEN STAFF", "PRODUCER", etc.
    """
    print("=" * 70)
    print("Suikoden Text Decoder — Self-Test")
    print("=" * 70)
    print()
    print("Test: Extract ASCII staff credits from VZ8.BIN")
    print("File: kit/extracted/bin_overlays/DATA/15_AREA.Z/VZ8.BIN")
    print("Offset: 0x1C14 (proven location)")
    print()
    
    # Locate the file
    base = os.path.dirname(os.path.abspath(__file__))
    # Try multiple possible locations
    candidates = [
        os.path.join(base, "../extracted/bin_overlays/DATA/15_AREA.Z/VZ8.BIN"),
        os.path.join(base, "../../kit/extracted/bin_overlays/DATA/15_AREA.Z/VZ8.BIN"),
        os.path.join(_KIT, "extracted/bin_overlays/DATA/15_AREA.Z/VZ8.BIN"),
    ]
    
    filepath = None
    for c in candidates:
        if os.path.exists(c):
            filepath = c
            break
    
    if not filepath:
        print("FAIL: VZ8.BIN not found. Tried:")
        for c in candidates:
            print(f"  {c}")
        return False
    
    print(f"Found: {filepath}")
    print()
    
    strings = decode_credits(filepath)
    
    if not strings:
        print("FAIL: No strings extracted")
        return False
    
    print(f"Extracted {len(strings)} strings:")
    print("-" * 70)
    for offset, s in strings[:25]:  # First 25
        print(f"  0x{offset:04X}: {s}")
    if len(strings) > 25:
        print(f"  ... and {len(strings) - 25} more")
    print("-" * 70)
    print()
    
    # Verify expected strings are present
    text = " ".join(s for _, s in strings)
    expected = ["GENSO SUIKODEN STAFF", "PRODUCER", "KITAUE KAZUMI", "DIRECTOR"]
    missing = [e for e in expected if e not in text]
    
    if missing:
        print(f"FAIL: Missing expected strings: {missing}")
        return False
    
    print("PASS: All expected staff credit strings found!")
    print()
    print("This proves:")
    print("  1. The game stores some text as plain ASCII (null-terminated)")
    print("  2. The string table extraction works on real disc data")
    print("  3. VZ8.BIN contains the staff roll (not a warehouse)")
    print()
    print("Note: Dialogue text uses a different format (not ASCII).")
    print("      See docs/text_encoding.md for the full pipeline spec.")
    print("=" * 70)
    return True


def self_test_table():
    """
    Self-test: verify build_translation_table() against the disassembled
    fill logic (area_tile_table_builder @ 0x8012ed84).

    Uses synthetic 0x18-byte source entries exercising:
      - filter rejection  ((u16@+4 & 0x101) == 0 -> no table slot)
      - Path A            (filter pass, classifier 0 -> index + flags)
      - Path B            (filter pass, classifier != 0 -> 0xFF)
      - flag bit assembly ((src_u16>>9)&1, 0x20 bit from src_u16&0x400)
    """
    import struct
    print("=" * 70)
    print("Translation-table builder self-test")
    print("=" * 70)

    def mkentry(filt, word12=0):
        e = bytearray(SRC_ENTRY_SIZE)
        struct.pack_into('<H', e, 4, filt)
        struct.pack_into('<I', e, 12, word12)
        return bytes(e)

    # Entry 0: filter fails (bit 0x101 clear) -> rejected, no slot
    # Entry 1: filter pass (0x001), classifier 0 -> Path A, index 0
    # Entry 2: filter pass (0x100), classifier 5 -> Path B, 0xFF
    # Entry 3: filter pass (0x401 | 0x101... use 0x501), classifier 0
    #          -> Path A, index 1, flags bit0=1 (>>9 of 0x501 = 2 -> &1 = 0?)
    #          0x501>>9 = 2, &1 = 0; 0x501&0x400 = 0x400 -> flags = 0x20
    # Entry 4: filter 0x301: 0x301>>9 = 1 -> &1 = 1; 0x301&0x400 = 0 -> flags = 0x01
    #          -> Path A, index 2
    srcs = [
        mkentry(0x000),          # rejected
        mkentry(0x001),          # Path A
        mkentry(0x100, 0),       # Path B (classifier forced nonzero below)
        mkentry(0x501),          # Path A, flags 0x20
        mkentry(0x301),          # Path A, flags 0x01
    ]
    cls = lambda w: 0xFF if w == 0xDEAD else 0
    # Path B needs a nonzero classifier result: mark entry 2's word12
    srcs[2] = mkentry(0x100, 0xDEAD)
    table = build_translation_table(srcs, classifier=cls)

    n = len(table) // ENTRY_SIZE
    assert n == 4, f"expected 4 accepted entries, got {n}"
    assert len(table) == 4 * ENTRY_SIZE

    # Entry slots: [PathA idx0] [PathB 0xFF] [PathA idx2] [PathA idx3]
    # (Path A byte0 = acceptance count, which includes Path-B slots)
    assert table[0 * 8 + ENTRY_TILE_INDEX] == 0, "slot0 byte0 should be index 0"
    assert table[0 * 8 + ENTRY_FLAGS] == 0, "slot0 flags: 0x001>>9&1=0, no 0x400"
    assert table[1 * 8 + ENTRY_TILE_INDEX] == 0xFF, "slot1 byte0 should be 0xFF"
    assert table[1 * 8 + ENTRY_FLAGS] == 0, "slot1 flags should be 0"
    assert table[2 * 8 + ENTRY_TILE_INDEX] == 2, "slot2 byte0 should be index 2"
    assert table[2 * 8 + ENTRY_FLAGS] == 0x20, \
        f"slot2 flags should be 0x20, got 0x{table[2*8+ENTRY_FLAGS]:02X}"
    assert table[3 * 8 + ENTRY_TILE_INDEX] == 3, "slot3 byte0 should be index 3"
    assert table[3 * 8 + ENTRY_FLAGS] == 0x01, \
        f"slot3 flags should be 0x01, got 0x{table[3*8+ENTRY_FLAGS]:02X}"
    # bytes 4-7 are zero placeholders (runtime pointers unknowable statically)
    for i in range(4):
        assert table[i * 8 + 4:i * 8 + 8] == b'\x00\x00\x00\x00'

    # translate_byte: NULL table -> 0x80 (matches 0x80133BB4 beq path)
    assert translate_byte(0x41, None) == 0x80
    # translate_byte reads byte0 of the raw*8 entry
    assert translate_byte(0, table) == 0
    assert translate_byte(1, table) == 0xFF
    assert translate_byte(3, table) == 3
    # out-of-range index raises (real table is per-area, not 256 entries)
    try:
        translate_byte(4, table)
        raise AssertionError("expected IndexError for byte past table end")
    except IndexError:
        pass

    print("  entries built     : 4 (1 rejected by filter, as disassembled)")
    print("  byte0 sequence    : 00 FF 02 03  (slot index / 0xFF / slot index)")
    print("  flags sequence    : 00 00 20 01  (matches (u16>>9)&1 | 0x20 logic)")
    print("  NULL-table path   : translate_byte -> 0x80  (matches beq v1,zero)")
    print("  OOB index         : raises IndexError (table is per-area sized)")
    print("PASS: builder reimplementation matches disassembled fill logic")
    print("=" * 70)
    return True


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("--help", "-h"):
        print(__doc__)
        return
    
    if sys.argv[1] == "--credits":
        success = self_test()
        sys.exit(0 if success else 1)

    elif sys.argv[1] == "--table-test":
        success = self_test_table()
        sys.exit(0 if success else 1)
    
    elif sys.argv[1] == "--lzss":
        if len(sys.argv) != 5:
            print("Usage: --lzss FILE OFFSET LENGTH")
            print("  OFFSET and LENGTH can be hex (0x...) or decimal")
            sys.exit(1)
        filepath = sys.argv[2]
        offset = int(sys.argv[3], 0)
        length = int(sys.argv[4], 0)
        print(f"Decompressing LZSS blob: {filepath} @ 0x{offset:X} ({length} bytes)")
        try:
            out = lzss_decode_blob(filepath, offset, length)
            print(f"Decompressed: {len(out)} bytes")
            print(f"Text-like: {sum(1 for b in out if 32 <= b < 127) / max(1, len(out)):.1%} printable")
            print()
            print("First 500 bytes:")
            print(repr(out[:500]))
        except Exception as e:
            print(f"Error: {e}")
            sys.exit(1)
    
    else:
        print(f"Unknown command: {sys.argv[1]}")
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
