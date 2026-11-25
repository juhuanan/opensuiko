#!/usr/bin/env python3
"""Scratch disassembly helper for the sprite-placement investigation (2026-10-03).

Reads kit/work/mainexe_code.bin (MAIN.EXE code, load base 0x800C0800) using the
decoder logic from kit/tools/mipsdec.py.  mipsdec.py has a module-level open()
of a path that no longer exists on this machine, so this helper loads it with
open() temporarily stubbed -- it never edits the tool.

Not a deliverable; scratch only.
"""
import builtins
import importlib.util
import io
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.abspath(os.path.join(HERE, "..", "..", "tools"))
WORK = os.path.abspath(os.path.join(HERE, ".."))

MAIN_BIN = os.path.join(WORK, "mainexe_code.bin")
MAIN_BASE = 0x800C0800

_real_open = builtins.open
builtins.open = lambda *a, **k: io.BytesIO(b"\0" * 4096)
try:
    _spec = importlib.util.spec_from_file_location("mipsdec", os.path.join(TOOLS, "mipsdec.py"))
    _m = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_m)
finally:
    builtins.open = _real_open
dec = _m.dec

with _real_open(MAIN_BIN, "rb") as f:
    MBODY = f.read()
MSIZE = len(MBODY)


def mword(va):
    off = va - MAIN_BASE
    if off < 0 or off + 4 > MSIZE:
        return None
    return struct.unpack_from("<I", MBODY, off)[0]


def mbyte(va):
    off = va - MAIN_BASE
    if off < 0 or off >= MSIZE:
        return None
    return MBODY[off]


def mbytes(va, n):
    off = va - MAIN_BASE
    return MBODY[off:off + n]


def dis(va, n):
    out = []
    for i in range(n):
        pc = va + i * 4
        w = mword(pc)
        if w is None:
            out.append((pc, None, "???"))
        else:
            s, _f = dec(pc, w)
            out.append((pc, w, s))
    return out


def show(va, n, file=sys.stdout):
    for pc, w, s in dis(va, n):
        if w is None:
            print(f"{pc:#010x}  ????????  ???", file=file)
        else:
            print(f"{pc:#010x}  {w:08x}  {s}", file=file)


def load_functions():
    """[(start, name, size)] from mainexe_functions.txt."""
    fn = []
    p = os.path.join(WORK, "mainexe_functions.txt")
    if not os.path.exists(p):
        return fn
    with _real_open(p) as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 3 and parts[0].startswith("0x"):
                fn.append((int(parts[0], 16), parts[1], int(parts[2])))
    return fn


def func_at(va, funcs=None):
    funcs = funcs or load_functions()
    for s, n, sz in funcs:
        if s == va:
            return (s, n, sz)
    return None


def func_containing(va, funcs=None):
    funcs = funcs or load_functions()
    best = None
    for s, n, sz in funcs:
        if s <= va < s + sz:
            if best is None or s > best[0]:
                best = (s, n, sz)
    return best


if __name__ == "__main__":
    a = int(sys.argv[1], 16)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    show(a, n)
