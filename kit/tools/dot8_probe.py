#!/usr/bin/env python3
"""dot8_probe.py -- evidence instrument for the `.8` payload-reader hunt.

Static analysis only; every disc byte comes through `kit/tools/disc.py`.
No emulator, no VRAM oracle.

What this tool can answer, and how:

  --table     Decode the 71-slot `.8` resource table out of MAIN.EXE (on-disc
              bytes: the table is not relocated) and match every entry to the
              ISO9660 listing by LBA.  Prints the field layout the loader uses.
  --records   On-disc record structure of one or more `.8` files: the 16-byte
              framing, the tag-byte alphabet, and the payload-nibble histogram
              for bytes 2..15 only (28 nibbles per record).
  --refs      Corpus-wide scan for code that resolves an absolute RAM address
              equal to a given target, base-independently (lui + sign-extended
              immediate).  Used to prove *which* functions touch the `.8`
              stream window.  Runs a positive control first.
  --calls     Corpus-wide scan for `jal` instructions targeting an address.
              Instructive for entry points (a 32-bit literal pointer scan is
              also performed, because callbacks are registered as values).
  --lui       Corpus-wide scan for `lui $r,0x801F` (i.e. code that materialises
              the 0x801F0000 scratch page at all).
  --reach     MAIN.EXE-only structural scans for the missing payload reader:
              16-byte-stride loops, nibble idioms, 4-bit sign-extend, nibble
              LUTs, table dispatch.

Housekeeping facts this file encodes (see
`kit/docs/dot8_payload_reader.md` for the argument):

  * MAIN.EXE body loads at 0x800C0800 (PS-X header `t_addr`); its `pc0` is
    0x801479A8.  SLUS_002.92 body loads at 0x80010000.
  * `.8` block = [u8 shift/filter][u8 flags][14 residual bytes]; the second byte
    is the SPU ADPCM flag:0x02 except one0x06 and one0x03 per file.
  * The loader streams 16 KiB blocks from the CD into a 32 KiB window based at
    0x801F0000 (pointer in [0x80179DD0]); the record cursor used by the only
    window reader is [0x80179DF0].

Usage:
    .venv/bin/python kit/tools/dot8_probe.py --table
    .venv/bin/python kit/tools/dot8_probe.py --records PASS.8 BATTLE1.8
    .venv/bin/python kit/tools/dot8_probe.py --refs
    .venv/bin/python kit/tools/dot8_probe.py --selftest
"""

import argparse
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import disc  # noqa: E402  (kit/tools/disc.py -- the only disc reader)

# MAIN.EXE body geometry (validated against the PS-X EXE header on the disc).
MAIN_BASE = 0x800C0800
EXE_HEADER = 2048

# `.8` resource table, established from the loader code:
#   +0x00 u32 lba ; +0x04 u16 X ; +0x06 u16 n1 ; +0x08 u16 n2 ; +0x0A u16 Y
# read at 0x80164E68 by 0x800C7C60/0x800C865C (lw +0), 0x800C864C (lhu +8),
# 0x800C8684 (lhu +6), 0x800C7C34/0x800C7978 (lbu +0x0A).
DOT8_TABLE_VA = 0x80164E68
DOT8_TABLE_STRIDE = 12
DOT8_TABLE_ENTRIES = 71

# The `.8` stream state in MAIN.EXE (all addresses are RAM addresses).
STREAM_WINDOW_PTR = 0x80179DD0      # u32 -> 0x801F0000 (32 KiB window base)
STREAM_SECTOR_PTR = 0x80179DD8      # u32, advanced 0x800 per CD-sector callback
STREAM_SECTOR_N = 0x80179DE0        # u8,  counts 0..16
STREAM_RECORD_PTR = 0x80179DE8      # u32, scratch inside the only reader
STREAM_RECORD_CUR = 0x80179DF0      # u32, record cursor (+4 per reader call)
STREAM_SCALE = 0x80179C0C           # u16, per-resource scale (table +0x0A byte)
RES_INDEX = 0x80179BF3              # u8,  current `.8` resource index
LOADER_STATE = 0x80179C04           # u8,  loader state machine
CD_POS = 0x80179CE8                 # u32, stream read position (sector)

