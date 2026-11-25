#!/usr/bin/env python3
"""Minimal MIPS I decoder + disassembler for Suikoden PS1 SLUS_002.92 static analysis.

Loads the SLUS_002.92 EXE body (2048-byte PS-X header stripped) at 0x80010000
straight off the disc through tools/disc.py. The body is loaded LAZILY on first
use -- importing this module has no file/decoder side effects -- so scanners can
import it without a disc present until they actually disassemble.
"""
import os
import struct
import sys

BASE = 0x80010000

# SLUS_002.92 on the ISO9660 image (kit/extracted/iso_files.json); the PS-X EXE
# header is 2048 bytes and the body loads at 0x80010000.
EXE_NAME = "SLUS_002.92"
EXE_LBA = 18346
EXE_SIZE = 593920
EXE_HEADER = 2048

_BODY = None


def _body():
    """Return the SLUS_002.92 EXE body, loading it from the disc on first call."""
    global _BODY
    if _BODY is None:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import disc
        raw = disc.extract(EXE_LBA, EXE_SIZE)
        _BODY = raw[EXE_HEADER:]
    return _BODY


def size():
    """Size in bytes of the loaded EXE body."""
    return len(_body())


def word_at(va):
    off = va - BASE
    body = _body()
    if off < 0 or off + 4 > len(body):
        return None
    return struct.unpack_from('<I', body, off)[0]

def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def jtarget(pc, w):
    return ((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)

REGS = ['$zero','$at','$v0','$v1','$a0','$a1','$a2','$a3',
        '$t0','$t1','$t2','$t3','$t4','$t5','$t6','$t7',
        '$s0','$s1','$s2','$s3','$s4','$s5','$s6','$s7',
        '$t8','$t9','$k0','$k1','$gp','$sp','$fp','$ra']

def dec(pc, w):
    """Return (mnemonic_string, dict of decoded fields)."""
    op = (w >> 26) & 0x3F
    rs, rt = (w >> 21) & 0x1F, (w >> 16) & 0x1F
    rd, sa = (w >> 11) & 0x1F, (w >> 6) & 0x1F
    fn = w & 0x3F
    imm = sx16(w)
    uimm = w & 0xFFFF
    br = pc + 4 + (imm << 2)
    f = {'pc': pc, 'w': w, 'op': op, 'rs': rs, 'rt': rt, 'rd': rd, 'sa': sa,
         'imm': imm, 'uimm': uimm, 'br': br}
    R, A = REGS, lambda r: REGS[r]
    if op == 0:
        f['fn'] = fn
        if fn == 0x20: return f"add {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x21: return f"addu {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x22: return f"sub {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x23: return f"subu {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x24: return f"and {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x25: return f"or {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x26: return f"xor {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x27: return f"nor {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x00: return (f"nop", f) if w == 0 else (f"sll {A(rd)},{A(rt)},{sa}", f)
        if fn == 0x02: return f"srl {A(rd)},{A(rt)},{sa}", f
        if fn == 0x03: return f"sra {A(rd)},{A(rt)},{sa}", f
        if fn == 0x04: return f"sllv {A(rd)},{A(rt)},{A(rs)}", f
        if fn == 0x08: return f"jr {A(rs)}", f
        if fn == 0x09: return f"jalr {A(rd)},{A(rs)}" if rd != 31 else f"jalr {A(rs)}", f
        if fn == 0x0A: return f"movz {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x0B: return f"movn {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x10: return f"mfhi {A(rd)}", f
        if fn == 0x11: return f"mthi {A(rs)}", f
        if fn == 0x12: return f"mflo {A(rd)}", f
        if fn == 0x13: return f"mtlo {A(rs)}", f
        if fn == 0x18: return f"mult {A(rs)},{A(rt)}", f
        if fn == 0x19: return f"multu {A(rs)},{A(rt)}", f
        if fn == 0x1A: return f"div {A(rs)},{A(rt)}", f
        if fn == 0x1B: return f"divu {A(rs)},{A(rt)}", f
        if fn == 0x2A: return f"slt {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x2B: return f"sltu {A(rd)},{A(rs)},{A(rt)}", f
        if fn == 0x0C: return f"syscall", f
        if fn == 0x0D: return f"break", f
        return f"SPECIAL fn={fn:#x}", f
    if op == 0x02: f['jt'] = jtarget(pc, w); return f"j {jtarget(pc,w):#x}", f
    if op == 0x03: f['jt'] = jtarget(pc, w); return f"jal {jtarget(pc,w):#x}", f
    if op == 0x04: f['cond'] = 'eq'; return f"beq {A(rs)},{A(rt)},{br:#x}", f
    if op == 0x05: f['cond'] = 'ne'; return f"bne {A(rs)},{A(rt)},{br:#x}", f
    if op == 0x06: return f"blez {A(rs)},{br:#x}", f
    if op == 0x07: return f"bgtz {A(rs)},{br:#x}", f
    if op == 0x01:
        t = rt
        if t == 0: return f"bltz {A(rs)},{br:#x}", f
        if t == 1: return f"bgez {A(rs)},{br:#x}", f
        if t == 0x10: return f"bltzal {A(rs)},{br:#x}", f
        if t == 0x11: return f"bgezal {A(rs)},{br:#x}", f
        return f"REGIMM rt={t:#x}", f
    if op == 0x08: return f"addi {A(rt)},{A(rs)},{imm:#x}", f
    if op == 0x09: return f"addiu {A(rt)},{A(rs)},{imm:#x}", f
    if op == 0x0A: return f"slti {A(rt)},{A(rs)},{imm:#x}", f
    if op == 0x0B: return f"sltiu {A(rt)},{A(rs)},{imm:#x}", f
    if op == 0x0C: return f"andi {A(rt)},{A(rs)},{uimm:#x}", f
    if op == 0x0D: return f"ori {A(rt)},{A(rs)},{uimm:#x}", f
    if op == 0x0E: return f"xori {A(rt)},{A(rs)},{uimm:#x}", f
    if op == 0x0F: return f"lui {A(rt)},{uimm:#x}", f
    if op == 0x10:
        fmt = (w >> 21) & 0x1F
        if fmt == 0x10:
            f2 = w & 0x3F
            return f"COP0 fn={f2:#x} rs={rs} rt={rt} rd={rd}", f
        return f"COPx op={op:#x}", f
    if op == 0x20: return f"lb {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x21: return f"lh {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x22: return f"lwl {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x23: return f"lw {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x24: return f"lbu {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x25: return f"lhu {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x26: return f"lwr {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x28: return f"sb {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x29: return f"sh {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x2A: return f"swl {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x2B: return f"sw {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x2E: return f"swr {A(rt)},{imm:#x}({A(rs)})", f
    if op == 0x2F: return f"cache {rt},{imm:#x}({A(rs)})", f
    return f"OP={op:#x}", f

def disasm(start, n):
    out = []
    pc = start
    for _ in range(n):
        w = word_at(pc)
        if w is None: break
        s, _ = dec(pc, w)
        out.append((pc, w, s))
        pc += 4
    return out

def dump(start, n, label=""):
    if label: print(f"=== {label} @ {start:#x} ===")
    for pc, w, s in disasm(start, n):
        print(f"{pc:#10x}  {w:08x}  {s}")

if __name__ == '__main__':
    a = int(sys.argv[1], 16)
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 40
    print(f"body size = {size():#x} ({size()})", file=sys.stderr)
    dump(a, n)
