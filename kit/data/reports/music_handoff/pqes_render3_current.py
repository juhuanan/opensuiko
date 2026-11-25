#!/usr/bin/env python3
"""pQES song renderer v3 with CORRECTED instrument mapping (2026-10-01).

Fixes vs render2:
1. VAG index = (u16 at tone+22) - 1, NOT the program number.
   The game's tone-select path (0x801589c0) reads lhu 0x16(tone) and
   beqz-skips when 0 -> 1-based VAG number. The old "program N -> VAG N
   identity" came from misreading u16 at tone+20 (which is the program
   number, b20=prog, b21=0). Tone tables now parsed from the VA files'
   real layout: 512-byte per-program blocks at file+2080.
2. SPU-style sample looping: VAGs ending in flag 0x06 loop the
   [loop_start..end] region for the note's full gate time. (render2
   played looped samples once, truncating sustained notes.)

Tone tables: work/{ORCH,HNK1,HNK2}_tones.json (generated from VA).
Loop info: work/vag_loop_info.json.
"""
import struct, wave, sys, os, json
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pqes_parse2 import parse_pqes, find_event_start

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.normpath(os.path.join(HERE, '..', 'work', 'assets_zig'))
SEQ = os.path.join(ASSETS, 'music', 'SEQ.BIN')
OUT_DIR = os.path.join(ASSETS, 'music', 'songs')

TPQ_VLQ = 120
SR = 44100
DEFAULT_BPM = 120.0

BANKS = {0: 'ORCH', 1: 'ORCH', 2: 'HNK1', 3: 'HNK2'}
TONES = {}   # bank -> {prog: [(vag, center, shift, min, max), ...]}
LOOPS = {}   # bank -> [ {end, loop_start_samp, total_samp}, ... ]
for bname in ('ORCH', 'HNK1', 'HNK2'):
    tj = json.load(open(os.path.join(HERE, '..', 'work', '%s_tones.json' % bname)))
    TONES[bname] = {int(p): [(t['vag'], t['center'], t['shift'], t['min'], t['max'])
                             for t in tl] for p, tl in tj['tones'].items()}
lj = json.load(open(os.path.join(HERE, '..', 'work', 'vag_loop_info.json')))
for bname in ('ORCH', 'HNK1', 'HNK2'):
    key = bname.lower()
    LOOPS[bname] = lj[key]

CH_PROG = {
    0: {0:0, 1:1, 2:2, 3:3, 4:4, 7:6, 8:7, 9:8, 10:10, 11:12, 12:11},
    1: {0:0, 1:1, 2:2, 4:4, 5:5, 7:6, 8:7, 9:8, 10:10, 11:12},
    2: {0:0, 1:1, 2:2, 4:4, 5:5, 6:6, 7:7},
    3: {0:0, 1:1, 2:2, 5:5, 6:6, 7:7, 8:8, 9:9, 10:10},
}

def tone_for(bank, prog, note):
    for (vag, center, shift, mn, mx) in TONES[bank].get(prog, []):
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

def load_sample(bank, vag):
    p = os.path.join(ASSETS, 'audio', 'samples', bank.lower(), 'sample%02d.wav' % vag)
    w = wave.open(p); n = w.getnframes()
    d = struct.unpack('<%dh' % n, w.readframes(n)); w.close()
    return d

def main():
    song = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    bank = BANKS[song]
    print('song %d -> bank %s' % (song, bank))
    data = open(SEQ, 'rb').read()
    bounds = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]
    sstart, send = bounds[song]
    ev_start, _ = find_event_start(data, sstart, send)
    events, tempo_map, err = parse_pqes(data[ev_start:send], DEFAULT_BPM)
    print('parse:', err, '| notes:', sum(1 for e in events if e[0] == 'on'))

    notes_prog = []
    cur_prog = defaultdict(int)
    for e in events:
        if e[0] == 'pc':
            _, ch, prog, _, _ = e
            cur_prog[ch] = prog
        elif e[0] == 'on':
            _, ch, note, dur, _, tick = e
            notes_prog.append((ch, note, dur, tick, cur_prog[ch]))
    final_map = dict(sorted(cur_prog.items()))
    assert final_map == CH_PROG[song], 'MISMATCH! %s' % final_map

    # load only needed samples
    need = set()
    for (ch, note, dur, tick, prog) in notes_prog:
        t = tone_for(bank, prog, note)
        if t: need.add(t[0])
    samples = {v: load_sample(bank, v) for v in need}
    print('loaded %d samples' % len(samples))

    def tick_to_sec(tick):
        sec = 0.0
        for idx, (t0, bpm) in enumerate(tempo_map):
            t1 = tempo_map[idx + 1][0] if idx + 1 < len(tempo_map) else None
            if tick < t0: break
            seg_end = min(tick, t1) if t1 is not None else tick
            sec += (seg_end - t0) / TPQ_VLQ * 60.0 / bpm
            if t1 is None or tick < t1: break
        return sec

    total_tick = max(e[3] for e in notes_prog)
    total_sec = tick_to_sec(total_tick)
    print('total: %d VLQ = %.1f sec' % (total_tick, total_sec))

    by_ch = defaultdict(list)
    for e in notes_prog:
        by_ch[e[0]].append(e)
    for ch in by_ch:
        by_ch[ch].sort(key=lambda e: e[3])

    out_len = int((total_sec + 2.0) * SR)
    out = [0.0] * out_len
    silent = 0
    used = defaultdict(int)

    for ch, nlist in by_ch.items():
        for idx, e in enumerate(nlist):
            _, note, dur, tick, prog = e
            t = tone_for(bank, prog, note)
            if t is None:
                silent += 1; continue
            vag, root = t
            used[(prog, vag)] += 1
            samp = samples[vag]
            nsamp = len(samp)
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
            n_out = int(gate_sec * SR)
            if start + n_out > out_len:
                n_out = out_len - start
            if n_out <= 0: continue
            # looping
            li = LOOPS[bank][vag]
            looped = (li['end'] == 0x06)
            ls = li['loop_start_samp'] if li['loop_start_samp'] is not None else 0
            le = li['total_samp']  # loop end (exclusive) = total
            vel = 0.5
            # render with resampling + loop
            pos = 0.0
            for j in range(n_out):
                # map output frame to sample position with looping
                p = pos
                if looped and p >= le:
                    # wrap into [ls, le)
                    p = ls + ((p - ls) % (le - ls))
                elif not looped and p >= nsamp:
                    break
                i0 = int(p)
                if i0 + 1 < nsamp:
                    frac = p - i0
                    # for looped, i0+1 might exceed le; wrap it
                    i1 = i0 + 1
                    if looped and i1 >= le:
                        i1 = ls + (i1 - le)
                    v = samp[i0] * (1 - frac) + samp[i1] * frac
                else:
                    v = samp[i0] if i0 < nsamp else 0
                out[start + j] += v * vel
                pos += ratio

    print('silent notes:', silent)
    print('program->vag usage:', dict(sorted(used.items())))
    peak = max(abs(v) for v in out) or 1
    g = 30000 / peak
    pcm = struct.pack('<%dh' % out_len,
                      *[int(max(-32768, min(32767, v * g))) for v in out])
    os.makedirs(OUT_DIR, exist_ok=True)
    outp = os.path.join(OUT_DIR, 'song%d_v3.wav' % song)
    w = wave.open(outp, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm); w.close()
    print('wrote', outp)

if __name__ == '__main__':
    main()
