#!/usr/bin/env python3
"""audit_gs_records.py -- independently check scan-record pointer provenance.

`gs_scan.py` emits accesses into the game-state struct (0x801B8000) reached
through a pointer it tracks from a seed load. A record is only meaningful if its base has an unclobbered writer path to the
access. The GS audit independently explores bounded control-flow paths between
writers and uses, follows direct transfers, and preserves MIPS load/call delay
instructions. It rejects the old linear-path false positive at800E9164, whose
reward object had been mislabeled gs+2250. Structptr records retain their
separate source executable and clobber audit.

This checks paths from independently classified register writers; it does not
prove full program reachability, dynamic indices, or object allocation bounds.
See `kit/docs/scanner_pointer_invalidation.md`.

Two seed forms are legitimate and are NOT violations:
    lw rt, -0x24DC($gp)                     (pattern B)
    lui rx,0x8018 ; lw rt,-0x24DC(rx)       (pattern A)

Usage:
    python3 kit/tools/audit_gs_records.py [RECORDS_JSON] [--quiet]

Exit 0 when there are no violations (a stale base would be a violation), 1 when
there are any, 2 on a usage/read error. Prints a class breakdown either way.
"""
import argparse
import collections
from collections import deque
import json
import os
import struct
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import disc                                              # noqa: E402
from mipsdec import dec                                   # noqa: E402
from mips_writers import IMM_OPS, dst_reg, is_call, is_load  # noqa: E402

# MAIN.EXE body: PS-X EXE header is 2048 bytes, code loads at 0x800C0800.
MBASE = 0x800C0800
MAINEXE_LBA = 17976
MAINEXE_SIZE = 757760
MAINEXE_HEADER = 2048

SEED_IMM = -0x24DC
MAXBACK = 600

# Caller-saved registers (o32): $at, $v0-$v1, $a0-$a3, $t0-$t9, $k0-$k1.
# A `jal`/`jalr` between the base's writer and the access can destroy any of
# these, so a base that no instruction *textually* writes is still not provably
# the gs pointer if it is volatile and a call sits in between. The scanners drop
# volatile regs on a call; this audit has to model that too, or it reports
# correct removals as losses.
VOLATILE = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 24, 25}

REGS = ['$zero', '$at', '$v0', '$v1', '$a0', '$a1', '$a2', '$a3',
        '$t0', '$t1', '$t2', '$t3', '$t4', '$t5', '$t6', '$t7',
        '$s0', '$s1', '$s2', '$s3', '$s4', '$s5', '$s6', '$s7',
        '$t8', '$t9', '$k0', '$k1', '$gp', '$sp', '$fp', '$ra']


# The two record sets come from DIFFERENT executables. Reading the wrong body
# makes every access "unreadable", which must never look like a pass.
BODIES = {
    # gs_scan.py reads MAIN.EXE
    'gs':        dict(lba=17976, size=757760, base=0x800C0800),
    # scan_structptr.py reads SLUS_002.92 (via mipsdec)
    'structptr': dict(lba=18346, size=593920, base=0x80010000),
}
EXE_HEADER = 2048


class Body:
    def __init__(self, spec, payload=None):
        raw = disc.extract(spec['lba'], spec['size']) if payload is None else payload
        self.body = raw[EXE_HEADER:]
        self.base = spec['base']

    def word(self, va):
        off = va - self.base
        if off < 0 or off + 4 > len(self.body):
            return None
        return struct.unpack_from('<I', self.body, off)[0]


def is_seed(va, w):
    """A seed load: `lw rt,-0x24DC(...)`. The chain origin, so not a clobber."""
    f = dec(va, w)[1]
    return f['op'] == 0x23 and f['imm'] == SEED_IMM


