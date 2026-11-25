#!/usr/bin/env python3
"""render_seq.py -- render Suikoden's four pQES songs from the corrected format.

Replaces pqes_render{,2,3}.py. Built on the format verified 2026-10-03
(see kit/docs/music_format_solved.md):

    SONGS  = Sony SEQ score (15-byte header, delta-BEFORE events)
    BANKS  = Sony VAB  (pBAV header; .VB = raw SPU ADPCM)
    SAMPLES= VAB size table gives exact .VB byte extents (no flag scanning)

Pipeline:
    15-byte header -> delta-before events -> program/tone -> VAG size table
      -> SPU ADPCM decode -> pitch/ADSR/pan/volume -> mix

Deliberate design choices, and why:

  * Stored sample boundaries come from the VAB size table. Playback stops or
    loops at the first end flag within each stored sample.

  * Tempo comes from the header, per song. The old DEFAULT_BPM=120 guess was
    applied to all four; only song 0 is actually 120.

  * Tempo metas are 5 bytes ("FF 51" + 3-byte us/qn, NO length byte), and
    repeats elide the FF. Getting either wrong desyncs the whole track.

  * Notes are paired on/off to get real durations. Velocity is NOT a duration.

Usage:
    python3 render_seq.py --bank HNK1  # explicit slot-2 context for songs 2/3
    python3 render_seq.py 0          # one song
    python3 render_seq.py --info     # parse and report; write no files
    python3 render_seq.py 0 --loop-passes 2  # bounded native loop playback
"""

import argparse
from fractions import Fraction
import os
import struct
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))       # kit/tools/seq
TOOLS = os.path.dirname(HERE)                            # kit/tools
KIT = os.path.dirname(TOOLS)                             # kit
OUT_DIR = os.path.join(KIT, 'work', 'candidates', 'seq')
sys.path.insert(0, TOOLS)
from disc import extract as disc_extract  # noqa: E402

from spu_fir import FIR          # PS1 SPU Gaussian interpolation taps

SR = 44100
SONGS = 4
# Physical track boundaries: each begins with the pQES magic.
TRACKS = [(0, 15812), (15812, 34352), (34352, 44438), (44438, 71168)]
BANKS = {0: 'ORCH', 1: 'ORCH'}  # Slot 2 depends on the bank load request.
START_LEVELS = (127,100,88,88) # MAIN800C6174, cue ids1..4
BANK_SOURCES = {
    'ORCH': ((18799,8736),(18804,108784)),
    'HNK1': ((80954,8224),(80959,101536)),
    'HNK2': ((81009,7712),(81013,111040)),
}

# PS1 SPU ADPCM filter coefficients.
FILTERS = ([0, 0], [60, 0], [115, -52], [98, -55], [122, -60])


# --------------------------------------------------------------------- SEQ
def read_vlq(buf, i):
    v = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not (b & 0x80):
            break
    return v, i


def _tempo_bpm(mpqn, initial=False):
    """MAIN header rounds ties down; tempo events truncate the quotient."""
    if mpqn <= 0:
        raise ValueError('zero/nonpositive SEQ tempo: the driver has no fallback')
    quotient, remainder = divmod(60_000_000, mpqn)
    return float(quotient + int(initial and remainder > (mpqn >> 1)))


