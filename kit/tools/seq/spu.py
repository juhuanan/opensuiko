#!/usr/bin/env python3
"""Numerical SPU voice previews based on Mednafen's SPU implementation (GPL).

The envelope and first-traversal behavior have focused numerical checks in
kit/tests/test_spu_envelope.py. Native game controller and reverb-parameter
proofs are separate in archive/docs/seq_controls_native.md. The preview does
not implement the complete live voice mixer or verified reverb network.
Reference: archive/docs/spu_reference_20261003.txt, with its corrections.
"""

from math import floor

FILTERS = ((0, 0), (60, 0), (115, -52), (98, -55), (122, -60))

# ADSR phases
ATTACK, DECAY, SUSTAIN, RELEASE, OFF = 0, 1, 2, 3, 4

ENV_MAX = 0x7FFF


def clamp16(v):
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return v


def calc_vc_delta(zs, speed, log_mode, dec_mode, inv_increment, current):
    """Transcribe Mednafen's CalcVCDelta exactly.

    Returns (increment, divinco). The envelope advances one step every time the
    divider accumulates past 0x8000, which is what makes SPU envelope rates
    non-linear in the shift value.
    """
    increment = 7 - (speed & 0x3)
    if inv_increment:
        increment = ~increment
    divinco = 32768

    if speed < 0x2C:
        increment <<= (0x2F - speed) >> 2
    if speed >= 0x30:
        divinco >>= (speed - 0x2C) >> 2

    if log_mode:
        if dec_mode:
            # log decrement: proportional to the current level
            increment = (current * increment) >> 15
        else:
            # log increment: slows as it approaches full scale
            if (current & 0x7FFF) >= 0x6000:
                if speed < 0x28:
                    increment >>= 2
                elif speed >= 0x2C:
                    divinco >>= 2
                else:
                    increment >>= 1
                    divinco >>= 1

    if divinco == 0 and speed < zs:
        divinco = 1

    return increment, divinco


class Envelope:
    """One voice's ADSR envelope, following the SPU's phase machine."""

    __slots__ = ('attack_rate', 'decay_rate', 'sustain_rate', 'release_rate',
                 'sustain_level', 'attack_exp', 'sustain_exp', 'sustain_dec',
                 'release_exp', 'level', 'divider', 'phase')

    def __init__(self, adsr1, adsr2):
        # adsr1: bit15 attack mode, bits14-10 attack shift, bits9-8 attack step,
        #        bits7-4 decay shift, bits3-0 sustain level
        # adsr2: bit15-13 sustain mode/direction, bits12-8 sustain shift,
        #        bits7-6 sustain step, bit5 release mode, bits4-0 release shift
        self.attack_exp = bool(adsr1 & 0x8000)
        self.attack_rate = (adsr1 >> 8) & 0x7F
        self.decay_rate = ((adsr1 >> 4) & 0x0F) << 2
        self.sustain_level = ((adsr1 & 0x0F) + 1) << 11

        self.sustain_exp = bool(adsr2 & 0x8000)
        self.sustain_dec = bool(adsr2 & 0x4000)
        self.sustain_rate = (adsr2 >> 6) & 0x7F
        self.release_exp = bool(adsr2 & 0x0020)
        self.release_rate = (adsr2 & 0x1F) << 2

        self.level = 0
        self.divider = 0
        self.phase = ATTACK

    def key_on(self):
        self.level = 0
        self.divider = 0
        self.phase = ATTACK

    def key_off(self):
        self.divider = 0
        self.phase = RELEASE

    def step(self):
        """Advance one sample. Returns the current level (0..0x7FFF)."""
        if self.phase == ATTACK and self.level >= ENV_MAX:
            self.phase = DECAY

        if self.phase == ATTACK:
            inc, div = calc_vc_delta(0x7F, self.attack_rate, self.attack_exp,
                                     False, False, self.level)
            of_reset = ENV_MAX
        elif self.phase == DECAY:
            inc, div = calc_vc_delta(0x1F << 2, self.decay_rate, True, True,
                                     True, self.level)
            of_reset = 0
        elif self.phase == SUSTAIN:
            inc, div = calc_vc_delta(0x7F, self.sustain_rate, self.sustain_exp,
                                     self.sustain_dec, self.sustain_dec,
                                     self.level)
            of_reset = 0 if self.sustain_dec else ENV_MAX
        elif self.phase == RELEASE:
            inc, div = calc_vc_delta(0x1F << 2, self.release_rate, self.release_exp,
                                     True, True, self.level)
            of_reset = 0
        else:
            return 0

        self.divider += div
        if self.divider & 0x8000:
            prev = self.level
            self.divider = 0
            self.level += inc

            if self.phase == ATTACK:
                # overflow to negative while the top bit was clear = clamp
                if ((prev ^ self.level) & self.level) & 0x8000:
                    self.level = of_reset
            else:
                if self.level & 0x8000 or self.level < 0:
                    self.level = of_reset

            if self.phase == DECAY and self.level < self.sustain_level:
                self.phase = SUSTAIN

        if self.level < 0:
            self.level = 0
        elif self.level > ENV_MAX:
            self.level = ENV_MAX
        return self.level


