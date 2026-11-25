#!/usr/bin/env python3
"""Shared disassembly helpers for the f-record consumer sweep."""
import sys
from capstone import Cs, CS_ARCH_MIPS, CS_MODE_MIPS32, CS_MODE_LITTLE_ENDIAN
from capstone.mips_const import *

KIT = '/home/hatch/workspace/suikoden/kit/'
DATA = open(KIT + 'work/mainexe_code.bin', 'rb').read()
BASE = 0x800C0800

FUNCS = []
for line in open(KIT + 'work/mainexe_functions.txt'):
    p = line.split()
    FUNCS.append((int(p[0], 16), p[1], int(p[2])))
FUNCS.sort()

MD = Cs(CS_ARCH_MIPS, CS_MODE_MIPS32 + CS_MODE_LITTLE_ENDIAN)
MD.detail = True


def func_of(va):
    lo, hi = 0, len(FUNCS) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if FUNCS[mid][0] <= va:
            lo = mid
        else:
            hi = mid - 1
    return FUNCS[lo]


def disas_range(a0, a1):
    return list(MD.disasm(DATA[a0 - BASE:a1 - BASE], a0))


def fmt(ins):
    return '0x%08x: %-8s %s' % (ins.address, ins.mnemonic, ins.op_str)


def mem_disp(ins):
    """(base_reg_name, disp) for a memory operand, or None."""
    for op in ins.operands:
        if op.type == MIPS_OP_MEM:
            return (ins.reg_name(op.mem.base), op.mem.disp)
    return None


def imm_of(ins):
    for op in ins.operands:
        if op.type == MIPS_OP_IMM:
            return op.imm
    return None
