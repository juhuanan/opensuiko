"""Find every instruction in the MAIN.EXE body whose signed 16-bit immediate
equals one of the requested values (BYTE offsets). Reports the full encoding so
the lui+imm address, if any, can be resolved WITH SIGN EXTENSION."""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import rd
from mipsdec import dec
def sx16(v):
    v &= 0xFFFF
    return v-0x10000 if v & 0x8000 else v
targets = [int(x,16) for x in sys.argv[1:]]
LO = 0x800C0800; HI = LO + rd.size()
pc = LO
while pc < HI:
    w = rd.word(pc)
    if w is None: break
    s, f = dec(pc, w)
    op = f['op']
    if op in (0x08,0x09,0x0A,0x0B,0x20,0x21,0x22,0x23,0x24,0x25,0x26,0x28,0x29,0x2A,0x2B,0x2E):
        imm = sx16(w)
        if imm in targets:
            print(f"{pc:#010x} {w:08x}  {s}")
    elif op == 0x0C or op == 0x0D or op == 0x0E:  # andi/ori/xori (unsigned)
        u = w & 0xFFFF
        if u in targets:
            print(f"{pc:#010x} {w:08x}  {s}")
    pc += 4