def parse_track(blob, loop_passes=None):
    """Parse one pQES track. Returns (notes, tempos, ppqn, bpm, stats).

    notes  : list of (ch, note, vel, start_tick, end_tick)
    tempos : list of (tick, bpm)
    loop_passes=None walks physical bytes; a positive bound follows native rewinds.
    """
    if loop_passes is not None and (not isinstance(loop_passes,int) or loop_passes<1):
        raise ValueError('loop passes must be a positive integer')
    assert blob[:4] == b'pQES', 'track must start with pQES'
    ppqn = struct.unpack_from('>H', blob, 0x08)[0]
    tempo_us = int.from_bytes(blob[0x0A:0x0D], 'big')
    bpm0 = _tempo_bpm(tempo_us, initial=True)

    ev = blob[15:]                 # <-- 15, not 16
    tempos = [(0, bpm0)]
    notes = []
    controls = []
    bends = []
    voice_events = []
    event_ticks = []
    pending = {}
    progs = {}                     # ch -> current program
    note_prog = {}                 # (ch,note) -> program at note-on

    i = 0
    tick = 0
    n = len(ev)
    last_status = None
    last_tempo = False
    unmatched_off = 0
    loop_marker=loop_armed=False;loop_count=0;loop_cursor=None
    bookmark_after_delta=False;read_delta=True;passes_left=loop_passes
    rewinds=0;loop_bounded=False

    while i < n:
        if read_delta:
            delta, i = read_vlq(ev, i)
            tick += delta
        else:read_delta=True
        if bookmark_after_delta:
            loop_cursor=i;bookmark_after_delta=False
        if i >= n:
            break
        b = ev[i]
        event_ticks.append(tick)

        # --- meta ---
        if b == 0xFF:
            if i + 1 >= n:
                break
            typ = ev[i + 1]
            if typ == 0x51:
                if i + 4 >= n:
                    break
                us = (ev[i + 2] << 16) | (ev[i + 3] << 8) | ev[i + 4]
                tempos.append((tick, _tempo_bpm(us)))
                i += 5
                last_tempo = True
                continue
            if typ == 0x2F:
                break
            if i + 2 < n:
                i += 3 + ev[i + 2]
                continue
            break

        # --- tempo with FF elided ---
        if last_tempo and b == 0x51:
            if i + 3 >= n:
                break
            us = (ev[i + 1] << 16) | (ev[i + 2] << 8) | ev[i + 3]
            tempos.append((tick, _tempo_bpm(us)))
            i += 4
            continue
        last_tempo = False

        # --- channel voice ---
        if b >= 0x80:
            status = b
            last_status = b
            i += 1
        else:
            if last_status is None:
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
            if nib == 0x8 or vel == 0:
                prv = pending.pop((ch, note), None)
                if prv is not None:
                    st, pv, pr = prv
                    notes.append((ch, note, pv, st, tick, pr))
                else:
                    unmatched_off += 1
            else:
                prv = pending.pop((ch, note), None)
                if prv is not None:
                    st, pv, pr = prv
                    notes.append((ch, note, pv, st, tick, pr))
                pending[(ch, note)] = (tick, vel, progs.get(ch, ch))
        elif nib in (0xB, 0xE):
            if i + 1 >= n:
                raise ValueError('truncated controller/pitch-bend event')
            if nib == 0xB:
                controls.append((tick, ch, ev[i], ev[i+1]))
            else:
                bends.append((tick, ch, ev[i], ev[i+1]))
            i += 2
            if nib==0xB and loop_passes is not None:
                cc,value=ev[i-2:i]
                if cc==99 and value==20:
                    loop_marker=True;bookmark_after_delta=True;passes_left=loop_passes
                elif cc==6 and loop_marker and not loop_armed:
                    loop_count=value;loop_armed=True
                elif cc==99 and value==30:
                    if 0<loop_count<127:loop_count-=1
                    if not loop_count:loop_armed=False
                    else:
                        outgoing,i=read_vlq(ev,i)
                        if loop_cursor is None:raise ValueError('loop end has no saved cursor')
                        if passes_left<=1:
                            loop_bounded=True;break
                        passes_left-=1;rewinds+=1
                        # Native finite rewind keeps the outgoing delay; infinite rewind forces0.
                        if loop_count<127:tick+=outgoing
                        i=loop_cursor;read_delta=False
        elif nib in (0xC, 0xD):
            progs[ch] = ev[i]
            i += 1
        else:
            break

    # close anything still open at the final tick
    for (ch, note), (st, pv, pr) in pending.items():
        notes.append((ch, note, pv, st, tick, pr))

    notes.sort(key=lambda x: x[3])
    stats = {'event_ticks':event_ticks, 'controls': controls, 'bends': bends, 'voice_events': voice_events, 'notes': len(notes), 'unmatched_off': unmatched_off,
             'last_tick': tick, 'tempo_changes': len(tempos),
             'loop_rewinds':rewinds,'loop_bounded':loop_bounded}
    return notes, tempos, ppqn, bpm0, stats