class Sweep:
    """SPU volume sweep generator (per-voice L/R, and the global pair).

    Transcribed from Mednafen's SPU_Sweep::Clock. A sweep either holds a static
    volume (when Control bit15 is clear: Current = (Control & 0x7FFF) << 1) or
    ramps it using the same CalcVCDelta arithmetic as the envelope, with its own
    log/dec/invert mode bits. Used for fades and tremolo.
    """

    __slots__ = ('control', 'current', 'divider')

    def __init__(self):
        self.control = 0
        self.current = 0
        self.divider = 0

    @property
    def volume(self):
        return self.current

    def clock(self):
        c = self.control
        if not (c & 0x8000):
            # sweep disabled: static volume, stored as a 15-bit value << 1
            self.current = (c & 0x7FFF) << 1
            return self.current

        log_mode = bool(c & 0x4000)
        dec_mode = bool(c & 0x2000)
        inv_mode = bool(c & 0x1000)
        inv_increment = (dec_mode ^ inv_mode) or (dec_mode and log_mode)
        vc_cv_xor = 0xFFFF if (inv_mode and not (dec_mode and log_mode)) else 0
        test_invert = 0xFFFF if inv_mode else 0

        cur = self.current
        signed = cur ^ vc_cv_xor
        if signed >= 0x8000:
            signed -= 0x10000
        inc, div = calc_vc_delta(0x7F, c & 0x7F, log_mode, dec_mode,
                                 inv_increment, signed)

        stopped = (dec_mode and not (inv_mode and log_mode)) and (
            (cur & 0x8000) == (0x0000 if inv_mode else 0x8000) or cur == 0)
        if stopped:
            self.current = 0
            return self.current

        self.divider += div
        if self.divider & 0x8000:
            self.divider = 0
            if dec_mode or ((cur ^ test_invert) != 0x7FFF):
                prev = cur
                cur = (cur + inc) & 0xFFFF
                if (not dec_mode and ((cur ^ prev) & 0x8000)
                        and ((cur ^ test_invert) & 0x8000)):
                    cur = 0x7FFF ^ test_invert
                self.current = cur
        return self.current


