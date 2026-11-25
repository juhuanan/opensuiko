#!/usr/bin/env python3
"""Extract version-6 VAB tones using the loader's compact program ranks.

128 logical program slots precede ps occupied 512-byte tone blocks. Each
program owns its declared number of consecutive 32-byte records. Tone sample
references are one-based; exported vag indices are zero-based.

Usage: vab_tones.py [--check] regenerates/verifies tracked metadata only.
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
BANKS = ('ORCH', 'HNK1', 'HNK2')
TONE_SIZE = 32
TONE_BASE = 0x820        # first tone block
TONE_STRIDE = 0x200      # bytes between one program's tone block and the next
PROG_SIZE = 16
PROG_OFF = 0x20


def parse_header(va):
    """Return (num_programs, num_tones, num_vags), asserting the magic."""
    if va[:4] != b'pBAV':
        raise SystemExit('not a VAB: magic %r' % va[:4])
    ps = struct.unpack_from('<H', va, 0x12)[0]
    ts = struct.unpack_from('<H', va, 0x14)[0]
    vs = struct.unpack_from('<H', va, 0x16)[0]
    return ps, ts, vs


def parse_programs(va, ps):
    """Return a list of program attribute dicts."""
    progs = []
    p = PROG_OFF
    for i in range(128):
        if p + PROG_SIZE > len(va):
            raise SystemExit('program table runs past end of %s' % 'VA')
        e = va[p:p + PROG_SIZE]
        progs.append({
            'tones': e[0],
            'mvol': e[1],
            'prior': e[2],
            'mode': e[3],
            'mpan': e[4],
            'attr': struct.unpack_from('<H', e, 6)[0],
        })
        p += PROG_SIZE
    return progs, p


def parse_tone(va, off):
    """Decode one 32-byte tone attribute at `off`."""
    e = va[off:off + TONE_SIZE]
    if len(e) < TONE_SIZE:
        raise SystemExit('tone record at 0x%x is truncated' % off)
    adsr1, adsr2 = struct.unpack_from('<HH', e, 0x10)
    prog, vag = struct.unpack_from('<hh', e, 0x14)
    return {
        'prior': e[0x00],
        'mode': e[0x01],
        'vol': e[0x02],
        'pan': e[0x03],
        'center': e[0x04],
        'shift': e[0x05],
        'min': e[0x06],
        'max': e[0x07],
        'vibW': e[0x08], 'vibT': e[0x09],
        'porW': e[0x0A], 'porT': e[0x0B],
        'pbmin': e[0x0C], 'pbmax': e[0x0D],
        'adsr1': adsr1, 'adsr2': adsr2,
        'prog': prog, 'vag': vag,
    }


def find_tone_table(va, ts, ps, vs, progs):
    """Read occupied blocks in logical-program order; reject inconsistent banks."""
    start, stride = TONE_BASE, TONE_STRIDE
    per_prog = [[] for _ in range(128)]
    rank = 0
    for pi, pr in enumerate(progs):
        n = pr['tones']
        if not n:
            continue
        if n > 16:
            raise ValueError('program tone count exceeds its 512-byte block')
        for k in range(n):
            t = parse_tone(va, start + rank * stride + k * TONE_SIZE)
            if t['prog'] != pi or not (1 <= t['vag'] <= vs):
                raise ValueError('tone owner or one-based sample reference is invalid')
            t['vag'] -= 1
            per_prog[pi].append(t)
        rank += 1
    if rank != ps or sum(map(len, per_prog)) != ts:
        raise ValueError('occupied program/tone counts disagree with header')
    return start, stride, per_prog


def extract(va_path):
    """Return (ps, ts, vs, programs, tones_per_program, start, stride)."""
    with open(va_path, 'rb') as fh:
        va = fh.read()
    ps, ts, vs = parse_header(va)
    progs, tone_off = parse_programs(va, ps)

    start, stride, per_prog = find_tone_table(va, ts, ps, vs, progs)
    return ps, ts, vs, progs, per_prog, start, stride


def main(argv):
    check_only = '--check' in argv
    ok = True
    for bank in BANKS:
        va = os.path.join(KIT, 'work', 'assets_zig', 'audio', 'banks_src', bank + '.VA')
        if not os.path.exists(va):
            print('%s: VA not present, skipped' % bank)
            continue
        ps, ts, vs, progs, per_prog, start, stride = extract(va)
        n_t = sum(len(tl) for tl in per_prog)
        print('=== %s: ps=%d ts=%d vs=%d  tone table @0x%x stride 0x%x, %d tones mapped'
              % (bank, ps, ts, vs, start, stride, n_t))

        # Sanity: every vag must be in range, and every referenced vag real.
        bad = [(pi, t['vag']) for pi, tl in enumerate(per_prog)
               for t in tl if not (0 <= t['vag'] < vs)]
        if bad:
            ok = False
            print('   OUT OF RANGE vag indices: %s' % bad[:8])

        out = {
            'ps': ps, 'ts': ts, 'vs': vs,
            'tones': {str(pi): [
                {k: t[k] for k in ('vag', 'center', 'shift', 'min', 'max',
                                   'vol', 'pan', 'prior', 'adsr1', 'adsr2')}
                for t in tl] for pi, tl in enumerate(per_prog) if tl},
        }
        path = os.path.join(KIT, 'work', '%s_tones.json' % bank)
        old = None
        if os.path.exists(path):
            with open(path) as fh:
                old = json.load(fh)
        # Report what changes, so the diff is reviewable rather than silent.
        if old:
            changes = []
            for pi, tl in out['tones'].items():
                otl = old.get('tones', {}).get(pi, [])
                for k, t in enumerate(tl):
                    if k < len(otl) and otl[k].get('vag') != t['vag']:
                        changes.append('prog%s[%d] vag %s -> %s'
                                       % (pi, k, otl[k].get('vag'), t['vag']))
            if changes:
                print('   vag corrections (%d): %s'
                      % (len(changes), '; '.join(changes[:6])))
                if len(changes) > 6:
                    print('     ... and %d more' % (len(changes) - 6))
            else:
                print('   no vag changes')
        if check_only and old != out:
            ok = False
            print('   tracked metadata differs from disc bank')
        if not check_only:
            with open(path, 'w') as fh:
                json.dump(out, fh, indent=1, sort_keys=True)
                fh.write('\n')
            print('   wrote %s' % path)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
