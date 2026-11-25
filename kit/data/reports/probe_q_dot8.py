#!/usr/bin/env python3
"""Minimal MIPS I static helpers for MAIN.EXE / overlay images.

Loads the MAIN.EXE body once through maindec (which reads the disc through
tools/disc.py) and offers:

  * lui-tracked address references: find every instruction I where some
    preceding `lui $r,hi` and I's 16-bit immediate reconstruct a target VA
    (base-independent for overlays too).
  * per-register constant propagation of `lui`/`ori`/`addiu` pairs, so a
    function's argument constants and pointer materialisations can be read off
    a listing.

This module deliberately contains no knowledge of the `.8` format: it is the
measuring instrument, not the finding.
"""
from __future__ import annotations

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mipsdec import dec, sx16, jtarget  # noqa: E402

import maindec  # noqa: E402

MBASE = maindec.MBASE


def words(va, n, body=None):
    """[(va, word, asm)] for n words at va."""
    return maindec.dis(va, n) if body is None else _dis(body, va, n)


def _dis(body, va, n):
    out = []
    for i in range(n):
        pc = va + i * 4
        off = pc - MBASE if body is maindec.body() else None
        w = None
        if 0 <= pc - MBASE and pc - MBASE + 4 <= len(body):
            w = struct.unpack_from('<I', body, pc - MBASE)[0]
        out.append((pc, w, dec(pc, w)[0] if w is not None else '???'))
    return out


def show(va, n, out=sys.stdout):
    for pc, w, a in words(va, n):
        if w is None:
            print(f"{pc:#010x}  ????????  ???", file=out)
        else:
            print(f"{pc:#010x}  {w:08x}  {a}", file=out)


# ---------------------------------------------------------------------------
# lui-tracked reference scan
# ---------------------------------------------------------------------------

# For a window of W instructions the last `lui $r,hi` seen for register $r is
# the effective high half. We report (site, hi, imm, reconstructed, op).
WINDOW = 8


def refs_to(target, body=None, base=MBASE, window=WINDOW):
    """Sites whose lui+imm reconstructs `target` (16-bit sign-extended imm).

    Returns [(site_va, word, asm, op, reg)]. Base-independent when `body` is an
    overlay image: pass `base` = that overlay's load base whenever it is known,
    otherwise compare the reconstructed address against the *low 16 bits* of the
    target only (see refs_by_lo).
    """
    if body is None:
        body = maindec.body()
    lo = target & 0xFFFF
    hi_target = (target - sx16(lo)) & 0xFFFFFFFF
    out = []
    reg_hi = {}
    start = 0
    for off in range(0, len(body) - 4, 4):
        w = struct.unpack_from('<I', body, off)[0]
        pc = base + off
        op = w >> 26
        rs = (w >> 21) & 0x1F
        rt = (w >> 16) & 0x1F
        imm = w & 0xFFFF
        if op == 0x0F:  # lui
            reg_hi[rt] = imm
            continue
        if imm == lo and rs in reg_hi:
            if (reg_hi[rs] << 16) == hi_target:
                out.append((pc, w, dec(pc, w)[0], op, rs))
    return out


def refs_by_lo(lo, body, base):
    """Sites where a lui+imm pair reconstructs an address whose low half is `lo`."""
    out = []
    reg_hi = {}
    for off in range(0, len(body) - 4, 4):
        w = struct.unpack_from('<I', body, off)[0]
        pc = base + off
        op = w >> 26
        rs = (w >> 21) & 0x1F
        rt = (w >> 16) & 0x1F
        imm = w & 0xFFFF
        if op == 0x0F:
            reg_hi[rt] = imm
            continue
        if imm == lo and rs in reg_hi:
            out.append((pc, w, dec(pc, w)[0], op, rs, (reg_hi[rs] << 16)))
    return out


def find_byte_table(body, lo, hi, base, row_bytes=64, stride=17, vmax=16):
    """Find a `k*17 -> k` style byte table in an image.

    Looks for a run of at least `run` bytes where byte[i] == i for
    i in 0..vmax at byte positions that are multiples of `stride`.
    """
    hits = []
    step = stride
    for start in range(lo, hi - vmax * step, 1):
        ok = True
        for k in range(vmax):
            if body[start + k * step] != k:
                ok = False
                break
        if ok:
            hits.append(base + start)
    return hits
