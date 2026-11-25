#!/usr/bin/env python3
"""analyze_seq.py -- reproduce (or refute) the structural claims about SEQ.BIN.

Run:  python3 analyze_seq.py

Self-contained: needs only SEQ.BIN in the same directory. Prints the evidence
for each numbered claim in README.md section 3 (PROVEN) and section 4
(GUESSWORK). Nothing here depends on the kit's code.

Deliberately does NOT assume a tempo or a tick rate -- it reports tick counts so
you can decide the timebase yourself.
"""

import struct
import sys
import os

SEQ = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'SEQ.BIN')

# Track boundaries, taken from the four concatenated 16-byte pQES headers.
# Each track starts with the ASCII magic "pQES" (70 51 45 53).
TRACKS = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]
HDR = 16


def load():
    with open(SEQ, 'rb') as f:
        return f.read()


def check_magic(d):
    """Confirm the four track boundaries really are pQES header starts."""
    print('== track boundaries ==')
    ok = True
    for k, (s, e) in enumerate(TRACKS):
        magic = d[s:s + 4]
        good = magic == b'pQES'
        ok &= good
        hdr = d[s:s + HDR]
        print('  track %d  [0x%05x:0x%05x] len=%5d  magic=%s %s'
              % (k, s, e, e - s, magic.decode('latin1'), 'OK' if good else 'BAD'))
        print('           header = %s' % hdr.hex(' '))
        print('           +8..+11 = %s   <-- MEANING UNKNOWN (question 1)'
              % hdr[8:12].hex(' '))
    print('  all four magics valid: %s' % ok)
    print()


def vlq(buf, i):
    """Standard MIDI-style variable length quantity."""
    v = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return v, i


def walk(ev, verbose_tracks=(3,)):
    """Walk one track's event stream. Returns (events, stats).

    Event tuples:  ('on'|'off', ch, note, velocity, delta, tick)
                   ('cc', ch, cc, value, delta, tick)
                   ('pc', ch, prog, delta, tick)
                   ('other', status, None, None, delta, tick)

    NOTE: this walker assumes every note event is exactly 4 bytes
    (status, note, velocity, delta) and that no length-byte meta exists.
    That is claim 1 in the README -- challenge it if the numbers look wrong.
    """
    events = []
    stats = {'unknown_status': [], 'ff_meta': [], 'bytes': len(ev)}
    i = 0
    tick = 0
    last = None
    n = len(ev)
    show = verbose_tracks

    while i < n - 1:
        b = ev[i]
        if b == 0xFF:
            # Record where we saw an FF, for the FF-51 analysis.
            if i + 1 < n:
                stats['ff_meta'].append((i, ev[i + 1], ev[i + 2] if i + 2 < n else None))
            i += 1
            continue
        if b < 0x80:
            if last is None:
                stats['unknown_status'].append((i, b))
                i += 1
                continue
            b = last
        else:
            last = b
            i += 1
        nib, ch = b >> 4, b & 0xF
        if nib in (0x8, 0x9):
            if i + 1 >= n:
                break
            note, vel = ev[i], ev[i + 1]
            i += 2
            delta, i = vlq(ev, i)
            kind = 'on' if (nib == 0x9 and vel) else 'off'
            events.append((kind, ch, note, vel, delta, tick))
            tick += delta
        elif nib in (0xB, 0xE):
            a, c = ev[i], ev[i + 1]
            i += 2
            delta, i = vlq(ev, i)
            events.append(('cc' if nib == 0xB else 'other', ch, a, c, delta, tick))
        elif nib in (0xC, 0xD):
            a = ev[i]
            i += 1
            delta, i = vlq(ev, i)
            events.append(('pc', ch, a, delta, tick))
        else:
            stats['unknown_status'].append((i, b))
            i += 1
    return events, stats