def writer_reaches(body,writer,access,reg):
    """Independent bounded CFG check: can a writer reach this use without a clobber?"""
    starts=(writer+4,)
    previous=body.word(writer-4)
    if previous is not None:
        pf=dec(writer-4,previous)[1];po=pf['op']
        if po==2:starts=(((writer)&0xF0000000)|((previous&0x3FFFFFF)<<2),)
        elif po in (1,4,5,6,7):
            target=writer+4*pf['imm'];starts=(writer+4,target)
            if (po==4 and pf['rs']==pf['rt']) or (po==1 and pf['rs']==0 and pf['rt']==1) or (po==6 and pf['rs']==0):starts=(target,)
            elif (po==5 and pf['rs']==pf['rt']) or (po==1 and pf['rs']==0 and pf['rt']==0) or (po==7 and pf['rs']==0):starts=(writer+4,)
        elif po==0 and pf.get('fn')==8:starts=()
        elif is_call(pf) and reg in VOLATILE:starts=()
    todo=deque((pc,None,None,0) for pc in starts);seen=set()
    while todo:
        pc,after,expires,steps=todo.popleft()
        if expires==0 or steps>=MAXBACK or not writer<pc<=writer+4*MAXBACK:continue
        key=(pc,after,expires)
        if key in seen:continue
        seen.add(key)
        if pc==access:return True
        w=body.word(pc)
        if w is None:continue
        f=dec(pc,w)[1];o=f['op'];new_expires=None if expires is None else expires-1
        if dst_reg(f)==reg or (is_call(f) and reg in VOLATILE):
            if is_load(f) or is_call(f):new_expires=1
            else:continue
        if after is not None:
            successors=[(target,None) for target in after]
        elif o==2:
            target=((pc+4)&0xF0000000)|((w&0x3FFFFFF)<<2)
            successors=[(pc+4,(target,))]
        elif o==0 and (f.get('fn')==8 or (f.get('fn')==9 and f.get('rd')==0)):
            successors=[(pc+4,())]
        elif o in (1,4,5,6,7):
            target=pc+4+4*f['imm'];targets=(pc+8,target)
            if (o==4 and f['rs']==f['rt']) or (o==1 and f['rs']==0 and f['rt']==1) or (o==6 and f['rs']==0):targets=(target,)
            elif (o==5 and f['rs']==f['rt']) or (o==1 and f['rs']==0 and f['rt']==0) or (o==7 and f['rs']==0):targets=(pc+8,)
            successors=[(pc+4,targets)]
        else:successors=[(pc+4,None)]
        for target,targets in successors:todo.append((target,targets,new_expires,steps+1))
    return False


def base_writer(body,va):
    """Provenance through an independently checked path, preserving load/call delays."""
    w=body.word(va)
    if w is None:return ('unreadable',None,'')
    r=dec(va,w)[1]['rs']
    if r==0:return ('base=$zero',None,'')
    nearest=None
    for k in range(1,MAXBACK+1):
        p=va-4*k;ww=body.word(p)
        if ww is None:break
        f=dec(p,ww)[1]
        if dst_reg(f)!=r:continue
        if k==1 and (is_load(f) or is_call(f)):continue
        text=dec(p,ww)[0]
        if is_load(f):kind='SEED load' if is_seed(p,ww) else 'CLOBBERING load'
        elif is_call(f):kind='call (writes $ra)'
        elif f['op']==0x0F:kind='lui (different constant base)'
        elif f['op'] in IMM_OPS:kind='immediate arith'
        elif f['op']==0 and f.get('fn') in (0x21,0x25):kind='addu/or'
        else:kind='other op=%#x'%f['op']
        if nearest is None:nearest=(kind,p,text)
        if kind=='CLOBBERING load' or is_call(f):continue
        if writer_reaches(body,p,va,r):return kind,p,text
    if nearest and nearest[0]=='CLOBBERING load':return nearest
    if nearest:return ('no control-flow path from base writer',nearest[1],nearest[2])
    return ('no-writer within %d words'%MAXBACK,None,'')


def load_records(path):
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict):
        for key in ('records', 'recs', 'entries'):
            if key in data:
                return data[key]
        raise SystemExit('cannot find a record list in %s' % path)
    return data


