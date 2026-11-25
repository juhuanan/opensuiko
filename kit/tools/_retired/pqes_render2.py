#!/usr/bin/env python3
"""pQES song renderer with TRUE instrument mapping (2026-10-01).

Instrument path (all verified from disc + code):
  SEQ 0xCn program-change -> VA program -> tone (by note min/max)
  -> VAG sample (tone bytes 20-21) -> pitch from center+shift/128.

Key findings:
- ORCH.VA (VABp v6): 12 toned programs, tones packed per-program
  (16 slots x 32B), program N -> VAG N (identity), except prog 9 = empty.
- Tone bytes: 4=center (root MIDI), 5=shift (fractional center, 1/128
  semitone; true root = center + shift/128 -- shifts of 120-124 land
  almost exactly on the next semitone, not coincidence),
  6=min note, 7=max note, 20-21=VAG index (u16le).
- Channel->program is static 1:1 per song from init 0xCn events
  (no mid-stream program changes). All 4 songs use ORCH.
- Confirmed in MAIN.EXE: tone-select loop reads min/max (bytes 6/7)
  and VAG (bytes 20-21); per-program 16-slot tone table layout.
- Song 3 ch9 -> program 9 (no tones) renders silent, as the game does.

Usage: pqes_render2.py <song#>   (0..3)
"""
import struct, wave, sys, os
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pqes_parse2 import parse_pqes, find_event_start

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, '..', 'work', 'assets_zig'))
SEQ = os.path.join(ASSETS, 'music', 'SEQ.BIN')
SAMP_DIR = os.path.join(ASSETS, 'audio', 'samples', 'orch')
OUT_DIR = os.path.join(ASSETS, 'music', 'songs')

TPQ_VLQ = 120
SR = 44100
DEFAULT_BPM = 120.0  # song0 has no tempo meta; assumption

# (vag, center, shift, min_note, max_note) per bank, from VA tone tables.
# ORCH: songs 0,1 (bank 7). HNK1: song 2 (bank 10). HNK2: song 3 (bank 8).
TONES_ORCH = {
     0: [(0, 81, 15, 0, 127)],
     1: [(1, 79, 25, 0, 127)],
     2: [(2, 68, 120, 0, 127)],
     3: [(3, 56, 7, 0, 127)],
     4: [(4, 70, 120, 0, 127)],
     5: [(5, 71, 40, 0, 127)],
     6: [(6, 46, 0, 46, 127), (6, 46, 0, 0, 45)],
     7: [(7, 51, 0, 49, 49), (7, 38, 0, 38, 38), (7, 70, 0, 51, 51)],
     8: [(8, 70, 60, 0, 127)],
     9: [],  # empty program -> silent
    10: [(10, 73, 123, 55, 127), (10, 53, 124, 0, 54)],
    11: [(11, 67, 0, 0, 127)],
    12: [(12, 53, 124, 0, 127)],
}
TONES_HNK1 = {
     0: [(0, 58, 84, 0, 61), (0, 68, 60, 50, 73), (0, 77, 24, 62, 127)],
     1: [(1, 57, 0, 0, 127)],
     2: [(2, 62, 0, 0, 127)],
     4: [(4, 67, 0, 0, 127)],
     5: [(5, 64, 0, 64, 64), (5, 65, 0, 65, 65), (5, 66, 0, 66, 66), (5, 75, 0, 67, 127)],
     6: [(6, 57, 18, 0, 127)],
     7: [(7, 67, 8, 0, 127)],
     8: [(8, 60, 0, 0, 127)],
     9: [(9, 60, 0, 0, 127)],
    10: [(10, 60, 0, 0, 127)],
    11: [(11, 60, 0, 48, 48), (11, 64, 0, 60, 60), (11, 80, 0, 72, 72)],
}
TONES_HNK2 = {
     0: [(0, 58, 84, 0, 61), (0, 68, 60, 50, 73), (0, 77, 24, 62, 104),
         (0, 120, 0, 105, 105), (0, 106, 0, 106, 106), (0, 107, 0, 107, 107)],
     1: [(1, 67, 0, 0, 127)],
     2: [(2, 60, 0, 0, 127)],
     5: [(5, 67, 0, 0, 127)],
     6: [(6, 67, 0, 0, 127)],
     7: [(7, 60, 0, 60, 60), (7, 63, 0, 62, 64), (7, 70, 0, 65, 71), (7, 75, 0, 72, 127)],
     8: [(8, 57, 0, 0, 127)],
     9: [(9, 67, 0, 0, 127)],
    10: [(10, 57, 12, 0, 127)],
    11: [(11, 60, 0, 48, 48), (11, 64, 0, 60, 60), (11, 80, 0, 72, 72)],
}
BANKS = {0: (TONES_ORCH, 'orch'), 1: (TONES_ORCH, 'orch'),
         2: (TONES_HNK1, 'hnk1'), 3: (TONES_HNK2, 'hnk2')}
