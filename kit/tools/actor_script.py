#!/usr/bin/env python3
"""Read-only lister for the battle **actor action-script** VM in MAIN.EXE.

Everything here is static, on-disc analysis of the MAIN.EXE body
(`kit/work/mainexe_code.bin`, PS-X EXE text address `0x800C0800`).  No emulator,
no runtime data.

Two facts drive the module:

* `0x800E3820(idx, a1, desc)` is the per-actor entry point.  It walks `desc` as a
  stream of **signed 16-bit opcodes**, calling `(*(0x8016BABC + 4*op))(idx, 0)`
  until a handler returns 0.  Each handler advances the actor's descriptor
  pointer (`actor[0x0C]`) itself, so the per-opcode operand length is a property
  of the handler, not of a table.
* The handler table at **`0x8016BABC`** holds **45** pointers (0..44) and ends
  with a zero word.  The "24 entries" figure in
  `kit/docs/battle_actor_system.md` is wrong (see
  `kit/docs/battle_actor_handlers.md`).

Address conventions in this file, stated once because the same confusion has
already cost this project time:

* every `va` is a **byte address**; `word(va)` reads the 32-bit word *at that
  byte address*;
* `OP_LEN_HW[op]` is a count of **halfwords** (2-byte units), not bytes and not
  word indices;
* every RAM constant is resolved from the full `lui`+immediate encoding **with
  sign extension** (`lui $s4,0x8017` + `addiu -0x4544` = `0x8016BABC`).

Usage
-----
    python3 kit/tools/actor_script.py table
    python3 kit/tools/actor_script.py dis 0x800E4C4C 40
    python3 kit/tools/actor_script.py desc 0x8016F234
    python3 kit/tools/actor_script.py actors
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mipsdec import dec  # noqa: E402

BASE = 0x800C0800
_HERE = os.path.dirname(os.path.abspath(__file__))
BODY_PATH = os.path.abspath(os.path.join(_HERE, os.pardir, 'work', 'mainexe_code.bin'))

# on-disc tables (byte addresses inside the body)
HANDLER_TABLE = 0x8016BABC          # 45 entries, zero-terminated
ANIM_TABLE_DEFAULT = 0x8016C208     # 16-entry table of descriptor pointers
DESC_DEFAULT_ACTOR = 0x8016F234     # the default actor descriptor (17 halfwords used)
DESC_TEAM_A = 0x8016C1C0            # per-actor descriptors handed to 0x800E3820
DESC_TEAM_B = 0x8016C2F0
FORMATION_TABLE = 0x8016B81C        # 10 x {s16 x, s16 y, s16 z}, 6 bytes/actor
FORMATION_ORIGIN_A = 0x8016B80C     # u32 x origin (128 on disc)
FORMATION_ORIGIN_B = 0x8016B810     # u32 y origin (0 on disc)
FORMATION_ORIGIN_MIRROR = 0x8016B814

_BODY = None


def body():
    """The MAIN.EXE body bytes (PS-X EXE 2048-byte header already stripped)."""
    global _BODY
    if _BODY is None:
        with open(BODY_PATH, 'rb') as fh:
            _BODY = fh.read()
    return _BODY


def size():
    return len(body())


def word(va):
    """u32 at the **byte** address `va` (little endian), or None if out of range."""
    off = va - BASE
    if off < 0 or off + 4 > len(body()):
        return None
    return struct.unpack_from('<I', body(), off)[0]


def half(va):
    """u16 at the byte address `va`."""
    off = va - BASE
    if off < 0 or off + 2 > len(body()):
        return None
    return struct.unpack_from('<H', body(), off)[0]


def shalf(va):
    """Sign-extended s16 at the byte address `va`."""
    h = half(va)
    if h is None:
        return None
    return h - 0x10000 if h & 0x8000 else h


def byte(va):
    off = va - BASE
    if off < 0 or off >= len(body()):
        return None
    return body()[off]


# --------------------------------------------------------------------------
# The 45 opcodes.
#
# OP_LEN_HW is **reasoned**: it is the byte advance the handler itself applies
# to the actor's descriptor pointer, read from the handler's own
# `addiu Rt,Rt,N` / `sw Rt,0xc(base)` pair.  Ops 0/1 are the two end markers.
# `None` means "the handler transfers control instead of advancing" (op 36
# re-enters 0x800E3820 with a new descriptor, so a linear walk cannot continue).
OP_LEN_HW = {
    0: 0, 1: 0, 2: 1, 3: 2, 4: 2, 5: 1, 6: 2, 7: 2, 8: 2, 9: 2, 10: 2,
    11: 2, 12: 2, 13: 2, 14: 2, 15: 3, 16: 3, 17: 5, 18: 5, 19: 5, 20: 6,
    21: 1, 22: 2, 23: 9, 24: 7, 25: 4, 26: 3, 27: 3, 28: 3, 29: 3, 30: 2,
    31: 2, 32: 4, 33: 6, 34: 2, 35: 3, 36: None, 37: 2, 38: 1, 39: 1,
    40: 3, 41: 4, 42: None,          # 42 is variable: 2 + desc[1] halfwords
    43: 4, 44: 3,
}

OP_NAME = {
    0: 'end', 1: 'end', 2: 'teardown(anim)',
    3: 'timer rec+0x12 = a', 4: 'set anim id', 5: 'wait anim flag',
    6: 'rec+0x01 = a', 7: 'anim flip/flag', 8: 'rec+0x02 = (a!=0)',
    9: 'flag[sel] = 1', 10: 'flag[sel] = 0', 11: 'wait flag[sel]!=0',
    12: 'wait flag[sel]==0', 13: 'rec[0x88][0] |= a', 14: 'rec[0x88][0] &= ~a',
    15: 'flags |= mask', 16: 'flags &= ~mask',
    17: 'camera move A', 18: 'camera move B', 19: 'camera move D',
    20: 'camera focus C (abs/self/owner)', 21: 'wait rec[0x10]>0',
    22: 'move to rec[0x5C/60/64]', 23: 'parabolic move / jump',
    24: 'give slot the graphic+script', 25: 'sync anim offsets',
    26: 'flags0x40 |= mask', 27: 'flags0x40 &= ~mask',
    28: 'wait flags0x40 & mask', 29: 'wait !(flags0x40 & mask)',
    30: 'rec[0x42] = a', 31: 'wait rec[0x42] == a', 32: 'copy graphic+pos to slot',
    33: 'long move (6 halfwords)', 34: 'call 0x800C3104(a)',
    35: 'mode 1/2 helper (rec[0x54])', 36: 'run sub-script',
    37: 'movement counter = a', 38: 'reset draw records',
    39: 'reset draw records (desc)', 40: 'battle sub-object',
    41: 'set RGB in both packet buffers', 42: 'copy halfword list -> rec[0x44..]',
    43: 'copy anim offsets from owner', 44: 'wait !(byte+5 & mask)',
}


def handler_table():
    """The 45 pointers at 0x8016BABC, stopping at the first null/short word."""
    out = []
    i = 0
    while True:
        w = word(HANDLER_TABLE + 4 * i)   # byte address: 4 bytes per entry
        if w is None or not (BASE <= w < BASE + size()):
            break
        out.append(w)
        i += 1
    return out


def op_len_hw(op, desc_va=None):
    """Advance in **halfwords**; op 42 depends on its own operand."""
    if op == 42:
        n = shalf(desc_va + 2) if desc_va is not None else None
        return None if n is None else 2 + max(n, 0)
    return OP_LEN_HW.get(op)


def decode(desc_va, limit=64):
    """Linear walk of a descriptor.  Returns a list of
    (desc_va, op, operands_as_s16) and stops on op 0/1, a bad opcode, or
    a handler that does not advance."""
    out = []
    va = desc_va
    for _ in range(limit):
        op = shalf(va)
        if op is None:
            out.append((va, None, 'past end of body'))
            break
        if not 0 <= op < len(handler_table()):
            out.append((va, op, 'OUT OF TABLE'))
            break
        n = op_len_hw(op, va)
        if n is None:
            out.append((va, op, 'control transfer / variable - walk stops'))
            break
        ops = [shalf(va + 2 * k) for k in range(1, n)] if n > 1 else []
        out.append((va, op, ops))
        if op in (0, 1, 2) and n == 0:
            break
        if op in (0, 1):
            break
        va += 2 * n
    return out


def show_dis(va, n):
    for i in range(n):
        pc = va + 4 * i
        w = word(pc)
        if w is None:
            print(f'{pc:#010x}  ????????  past end')
            return
        s, _ = dec(pc, w)
        print(f'{pc:#010x}  {w:08x}  {s}')


def main(argv):
    if not argv or argv[0] not in ('table', 'dis', 'desc', 'actors'):
        print(__doc__)
        return 1
    cmd = argv[0]
    if cmd == 'table':
        t = handler_table()
        print(f'handler table @ {HANDLER_TABLE:#x}: {len(t)} entries')
        for i, a in enumerate(t):
            print(f'  op {i:2d} -> {a:#010x}  {OP_NAME.get(i, "?")}  '
                  f'len={OP_LEN_HW.get(i)} halfwords')
    elif cmd == 'dis':
        show_dis(int(argv[1], 16), int(argv[2]) if len(argv) > 2 else 40)
    elif cmd == 'desc':
        va = int(argv[1], 16) if len(argv) > 1 else DESC_DEFAULT_ACTOR
        for a, op, ops in decode(va):
            print(f'  {a:#010x}  op {op!s:>4}  {ops}  {OP_NAME.get(op, "")}')
    elif cmd == 'actors':
        n = byte(FORMATION_ORIGIN_A - 4) if False else None
        print(f'formation origin A @ {FORMATION_ORIGIN_A:#x} = '
              f'{word(FORMATION_ORIGIN_A)}')
        print(f'formation origin B @ {FORMATION_ORIGIN_B:#x} = '
              f'{word(FORMATION_ORIGIN_B)}')
        print(f'mirror origin     @ {FORMATION_ORIGIN_MIRROR:#x} = '
              f'{word(FORMATION_ORIGIN_MIRROR):#x}')
        base_x = word(FORMATION_ORIGIN_A) or 0
        base_y = word(FORMATION_ORIGIN_B) or 0
        print('slot  disc(x,y,z)        world 12.12 (<<12)')
        for i in range(10):
            a = FORMATION_TABLE + 6 * i
            x, y, z = shalf(a), shalf(a + 2), shalf(a + 4)
            print(f'  {i:2d}  ({x:5d},{y:5d},{z:5d})   '
                  f'({(x + base_x) << 12:#010x}, {(y + base_y) << 12:#010x}, '
                  f'{z << 12:#010x})')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