def tick_to_sec_factory(tempos, ppqn):
    """Return a tick -> seconds function honouring tempo changes."""
    def f(tick):
        sec = 0.0
        for idx, (t0, bpm) in enumerate(tempos):
            if tick <= t0:
                break
            t1 = tempos[idx + 1][0] if idx + 1 < len(tempos) else None
            end = tick if t1 is None else min(tick, t1)
            sec += (end - t0) / ppqn * 60.0 / bpm
            if t1 is None or tick <= t1:
                break
        return sec
    return f


def clock_parameters(ppqn, bpm, rate=60):
    """Native signed halfwords: slow countdown or rounded delta-tenths step."""
    product=int(ppqn)*int(bpm)
    if product<=0 or rate<=0:raise ValueError('nonpositive sequence clock')
    if product*10<60*rate:
        step=600*rate//product;slow=step
    else:
        step,remainder=divmod(product*10,60*rate)
        step+=int(remainder>30*rate);slow=-1
    if step>32767:raise ValueError('sequence clock exceeds signed timing halfword')
    return slow,step


def schedule_ticks(event_ticks, tempos, ppqn, rate=60):
    """Map parsed event ticks to audio-update indices, retaining native remainder."""
    if not event_ticks:return {}
    slow,step=clock_parameters(ppqn,tempos[0][1],rate)
    tempo=1;index=0;update=0;pending=event_ticks[0]*10;times={}
    while index<len(event_ticks):
        if pending>step:
            if slow>0:slow-=1
            elif slow==0:slow=step;pending-=1
            else:pending-=step
        else:
            budget=pending
            while index<len(event_ticks):
                tick=event_ticks[index]
                if tick in times and times[tick]!=update:
                    raise ValueError('same logical tick spans audio updates')
                times[tick]=update
                while tempo<len(tempos) and tempos[tempo][0]<=tick:
                    slow,step=clock_parameters(ppqn,tempos[tempo][1],rate);tempo+=1
                index+=1
                if index==len(event_ticks):break
                pending=(event_ticks[index]-tick)*10
                if pending<0:raise ValueError('sequence ticks move backwards')
                if pending==0:continue
                budget+=pending
                if budget>=step:
                    pending=budget-step;break
        update+=1
    return times


# --------------------------------------------------------------------- VAB
def parse_vab(va_path, vb_path):
    """Read a VA/VB pair; return decoded samples, tone programs and loops."""
    with open(va_path,'rb') as f:va=f.read()
    with open(vb_path,'rb') as f:vb=f.read()
    return parse_vab_bytes(va,vb)


def parse_vab_bytes(va,vb):
    if va[:4]!=b'pBAV':raise ValueError('not a VAB')
    ps = struct.unpack_from('<H', va, 0x12)[0]
    ts = struct.unpack_from('<H', va, 0x14)[0]
    vs = struct.unpack_from('<H', va, 0x16)[0]

    size_off=0x20+128*16+ps*512
    entries=struct.unpack_from('<'+str(vs+1)+'H',va,size_off)
    sizes=[n*8 for n in entries[1:]]
    if entries[0]!=0 or sum(sizes)!=len(vb) or any(n%16 for n in sizes):
        raise ValueError('VAB sample-size table does not consume the complete ADPCM body')

    # --- decode each sample ---
    samples = []
    loops = []
    off = 0
    for sz in sizes:
        data = vb[off:off + sz]
        end = next((i + 16 for i in range(0, sz, 16) if data[i + 1] & 1), sz)
        pcm, loop = decode_adpcm(data[:end])
        samples.append(pcm)
        loops.append(loop)
        off += sz

    # Read the same VA being decoded; curated tables cannot override bank bytes.
    from vab_tones import parse_programs, find_tone_table
    progs, _ = parse_programs(va, ps)
    _, _, programs = find_tone_table(va, ts, ps, vs, progs)
    for program,tones in enumerate(programs):
        for tone in tones:
            tone.update(bank_vol=va[0x18],program_vol=progs[program]['mvol'],
                        program_pan=progs[program]['mpan'])
    return samples, programs, loops


