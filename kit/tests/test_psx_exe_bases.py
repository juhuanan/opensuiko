#!/usr/bin/env python3
"""PS-EXE bases and the header/image split — regression guard.

`disc.extract()` on a PS-EXE returns header + image, and `t_addr` (header
+0x18) is the base of the IMAGE. Scanning the whole file with the image base
shifts every address by 0x800 and finds the same sites at wrong addresses.
This test pins the two binaries' bases and the descriptor-read population, so
the mistake cannot return silently.

Run directly:  .venv/bin/python kit/tests/test_psx_exe_bases.py
"""
import json
import os
import struct
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import disc  # noqa: E402

FAILED = []
CHECKS = [0]

EXPECTED = {"MAIN.EXE": 0x800C0800, "SLUS_002.92": 0x80010000}


def check(name, cond, detail=""):
    CHECKS[0] += 1
    if cond:
        print("ok   %s" % name)
    else:
        print("FAIL %s %s" % (name, detail))
        FAILED.append(name)


def files():
    with open(os.path.join(KIT, "extracted", "iso_files.json")) as f:
        return {x["path"]: x for x in json.load(f) if not x.get("dir")}


def body_and_base(name, fs):
    r = fs[name]
    d = disc.extract(r["lba"], r["size"])
    if d[:8] != b"PS-X EXE":
        return d, None, d
    pc, gp, addr, size = struct.unpack_from("<4I", d, 0x10)
    return d[2048:], addr, d, size


def strict_refs(body, base, target):
    n = len(body) // 4
    out = []
    for k in range(n):
        iw = struct.unpack_from("<I", body, k * 4)[0]
        if iw >> 26 != 0x0F or (iw & 0xFFFF) != (target >> 16):
            continue
        if k + 1 >= n:
            continue
        kw = struct.unpack_from("<I", body, (k + 1) * 4)[0]
        if kw >> 26 != 0x23 or ((kw >> 21) & 0x1F) != ((iw >> 16) & 0x1F):
            continue
        imm = kw & 0xFFFF
        if imm & 0x8000:
            imm -= 0x10000
        if ((target >> 16) << 16) + imm == target:
            out.append(base + (k + 1) * 4)
    return out


def test_bases_match_the_headers():
    fs = files()
    for name, want in EXPECTED.items():
        r = fs[name]
        d = disc.extract(r["lba"], r["size"])
        check("%s is a PS-EXE" % name, d[:8] == b"PS-X EXE", d[:8])
        pc, gp, addr, size = struct.unpack_from("<4I", d, 0x10)
        check("%s t_addr == %#x" % (name, want), addr == want, hex(addr))
        check("%s is header + image" % name, 2048 + size == len(d),
              "%d + %d != %d" % (2048, size, len(d)))


def test_mainexe_code_bin_is_the_headerless_image():
    fs = files()
    r = fs["MAIN.EXE"]
    d = disc.extract(r["lba"], r["size"])
    with open(os.path.join(KIT, "work", "mainexe_code.bin"), "rb") as f:
        b = f.read()
    check("mainexe_code.bin == extract()[2048:]", b == d[2048:],
          "%d vs %d" % (len(b), len(d) - 2048))


def test_descriptor_reader_population():
    """2 in MAIN, 0 in SLUS -- and both are the SAME two sites the loose scan
    found, which is how the 0x800 mis-base was caught."""
    fs = files()
    main, mbase, *_ = body_and_base("MAIN.EXE", fs)
    slus, sbase, *_ = body_and_base("SLUS_002.92", fs)
    m = strict_refs(main, mbase, 0x80080000)
    s = strict_refs(slus, sbase, 0x80080000)
    check("MAIN has exactly 2 descriptor reads", len(m) == 2, [hex(x) for x in m])
    check("they are the world-map and scene sites",
          m == [0x80126FB0, 0x801313E4], [hex(x) for x in m])
    check("SLUS boot binary has none", s == [], [hex(x) for x in s])
    check("the mis-based scan would be +0x800",
          [x + 0x800 for x in m] == [0x801277B0, 0x80131BE4])


if __name__ == "__main__":
    test_bases_match_the_headers()
    test_mainexe_code_bin_is_the_headerless_image()
    test_descriptor_reader_population()
    print()
    print("%d passed, %d failed" % (CHECKS[0] - len(FAILED), len(FAILED)))
    sys.exit(1 if FAILED else 0)