# --------------------------------------------------------------- structptr ----
def classify_structptr(body, load_pc, access_pc):
    """Provenance of a `scan_structptr` record's base register.

    The pointer is loaded at `load_pc` and is not visible until `load_pc + 8`
    (one delay slot), so the walk starts there. A base that a later `addiu`
    rebases is legitimate -- the tool folds the addend, and that is the whole
    point of the fix -- so immediate arithmetic is not a violation. A base that
    a LOAD overwrites holds memory, and a volatile base with a call in between
    is not provably the pointer. Both are violations.
    """
    w = body.word(access_pc)
    if w is None:
        return ('unreadable', None, '')
    r = dec(access_pc, w)[1]['rs']
    if r == 0:
        return ('base=$zero', None, '')
    call_at = None
    p = load_pc + 8
    while p < access_pc:
        ww = body.word(p)
        if ww is None:
            break
        f = dec(p, ww)[1]
        if call_at is None and is_call(f):
            call_at = p
        if dst_reg(f) == r:
            text = dec(p, ww)[0]
            if is_load(f):
                return ('CLOBBERING load (base reloaded from memory)', p, text)
            if is_call(f):
                return ('call writes the base', p, text)
            if f['op'] in IMM_OPS or f['op'] == 0x0F:
                return ('derived by %s' % text.split()[0], p, text)
            if f['op'] == 0 and f.get('fn') in (0x21, 0x25):
                return ('derived by %s' % text.split()[0], p, text)
            return ('overwritten by op=%#x' % f['op'], p, text)
        p += 4
    if call_at is not None and r in VOLATILE:
        return ('volatile base across a call at %#x (%s)' % (call_at, REGS[r]),
                None, '')
    return ('clean (base still holds the loaded pointer)', None, '')


def audit_structptr(body, recs):
    classes = collections.Counter()
    violations = []
    for r in recs:
        try:
            load_pc, access_pc = int(r['load_pc']), int(r['access_pc'])
        except (KeyError, TypeError, ValueError):
            continue
        cls, p, text = classify_structptr(body, load_pc, access_pc)
        classes[cls] += 1
        if cls.startswith('CLOBBERING') or cls.startswith('volatile') \
                or cls.startswith('call writes') or cls.startswith('overwritten') \
                or cls == 'unreadable':
            violations.append((access_pc, 'struct+%#x' % r.get('offset', 0), p, text))
    return classes, violations


def audit_gs(body, recs):
    classes = collections.Counter()
    violations = []
    for r in recs:
        # record shape: (kind, va, oname, mnemonic, width, rw, descriptor)
        try:
            va = int(r[1])
            desc = str(r[-1])
        except (IndexError, TypeError, ValueError):
            continue
        cls, p, text = base_writer(body, va)
        classes[cls] += 1
        if cls == 'CLOBBERING load' or cls.startswith('volatile base across') \
                or cls == 'no control-flow path from base writer' \
                or cls.startswith('no-writer') \
                or cls == 'unreadable':
            violations.append((va, desc, p, text))
    return classes, violations


def detect_format(recs):
    for r in recs:
        if isinstance(r, dict) and 'access_pc' in r:
            return 'structptr'
        if isinstance(r, (list, tuple)):
            return 'gs'
    return 'gs'


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[1])
    ap.add_argument('records', nargs='?',
                    default=os.path.join(KIT, 'work', 'gs_recs.json'))
    ap.add_argument('--format', choices=('auto', 'gs', 'structptr'), default='auto',
                    help='record-set shape (default: detect from the data)')
    args = ap.parse_args(argv)

    if not os.path.exists(args.records):
        sys.stderr.write('no such records file: %s\n' % args.records)
        return 2
    recs = load_records(args.records)
    fmt = detect_format(recs) if args.format == 'auto' else args.format
    try:
        body = Body(BODIES[fmt])
    except Exception as ex:                              # noqa: BLE001
        sys.stderr.write('could not read the disc body (%s: %s)\n'
                         % (type(ex).__name__, ex))
        return 2
    classes, violations = (audit_structptr(body, recs) if fmt == 'structptr'
                           else audit_gs(body, recs))

    print('%s: %d records (%s format)' % (args.records, len(recs), fmt))
    for k, v in classes.most_common():
        print('   %-52s %d' % (k, v))
    if violations:
        print('\n%d record(s) whose base is not provably the struct pointer:'
              % len(violations))
        for va, desc, p, text in violations[:20]:
            where = '  base written by %#x  %s' % (p, text) if p else ''
            print('   %#x (%s)%s' % (va, desc, where))
        print('\nFAIL: the invariant "recorded accesses need a valid writer path and no clobbered or '
              'call-clobbered base" is violated')
        return 1
    print('\nPASS: recorded bases have valid writer paths and no clobbering load')
    return 0


if __name__ == '__main__':
    sys.exit(main())