def decode_adpcm(data):
    """Decode 16-byte SPU ADPCM blocks, preserving predictor history.

    Byte 0 holds shift/filter, byte 1 loop flags, and bytes 2..15 hold
    28 samples, low nibble first. Mednafen RunDecoder reads a little-endian
    16-bit word before shifting it left 12; its first extraction is therefore
    the first byte's LOW nibble. Return PCM and the existing loop metadata.
    """
    out = []
    m1 = m2 = 0
    loop_start = loop_end = None
    loop_repeats = False
    n_blocks = len(data) // 16
    for b in range(n_blocks):
        blk = data[b * 16:b * 16 + 16]
        shift = blk[0] & 0x0F
        weight = (blk[0] >> 4) & 0x0F
        flags = blk[1]
        if flags & 0x04:                      # loop start
            loop_start = len(out)
        if flags & 0x01:                      # loop end
            loop_end = len(out)
            loop_repeats = bool(flags & 0x02)
        if weight > 4:
            weight = 0
        illegal_shift = shift > 12
        if illegal_shift:
            shift = 8
        w1, w2 = FILTERS[weight]
        for i in range(2, 16):                # 14 data bytes -> 28 samples
            byte = blk[i]
            for nib in (byte & 0x0F, byte >> 4):
                if illegal_shift:
                    nib &= 8
                # Hardware: sample = (int16)((nib << 12) & 0xF000) >> shift.
                # The mask+int16 cast matters: it keeps the value in 16 bits
                # BEFORE the shift, so a large shift discards bits instead of
                # scaling them. Doing this on an unbounded Python int is not
                # equivalent and was a real bug.
                s = ((nib << 12) & 0xF000)
                if s & 0x8000:
                    s -= 0x10000
                s >>= shift
                s += (m1 * w1) >> 6
                s += (m2 * w2) >> 6
                if s > 32767:
                    s = 32767
                elif s < -32768:
                    s = -32768
                out.append(s)
                m2 = m1
                m1 = s
    return out, (loop_start, loop_end, loop_repeats)


# ------------------------------------------------------------- SPU envelope
def spu_adsr(adsr1, adsr2, sr=SR):
    """Build a per-sample gain envelope from PS1 SPU ADSR registers.

    adsr1 (16-bit): bit15 = attack mode (0=linear,1=exponential)
                    bits14-10 = attack shift, bits9-8 = attack step
                    bits7-4   = decay shift,  bits3-0 = sustain level
    adsr2 (16-bit): bit15-13 = sustain mode/direction, bits12-8 = sustain shift
                    bits7-6   = sustain step, bits5-0 = release shift

    Returns (attack_env, sustain_level, release_shift) in a simplified form:
    we render attack as a ramp to peak and release as an exponential decay,
    which is what dominates the perceived character.
    """
    a_mode = (adsr1 >> 15) & 1
    a_shift = (adsr1 >> 10) & 0x1F
    a_step = (adsr1 >> 8) & 0x03
    d_shift = (adsr1 >> 4) & 0x0F
    s_level = adsr1 & 0x0F
    r_shift = adsr2 & 0x1F

    def rate(shift, step):
        # SPU: step * 2^-shift per sample, as a fraction of full scale
        return (step + 1) / float(1 << min(shift + 1, 30))

    a_rate = rate(a_shift, a_step)
    d_rate = rate(d_shift, 0)
    s_frac = (s_level + 1) / 16.0
    r_rate = rate(r_shift, 0)
    return {'a_rate': a_rate, 'a_exp': bool(a_mode), 'd_rate': d_rate,
            's_frac': s_frac, 'r_rate': r_rate, 'r_exp': True}


def find_loop_period(s, sr=SR):
    """Find a sustain-loop period for a sample by autocorrelation.

    These .VB files carry no usable SPU loop-flag data (verified: byte 15 of a
    frame matches a pure-ADPCM distribution, so scanning for flags is
    meaningless). But every sustained tone is periodic, so we can recover the
    waveform period directly: pick the lag in the sample's middle region with
    the highest normalised autocorrelation. Measured correlations on ORCH are
    0.96-0.999 at musically sensible periods (0.7-6.1 ms), i.e. the real
    waveform periods rather than an arbitrary splice.

    Returns the period in samples, or None if the sample is not periodic
    enough to loop safely (then callers should treat it as a one-shot).
    """
    n = len(s)
    if n < 1200:
        return None
    lo = int(n * 0.25)
    best_c, best_lag = 0.0, 0
    for lag in range(30, 1200):
        b = lo + lag
        if b + lag > n:
            break
        num = 0.0
        d1 = 0.0
        d2 = 0.0
        for i in range(0, lag, 4):
            x = s[lo + i]
            y = s[b + i]
            num += x * y
            d1 += x * x
            d2 += y * y
        if d1 <= 0 or d2 <= 0:
            continue
        c = num / ((d1 ** 0.5) * (d2 ** 0.5))
        if c > best_c:
            best_c, best_lag = c, lag
    if best_c < 0.75:
        return None
    return best_lag


