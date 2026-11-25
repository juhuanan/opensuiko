#!/usr/bin/env python3
"""pqes_clean.py -- Sony SEQ parser built from the corrected 15-byte header.

Implements the format as established 2026-10-03 from the user's second-opinion
analysis, then VERIFIED against the bytes here:

  SEQ header = 15 bytes, NOT 16:
    +0x00  4  magic "pQES"
    +0x04  4  version
    +0x08  2  PPQN (ticks per quarter note; 480 in all four Suikoden songs)
    +0x0A  3  tempo, microseconds per quarter note (big-endian)
    +0x0D  2  rhythm bytes
  Score data begins at +0x0F.

  Events are MIDI-style DELTA-BEFORE-EVENT: a VLQ delta precedes each event.
  Tempo metas are "FF 51 <3 bytes>", with no length byte. Repeated metas
  may omit FF (running status on the meta), e.g. "51 xx xx xx".

This is a clean-room reimplementation written to check the claim that the four
sequences parse to their exact physical boundaries with perfectly balanced
note-on/note-off pairs. It does not import the kit's parser.
"""

import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEQ_PATH = os.path.join(HERE, 'SEQ.BIN')

SEQ_HDR = 15
PPQN_OFF, TEMPO_OFF = 0x08, 0x0A

# Physical track boundaries: each starts with the "pQES" magic.
TRACKS = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]


def read_vlq(buf, i):
    v = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return v, i


def parse_track(blob, verbose=False):
    """Parse one track. Returns dict with events, tempo map and notes."""
    assert blob[:4] == b'pQES', 'track does not start with pQES'
    ppqn = struct.unpack_from('>H', blob, PPQN_OFF)[0]
    tempo = int.from_bytes(blob[TEMPO_OFF:TEMPO_OFF + 3], 'big')
    bpm = 60000000.0 / tempo if tempo else 0.0

    ev = blob[SEQ_HDR:]
    events = []
    tempos = [(0, bpm)]
    notes = []            # (on_tick, off_tick, ch, note, vel)
    pending = {}          # (ch, note) -> (tick, vel)
    line = []             # (tick, kind, detail)

    i = 0
    tick = 0
    n = len(ev)
    last_status = None
    last_was_tempo_meta = False
    controls = []
    bends = []
    voice_events = []
    matched = unmatched_on = unmatched_off = 0
    err = None

    while i < n:
        # ---- delta BEFORE the event ----
        delta, i = read_vlq(ev, i)
        tick += delta
        if i >= n:
            break
        b = ev[i]

        # ---- meta ----
        if b == 0xFF:
            if i + 1 >= n:
                break
            typ = ev[i + 1]
            if typ == 0x51:
                # Tempo meta carries NO length byte: "FF 51 <3-byte us/qn>",
                # 5 bytes total. VERIFIED: reading it this way walks track 1 to
                # its exact physical end (ev+18522) with zero desyncs, while a
                # length-byte reading desyncs on the first one.
                if i + 4 >= n:
                    break
                us = (ev[i + 2] << 16) | (ev[i + 3] << 8) | ev[i + 4]
                tempos.append((tick, 60000000.0 / us if us else bpm))
                i += 5
                last_was_tempo_meta = True
                continue
            if typ == 0x2F:
                i += 3
                line.append((tick, 'end', ''))
                break
            # unknown meta: honour a length byte if present
            if i + 2 < n:
                ln = ev[i + 2]
                i += 3 + ln
                continue
            break

        # ---- tempo meta with FF omitted (running status on the meta) ----
        if last_was_tempo_meta and b == 0x51:
            # repeated tempo meta with FF omitted: "51 <3-byte us/qn>" = 4 bytes
            if i + 3 >= n:
                break
            us = (ev[i + 1] << 16) | (ev[i + 2] << 8) | ev[i + 3]
            tempos.append((tick, 60000000.0 / us if us else bpm))
            i += 4
            continue
        last_was_tempo_meta = False

        # ---- channel voice ----
        if b >= 0x80:
            status = b
            last_status = b
            i += 1
        else:
            if last_status is None:
                err = 'data without status at %d' % i
                break
            status = last_status

        nib, ch = status >> 4, status & 0xF
        size=1 if nib in (0xC,0xD) else 2
        if nib in (0x8,0x9,0xB,0xC,0xD,0xE) and i+size<=n:
            voice_events.append((tick,nib,ch,ev[i],ev[i+1] if size==2 else None))

        if nib in (0x8, 0x9):
            if i + 1 >= n:
                break
            note, vel = ev[i], ev[i + 1]
            i += 2
            is_off = (nib == 0x8) or (vel == 0)
            if is_off:
                prv = pending.pop((ch, note), None)
                if prv is not None:
                    notes.append((prv[0], tick, ch, note, prv[1]))
                    matched += 1
                else:
                    unmatched_off += 1
            else:
                if (ch, note) in pending:
                    prv = pending.pop((ch, note))
                    notes.append((prv[0], tick, ch, note, prv[1]))
                    matched += 1
                pending[(ch, note)] = (tick, vel)
        elif nib in (0xB, 0xE):
            if i + 1 >= n:
                err = 'truncated controller/pitch-bend event'
                break
            if nib == 0xB:
                controls.append((tick, ch, ev[i], ev[i+1]))
            else:
                bends.append((tick, ch, ev[i], ev[i+1]))
            i += 2
        elif nib in (0xC, 0xD):
            i += 1
        else:
            err = 'unknown status %02X at %d' % (status, i)
            break

        events.append((tick, status))

    unmatched_on = len(pending)
    return {
        'controls': controls, 'bends': bends, 'voice_events': voice_events, 'ppqn': ppqn, 'tempo': tempo, 'bpm': bpm, 'tempos': tempos,
        'notes': notes, 'events': events, 'err': err,
        'matched': matched, 'unmatched_on': unmatched_on,
        'unmatched_off': unmatched_off, 'bytes_used': i, 'bytes_total': n,
        'last_tick': tick,
    }


def main():
    data = open(SEQ_PATH, 'rb').read()
    print('SEQ.BIN %d bytes' % len(data))
    print()
    total_matched = 0
    for k, (s, e) in enumerate(TRACKS):
        blob = data[s:e]
        r = parse_track(blob)
        ons = r['matched'] + r['unmatched_on']
        offs = r['matched'] + r['unmatched_off']
        print('track %d  [0x%05x:0x%05x]  %d bytes' % (k, s, e, e - s))
        print('   PPQN=%d  tempo=%d us/qn = %.1f BPM' % (r['ppqn'], r['tempo'], r['bpm']))
        print('   note-ons=%d  note-offs=%d  matched=%d  unmatched_on=%d  unmatched_off=%d'
              % (ons, offs, r['matched'], r['unmatched_on'], r['unmatched_off']))
        print('   consumed %d/%d bytes (%.2f%%)   last_tick=%d   err=%s'
              % (r['bytes_used'], r['bytes_total'],
                 100 * r['bytes_used'] / r['bytes_total'], r['last_tick'], r['err']))
        if r['tempos']:
            print('   tempo changes: %d  %s' % (len(r['tempos']),
                  ['%.1f' % b for _, b in r['tempos'][:4]]))
        total_matched += ons
        print()
    print('TOTAL note-ons across all four tracks: %d' % total_matched)
    print('(second-opinion analysis reported 8,955)')


if __name__ == '__main__':
    sys.exit(main())
