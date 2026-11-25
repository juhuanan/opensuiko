#!/usr/bin/env python3
"""Decode the battle spell-name pointer table at 0x8016D340."""
import json
import struct
from pathlib import Path

import maindec

ROOT = Path(__file__).resolve().parents[2]
TABLE = 0x8016D340


def text(data, address):
    out = []
    for c in data[address - maindec.MBASE:address - maindec.MBASE + 30]:
        if c == 0:
            break
        if c == 0x10:
            out.append(' ')
        elif 0x11 <= c <= 0x2A:
            out.append(chr(ord('a') + c - 0x11))
        elif 0x2B <= c <= 0x44:
            out.append(chr(ord('A') + c - 0x2B))
        elif 0x45 <= c <= 0x4E:
            out.append(str(c - 0x45))
    return ''.join(out)


def main():
    body = maindec.body()
    rows = []
    for index in range(64):
        address = struct.unpack_from('<I', body, TABLE - maindec.MBASE + index * 4)[0]
        if address == 0:
            break
        name = text(body, address)
        if len(name) < 2:
            continue
        rows.append(dict(index=index, game_text_pointer=f'0x{address:08X}', name=name))
    print(json.dumps(rows, indent=2))


if __name__ == '__main__':
    main()
