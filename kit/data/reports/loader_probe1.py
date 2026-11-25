#!/usr/bin/env python3
"""Probe MAIN.EXE for CD loader functions. Run from kit/work."""
import mx, struct, re, sys

data = mx.data

def w(off): return struct.unpack('<I', data[off:off+4])[0]

# ---------- 1. trampolines: all jr $t2 preceded by addiu $t2,$zero,imm ----------
tramps = {}  # addr -> (table, num)
for m in re.finditer(struct.pack('<I', 0x01400008), data):
    off = m.start()
    prev = w(off-4)
    if prev in (0x240a00a0, 0x240a00b0):
        nxt = w(off+4); nxt2 = w(off+8)
        if (nxt >> 16) == 0x2409 and nxt2 == 0:
            a = mx.r2a(off-4)
            tramps[a] = ('A' if prev == 0x240a00a0 else 'B', nxt & 0xff)

BIOS = {
 ('A',0x39):'InitHeap', ('A',0x3f):'printf', ('A',0x51):'LoadExec',
 ('A',0x71):'_96_init', ('A',0x72):'_96_remove', ('A',0x78):'CdAsyncSeekL',
 ('A',0x7c):'CdAsyncGetStatus', ('A',0x7e):'CdAsyncReadSector',
 ('A',0x81):'CdAsyncSetMode', ('A',0x70):'_bu_init', ('A',0xab):'_card_info',
 ('A',0xac):'_card_load', ('A',0x19):'strcpy', ('A',0x1b):'strlen',
 ('A',0x15):'strcat', ('A',0x2a):'memcpy', ('A',0x30):'srand', ('A',0x31):'qsort',
 ('A',0x2f):'rand', ('A',0x13):'setjmp', ('A',0x44):'FlushCache',
 ('A',0x49):'GPU_cw',
 ('B',0x07):'DeliverEvent', ('B',0x08):'OpenEvent', ('B',0x09):'CloseEvent',
 ('B',0x0a):'WaitEvent', ('B',0x0b):'TestEvent', ('B',0x0c):'EnableEvent',
 ('B',0x0d):'DisableEvent', ('B',0x32):'open', ('B',0x33):'lseek',
 ('B',0x34):'read', ('B',0x35):'write', ('B',0x36):'close',
 ('B',0x38):'exit', ('B',0x39):'isatty', ('B',0x3f):'puts',
 ('B',0x41):'format', ('B',0x42):'firstfile2', ('B',0x43):'nextfile',
 ('B',0x4a):'InitCARD2', ('B',0x4b):'StartCARD2', ('B',0x4c):'StopCARD2',
 ('B',0x4e):'_card_write', ('B',0x4f):'_card_read', ('B',0x50):'_new_card',
 ('B',0x5b):'ChangeClearPAD', ('B',0x14):'StopPAD2', ('B',0x15):'PAD_init2',
 ('B',0x16):'PAD_dr', ('B',0x17):'ReturnFromException', ('B',0x18):'ResetEntryInt',
 ('B',0x19):'HookEntryInt',
}

print('=== TRAMPOLINES (%d) ===' % len(tramps))
for a in sorted(tramps):
    t, n = tramps[a]
    print('0x%08x  %s(0x%02x) %s' % (a, t, n, BIOS.get((t,n), '?')))

# ---------- 2. callers of each trampoline ----------
jal_to = lambda t: struct.pack('<I', 0x0C000000 | ((t >> 2) & 0x3FFFFFF))
print()
print('=== CALLERS OF CD/EVENT-RELATED TRAMPOLINES ===')
want_names = {'CdAsyncSeekL','CdAsyncReadSector','CdAsyncGetStatus','CdAsyncSetMode',
              '_96_init','_96_remove','TestEvent','WaitEvent','EnableEvent',
              'DisableEvent','CloseEvent','OpenEvent','DeliverEvent'}
for a in sorted(tramps):
    t, n = tramps[a]
    nm = BIOS.get((t,n),'?')
    if nm not in want_names: continue
    sites = [mx.r2a(m.start()) for m in re.finditer(re.escape(jal_to(a)), data)]
    print('0x%08x %s(0x%02x)=%s called from %d sites:' % (a, t, n, nm, len(sites)))
    for s in sites:
        f = mx.func_of(s)
        print('    0x%08x in func 0x%08x' % (s, f if f else 0))
