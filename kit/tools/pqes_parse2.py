#!/usr/bin/env python3
"""Correct pQES event parser with tempo support (2026-10-01).

Verified against MAIN.EXE disassembly:
- 0x9n: [note][dur][VLQ-delta], NO velocity byte. dur=0 notes DO sound.
- 0xBn: [cc][val], 0xCn: [prog], 0xEn: [b1][b2] (ignored).
- 0xFF 0x51 <3 bytes>: Set Tempo, microseconds per quarter (BE).
  NO length byte (Sony SEQ vs SMF). Followed by a VLQ delta like every
  other event; the old "1 pad byte" assumption desynced the parse whenever
  the delta was multi-byte (e.g. 81 16). Tick advances by the delta.
  Game computes BPM = 60000000 / us (MAIN.EXE 0x8015d11c).
- 0xFF 0x2F 0x00: end of track.
- Running status preserved across 0xFF, AND applies to 0xFn meta events:
  after FF 51, a bare 51 is another tempo event (FF omitted).

Returns: (events, tempo_map, error)
  events: list of ('on', ch, note, dur, delta_vlq) etc.
  tempo_map: list of (tick_vlq, bpm) sorted by tick.
"""

def parse_pqes(ev, default_bpm=120.0):
    events = []
    tempo_map = [(0, float(default_bpm))]
    tick = 0
    i, n = 0, len(ev)
    last = None       # last channel status (0x80-0xEF) for running status
    last_was_meta = False  # True if most recent event was FF-meta
    last_meta = None  # meta type (0x51), valid when last_was_meta
    def read_vlq():
        nonlocal i
        v = 0
        while i < n:
            bb = ev[i]; i += 1
            v = (v << 7) | (bb & 0x7F)
            if not bb & 0x80:
                break
        return v
    while i < n:
        b = ev[i]
        if b == 0xFF:
            if i + 1 >= n:
                break
            typ = ev[i + 1]
            if typ == 0x51:
                if i + 4 >= n:
                    break
                us = (ev[i + 2] << 16) | (ev[i + 3] << 8) | ev[i + 4]
                bpm = 60000000.0 / us if us else default_bpm
                tempo_map.append((tick, bpm))
                i += 5  # FF 51 ttt (NO length byte, Sony SEQ)
                v = read_vlq()  # VLQ delta AFTER every event (incl. meta)
                tick += v
                last_was_meta = True
                last_meta = 0x51
            elif typ == 0x2F:
                i += 3
                break
            else:
                return events, tempo_map, 'unknown meta %02X at %d' % (typ, i)
            continue
        if b < 0x80:
            # Sony SEQ: running status applies to 0xFn meta events too.
            # After FF 51, a bare 51 is another tempo (FF omitted).
            if last_was_meta and b == 0x51 and last_meta == 0x51:
                if i + 4 >= n:
                    break
                us = (ev[i + 1] << 16) | (ev[i + 2] << 8) | ev[i + 3]
                bpm = 60000000.0 / us if us else default_bpm
                tempo_map.append((tick, bpm))
                i += 4  # 51 ttt (FF omitted via running status)
                v = read_vlq()
                tick += v
                # last_was_meta/last_meta stay set (chainable)
                continue
            if last is None:
                return events, tempo_map, 'data w/o status at %d' % i
            b = last
            last_was_meta = False
        else:
            last = b
            last_was_meta = False
            last_meta = None
            i += 1
        if i >= n:
            break
        nib, ch = b >> 4, b & 0xF
        if nib == 0x9:
            if i + 1 >= n:
                break
            note, dur = ev[i], ev[i + 1]
            i += 2
            v = read_vlq()
            events.append(('on', ch, note, dur, v, tick))
            tick += v
        elif nib == 0xB:
            if i + 1 >= n:
                break
            cc, val = ev[i], ev[i + 1]
            i += 2
            v = read_vlq()  # delta advances cursor but NOT tick (verified: no call to tick fn)
            events.append(('cc', ch, cc, val, v, tick))
        elif nib == 0xC:
            prog = ev[i]
            i += 1
            v = read_vlq()  # delta advances cursor but NOT tick
            events.append(('pc', ch, prog, v, tick))
        elif nib == 0xE:
            i += 2
            v = read_vlq()
            tick += v
        else:
            return events, tempo_map, 'unknown status %02X at %d' % (b, i)
    return events, tempo_map, 'ok'


def find_event_start(data, song_start, song_end):
    """Events start at +16 (after 16-byte pQES file header).

    The bytes after +16 that look like tables (Cn/Bn) are actually
    MIDI init events (PC, CC#7 volume, CC#10 pan), not separate tables.
    Returns (event_offset, {}) — no program map exists in the file.
    """
    return song_start + 16, {}