STREAM_GLOBALS = [
    STREAM_WINDOW_PTR, STREAM_SECTOR_PTR, STREAM_SECTOR_N, STREAM_RECORD_PTR,
    STREAM_RECORD_CUR, STREAM_SCALE, RES_INDEX, CD_POS, 0x801F0000, 0x801F4000,
]

# Loader state table (0x800C0CA8) -> handler, and the handlers' read geometry.
LOADER_READS = {
    3: (0x800C8140, "0x4000 @ window+0x0000", 0x1010, 0x06, 0x0001),
    4: (0x800C81F0, "0x4000 @ window+0x4000", 0x9010, 0x06, 0x4001),
    8: (0x800C8468, "0x4000 @ window+0x0000", 0x5010, 0x03, 0x3FF1),
    9: (0x800C85C4, "0x4000 @ window+0x4000", 0xD010, 0x03, 0x7FF1),
}


# --------------------------------------------------------------------------
# disc access
# --------------------------------------------------------------------------

def _iso_listing():
    path = os.path.join(ROOT, 'kit', 'extracted', 'iso_files.json')
    with open(path) as fh:
        return [r for r in json.load(fh) if not r.get('dir')]


def _iso_entry(name, listing=None):
    for r in (listing if listing is not None else _iso_listing()):
        if r['path'].split('/')[-1] == name:
            return r
    raise KeyError(name)


