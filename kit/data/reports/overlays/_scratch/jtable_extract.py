#!/usr/bin/env python3
"""Find jump-table dispatches (jr $reg after lw from in-file table)."""
import sys, struct
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
path, base_s = sys.argv[1], sys.argv[2]
base = int(base_s, 16)
data = open(path, 'rb').read()
words = struct.unpack('<%dI' % (len(data)//4), data)
def va(o): return base + o
def in_range(a): return base <= a < base + len(data)
md = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
# decode all
insns = {}
for i in range(0, len(data)-3, 4):
    for ins in md.disasm(data[i:i+4], base+i):
        insns[base+i] = ins
        break
for a, ins in sorted(insns.items()):
    if ins.mnemonic == 'jr' and ins.op_str != '$ra':
        # look back for lw $reg,(table) pattern within 12 insns
        reg = ins.op_str
        for b in range(a-4, a-48, -4):
            p = insns.get(b)
            if not p: continue
            if p.mnemonic == 'lw' and p.op_str.startswith(reg + ','):
                # parse offset(base)
                import re
                m = re.match(r'\$[a-z0-9]+,\s*(?:(-?0x[0-9a-f]+|\-?\d+))?\(\$([a-z0-9]+)\)', p.op_str)
                if not m: continue
                # find the lui/addiu that set the table base register
                tblreg = m.group(2)
                tbl = None
                for c in range(b-4, b-64, -4):
                    q = insns.get(c)
                    if not q: continue
                    if q.mnemonic == 'lui' and q.op_str.startswith('$'+tblreg+','):
                        hi = int(q.op_str.split(',')[1].strip(), 16)
                        # find addiu
                        for d in range(c+4, b, 4):
                            r = insns.get(d)
                            if r and r.mnemonic == 'addiu' and r.op_str.startswith('$'+tblreg+','):
                                lo = int(r.op_str.split(',')[2].strip(), 16)
                                if lo & 0x8000: lo -= 0x10000
                                tbl = ((hi << 16) + lo) & 0xFFFFFFFF
                                break
                        break
                if tbl and in_range(tbl):
                    # read targets until one goes out of range or hits code-like
                    tgts = []
                    o = tbl - base
                    while o + 4 <= len(data) and len(tgts) < 40:
                        t = struct.unpack('<I', data[o:o+4])[0]
                        if not in_range(t): break
                        tgts.append(t); o += 4
                    if len(tgts) >= 2:
                        print(f"jr@{hex(a)} table@{hex(tbl)} n={len(tgts)}: " + " ".join(hex(t) for t in tgts))
                break