# ------------------------------------------------------------------ render
def pitch_register(note, center, shift, adjustment=None):
    """MAIN80155C88/80155D44: table lookup, signed quotient and16-bit result."""
    import maindec as M
    fraction=shift>>3 if adjustment is None else ((adjustment&65535)+shift)>>3
    carry=int(adjustment is not None and fraction>=16)
    fraction=min(fraction,15) if adjustment is None else fraction-16*carry
    n=((note+60-center+carry+32768)&65535)-32768
    octave=(abs(n)//12)*(-1 if n<0 else 1)
    index=16*(n-12*octave)+fraction
    # Negative remainders read before the nominal table, just as the native code.
    off=0x80178424-M.MBASE+2*index
    body=M.body()
    if not 0<=off<=len(body)-2:raise ValueError('pitch lookup outside MAIN image')
    value=struct.unpack_from('<H',body,off)[0]
    amount=octave-5
    value=(value<<(amount&31)) if amount>0 else value>>((-amount)&31)
    return value&65535


def bend_register(note, tone, bend):
    delta=bend-64
    if delta>0:
        whole,fraction=divmod(delta*tone['pbmax'],63)
        note+=whole;fine=2*fraction
    elif delta<0:
        value=delta*tone['pbmin'];whole=-(abs(value)//64)
        note+=whole-1;fine=2*(value-64*whole)+127
    else:fine=0
    return pitch_register(note,tone['center'],tone['shift'],fine)


def render_events(events, samples, programs, loops, t2s, end_tick, sequence=(127,127), reverb=False):
    """Stage ordered score events after each nominal60-update sampler/flush."""
    from spu import Voice, Envelope, allocate_voice, voice_levels, poll_voice_status, reset_voice_history
    from reverb import Reverb,disc_preset
    network=Reverb(*disc_preset()) if reverb else None
    depth=40*32767//127 # MAIN800C57CC startup depth, same on both sides
    left=[0.0]*(int(t2s(end_tick)*SR)+3*SR//5);right=[0.0]*len(left)
    states=[dict(status=0,level=0,priority=0,age=0,voice=None,program=-1,note=-1,tone=None,
                 dirty=0,command=None,start=None,pitch=0,gain=(0,0),adsr=(0,0),send=False,pending_send=None) for _ in range(22)]
    history=[0]*16;history_index=0;next_update=0
    selected=list(range(16));volumes=[127]*16;pans=[64]*16
    last_velocity=127;program_gain=0;program_pan=64;tone_gain=0;tone_pan=64
    bank_gain=0;cursor=0;played=silent=0
    def flush():
        nonlocal history_index
        levels=[state['voice'].env.level if state['voice'] is not None and state['voice'].active else 0
                for state in states]
        history_index=poll_voice_status(states,history,history_index,levels)
        for state in states:
            voice=state['voice'];dirty=state['dirty'];command=state['command']
            if state['pending_send'] is not None:
                state['send']=state['pending_send'];state['pending_send']=None
            if command is True:
                voice=Voice(*state['start'],min(state['pitch'],0x3FFF)/4096.0,*state['adsr'])
                voice.env.key_on();state['voice']=voice
            elif dirty&16 and voice is not None and voice.active:
                configured=Envelope(*state['adsr'])
                for field in ('attack_rate','decay_rate','sustain_rate','release_rate','sustain_level',
                              'attack_exp','sustain_exp','sustain_dec','release_exp'):
                    setattr(voice.env,field,getattr(configured,field))
            if voice is not None and voice.active:
                if dirty&1 or command is True:
                    voice.vol_l,voice.vol_r=(value/16384.0 for value in state['gain'])
                if dirty&4 or command is True:voice.step=min(state['pitch'],0x3FFF)/4096.0
                if command is False:
                    voice.env.key_off()
                    if voice.env.release_rate==124 and voice.env.level:
                        raise ValueError('cannot finish a non-decaying release envelope')
            state['dirty']=0;state['command']=None
    def render_to(stop):
        nonlocal cursor
        if stop==cursor:return
        send=([0]*(stop-cursor),[0]*(stop-cursor)) if network else None
        for state in states:
            voice=state['voice']
            if voice is not None and voice.active:
                if network and state['send']:
                    voice.render(FIR,left,right,cursor,stop-cursor,SR,send=send)
                else:voice.render(FIR,left,right,cursor,stop-cursor,SR)
        if network:
            for k,(l,r) in enumerate(zip(*send)):
                wet=network.process(l,r)
                left[cursor+k]+=(wet[0]*depth)>>15
                right[cursor+k]+=(wet[1]*depth)>>15
        cursor=stop
    def advance(stop):
        nonlocal next_update
        if stop<cursor:raise ValueError('score events are out of order')
        for output in (left,right):output.extend([0.0]*max(0,stop-len(output)))
        while next_update*SR//60<=stop:
            render_to(next_update*SR//60)
            flush();next_update+=1
        render_to(stop)
    def key_off(program,note):
        for state in states:
            if state['program']==program and state['note']==note and state['status']:
                state['command']=False;state['status']=0
    for tick,kind,ch,a,b in events:
        advance(int(t2s(tick)*SR))
        program=selected[ch]
        if kind==0xC:
            selected[ch]=a
        elif kind in (0x8,0x9):
            if kind==0x8 or b==0:
                key_off(program,a)
                continue
            level=b*volumes[ch]//127
            tones=programs[program] if program<len(programs) else []
            if tones:
                bank_gain=tones[0]['bank_vol'];program_gain=tones[0]['program_vol']
                program_pan=tones[0]['program_pan']
            if level==0:
                key_off(program,a)
            else:
                matched=False
                for tone in tones:
                    if not tone['min']<=a<=tone['max']:continue
                    matched=True;tone_gain=tone['vol'];tone_pan=tone['pan']
                    slot=allocate_voice(states,tone['prior'])
                    if slot>=len(states):silent+=1;continue
                    vag=tone['vag']
                    if not 0<=vag<len(samples) or not samples[vag]:
                        raise ValueError('selected tone has no decoded sample')
                    ls,le,repeat=loops[vag]
                    if ls is None or le is None or not repeat or le<ls:ls,le,repeat=0,0,False
                    pitch=pitch_register(a,tone['center'],tone['shift'])
                    l,r=voice_levels((bank_gain,level,program_gain,tone_gain),
                                     (tone_pan,program_pan,pans[ch]),sequence=sequence)
                    reset_voice_history(history,slot)
                    states[slot].update(status=1,level=32767,program=program,note=a,tone=tone,
                                        start=(samples[vag],ls,le,repeat),pitch=pitch,gain=(l,r),
                                        adsr=(tone['adsr1'],tone['adsr2']),dirty=31,command=True,
                                        pending_send=bool(tone['mode']&4))
                    played+=1
                if not matched:silent+=1
            last_velocity=b
        elif kind==0xB:
            if a in (7,10):
                if a==7:volumes[ch]=b
                else:pans[ch]=b
                level=last_velocity*volumes[ch]//127
                l,r=voice_levels((bank_gain,level,program_gain,tone_gain),
                                 (tone_pan,program_pan,pans[ch]),sequence=sequence,update=True)
                for state in states:
                    if state['program']==program:
                        state['gain']=(l,r);state['dirty']|=3
            elif a==91:depth=b*32767//127
            elif a not in (6,99):
                raise ValueError('unsupported preview controller: '+str(a))
            # NRPN rewinds are resolved by parse_track before voice playback.
        elif kind==0xE:
            for state in states:
                if state['program']==program:
                    state['pitch']=bend_register(state['note'],state['tone'],b);state['dirty']|=4
        else:raise ValueError('unsupported preview event: '+str(kind))
    advance(int(t2s(end_tick)*SR))
    for state in states:
        # The artificial preview stop includes silent hardware voices freed by polling.
        if state['status'] or (state['voice'] is not None and state['voice'].active):
            state['command']=False;state['status']=0
    while any(state['command'] is not None or
              (state['voice'] is not None and state['voice'].active) for state in states):
        advance(cursor+max(1,SR//2))
    if network:
        # shortcut: finite preview adds4s of wet continuation; a live player keeps running.
        advance(cursor+4*SR)
    return left,right,played,silent,len(left)/SR


def render_song(song, seq_data, bank_cache, out_dir, write=True, bank=None, loop_passes=1, reverb=False):
    s, e = TRACKS[song]
    bname = BANKS.get(song) if song < 2 else bank
    if bname is None:
        raise ValueError('sequence uses bank slot 2; supply its loaded bank with --bank')
    if bname not in ('ORCH', 'HNK1', 'HNK2'):
        raise ValueError('unsupported render bank: ' + str(bname))
    notes, tempos, ppqn, bpm, stats = parse_track(seq_data[s:e],loop_passes=loop_passes)
    print('song %d  bank=%s  PPQN=%d  %.1f BPM  notes=%d  tempo_changes=%d'
          % (song, bname, ppqn, bpm, stats['notes'], stats['tempo_changes']))

    if bname not in bank_cache:
        va,vb=BANK_SOURCES[bname]
        bank_cache[bname] = parse_vab_bytes(disc_extract(*va),disc_extract(*vb))
    samples, programs, loops = bank_cache[bname]
    print('   bank: %d samples, %d programs' % (len(samples), len(programs)))

    # shortcut: nominal60 updates; exact external callback arrival remains AU04.
    timing=schedule_ticks(stats['event_ticks'],tempos,ppqn)
    if not timing:timing[0]=0
    t2s=lambda tick:Fraction(timing[tick],60)
    left,right,played,silent,total=render_events(stats['voice_events'],samples,programs,loops,
                                               t2s,stats['last_tick'],sequence=(START_LEVELS[song],)*2,reverb=reverb)
    # Startup master register127*129, without peak normalization.
    # shortcut: external command timelines remain AU04 integration work.
    from reverb import mix_sample
    pcm=bytearray()
    for l,r in zip(left,right):
        for value in (l,r):
            value=mix_sample(int(value),0,0)
            pcm.extend(struct.pack('<h',value))
    print('   voices=%d silent=%d  duration=%.1f s' % (played,silent,total))

    if write:
        os.makedirs(out_dir, exist_ok=True)
        path = os.path.join(out_dir, 'song%d_v3%s.wav' % (song,'_reverb' if reverb else ''))
        w = wave.open(path, 'wb')
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
        w.close()
        print('   wrote %s' % path)
    return total


def main(argv):
    parser = argparse.ArgumentParser(description='Render a sequence with an explicit slot-2 bank context')
    parser.add_argument('song', nargs='?', type=int, choices=range(SONGS))
    parser.add_argument('--bank', choices=('HNK1', 'HNK2'), help='bank loaded in slot 2')
    parser.add_argument('--reverb',action='store_true',help='disc Studio Medium network, startup depth40, finite4s wet continuation')
    parser.add_argument('--info', action='store_true', help='parse sequence metadata without rendering')
    parser.add_argument('--loop-passes',type=int,default=1,help='maximum native loop traversals in this finite preview')
    args = parser.parse_args(argv)
    if args.loop_passes<1:parser.error('--loop-passes must be positive')
    songs = [args.song] if args.song is not None else list(range(SONGS))
    if not args.info and any(s >= 2 for s in songs) and args.bank is None:
        parser.error('sequences 2/3 use dynamic bank slot 2; specify --bank HNK1 or HNK2')
    seq = disc_extract(22410,71162)
    cache = {}
    for s in songs:
        if args.info:
            notes, tempos, ppqn, bpm, _ = parse_track(seq[slice(*TRACKS[s])],loop_passes=args.loop_passes)
            print(f'song {s}: slot={1 if s < 2 else 2}, PPQN={ppqn}, BPM={bpm}, '
                  f'notes={len(notes)}, tempos={len(tempos)}')
        else:
            render_song(s, seq, cache, OUT_DIR, bank=args.bank,loop_passes=args.loop_passes,reverb=args.reverb)
        print()


if __name__ == '__main__':
    main(sys.argv[1:])
