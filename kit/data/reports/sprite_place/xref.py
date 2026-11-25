#!/usr/bin/env python3
"""Absolute-address xref sweep for MAIN.EXE (2026-10-03 scratch).

Reconstructs lui+addiu/ori pairs so the lui sign-extension trap is handled
(a lui 0x8018 followed by addiu -0x41e0 gives 0x8017BE20, not 0x8018xx).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dis as D  # noqa: E402


def sweep(targets, funcs=None):
    """Return {target: [(va, reg, insn_text)]}."""
    funcs = funcs or D.load_functions()
    out = {t: [] for t in targets}
    lui = {}  # reg -> (va, value)
    for start, name, size in funcs:
        lui.clear()
        for va in range(start, start + size, 4):
            w = D.mword(va)
            if w is None:
                continue
            op = (w >> 26) & 0x3F
            rs = (w >> 21) & 0x1F
            rt = (w >> 16) & 0x1F
            imm = w & 0xFFFF
            text, f = D.dec(va, w)
            if op == 0x0F:  # lui
                val = imm << 16
                lui[rt] = (va, val)
                continue
            # reg-reg (addu/or) propagates a lui constant
            if op == 0 and (w & 0x3F) in (0x21, 0x25) and (w >> 11) & 0x1F == rt:
                r2 = rs
                if r2 in lui and rt not in (0,):
                    lui.setdefault(rt, lui[r2])
                continue
            if op in (0x09, 0x0D):  # addiu / ori
                if rs in lui:
                    base = lui[rs][1]
                    if op == 0x09:
                        addr = (base + (imm - 0x10000 if imm & 0x8000 else imm)) & 0xFFFFFFFF
                    else:
                        addr = (base | imm) & 0xFFFFFFFF
                    if addr in out:
                        out[addr].append((va, name, text))
            if op in (0x23, 0x2B, 0x20, 0x21, 0x24, 0x25, 0x28, 0x29, 0x2A) and rs in lui:
                base = lui[rs][1]
                addr = (base + (imm - 0x10000 if imm & 0x8000 else imm)) & 0xFFFFFFFF
                if addr in out:
                    out[addr].append((va, name, text))
    return out


if __name__ == "__main__":
    tg = [int(a, 16) for a in sys.argv[1:]]
    res = sweep(tg)
    for t in tg:
        print("=== %08x : %d refs ===" % (t, len(res[t])))
        for va, name, text in res[t]:
            print("   %08x  %-18s %s" % (va, name, text))
