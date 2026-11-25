#!/usr/bin/env python3
"""Scan all 19 Area C/D/E overlays for (a) LZSS decompressor candidates and
(b) FACE/portrait references. Static analysis only."""
import struct, os, sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN

BIN_DIR = "/home/hatch/workspace/suikoden/kit/extracted/bin_overlays/DATA"
FILES = [
    ("06_AREA.C/C_DATA.BIN", 0x80080000), ("06_AREA.C/VC3.BIN", 0x80010000),
    ("06_AREA.C/VC6.BIN", 0x80010000), ("07_AREA.D/D_DATA.BIN", 0x80080000),
    ("07_AREA.D/K_DATA.BIN", 0x80080000), ("07_AREA.D/VD1.BIN", 0x80010000),
    ("07_AREA.D/VD2.BIN", 0x80010000), ("07_AREA.D/VD3.BIN", 0x80010000),
    ("07_AREA.D/VD4.BIN", 0x80010000), ("07_AREA.D/VD5.BIN", 0x80010000),
    ("07_AREA.D/VD6.BIN", 0x80010000), ("07_AREA.D/VD7.BIN", 0x80010000),
    ("08_AREA.E/E_DATA.BIN", 0x80080000), ("08_AREA.E/VE1.BIN", 0x80010000),
    ("08_AREA.E/VE2.BIN", 0x80010000), ("08_AREA.E/VE3.BIN", 0x80010000),
    ("08_AREA.E/VE4.BIN", 0x80010000), ("08_AREA.E/VE5.BIN", 0x80010000),
    ("08_AREA.E/VE6.BIN", 0x80010000),
]

def load(path, base):
    raw = open(path, "rb").read()
    n = len(raw) // 4
    data = raw[:n * 4]
    words = struct.unpack("<%dI" % n, data)
    md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 | CS_MODE_LITTLE_ENDIAN)
    md.detail = True
    insns = {}
    for o in range(0, len(data) - 3, 4):
        try:
            for ins in md.disasm(data[o:o + 4], base + o):
                insns[ins.address] = ins
                break
        except Exception:
            pass
    return raw, data, words, insns

def discover(data, words, insns, base):
    def inr(a): return base <= a < base + len(data)
    def get(a): return insns.get(a)
    def word_at(a):
        o = a - base
        if 0 <= o <= len(data) - 4: return words[o // 4]
        return None
    def jtarget(a, w): return ((a + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)
    JRRA = 0x03E00008
    BRANCH_OPS = {1, 4, 5, 6, 7}
    def branch_target(a, w):
        imm = w & 0xFFFF
        if imm & 0x8000: imm -= 0x10000
        return (a + 4 + (imm << 2)) & 0xFFFFFFFF
    seeds = set()
    for o in range(0, len(data) - 3, 4):
        w = words[o // 4]
        if (w >> 26) == 9:
            rs, rt = (w >> 21) & 31, (w >> 16) & 31
            imm = (w & 0xFFFF) - 0x10000 if w & 0x8000 else w & 0xFFFF
            if rs == 29 and rt == 29 and imm < 0 and -imm % 8 == 0 and -imm < 0x2000:
                seeds.add(base + o)
    def walk_body(s, seed_set):
        seen = set(); jals = set(); stack = [s]
        limit = base + len(data)
        while stack:
            a = stack.pop()
            while True:
                if a in seen: break
                if a in seed_set and a != s: break
                w = word_at(a); ins = get(a)
                if w is None or ins is None: break
                seen.add(a)
                if w == JRRA: break
                m = ins.mnemonic; op = w >> 26
                if m == "jr": break
                if op == 2:
                    t = jtarget(a, w)
                    if s <= t < limit and t not in seen: stack.append(t)
                    break
                if op == 3:
                    t = jtarget(a, w)
                    if inr(t) and get(t) is not None: jals.add(t)
                    a += 8; continue
                if op in BRANCH_OPS:
                    t = branch_target(a, w)
                    if s <= t < limit and t not in seen: stack.append(t)
                    a += 4; continue
                a += 4
        return seen, jals
    changed = True
    while changed:
        changed = False
        for s in sorted(seeds):
            _, jals = walk_body(s, seeds)
            new = {t for t in jals if t not in seeds}
            if new: seeds.update(new); changed = True
    funcs = []
    for s in sorted(seeds):
        seen, _ = walk_body(s, seeds)
        funcs.append((s, max(seen) + 4 if seen else s + 4))
    funcs.sort()
    merged = []
    for s, e in funcs:
        if merged and s < merged[-1][1]:
            if e > merged[-1][1]: merged[-1] = (merged[-1][0], e)
        else: merged.append((s, e))
    return [(s, e) for s, e in merged if get(s) is not None]

def body_insns(insns, s, e):
    out = []
    a = s
    while a < e:
        ins = insns.get(a)
        if ins is None: break
        out.append(ins)
        a += 4
    return out

def has_backward_branch_loop(insns_list, s):
    """True if function contains a branch to an earlier address (a loop)."""
    for ins in insns_list:
        if ins.mnemonic in ("beq", "bne", "blez", "bgtz", "bgez", "bltz"):
            try:
                tgt = int(ins.op_str.split(",")[-1].strip(), 0)
                if tgt < ins.address: return True
            except Exception: pass
    return False

def scan(path, base):
    raw, data, words, insns = load(path, base)
    funcs = discover(data, words, insns, base)
    decomp = []
    for s, e in funcs:
        bl = body_insns(insns, s, e)
        mnems = [i.mnemonic for i in bl]
        has_srl = "srl" in mnems
        has_copy = any(m in ("lb", "lbu") for m in mnems) and "sb" in mnems
        has_fff = False
        has_1000 = False
        for i in bl:
            for op in i.operands:
                if op.type == 2:
                    v = op.imm & 0xFFFFFFFF
                    if v == 0xFFF or (i.mnemonic == "andi" and v == 0xFFF):
                        has_fff = True
                    if v == 0x1000:
                        has_1000 = True
        loop = has_backward_branch_loop(bl, s)
        score = sum([has_srl, has_copy, has_fff or has_1000, loop])
        # tightened: need bit-shift flag loop AND match-copy loop AND window const
        if has_srl and has_copy and (has_fff or has_1000):
            decomp.append((s, e, len(bl), has_fff, has_1000, loop))
    # FACE / portrait references
    face_hits = []
    up = raw.upper()
    for needle in (b"FACE", b"KAO", b"PORTRAIT"):
        idx = 0
        while True:
            idx = up.find(needle, idx)
            if idx < 0: break
            face_hits.append((base + idx, needle.decode()))
            idx += 1
            if len(face_hits) > 40: break
    return funcs, decomp, face_hits

print("=== DECOMPRESSOR + FACE SCAN (19 files) ===")
total_funcs = 0
for rel, base in FILES:
    path = os.path.join(BIN_DIR, rel)
    funcs, decomp, face = scan(path, base)
    total_funcs += len(funcs)
    short = rel.split("/")[-1]
    print(f"\n{short}: {len(funcs)} funcs")
    for s, e, n, hf, h1k, loop in decomp:
        print(f"  DECOMP-CAND {hex(s)}-{hex(e)} ({n} insns) fff={hf} 0x1000={h1k} loop={loop}")
    for a, needle in face[:10]:
        print(f"  FACE-STR {needle} at {hex(a)}")
    if not decomp and not face:
        print("  (no decompressor candidates, no FACE strings)")
print(f"\nTOTAL functions scanned: {total_funcs}")
