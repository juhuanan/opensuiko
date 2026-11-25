#!/usr/bin/env python3
"""Test whether Suikoden 2's sprite-pack control-byte codec decodes
Suikoden 1's 04_PLAY compressed sections.

S2 rule (RHDN 2009 thread, FaustWolf/Tauwasser):
  - stream of control bytes; binary 11000XXX (0xC0-0xC7) -> (XXX)+8 literal bytes follow
    (0xC1->9, 0xC2->10, 0xC3->11)
  - 0x80 -> 7 literal bytes follow (breaks the pattern)
  - all other opcodes (matches etc.) were never cracked -> treated as unknown/fail

Test: parse each S1 04_PLAY raw compressed payload with ONLY the documented
literal-run opcodes. A clean full parse + sane output size = codec may apply.
Early/ubiquitous failure = codec does not apply (exact failure mode recorded).
"""
import struct, os, sys, glob

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)


RAWDIR = os.path.join(_KIT, "extracted/bin_overlays/DATA/04_PLAY")

def parse_container(path):
    with open(path, 'rb') as fh:
        d = fh.read()
    secs = struct.unpack('<8I', d[0x20:0x40])
    return d, secs

def get_s1(d, s1base):
    a, b, magic, c, dd, e, f, g = struct.unpack('<HH6I', d[s1base:s1base+28])
    return dict(a=a, b=b, magic=magic, c=c, d=dd, e=e, f=f, g=g)

def get_payload(d, off):
    """Extract [u32 len][data] unit at off; return (len_field, payload) or None if OOB."""
    if off + 4 > len(d):
        return None
    ln = struct.unpack_from('<I', d, off)[0]
    if off + 4 + ln > len(d):
        return None
    return ln, d[off+4:off+4+ln]

def s2_parse(payload):
    """Parse payload with S2 literal-run rule.
    Returns (ok, out_bytes, consumed, fail_pos, fail_byte).
    ok=True only if the ENTIRE payload parses."""
    out = bytearray()
    pos = 0
    n = len(payload)
    while pos < n:
        b = payload[pos]
        if 0xC0 <= b <= 0xC7:
            run = (b & 7) + 8
            pos += 1
            if pos + run > n:
                return False, bytes(out), pos - 1, pos - 1, b  # truncated run
            out += payload[pos:pos+run]
            pos += run
        elif b == 0x80:
            pos += 1
            if pos + 7 > n:
                return False, bytes(out), pos - 1, pos - 1, b
            out += payload[pos:pos+7]
            pos += 7
        else:
            return False, bytes(out), pos, pos, b
    return True, bytes(out), pos, -1, -1

def main():
    files = sorted(glob.glob(os.path.join(RAWDIR, '*.BIN')))
    print(f'{len(files)} files')
    # aggregate stats per section kind
    kinds = ['S1.c', 'S1.d', 'S1.e', 'S1.f', 'S3']
    stats = {k: {'n':0, 'full_ok':0, 'fail_pos0':0, 'out_lens':[], 'fail_bytes':{}} for k in kinds}
    examples = {}
    for path in files:
        name = os.path.basename(path)
        d, secs = parse_container(path)
        s1 = get_s1(d, secs[1])
        units = {
            'S1.c': s1['c'], 'S1.d': s1['d'], 'S1.e': s1['e'], 'S1.f': s1['f'],
            'S3': secs[3],
        }
        for k, off in units.items():
            u = get_payload(d, off)
            st = stats[k]
            if u is None:
                st['n'] += 1
                continue
            ln, payload = u
            st['n'] += 1
            ok, out, consumed, fpos, fb = s2_parse(payload)
            if ok:
                st['full_ok'] += 1
                st['out_lens'].append(len(out))
                if k not in examples:
                    examples[k] = (name, ln, len(out))
            else:
                if fpos == 0:
                    st['fail_pos0'] += 1
                st['fail_bytes'][fb] = st['fail_bytes'].get(fb, 0) + 1
    for k in kinds:
        st = stats[k]
        print(f'--- {k}: n={st["n"]} full_parse_ok={st["full_ok"]} fail_at_pos0={st["fail_pos0"]}')
        if st['out_lens']:
            print(f'    out_lens: min={min(st["out_lens"])} max={max(st["out_lens"])} ex={examples[k]}')
        if st['fail_bytes']:
            top = sorted(st['fail_bytes'].items(), key=lambda x: -x[1])[:8]
            print(f'    top fail bytes: {[(hex(b), c) for b, c in top]}')

if __name__ == '__main__':
    main()
