#!/usr/bin/env python3
"""
text_decode_demo.py — demonstrate the Suikoden text pipeline on real game bytes.

Mimics the MAIN.EXE path:
  dialogue_text_char_processor @ 0x8013B1E0
    v0 = lbu [0x8017AF84]++            # one raw byte from the script cursor
    tile = char_encoding_translate(v0) # @ 0x80133BB4: per-area 256x8 table
    (U,V) = text_char_decoder(tile)    # @ 0x8013AFA0: picks descriptor table

  text_char_decoder table select:
    code & 0x40  -> system-font table [0x8017AF94] + (code&0x3F)*24   (ASCII)
    else         -> area tile table   [0x8017DAA0] + code*24          (per-area)

For the US version the system-font table is ASCII-ordered (proven by the
font test strings ABADAFAH... in AZUKARI.BIN etc.), so bytes 0x40-0x7F
decode as ASCII directly. Bytes 0x00-0x3F need the per-area table
(runtime-built) and are shown as <tile:XX>.

Usage: python3 text_decode_demo.py
"""
import os
import sys

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)

BASE = os.path.join(_KIT, "extracted/bin_overlays/DATA")

def decode(raw: bytes) -> str:
    out = []
    for b in raw:
        if b == 0:
            break
        if 0x40 <= b <= 0x7F:
            # system-font path: ASCII
            out.append(chr(b))
        elif b == 0x0A:
            out.append("\n")
        else:
            # per-area tile path: needs runtime table; show placeholder
            out.append(f"<tile:{b:#04x}>")
    return "".join(out)

def show(label, relpath, offset, length=64):
    with open(os.path.join(BASE, relpath), "rb") as f:
        f.seek(offset)
        raw = f.read(length)
    print(f"--- {label} ({relpath} @ {offset:#x}) ---")
    print(f"raw bytes: {raw[:32].hex(' ')}")
    print(f"decoded:   {decode(raw)}")
    print()

def main():
    """Run the demonstration decodes."""
    show("Staff credit", "15_AREA.Z/VZ8.BIN", 0x1C14)
    show("Staff credit", "15_AREA.Z/VZ8.BIN", 0x1C84)
    show("Battle command", "02_AREA.B/B_DATA.BIN", 0x1C)
    show("Enemy name", "08_AREA.E/VE1.BIN", 0xD0)
    show("System word", "16_WAR/WAR1.BIN", 0x2D)
    show("System word", "16_WAR/WAR1.BIN", 0xA0)


if __name__ == "__main__":
    main()