TONES = TONES_ORCH  # default; overridden per song in main()

# channel -> program per song, from init 0xCn events (static, no changes)
CH_PROG = {
    0: {0:0, 1:1, 2:2, 3:3, 4:4, 7:6, 8:7, 9:8, 10:10, 11:12, 12:11},
    1: {0:0, 1:1, 2:2, 4:4, 5:5, 7:6, 8:7, 9:8, 10:10, 11:12},
    2: {0:0, 1:1, 2:2, 4:4, 5:5, 6:6, 7:7},
    3: {0:0, 1:1, 2:2, 5:5, 6:6, 7:7, 8:8, 9:9, 10:10},
}

def tone_for(prog, note):
    for (vag, center, shift, mn, mx) in TONES.get(prog, []):
        if mn <= note <= mx:
            return vag, center + shift / 128.0
    return None

M = 0x81020409
def engine_dur_vlq(dur):
    x = dur * 127
    prod = x * M
    hi = (prod >> 32) & 0xFFFFFFFF
    lo = prod & 0xFFFFFFFF
    q = (hi + lo) >> 6
    lo_s = lo if lo < 0x80000000 else lo - 0x100000000
    return (q - (lo_s >> 31)) / 10.0


def main():
    song = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    tones, bank_name = BANKS[song]
    global TONES
    TONES = tones
    print('song %d -> bank %s' % (song, bank_name))
    data = open(SEQ, 'rb').read()
    bounds = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]
    sstart, send = bounds[song]
    ev_start, bmap = find_event_start(data, sstart, send)
    print('event start: file+%d (hdr+%d)' % (ev_start, ev_start - sstart))
    events, tempo_map, err = parse_pqes(data[ev_start:send], DEFAULT_BPM)
    print('parse:', err, '| notes:', sum(1 for e in events if e[0] == 'on'))
    print('tempo map:', [(t, round(b, 1)) for t, b in tempo_map])

    notes = []
    cur_prog = defaultdict(int)  # default program 0 (BSS-cleared voice state)
    for e in events:
        if e[0] == 'pc':
            _, ch, prog, _, _ = e
            cur_prog[ch] = prog
        elif e[0] == 'on':
            _, ch, note, dur, _, tick = e
            notes.append((ch, note, dur, tick, cur_prog[ch]))
    # verify against static map (all PCs are at init; cur_prog should match)
    final_map = dict(sorted(cur_prog.items()))
    print('final PC map:', final_map)
    assert final_map == CH_PROG[song], 'MISMATCH!'

    samples = []
    samp_dir = os.path.join(ASSETS, 'audio', 'samples', bank_name)
    # find max vag index needed
    max_vag = max(v for tl in tones.values() for (v, _, _, _, _) in tl)
    for i in range(max_vag + 1):
        w = wave.open(os.path.join(samp_dir, 'sample%02d.wav' % i))
        n = w.getnframes()
        samples.append(struct.unpack('<%dh' % n, w.readframes(n)))
        w.close()
    print('loaded %d samples from %s' % (len(samples), samp_dir))

    def tick_to_sec(tick):
        sec = 0.0
        for idx, (t0, bpm) in enumerate(tempo_map):
            t1 = tempo_map[idx + 1][0] if idx + 1 < len(tempo_map) else None
            if tick < t0:
                break
            seg_end = min(tick, t1) if t1 is not None else tick
            sec += (seg_end - t0) / TPQ_VLQ * 60.0 / bpm
            if t1 is None or tick < t1:
                break
        return sec

    notes = [e for e in events if e[0] == 'on']
    # attach program via event-order tracking (handles pre-PC notes)
    notes_prog = []
    cur_prog = defaultdict(int)
    for e in events:
        if e[0] == 'pc':
            _, ch, prog, _, _ = e
            cur_prog[ch] = prog
        elif e[0] == 'on':
            _, ch, note, dur, _, tick = e
            notes_prog.append((ch, note, dur, tick, cur_prog[ch]))
    notes = notes_prog
    total_tick = max(e[3] for e in notes) if notes else 0
    total_sec = tick_to_sec(total_tick)
    print('total: %d VLQ = %.1f sec' % (total_tick, total_sec))

    by_ch = defaultdict(list)
    for e in notes:
        # e = (ch, note, dur, tick, prog)
        by_ch[e[0]].append(e)
    for ch in by_ch:
        by_ch[ch].sort(key=lambda e: e[3])

    out_len = int((total_sec + 2.0) * SR)
    out = [0.0] * out_len
    silent_notes = 0
    used = defaultdict(int)

    for ch, nlist in by_ch.items():
        for idx, e in enumerate(nlist):
            _, note, dur, tick, prog = e
            t = tone_for(prog, note)
            if t is None:
                silent_notes += 1
                continue
            vag, root = t
            used[(prog, vag)] += 1
            samp = samples[vag]
            if dur > 0:
                gate_vlq = engine_dur_vlq(dur)
            else:
                gate_vlq = (nlist[idx + 1][3] - tick) if idx + 1 < len(nlist) else 2 * TPQ_VLQ
                gate_vlq = min(gate_vlq, 4 * TPQ_VLQ)
            start_sec = tick_to_sec(tick)
            _, bpm_here = max((t0, b) for t0, b in tempo_map if t0 <= tick)
            gate_sec = gate_vlq / TPQ_VLQ * 60.0 / bpm_here
            ratio = 2 ** ((note - root) / 12.0)
            start = int(start_sec * SR)
            n_out = min(int(gate_sec * SR), int(len(samp) / ratio))
            if start + n_out > out_len:
                n_out = out_len - start
            if n_out <= 0:
                continue
            vel = 0.5
            for j in range(n_out):
                pos = j * ratio
                i0 = int(pos)
                if i0 + 1 < len(samp):
                    v = samp[i0] * (1 - (pos - i0)) + samp[i0 + 1] * (pos - i0)
                else:
                    v = samp[i0]
                out[start + j] += v * vel

    print('silent notes (no tone match):', silent_notes)
    print('program->vag usage:', dict(sorted(used.items())))
    peak = max(abs(v) for v in out) or 1
    g = 30000 / peak
    pcm = struct.pack('<%dh' % out_len,
                      *[int(max(-32768, min(32767, v * g))) for v in out])
    os.makedirs(OUT_DIR, exist_ok=True)
    # back up previous fixed render
    old = os.path.join(OUT_DIR, 'song%d_fixed.wav' % song)
    bak = os.path.join(OUT_DIR, 'song%d_fixed_v1.wav' % song)
    if os.path.exists(old) and not os.path.exists(bak):
        os.rename(old, bak)
        print('backed up old render ->', bak)
    outp = os.path.join(OUT_DIR, 'song%d_fixed.wav' % song)
    w = wave.open(outp, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm); w.close()
    print('wrote', outp)

if __name__ == '__main__':
    main()
