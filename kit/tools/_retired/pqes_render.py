#!/usr/bin/env python3
"""Correct pQES song renderer with tempo-map support (2026-10-01 repair).

Fixes vs old renderer:
1. 0x9n = [note][dur][VLQ-delta], NO velocity byte. dur=0 notes DO sound
   (old dropped ~50% of notes -> the "glitch").
2. Beat = 120 VLQ (onset grid analysis), not 480. Old played ~2.2x fast.
3. Samples at 44100 Hz (SPU native), not 37800 Hz.
4. Real tempo from FF 51 metas (BPM = 60M/us). Song0 has no tempo meta,
   uses 120 BPM default (labeled assumption).
5. Channel->sample: spectral heuristic (dark samples for bass channels).

Remaining guesses: song0 120 BPM, root MIDI 60 for all samples,
dur=0 gate = legato, patch->sample mapping.

Usage: pqes_render.py <song#>   (0..3)
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
ROOT_MIDI = 60
DEFAULT_BPM = 120.0  # song0 has no tempo meta; assumption

CH_SAMPLE = {
    0: 5, 1: 6, 2: 8, 3: 2, 4: 7, 5: 4, 6: 1,
    7: 9, 8: 12, 9: 11, 10: 0, 11: 3, 12: 10,
}

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
    data = open(SEQ, 'rb').read()
    bounds = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]
    sstart, send = bounds[song]
    ev_start, bmap = find_event_start(data, sstart, send)
    print('event start: file+%d (hdr+%d)' % (ev_start, ev_start - sstart))
    events, tempo_map, err = parse_pqes(data[ev_start:send], DEFAULT_BPM)
    print('parse:', err, '| notes:', sum(1 for e in events if e[0] == 'on'))
    print('tempo map:', [(t, round(b, 1)) for t, b in tempo_map])
    print('b-table:', {k: 'bank%02X/patch%02X' % v for k, v in sorted(bmap.items())})

    samples = []
    for i in range(13):
        w = wave.open(os.path.join(SAMP_DIR, 'sample%02d.wav' % i))
        n = w.getnframes()
        samples.append(struct.unpack('<%dh' % n, w.readframes(n)))
        w.close()

    # tick -> seconds via tempo map
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
    total_tick = max(e[5] for e in notes) if notes else 0
    total_sec = tick_to_sec(total_tick)
    print('total: %d VLQ = %.1f sec' % (total_tick, total_sec))

    by_ch = defaultdict(list)
    for e in notes:
        by_ch[e[1]].append(e)
    for ch in by_ch:
        by_ch[ch].sort(key=lambda e: e[5])

    out_len = int((total_sec + 2.0) * SR)
    out = [0.0] * out_len

    for ch, nlist in by_ch.items():
        samp = samples[CH_SAMPLE.get(ch, 0)]
        for idx, e in enumerate(nlist):
            _, ch, note, dur, _, tick = e
            if dur > 0:
                gate_vlq = engine_dur_vlq(dur)
            else:
                gate_vlq = (nlist[idx + 1][5] - tick) if idx + 1 < len(nlist) else 2 * TPQ_VLQ
                gate_vlq = min(gate_vlq, 4 * TPQ_VLQ)
            start_sec = tick_to_sec(tick)
            # approximate gate in seconds using local tempo
            _, bpm_here = max((t, b) for t, b in tempo_map if t <= tick)
            gate_sec = gate_vlq / TPQ_VLQ * 60.0 / bpm_here
            ratio = 2 ** ((note - ROOT_MIDI) / 12.0)
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

    peak = max(abs(v) for v in out) or 1
    g = 30000 / peak
    pcm = struct.pack('<%dh' % out_len,
                      *[int(max(-32768, min(32767, v * g))) for v in out])
    os.makedirs(OUT_DIR, exist_ok=True)
    v1 = os.path.join(OUT_DIR, 'song%d.wav' % song)
    beff = os.path.join(OUT_DIR, 'song%d_besteffort.wav' % song)
    if os.path.exists(v1) and not os.path.exists(os.path.join(OUT_DIR, 'song%d_v1.wav' % song)):
        os.rename(v1, os.path.join(OUT_DIR, 'song%d_v1.wav' % song))
    outp = os.path.join(OUT_DIR, 'song%d_fixed.wav' % song)
    w = wave.open(outp, 'wb')
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(pcm); w.close()
    print('wrote', outp, '(best-effort kept at %s)' % beff if os.path.exists(beff) else 'wrote ' + outp)

if __name__ == '__main__':
    main()