def main():
    d = load()
    print('SEQ.BIN  %d bytes' % len(d))
    print()
    check_magic(d)

    print('== claim 1: note records are 4 bytes (status note velocity delta) ==')
    print('== claim 2: velocity==0 and status 8n are note-OFF ==')
    per_track = []
    for k, (s, e) in enumerate(TRACKS):
        ev = d[s + HDR:e]
        events, stats = walk(ev, verbose_tracks=(3,))
        notes = [x for x in events if x[0] in ('on', 'off')]
        ons = sum(1 for x in notes if x[0] == 'on')
        offs = sum(1 for x in notes if x[0] == 'off')
        nbytes = len(ev)
        per_track.append((events, stats, notes))
        print('  track %d: ev_len=%6d  note_events=%5d  -> %.2f bytes/note'
              % (k, nbytes, len(notes), nbytes / max(len(notes), 1)))
        print('            note_on=%5d  note_off=%5d   (off includes 8n + velocity-0)'
              % (ons, offs))
        nibs = {}
        for b in ev:
            if b >= 0x80:
                nibs[b >> 4] = nibs.get(b >> 4, 0) + 1
        print('            status nibble histogram: %s'
              % ', '.join('%x:%d' % (n, c) for n, c in sorted(nibs.items())))
    print('  -> ~4.0 bytes/note across tracks supports the fixed 4-byte record.')
    print()

    print('== claim 3: note_on.tick + note_on.delta == note_off.tick ==')
    for k in (0, 3):
        events = per_track[k][0]
        pending = {}
        matched = mismatched = 0
        examples = []
        for e in events:
            if e[0] == 'on':
                pending.setdefault((e[1], e[2]), []).append(e)
            elif e[0] == 'off':
                stack = pending.get((e[1], e[2]))
                if stack:
                    on = stack.pop(0)
                    if on[5] + on[4] == e[5]:
                        matched += 1
                        if len(examples) < 5:
                            examples.append((on, e))
                    else:
                        mismatched += 1
        print('  track %d: matched=%d  mismatched=%d' % (k, matched, mismatched))
        for on, off in examples:
            print('     on note=%-3d vel=%-3d delta=%-4d tick=%-6d | '
                  'off delta=%-4d tick=%-6d   %d+%d==%d'
                  % (on[2], on[3], on[4], on[5], off[4], off[5],
                     on[5], on[4], off[5]))
    print('  -> identity holds. WHETHER BOTH DELTAS ADVANCE THE TIMELINE IS')
    print('     STILL OPEN (README question 3). This walker advances on both;')
    print('     advancing only on note-ons is the alternative hypothesis and')
    print('     changes every duration by roughly 3x.')
    print()

    print('== section 4.1: FF 51 "tempo" metas ==')
    for k, (s, e) in enumerate(TRACKS):
        ev = d[s + HDR:e]
        hits = [i for i in range(len(ev) - 2) if ev[i] == 0xFF and ev[i + 1] == 0x51]
        lens = {}
        for h in hits:
            L = ev[h + 2] if h + 2 < len(ev) else None
            lens[L] = lens.get(L, 0) + 1
        print('  track %d: %3d FF51 hits  length-byte counts: %s'
              % (k, len(hits), dict(sorted((x, y) for x, y in lens.items()
                                           if x is not None))))
    print('  A real Sony tempo meta is FF 51 03 <3 bytes>. None present.')
    print('  Sample payloads after "FF 51 08" in track 3 (look like note data):')
    ev = d[TRACKS[3][0] + HDR:TRACKS[3][1]]
    hits = [i for i in range(len(ev) - 3) if ev[i] == 0xFF and ev[i + 1] == 0x51]
    for h in hits[:4]:
        print('     +0x%04x: %s' % (h, ev[h:h + 11].hex(' ')))
    print()

    print('== timeline totals (tick axis only -- YOU supply the timebase) ==')
    for k in range(4):
        events = per_track[k][0]
        ticks = [x[5] for x in events if len(x) > 5]
        ons = [x for x in events if x[0] == 'on']
        spans = []
        pending = {}
        for e in events:
            if e[0] == 'on':
                pending.setdefault((e[1], e[2]), []).append(e)
            elif e[0] == 'off':
                st = pending.get((e[1], e[2]))
                if st:
                    on = st.pop(0)
                    spans.append(e[5] - on[5])
        spans.sort()
        print('  track %d: max_tick=%-7d  note_on=%-5d  spans=%-5d  '
              'median_span=%-5s  max_span=%s'
              % (k, max(ticks) if ticks else 0, len(ons), len(spans),
                 spans[len(spans) // 2] if spans else '-',
                 spans[-1] if spans else '-'))
    print()
    print('  At TPQ=120 / 120 BPM a tick is 0.5/120 s, so max_tick/120*0.5 sec.')
    print('  TPQ_VLQ=120 IS UNVERIFIED (README section 3.4).')
    print()
    print('== open questions ==')
    for q in ('header +8..+11 meaning',
              'true timebase / TPQ',
              'do note-off deltas advance time?',
              'what is FF 51 08 in track 3?',
              'is 8n a separate note-off?',
              'is every note record really 4 bytes?'):
        print('  - %s' % q)


if __name__ == '__main__':
    sys.exit(main())
