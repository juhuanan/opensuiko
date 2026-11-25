#!/usr/bin/env python3
"""Ad-hoc MAIN.EXE / overlay disassembly helper for the .8 record question.
MAIN.EXE body = disc.extract(...)[2048:] at base 0x800C0800 (header STRIPPED)."""
import json, os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.join(HERE, '..', '..', 'tools')
sys.path.insert(0, os.path.abspath(TOOLS))
import disc

ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
MAIN_BASE = 0x800C0800
EXE_HEADER = 2048
_cache = {}

def listing():
    with open(os.path.join(ROOT, 'kit', 'extracted', 'iso_files.json')) as fh:
        return [r for r in json.load(fh) if not r.get('dir')]

def entry(name):
    for r in listing():
        if r['path'].split('/')[-1] == name:
            return r
    raise KeyError(name)

def read_file(name):
    if name in _cache:
        return _cache[name]
    r = entry(name)
    out = bytearray(); off = 0
    while off < r['size']:
        step = min(1 << 20, r['size'] - off)
        out += disc.extract(r['lba'] + off // 2048, step)
        off += step
    _cache[name] = bytes(out[:r['size']])
    return _cache[name]

def main_body():
    if 'MAINBODY' not in _cache:
        _cache['MAINBODY'] = read_file('MAIN.EXE')[EXE_HEADER:]
    return _cache['MAINBODY']

def slus_body():
    if 'SLUSBODY' not in _cache:
        _cache['SLUSBODY'] = read_file('SLUS_002.92')[EXE_HEADER:]
    return _cache['SLUSBODY']

def overlay_body(name):
    k = 'OV:' + name
    if k not in _cache:
        _cache[k] = read_file(name)
    return _cache[k]

REGS = ['zero','at','v0','v1','a0','a1','a2','a3','t0','t1','t2','t3','t4','t5','t6','t7',
        's0','s1','s2','s3','s4','s5','s6','s7','t8','t9','k0','k1','gp','sp','fp','ra']

def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v

def dec(pc, w):
    op = (w >> 26) & 0x3F
    rs, rt = (w >> 21) & 0x1F, (w >> 16) & 0x1F
    rd, sa = (w >> 11) & 0x1F, (w >> 6) & 0x1F
    fn = w & 0x3F
    imm = sx16(w); uimm = w & 0xFFFF
    br = pc + 4 + (imm << 2)
    A = lambda r: '$' + REGS[r]
    if op == 0:
        if fn == 0x20: return f"add {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x21: return f"addu {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x22: return f"sub {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x23: return f"subu {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x24: return f"and {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x25: return f"or {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x26: return f"xor {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x27: return f"nor {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x00:
            if w == 0: return "nop"
            return f"sll {A(rd)},{A(rt)},{sa}"
        if fn == 0x02: return f"srl {A(rd)},{A(rt)},{sa}"
        if fn == 0x03: return f"sra {A(rd)},{A(rt)},{sa}"
        if fn == 0x04: return f"sllv {A(rd)},{A(rt)},{A(rs)}"
        if fn == 0x06: return f"srlv {A(rd)},{A(rt)},{A(rs)}"
        if fn == 0x07: return f"srav {A(rd)},{A(rt)},{A(rs)}"
        if fn == 0x08: return f"jr {A(rs)}"
        if fn == 0x09: return f"jalr {A(rd)},{A(rs)}" if rd != 31 else f"jalr {A(rs)}"
        if fn == 0x10: return f"mfhi {A(rd)}"
        if fn == 0x11: return f"mthi {A(rs)}"
        if fn == 0x12: return f"mflo {A(rd)}"
        if fn == 0x13: return f"mtlo {A(rs)}"
        if fn == 0x18: return f"mult {A(rs)},{A(rt)}"
        if fn == 0x19: return f"multu {A(rs)},{A(rt)}"
        if fn == 0x1A: return f"div {A(rs)},{A(rt)}"
        if fn == 0x1B: return f"divu {A(rs)},{A(rt)}"
        if fn == 0x2A: return f"slt {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x2B: return f"sltu {A(rd)},{A(rs)},{A(rt)}"
        if fn == 0x0C: return "syscall"
        if fn == 0x0D: return "break"
        return f"SPECIAL fn={fn:#x}"
    if op == 0x02: return f"j {(pc+4 & 0xF0000000) | ((w & 0x3FFFFFF) << 2):#x}"
    if op == 0x03: return f"jal {(pc+4 & 0xF0000000) | ((w & 0x3FFFFFF) << 2):#x}"
    if op == 0x04: return f"beq {A(rs)},{A(rt)},{br:#x}"
    if op == 0x05: return f"bne {A(rs)},{A(rt)},{br:#x}"
    if op == 0x06: return f"blez {A(rs)},{br:#x}"
    if op == 0x07: return f"bgtz {A(rs)},{br:#x}"
    if op == 0x01:
        return {0: f"bltz {A(rs)},{br:#x}", 1: f"bgez {A(rs)},{br:#x}",
                0x10: f"bltzal {A(rs)},{br:#x}", 0x11: f"bgezal {A(rs)},{br:#x}"}.get(rt, f"REGIMM rt={rt:#x}")
    if op == 0x08: return f"addi {A(rt)},{A(rs)},{imm}"
    if op == 0x09: return f"addiu {A(rt)},{A(rs)},{imm}"
    if op == 0x0A: return f"slti {A(rt)},{A(rs)},{imm}"
    if op == 0x0B: return f"sltiu {A(rt)},{A(rs)},{imm}"
    if op == 0x0C: return f"andi {A(rt)},{A(rs)},{uimm:#x}"
    if op == 0x0D: return f"ori {A(rt)},{A(rs)},{uimm:#x}"
    if op == 0x0E: return f"xori {A(rt)},{A(rs)},{uimm:#x}"
    if op == 0x0F: return f"lui {A(rt)},{uimm:#x}"
    if op == 0x10:
        if ((w >> 21) & 0x1F) == 0x10:
            return f"COP0 fn={(w & 0x3F):#x} rs={rs} rt={rt} rd={rd}"
        return f"COP2 co={((w>>25)&1)} rs={rs} rt={rt} rd={rd} fn={(w&0x3F):#x}"
    if op == 0x20: return f"lb {A(rt)},{imm}({A(rs)})"
    if op == 0x21: return f"lh {A(rt)},{imm}({A(rs)})"
    if op == 0x22: return f"lwl {A(rt)},{imm}({A(rs)})"
    if op == 0x23: return f"lw {A(rt)},{imm}({A(rs)})"
    if op == 0x24: return f"lbu {A(rt)},{imm}({A(rs)})"
    if op == 0x25: return f"lhu {A(rt)},{imm}({A(rs)})"
    if op == 0x26: return f"lwr {A(rt)},{imm}({A(rs)})"
    if op == 0x28: return f"sb {A(rt)},{imm}({A(rs)})"
    if op == 0x29: return f"sh {A(rt)},{imm}({A(rs)})"
    if op == 0x2A: return f"swl {A(rt)},{imm}({A(rs)})"
    if op == 0x2B: return f"sw {A(rt)},{imm}({A(rs)})"
    if op == 0x2E: return f"swr {A(rt)},{imm}({A(rs)})"
    if op == 0x2F: return f"cache {rt},{imm}({A(rs)})"
    return f"OP={op:#x}"

def dump(body, base, start, n=40, out=sys.stdout, marks=()):
    off = start - base
    for i in range(n):
        pc = start + 4*i
        if off + 4*i + 4 > len(body) or off + 4*i < 0:
            break
        w = struct.unpack_from('<I', body, off + 4*i)[0]
        mark = '   <<<' if pc in marks else ''
        print(f"{pc:#010x}  {w:08x}  {dec(pc, w)}{mark}", file=out)

def main_body_word(va):
    return struct.unpack_from('<I', main_body(), va - MAIN_BASE)[0]
