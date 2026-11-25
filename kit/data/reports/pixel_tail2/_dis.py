#!/usr/bin/env python3
"""Scratch disassembler helper for the shiro pixel-tail-2 task (not tracked)."""
import json
import os
import struct
import sys

_TOOLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools")
sys.path.insert(0, os.path.abspath(_TOOLS))
import disc  # noqa: E402
from mipsdec import dec  # noqa: E402

_KIT = os.path.abspath(os.path.join(_TOOLS, ".."))
ISO = os.path.join(_KIT, "extracted", "iso_files.json")


def iso():
    with open(ISO) as f:
        return [r for r in json.load(f) if not r.get("dir")]


_CACHE = {}


def raw(path):
    if path not in _CACHE:
        r = next(r for r in iso() if r["path"] == path)
        _CACHE[path] = disc.extract(r["lba"], r["size"])
    return _CACHE[path]


def img(path):
    """(base, body) for an overlay / exe."""
    d = raw(path)
    b = os.path.basename(path)
    if b == "MAIN.EXE":
        return 0x800C0800, d[2048:]
    if b.startswith("SLUS"):
        return struct.unpack_from("<I", d, 0x18)[0], d[2048:]
    w0 = struct.unpack_from("<I", d, 0)[0]
    if 0x80080000 <= w0 < 0x800A0000:
        return 0x80080000, d
    return 0x80010000, d


def dis(path, a0, n):
    base, d = img(path)
    out = []
    for i in range(n):
        a = a0 + 4 * i
        o = a - base
        if o < 0 or o + 4 > len(d):
            break
        w = struct.unpack_from("<I", d, o)[0]
        s, f = dec(a, w)
        out.append((a, w, s, f))
    return out


def show(path, a0, n):
    print(f"=== {path} @ {a0:#x} ({n} insns) ===")
    for a, w, s, f in dis(path, a0, n):
        print(f"{a:#010x} {w:08x}  {s}")


if __name__ == "__main__":
    p = sys.argv[1]
    a = int(sys.argv[2], 16)
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    show(p, a, n)