def voice_levels(volumes, pans, stereo=True, sequence=(127,127), direct=False, update=False):
    """MAIN80154F08 setup /63 pans;80158460 updates /64 pans."""
    header,level,program,tone=volumes
    level=header*16383*level//16129
    level=level*program*tone//16129
    left,right=(level,level) if direct else tuple(level*v//127 for v in sequence)
    denominator=64 if update else 63
    for pan in pans:
        if pan<64:right=right*pan//denominator
        else:left=left*(127-pan)//denominator
    if not stereo:left=right=max(left,right)
    return left*left//16383,right*right//16383


def reset_voice_history(history, voice):
    """801553E8: a staged note clears its bit from all16 quiet-history slots."""
    for i in range(16):history[i]&=~(1<<voice)


def poll_voice_status(states, history, index, levels, inhibit=False):
    """8015735C: sample envelopes, rotate16 slots and intersect slots0..14."""
    if len(levels)!=len(states):raise ValueError('voice sample count differs')
    index=(index+1)&15;history[index]=0
    for i,(state,level) in enumerate(zip(states,levels)):
        state['level']=level&65535
        if state['level']==0:history[index]|=1<<i
    quiet=0xFFFFFFFF
    for mask in history[:15]:quiet&=mask
    if not inhibit:
        for i,state in enumerate(states):
            if quiet&(1<<i):state['status']=0
    return index


def allocate_voice(states, priority):
    """MAIN80154C8C: first free, then priority/envelope/age selection."""
    chosen=99;ties=0;best_priority=priority;best_level=65535;best_age=0
    for i,state in enumerate(states):
        if state['status']==0 and state['level']==0:
            chosen=i
            break
        old=state['priority'];old=old-65536 if old&32768 else old
        if old<best_priority:
            best_priority=old&65535;chosen=i;best_level=state['level'];best_age=state['age'];ties=1
        elif old==best_priority:
            ties+=1
            age=state['age'];signed_age=age-65536 if age&32768 else age
            if state['level']<best_level:
                chosen=i;best_level=state['level'];best_age=age
            elif state['level']==best_level and best_age<signed_age:
                chosen=i;best_age=signed_age
    if chosen==99:chosen=chosen if ties else len(states)
    if chosen<len(states):
        for state in states:state['age']=(state['age']+1)&65535
        states[chosen]['age']=0;states[chosen]['priority']=priority
    return chosen


class Voice:
    """One SPU voice."""

    __slots__ = ('samples', 'loop_start', 'loop_end', 'loops', 'pos', 'step',
                 'env', 'vol_l', 'vol_r', 'active', 'note', 'ch',
                 'last', 'prev', 'mod_source', 'pitch_mod', 'looped')

    def __init__(self, samples, loop_start, loop_end, loops, step, adsr1, adsr2):
        self.samples = samples
        self.loop_start = loop_start
        self.loop_end = loop_end
        self.loops = loops
        self.pos = 0.0
        self.looped = False
        self.step = step
        self.env = Envelope(adsr1, adsr2)
        self.vol_l = 1.0
        self.vol_r = 1.0
        self.active = True
        self.last = 0
        self.prev = 0
        # Pitch modulation (SPU "FM mode"): this voice's phase increment is
        # perturbed by the PREVIOUS voice's output sample. The reference uses
        #   phase_inc = Pitch + ((int16)(Pitch * prev_voice_sample) >> 15)
        # which handles carrier pitches >= 0x8000 correctly (the older, wrong
        # form was (Pitch * (sample + 0x8000)) >> 15).
        self.mod_source = None
        self.pitch_mod = False

    def render(self, fir, out_l, out_r, start, n, sr, send=None):
        """Render the first traversal, then wrap after the loop-end block.

        FIR history before the first loop entry belongs to the attack. Once
        the loop has wrapped, those taps belong to the preceding loop tail.
        A lookahead tap beyond the end block already reads the next traversal.
        Optional send buffers receive this call's post-pan samples at indices0..n-1.
        """
        if not self.active or not self.samples:
            return 0
        s = self.samples
        nsrc = len(s)
        ls, le = self.loop_start, self.loop_end
        can_loop = bool(self.loops and 0 <= ls <= le < nsrc)
        # Loop body includes the loop-END block: [ls, le + 28).
        body_end = le + 28 if can_loop else 0
        if can_loop and body_end > nsrc:
            body_end = nsrc
        span = body_end - ls if can_loop else 0

        def tap(i):
            """Sample index i, wrapped inside the loop body when looping."""
            if can_loop and (i >= body_end or (self.looped and i < ls)):
                return ls + ((i - ls) % span)
            if i < 0:
                return 0
            if i >= nsrc:
                return nsrc - 1
            return i

        produced = 0
        for k in range(n):
            idx = start + k
            if idx >= len(out_l):
                break
            # Jump back after the loop-END block has played, not at the end of
            # the sample data and not at the start of the end block.
            if can_loop and self.pos >= body_end:
                self.pos = ls + ((self.pos - ls) % span)
                self.looped = True
            elif not can_loop and self.pos >= nsrc:
                # SPU end without repeat forces the envelope to zero.
                self.env.level = 0
                self.env.phase = RELEASE
                self.active = False
                break
            lvl = self.env.step()
            if lvl <= 0 and self.env.phase == RELEASE:
                self.active = False
                break

            i0 = int(self.pos)
            if i0 >= nsrc:
                i0 = nsrc - 1
            frac = self.pos - i0
            ph = int(frac * 256.0) & 0xFF
            c = fir[ph]
            a = s[tap(i0 - 2)]
            b = s[tap(i0 - 1)]
            cc = s[tap(i0)]
            d = s[tap(i0 + 1)]
            v = (a * c[0] + b * c[1] + cc * c[2] + d * c[3]) >> 15
            self.prev = self.last
            self.last = v
            v = (v * lvl) >> 15
            left,right=floor(v*self.vol_l),floor(v*self.vol_r)
            out_l[idx]+=left;out_r[idx]+=right
            if send is not None:send[0][k]+=left;send[1][k]+=right
            if self.pitch_mod and self.mod_source is not None:
                p = self.step
                mod = p + ((p * self.mod_source.last) / 32768.0)
                if mod > 3.9999:
                    mod = 3.9999
                if mod < 0.0001:
                    mod = 0.0001
                self.pos += mod
            else:
                self.pos += self.step
            produced += 1
        return produced


class Noise:
    """SPU noise generator (24-bit LFSR)."""

    def __init__(self):
        self.lfsr = 0x4001
        self.divider = 0
        self.counter = 0

    def step(self, rf=0):
        div_inc = 2 << (rf >> 2)
        cnt_inc = 4 + (rf & 0x3)
        if rf >= 0x3C:
            div_inc = 0x8000
            cnt_inc = 8
        self.divider += div_inc
        if self.divider & 0x8000:
            self.divider = 0
            self.counter += cnt_inc
            if self.counter & 0x8:
                self.counter &= 0x7
                l = self.lfsr
                bit = ((l >> 15) ^ (l >> 12) ^ (l >> 11) ^ (l >> 10) ^ 1) & 1
                self.lfsr = ((l << 1) | bit) & 0xFFFFFF
        return self.lfsr


class VoicePool:
    """24-voice pool with allocation, as the hardware has.

    The real SPU has exactly 24 voices. Previously the renderer summed however
    many notes happened to overlap; song 0 reaches 14 simultaneous voices, so
    there was no limit and no stealing. Modelling the pool makes the render
    behave like the console under load.
    """

    def __init__(self, size=24):
        self.size = size
        self.voices = [None] * size

    def allocate(self):
        for i in range(self.size):
            if self.voices[i] is None or not self.voices[i].active:
                return i
        # steal the voice closest to finishing (lowest envelope level)
        worst, wi = None, 0
        for i, v in enumerate(self.voices):
            if v is None:
                return i
            if worst is None or v.env.level < worst.env.level:
                worst, wi = v, i
        return wi

    def put(self, v):
        i = self.allocate()
        self.voices[i] = v
        return i