def mainexe_body():
    """MAIN.EXE body (PS-X header stripped), chunked through disc.py."""
    r = _iso_entry('MAIN.EXE')
    n = r['size']
    out = bytearray()
    off = 0
    while off < n:
        step = min(1 << 20, n - off)
        out += disc.extract(r['lba'] + off // 2048, step)
        off += step
    return bytes(out[EXE_HEADER:r['size']])


def slus_body():
    """SLUS_002.92 body (the BOOT program per SYSTEM.CNF), base 0x80010000."""
    r = _iso_entry('SLUS_002.92')
    out = bytearray()
    off = 0
    while off < r['size']:
        step = min(1 << 20, r['size'] - off)
        out += disc.extract(r['lba'] + off // 2048, step)
        off += step
    return bytes(out[EXE_HEADER:r['size']])


SLUS_BASE = 0x80010000
# The two builds' 41-entry loader state tables (dispatcher 0x800C7E10 /
# 0x8001F2D8, bound check < 0x28, sll by 2, lw, jr).
MAIN_STATE_TABLE = 0x800C0CA8
SLUS_STATE_TABLE = 0x8001062C


def state_table_report():
    """Compare the two builds' loader state tables.

    Returns (rows, deltas, same_shape); rows are (state, main, slus).
    """
    main = mainexe_body()
    slus = slus_body()
    rows = []
    for i in range(41):
        m = struct.unpack_from('<I', main,
                               MAIN_STATE_TABLE - MAIN_BASE + 4 * i)[0]
        s = struct.unpack_from('<I', slus,
                               SLUS_STATE_TABLE - SLUS_BASE + 4 * i)[0]
        rows.append((i, m, s))
    deltas = sorted(set(m - s for _, m, s in rows))
    return rows, deltas, len(deltas) == 1


def read_dot8(name, listing=None):
    """Full `.8` file bytes (name matched against the ISO9660 listing)."""
    r = _iso_entry(name, listing)
    out = bytearray()
    off = 0
    while off < r['size']:
        step = min(1 << 20, r['size'] - off)
        out += disc.extract(r['lba'] + off // 2048, step)
        off += step
    return bytes(out[:r['size']])


def corpus_files():
    """Every executable-bearing on-disc file: MAIN.EXE + 344 overlay .BINs +
    SLUS_002.92, as (label, bytes) pairs (bytes read through disc.py)."""
    listing = _iso_listing()
    files = [('MAIN.EXE', mainexe_body())]
    for r in listing:
        if r['path'].endswith('.BIN'):
            out = bytearray()
            off = 0
            while off < r['size']:
                step = min(1 << 20, r['size'] - off)
                out += disc.extract(r['lba'] + off // 2048, step)
                off += step
            files.append((r['path'], bytes(out[:r['size']])))
    slus = _iso_entry('SLUS_002.92', listing)
    out = bytearray()
    off = 0
    while off < slus['size']:
        step = min(1 << 20, slus['size'] - off)
        out += disc.extract(slus['lba'] + off // 2048, step)
        off += step
    files.append(('SLUS_002.92', bytes(out[EXE_HEADER:slus['size']])))
    return files


# --------------------------------------------------------------------------
# resource table
# --------------------------------------------------------------------------

def dot8_table(body=None):
    """The 71-slot `.8` resource table, decoded from MAIN.EXE on-disc bytes."""
    body = body if body is not None else mainexe_body()
    rows = []
    for i in range(DOT8_TABLE_ENTRIES):
        o = DOT8_TABLE_VA - MAIN_BASE + DOT8_TABLE_STRIDE * i
        if o < 0 or o + DOT8_TABLE_STRIDE > len(body):
            break
        lba = struct.unpack_from('<I', body, o)[0]
        x, n1, n2, y = struct.unpack_from('<HHHH', body, o + 4)
        rows.append(dict(idx=i, lba=lba, x=x, n1=n1, n2=n2, y=y))
    return rows


def table_report():
    listing = _iso_listing()
    by_lba = {r['lba']: r for r in listing if r['path'].endswith('.8')}
    rows = dot8_table()
    matched = 0
    for row in rows:
        r = by_lba.get(row['lba'])
        row['name'] = r['path'].split('/')[-1] if r else None
        row['size'] = r['size'] if r else None
        row['sectors'] = (r['size'] // 2048) if r else None
        if r and row['n2'] == r['size'] // 2048:
            matched += 1
    return rows, matched


# --------------------------------------------------------------------------
# record / nibble statistics
# --------------------------------------------------------------------------

def _sx4(n):
    n &= 0xF
    return n - 16 if n >= 8 else n


def record_stats(data):
    """16-byte framing, tag alphabet and payload-nibble histogram."""
    n = len(data) // 16
    tags = {}
    non_data = []
    nib = [0] * 16              # index 0..15 means -8..+7
    payload_nib = [0] * 16
    for i in range(n):
        rec = data[16 * i:16 * i + 16]
        tags[rec[0]] = tags.get(rec[0], 0) + 1
        if rec[1] != 0x02:
            non_data.append((i, rec[0], rec[1]))
        for k, b in enumerate(rec):
            nib[_sx4(b >> 4) + 8] += 1
            nib[_sx4(b & 0xF) + 8] += 1
            if k >= 2:
                payload_nib[_sx4(b >> 4) + 8] += 1
                payload_nib[_sx4(b & 0xF) + 8] += 1
    return dict(records=n, tags=tags, non_data=non_data,
                nibbles=nib, payload_nibbles=payload_nib)


def laplacian_lines(hist):
    """Histogram as -8..+7 lines, plus the +/- pair symmetry ratio."""
    lines = []
    worst = 0.0
    for v in range(1, 8):
        lo, hi = hist[8 - v], hist[8 + v]
        denom = max(lo, hi) or 1
        rel = abs(lo - hi) / denom
        worst = max(worst, rel)
        lines.append((v, lo, hi, rel))
    return lines, worst


# --------------------------------------------------------------------------
# code scans
# --------------------------------------------------------------------------

IMM_OPS = {0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E}
LOAD_OPS = {0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26}
STORE_OPS = {0x28, 0x29, 0x2A, 0x2B, 0x2E}
ALL_IMM_OPS = IMM_OPS | LOAD_OPS | STORE_OPS | {0x2F}


def sx16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def scan_refs(files, targets, window=8):
    """Base-independent absolute-address references.

    `lui $r,hi` followed within `window` instructions by an immediate/load/store
    op with rs==r resolves to addr = (hi<<16) + sx16(imm) -- with the full
    documented sign extension (lui 0x8018 + imm -0x6230 == 0x80179DD0).  The
    answer therefore does not depend on knowing an overlay's load base.

    Returns [(label, addr, insn_offset, opcode)].
    """
    targets = set(targets)
    out = []
    for label, data in files:
        n = len(data) // 4
        for i in range(n):
            w = struct.unpack_from('<I', data, 4 * i)[0]
            if (w >> 26) != 0x0F:
                continue
            reg = (w >> 16) & 0x1F
            hi = (w & 0xFFFF) << 16
            for k in range(1, window + 1):
                j = i + k
                if j >= n:
                    break
                w2 = struct.unpack_from('<I', data, 4 * j)[0]
                op = w2 >> 26
                if op == 0x0F:
                    break
                if ((w2 >> 21) & 0x1F) != reg:
                    continue
                if op in ALL_IMM_OPS:
                    a = (hi + sx16(w2)) & 0xFFFFFFFF
                    if a in targets:
                        out.append((label, a, 4 * i, op))
    return out


def scan_lui(files, imm16):
    """Every instruction word `lui $r,imm16` (i.e. address imm16<<16 formed)."""
    want = 0x0F << 26 | imm16
    mask = 0xFFFF | 0xFC000000
    out = []
    for label, data in files:
        for i in range(len(data) // 4):
            w = struct.unpack_from('<I', data, 4 * i)[0]
            if (w & mask) == want:
                out.append((label, 4 * i))
    return out


def scan_jal(files, target):
    """`jal target` for any pc in 0x80000000-0x8FFFFFFF: the target's low 28
    bits are imm26<<2, so the instruction word alone identifies the call."""
    want = struct.pack('<I', (3 << 26) | ((target & 0x0FFFFFFF) >> 2))
    out = []
    for label, data in files:
        i = data.find(want)
        while i >= 0:
            if i % 4 == 0:
                out.append((label, i))
            i = data.find(want, i + 1)
    return out


def scan_pointer_literal(files, target):
    """Raw little-endian 32-bit literal (function-pointer tables / callbacks)."""
    want = struct.pack('<I', target)
    out = []
    for label, data in files:
        i = data.find(want)
        while i >= 0:
            out.append((label, i))
            i = data.find(want, i + 1)
    return out


# --------------------------------------------------------------------------
# MAIN.EXE structural scans
# --------------------------------------------------------------------------

class Main(object):
    def __init__(self, body):
        self.body = body
        self.words = [struct.unpack_from('<I', body, 4 * i)[0]
                      for i in range(len(body) // 4)]
        self.vas = [MAIN_BASE + 4 * i for i in range(len(self.words))]
        self.idx = {v: i for i, v in enumerate(self.vas)}

    def f(self, w):
        return dict(op=(w >> 26) & 0x3F, rs=(w >> 21) & 0x1F,
                    rt=(w >> 16) & 0x1F, rd=(w >> 11) & 0x1F,
                    sa=(w >> 6) & 0x1F, fn=w & 0x3F, imm=sx16(w))

    def stride_loops(self, stride=0x10, maxlen=400):
        out = []
        for i, w in enumerate(self.words):
            g = self.f(w)
            if g['op'] not in (0x01, 0x04, 0x05, 0x06, 0x07):
                continue
            tgt = self.vas[i] + 4 + (g['imm'] << 2)
            ti = self.idx.get(tgt)
            if ti is None or ti >= i or i - ti > maxlen:
                continue
            st = [self.vas[k] for k in range(ti, i + 1)
                  if self.f(self.words[k])['op'] == 0x09
                  and self.f(self.words[k])['rs'] == self.f(self.words[k])['rt']
                  and self.f(self.words[k])['imm'] == stride]
            if st:
                out.append((tgt, self.vas[i], st))
        return out

    def nibble_idioms(self):
        """srl x,4 ; andi x,0xF ; sll/sra 28 sign-extend ; srl 4 + addiu +/-8."""
        srl4, andi_f, signext, bias8, xori8, fold16 = [], [], [], [], [], []
        for i, w in enumerate(self.words):
            g = self.f(w)
            if g['op'] == 0x0C and g['imm'] == 0xF:
                andi_f.append(self.vas[i])
            if g['op'] == 0x0E and g['imm'] == 8:
                xori8.append(self.vas[i])
            if g['op'] == 0 and g['fn'] == 0x03 and g['sa'] == 28 and i:
                p = self.f(self.words[i - 1])
                if p['op'] == 0 and p['fn'] == 0x00 and p['sa'] == 28:
                    signext.append(self.vas[i - 1])
            if g['op'] == 0 and g['fn'] == 0x02 and g['sa'] == 4:
                srl4.append(self.vas[i])
                for k in (1, 2):
                    if i + k < len(self.words):
                        g2 = self.f(self.words[i + k])
                        if g2['op'] == 0x09 and g2['imm'] in (8, -8):
                            bias8.append((self.vas[i], self.vas[i + k]))
            if g['op'] in (0x09, 0x0D) and g['imm'] == 16:
                r = g['rt']
                for k in range(i + 1, min(i + 6, len(self.words))):
                    g2 = self.f(self.words[k])
                    if g2['op'] == 0 and g2['fn'] == 0x23 and g2['rs'] == r:
                        fold16.append((self.vas[i], self.vas[k]))
                        break
        return dict(srl4=srl4, andi_f=andi_f, signext=signext, bias8=bias8,
                    xori8=xori8, fold16=fold16)

    def nibble_luts(self):
        """Nibble lookup tables: 16-entry sign tables and 256/512-entry maps."""
        d = self.body
        found = []
        probs = [
            ('sx4-table-16-B', bytes((_sx4(k) & 0xFF) for k in range(16))),
            ('sx4-table-16-H',
             b''.join(struct.pack('<h', _sx4(k)) for k in range(16))),
            ('T512-rshift4-maskF',
             bytes(v for i in range(256) for v in ((i >> 4), i & 0xF))),
            ('T512-maskF-rshift4',
             bytes(v for i in range(256) for v in (i & 0xF, i >> 4))),
            ('T256-rshift4', bytes((i >> 4) & 0xFF for i in range(256))),
            ('T256-maskF', bytes(i & 0xF for i in range(256))),
        ]
        for name, pat in probs:
            i = d.find(pat)
            while i >= 0:
                found.append((name, MAIN_BASE + i))
                i = d.find(pat, i + 1)
        return found

    def jal_targets(self):
        out = []
        for i, w in enumerate(self.words):
            if (w >> 26) == 3:
                pc = self.vas[i]
                out.append((pc, ((pc + 4) & 0xF0000000) | ((w & 0x3FFFFFF) << 2)))
        return out


# --------------------------------------------------------------------------
# self-test / reporting
# --------------------------------------------------------------------------


# NOTE 2026-10-05: --records / --all-records read .8 bytes with disc.extract(),
# i.e. the Form 1 (2048-byte) user field. .8 files are MODE2 **Form 2** (2324-byte),
# so those two modes describe a MISREAD stream: every 16-byte 'record' is an
# alignment artifact. .8 is XA audio (submode 0x08 on every sampled sector of all
# 67 files) -- see kit/docs/dot8_is_xa_audio.md. --bios / --refs / --calls
# / --table / --lui are unaffected: they work on MAIN.EXE and the ISO listing.

# --- BIOS jump-table calls -------------------------------------------------
# MAIN.EXE performs no direct hardware access at all (zero references to
# 0x1F8010B0/0x1F8010C0/0x1F801Dxx across the whole image), so all CD/SPU/DMA
# I/O goes through the BIOS entry tables. A call is the PSY-Q idiom:
#     addiu $t2,$zero,TABLE ; jr $t2 ; addiu $t1,$zero,FUNC   (the delay slot)
# with TABLE in {0xA0,0xB0,0xC0}. Enumerating them is what makes "is this a CD
# read or an SPU write?" answerable, or provably unanswerable, from the disc.
def scan_bios_calls(body):
    """[(pc, table, function)] for every BIOS jump-table call in `body`."""
    import struct as _s
    n = len(body) // 4
    out = []
    for i in range(n):
        iw = _s.unpack_from('<I', body, i * 4)[0]
        if iw >> 26 != 0x09:                       # addiu
            continue
        if ((iw >> 21) & 0x1F) != 0 or ((iw >> 16) & 0x1F) != 10:
            continue                               # must be $t2,$zero,N
        table = iw & 0xFFFF
        if table not in (0xA0, 0xB0, 0xC0):
            continue
        if i + 1 >= n or _s.unpack_from('<I', body, (i + 1) * 4)[0] != 0x01400008:
            continue                               # must be jr $t2
        fn = None
        if i + 2 < n:
            dw = _s.unpack_from('<I', body, (i + 2) * 4)[0]
            if dw >> 26 == 0x09 and ((dw >> 16) & 0x1F) == 9:
                fn = dw & 0xFFFF                   # addiu $t1,$zero,N
        out.append((MAIN_BASE + i * 4, table, fn))
    return out

def selftest(verbose=True):
    """Prove the scans can find known positives before believing a negative."""
    body = mainexe_body()
    files = [('MAIN.EXE', body)]
    checks = []

    # 1. resource table base is reached by the loader at four known sites.
    refs = scan_refs(files, [DOT8_TABLE_VA,
                             DOT8_TABLE_VA + 6,
                             DOT8_TABLE_VA + 8,
                             DOT8_TABLE_VA + 0x0A])
    sites = sorted(set(o for _, _, o, _ in refs))
    want_sites = [0x800C7C34, 0x800C7C60, 0x800C864C, 0x800C865C, 0x800C8684]
    got_sites = sorted(MAIN_BASE + o for o in sites)
    checks.append(('table reader sites',
                   sorted(set(got_sites) & set(want_sites)), want_sites))

    # 2. the window pointer is touched by the loader family only.
    refs2 = scan_refs(files, [STREAM_WINDOW_PTR, STREAM_SECTOR_PTR,
                              STREAM_RECORD_CUR, STREAM_SCALE])
    checks.append(('window-global refs in MAIN', len(refs2), None))

    # 3. the reader is not called: no jal, no j, no literal pointer.
    jal = scan_jal(files, 0x800C8A80)
    lit = scan_pointer_literal(files, 0x800C8A80)
    checks.append(('jal to the only window reader 0x800C8A80', len(jal), 0))
    checks.append(('literal pointer to 0x800C8A80', len(lit), 0))

    # 4. positive control for scan_jal: the loader dispatcher is called once.
    jal2 = scan_jal(files, 0x800C7E10)
    checks.append(('jal to loader dispatcher 0x800C7E10', len(jal2), 1))

    # 5. record framing on the smallest `.8` file.
    data = read_dot8('CDSE11.8')
    st = record_stats(data)
    non2 = [(i, hex(t), hex(c)) for i, t, c in st['non_data']]
    checks.append(('CDSE11.8 records', st['records'], 192 * 2048 // 16))
    checks.append(('CDSE11.8 non-0x02 category bytes', len(non2), 2))

    if verbose:
        for name, got, want in checks:
            ok = want is None or got == want
            print('%s %-44s got=%s want=%s'
                  % ('OK ' if ok else 'HMM', name, got, want))
    return checks


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--table', action='store_true')
    ap.add_argument('--records', nargs='*')
    ap.add_argument('--all-records', action='store_true',
                    help='framing check over every .8 file (288 MB of I/O)')
    ap.add_argument('--refs', action='store_true')
    ap.add_argument('--calls', nargs='*')
    ap.add_argument('--lui', nargs='*')
    ap.add_argument('--reach', action='store_true')
    ap.add_argument('--bios', action='store_true',
                    help='enumerate BIOS jump-table calls in MAIN.EXE')
    ap.add_argument('--slus', action='store_true',
                    help='compare the MAIN.EXE and SLUS_002.92 loader tables')
    ap.add_argument('--selftest', action='store_true')
    args = ap.parse_args()

    if args.selftest or not any(vars(args).values()):
        selftest()
        return

    if args.slus:
        rows, deltas, same = state_table_report()
        print('# MAIN.EXE %#x vs SLUS_002.92 %#x, 41 states, '
              'constant delta=%s, same shape=%s'
              % (MAIN_STATE_TABLE, SLUS_STATE_TABLE,
                 [hex(d) for d in deltas], same))
        for st, m, s in rows:
            print('%2d  main=%08x  slus=%08x  delta=%+#x'
                  % (st, m, s, m - s))

    if args.bios:
        body = mainexe_body()
        calls = scan_bios_calls(body)
        print('BIOS jump-table calls in MAIN.EXE: %d' % len(calls))
        for pc, table, fn in calls:
            print('  %#010x  BIOS %#04x(%s)'
                  % (pc, table, fn if fn is not None else '?'))
        return 0

    if args.table:
        rows, matched = table_report()
        print('# %d/%d non-empty entries match an ISO `.8` file by LBA and '
              'n2 == size/2048' % (matched, sum(1 for r in rows if r['lba'])))
        for r in rows:
            if not r['lba']:
                continue
            print('%2d %-14s lba=%6d sec=%5d n1=%5d n2=%5d X=%#06x Y=%#06x %s'
                  % (r['idx'], r['name'] or '?', r['lba'], r['sectors'] or 0,
                     r['n1'], r['n2'], r['x'], r['y'],
                     'OK' if r['sectors'] == r['n2'] else 'MISMATCH'))

    if args.records:
        for name in args.records:
            data = read_dot8(name)
            st = record_stats(data)
            lines, worst = laplacian_lines(st['payload_nibbles'])
            print('== %s: %d bytes, %d records, tags=%d distinct'
                  % (name, len(data), st['records'], len(st['tags'])))
            print('   category bytes != 0x02: %s'
                  % [(i, hex(t), hex(c)) for i, t, c in st['non_data']])
            print('   tag alphabet: %s'
                  % ' '.join('%02x' % k for k in sorted(st['tags'])))
            print('   payload nibbles (bytes 2..15, 28/record): %d, worst '
                  '+/- pair asymmetry %.3f' % (sum(st['payload_nibbles']), worst))
            for v, lo, hi in lines:
                print('     %+d: %8d / %+d: %8d' % (-v, lo, v, hi))

    if args.all_records:
        listing = _iso_listing()
        tot = bad = 0
        for r in listing:
            if not r['path'].endswith('.8'):
                continue
            st = record_stats(read_dot8(r['path'].split('/')[-1]))
            tot += st['records']
            bad += len(st['non_data'])
            print('%-14s records=%7d non-0x02=%d'
                  % (r['path'].split('/')[-1], st['records'],
                     len(st['non_data'])))
        print('TOTAL records=%d, category bytes != 0x02: %d' % (tot, bad))

    if args.refs:
        files = corpus_files()
        print('# positive control: refs in MAIN.EXE')
        for lbl, a, o, op in scan_refs(files[:1], STREAM_GLOBALS):
            print('   %-12s %08x via off %#x op %#x' % (lbl, a, o, op))
        print('# corpus-wide (MAIN + 344 .BIN + SLUS):')
        hits = scan_refs(files, STREAM_GLOBALS)
        for lbl, a, o, op in hits:
            print('   %-40s %08x off %#x op %#x' % (lbl, a, o, op))
        print('   total %d' % len(hits))

    if args.calls:
        files = corpus_files()
        for t in args.calls:
            t = int(t, 0)
            jal = scan_jal(files, t)
            lit = scan_pointer_literal(files, t)
            print('%08x: jal=%d literal=%d' % (t, len(jal), len(lit)))
            for lbl, o in jal + lit:
                print('   %-40s off %#x' % (lbl, o))

    if args.lui:
        files = corpus_files()
        for imm in args.lui:
            imm = int(imm, 0)
            hits = scan_lui(files, imm)
            print('lui 0x%04x: %d hits' % (imm, len(hits)))
            for lbl, o in hits:
                print('   %-40s off %#x' % (lbl, o))

    if args.reach:
        m = Main(mainexe_body())
        sl = m.stride_loops(0x10)
        print('16-byte-stride loops in MAIN.EXE: %d' % len(sl))
        for tgt, end, st in sl:
            print('   %08x..%08x strides=%s'
                  % (tgt, end, [hex(x) for x in st[:3]]))
        idioms = m.nibble_idioms()
        for k in ('srl4', 'andi_f', 'signext', 'bias8', 'xori8', 'fold16'):
            print('%-8s %d %s' % (k, len(idioms[k]),
                                  [hex(x) if not isinstance(x, tuple) else
                                   (hex(x[0]), hex(x[1])) for x in idioms[k][:12]]))
        print('nibble LUTs: %s' % m.nibble_luts())


if __name__ == '__main__':
    main()
