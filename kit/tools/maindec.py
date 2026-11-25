#!/usr/bin/env python3
"""Disassembler helper for MAIN.EXE at base 0x800C0800.

MAIN.EXE's PS-X EXE body (2048-byte header stripped) is read straight off the
disc through tools/disc.py -- no path is hardcoded. It is loaded LAZILY, so
importing this module has no file/decoder side effects.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsdec import dec  # noqa: E402

# MAIN.EXE on the ISO9660 image (kit/extracted/iso_files.json); the PS-X EXE
# text address is 0x800C0800 and the header is 2048 bytes.
MBASE = 0x800C0800
EXE_LBA = 17976
EXE_SIZE = 757760
EXE_HEADER = 2048

_MBODY = None


def body():
    """Return the MAIN.EXE body, loading it from the disc on first call."""
    global _MBODY
    if _MBODY is None:
        import disc
        _MBODY = disc.extract(EXE_LBA, EXE_SIZE)[EXE_HEADER:]
    return _MBODY


def msize():
    return len(body())


def mword(va):
    off = va - MBASE
    b = body()
    if off < 0 or off + 4 > len(b):
        return None
    return struct.unpack_from('<I', b, off)[0]


def dis(va, n):
    """Return list of (va, word, asm) for n instructions."""
    out = []
    for i in range(n):
        pc = va + i*4
        w = mword(pc)
        if w is None:
            out.append((pc, None, '???'))
        else:
            s, f = dec(pc, w)
            out.append((pc, w, s))
    return out


def show(va, n, file=sys.stdout):
    for pc, w, s in dis(va, n):
        if w is None:
            print(f"{pc:#010x}  ????????  ???", file=file)
        else:
            print(f"{pc:#010x}  {w:08x}  {s}", file=file)


if __name__ == '__main__':
    va = int(sys.argv[1], 16)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    show(va, n)
