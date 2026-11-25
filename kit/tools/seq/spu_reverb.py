#!/usr/bin/env python3
"""Historical rejected reverb approximation, no longer used by render_seq.

Canonical isolated DSP: reverb.py; numerical scope: seq_reverb_network.md.
The historical code below remains rejected.

This model does not implement the32-register SPU network and its PRESET_HALL
values are not Sony's Hall preset. Keep it only as the source snapshot behind
archive/docs/spu_review.md. The actual disc presets and native upload path
are recovered in archive/docs/seq_controls_native.md; verified rendering of
their network remains an open question. Do not present this output as game audio.
"""

# SPU reverb work area in words (0x40000 words = 256 KB span).
REVERB_WA = 0xE0000       # typical SPU RAM offset games place the work area at
REVERB_MASK = 0x3FFFF

# 20-tap resampling filter used by both the down- and up-sampler.
RESAMP = (-1, 2, -10, 35, -103, 266, -616, 1332, -2960, 10246,
          10246, -2960, 1332, -616, 266, -103, 35, -10, 2, -1)

# Rejected historical parameter dictionary; not the Sony Hall register set.
PRESET_HALL = {
    'dAPF1': 0x01A5, 'dAPF2': 0x0139,
    'vIIR': 0x6000,
    'vCOMB1': 0x5000, 'vCOMB2': 0x5000, 'vCOMB3': 0x5000, 'vCOMB4': 0x5000,
    'dCOMB1': 0x1160, 'dCOMB2': 0x1160, 'dCOMB3': 0x1160, 'dCOMB4': 0x1160,
    'dAPF1b': 0x0035, 'dAPF2b': 0x0023,
    'vAPF1': -0x6000, 'vAPF2': -0x6000,
    'mLSAME': 0x0028, 'mRSAME': 0x0028,
    'dLSAME': 0x00B0, 'dRSAME': 0x00B0,
    'mLDIF1': 0x0000, 'mRDIF1': 0x0000,
    'mLDIFF': 0x0000, 'mRDIFF': 0x0000,
    'dLDIF1': 0x0000, 'dRDIF1': 0x0000,
    'dLDIFF': 0x0000, 'dRDIFF': 0x0000,
}


def _sat(v):
    if v > 32767:
        return 32767
    if v < -32768:
        return -32768
    return v


class Reverb:
    """One SPU reverb unit.

    The SPU runs the algorithm on a 44.1 kHz -> 22.05 kHz downsampled signal and
    upsamples the result, which is why the resample filters appear twice.
    """

    def __init__(self, preset=None, wa=REVERB_WA):
        p = dict(PRESET_HALL)
        if preset:
            p.update(preset)
        self.p = p
        self.wa = wa & REVERB_MASK
        # SPU work RAM: 256 KB of 16-bit words
        self.ram = [0] * 0x40000
        self.cur = self.wa
        self.rd_pos = 0            # RvbResPos, 0..0x3F
        # 0x80 entries: the reference writes both [pos] and [pos|0x40] so the
        # 39-tap MAC loop needs no bounds check across the wrap.
        self.rdsb = [[0] * 0x80, [0] * 0x80]
        self.rusb = [[0] * 0x80, [0] * 0x80]
        self.R = self._regs()

    # ---- addressing -------------------------------------------------------
    # The reference resolves every reverb register as
    #     Get_Reverb_Offset((raw_offs << 2) + extra)
    # i.e. register values are WORD offsets (shifted left 2 to become a word
    # address), then the moving cursor ReverbCur is added and the result is
    # wrapped so it never falls below the work area. My first version treated
    # them as plain absolute addresses with no <<2 and no cursor, which is why
    # nothing ever propagated through the network.
    def _off(self, raw, extra=0):
        o = (self.cur + (((raw << 2) + extra) & REVERB_MASK)) & REVERB_MASK
        if o < self.wa:
            o = (o + self.wa) & REVERB_MASK
        return o

    def _rd(self, raw, extra=0):
        return self.ram[self._off(raw, extra)]

    def _wr(self, raw, val):
        self.ram[self._off(raw, 0)] = val

    def _regs(self):
        p = self.p
        return {
            'IIR_SRC_A0': p['mLSAME'], 'IIR_SRC_A1': p['mRSAME'],
            'IIR_SRC_B0': p['mLDIF1'], 'IIR_SRC_B1': p['mRDIF1'],
            'IIR_DEST_A0': p['mLSAME'] + p['dLSAME'],
            'IIR_DEST_A1': p['mRSAME'] + p['dRSAME'],
            'IIR_DEST_B0': p['mLDIF1'] + p['dLDIF1'],
            'IIR_DEST_B1': p['mRDIF1'] + p['dRDIF1'],
            'ACC_SRC_A0': p['mLSAME'] + p['dLSAME'] + p['dAPF1'],
            'ACC_SRC_A1': p['mRSAME'] + p['dRSAME'] + p['dAPF1'],
            'ACC_SRC_B0': p['mLDIFF'] + p['dLDIFF'] + p['dAPF1'],
            'ACC_SRC_B1': p['mRDIFF'] + p['dRDIFF'] + p['dAPF1'],
            'ACC_SRC_C0': p['mLDIF1'] + p['dLDIF1'] + p['dAPF2'],
            'ACC_SRC_C1': p['mRDIF1'] + p['dRDIF1'] + p['dAPF2'],
            'ACC_SRC_D0': p['mLSAME'] + p['dLSAME'] + p['dAPF2'],
            'ACC_SRC_D1': p['mRSAME'] + p['dRSAME'] + p['dAPF2'],
            'MIX_DEST_A0': p['mLDIFF'], 'MIX_DEST_A1': p['mRDIFF'],
            'MIX_DEST_B0': p['mLDIFF'] + p['dAPF1'],
            'MIX_DEST_B1': p['mRDIFF'] + p['dAPF1'],
            'FB_SRC_A': p['dAPF1'], 'FB_SRC_B': p['dAPF2'],
        }

    # ---- resamplers -------------------------------------------------------
    @staticmethod
    def _down(src):
        out = 0
        for i in range(20):
            out += RESAMP[i] * src[i * 2]
        out += 0x4000 * src[19]
        out >>= 15
        return _sat(out)

    @staticmethod
    def _up(src):
        out = 0
        for i in range(20):
            out += RESAMP[i] * src[i]
        out >>= 14
        return _sat(out)

    # ---- per-sample processing -------------------------------------------
    def process(self, in_l, in_r, enabled=True):
        """Run one stereo sample pair. Returns (out_l, out_r)."""
        p = self.p
        pos = self.rd_pos
        self.rdsb[0][pos] = in_l
        self.rdsb[0][pos | 0x40] = in_l
        self.rdsb[1][pos] = in_r
        self.rdsb[1][pos | 0x40] = in_r

        if pos & 1:
            dl = self._down(self.rdsb[0][(pos - 39) & 0x3F:])
            dr = self._down(self.rdsb[1][(pos - 39) & 0x3F:])
            if enabled:
                ALPHA = p['vIIR']
                IN_L = p['vCOMB1']
                IN_R = p['vCOMB2']

                IIR_IN_A0 = _sat(((self._rd(self.R['IIR_SRC_A0']) * IN_L) >> 15)
                                 + ((dl * IN_L) >> 15))
                IIR_IN_A1 = _sat(((self._rd(self.R['IIR_SRC_A1']) * IN_R) >> 15)
                                 + ((dr * IN_R) >> 15))
                IIR_IN_B0 = _sat(((self._rd(self.R['IIR_SRC_B0']) * IN_L) >> 15)
                                 + ((dl * IN_L) >> 15))
                IIR_IN_B1 = _sat(((self._rd(self.R['IIR_SRC_B1']) * IN_R) >> 15)
                                 + ((dr * IN_R) >> 15))

                def iir(inp, dest, alpha):
                    fb = self._rd(dest, -4)
                    if alpha == -32768:
                        ii = 0 if fb == -32768 else fb * -65536
                    else:
                        ii = fb * (32768 - alpha)
                    return _sat((((inp * alpha) >> 14) + (ii >> 14)) >> 1)

                a0 = iir(IIR_IN_A0, self.R['IIR_DEST_A0'], ALPHA)
                a1 = iir(IIR_IN_A1, self.R['IIR_DEST_A1'], ALPHA)
                b0 = iir(IIR_IN_B0, self.R['IIR_DEST_B0'], ALPHA)
                b1 = iir(IIR_IN_B1, self.R['IIR_DEST_B1'], ALPHA)
                self._wr(self.R['IIR_DEST_A0'], a0)
                self._wr(self.R['IIR_DEST_A1'], a1)
                self._wr(self.R['IIR_DEST_B0'], b0)
                self._wr(self.R['IIR_DEST_B1'], b1)

                acc0 = _sat((((self._rd(self.R['ACC_SRC_A0']) * p['vCOMB1']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_B0']) * p['vCOMB2']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_C0']) * p['vCOMB3']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_D0']) * p['vCOMB4']) >> 14)) >> 1)
                acc1 = _sat((((self._rd(self.R['ACC_SRC_A1']) * p['vCOMB1']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_B1']) * p['vCOMB2']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_C1']) * p['vCOMB3']) >> 14)
                             + ((self._rd(self.R['ACC_SRC_D1']) * p['vCOMB4']) >> 14)) >> 1)

                fb_a0 = self._rd(self.R['MIX_DEST_A0'], -(self.R['FB_SRC_A'] << 2))
                fb_a1 = self._rd(self.R['MIX_DEST_A1'], -(self.R['FB_SRC_A'] << 2))
                fb_b0 = self._rd(self.R['MIX_DEST_B0'], -(self.R['FB_SRC_B'] << 2))
                fb_b1 = self._rd(self.R['MIX_DEST_B1'], -(self.R['FB_SRC_B'] << 2))

                fb_alpha = p['vAPF1']
                fb_x = p['vAPF2']
                self._wr(self.R['MIX_DEST_A0'],
                         _sat(acc0 - ((fb_a0 * fb_alpha) >> 15)))
                self._wr(self.R['MIX_DEST_A1'],
                         _sat(acc1 - ((fb_a1 * fb_alpha) >> 15)))
                self._wr(self.R['MIX_DEST_B0'],
                         _sat(((fb_alpha * acc0) >> 15)
                              - ((fb_a0 * (0x8000 ^ (fb_alpha & 0xFFFF))) >> 15)
                              - ((fb_b0 * fb_x) >> 15)))
                self._wr(self.R['MIX_DEST_B1'],
                         _sat(((fb_alpha * acc1) >> 15)
                              - ((fb_a1 * (0x8000 ^ (fb_alpha & 0xFFFF))) >> 15)
                              - ((fb_b1 * fb_x) >> 15)))

            o0 = (self._rd(self.R['MIX_DEST_A0']) + self._rd(self.R['MIX_DEST_B0'])) >> 1
            o1 = (self._rd(self.R['MIX_DEST_A1']) + self._rd(self.R['MIX_DEST_B1'])) >> 1
            self.rusb[0][(pos >> 1) | 0x20] = o0
            self.rusb[0][pos >> 1] = o0
            self.rusb[1][(pos >> 1) | 0x20] = o1
            self.rusb[1][pos >> 1] = o1

            self.cur = (self.cur + 1) & REVERB_MASK
            if self.cur == 0:
                self.cur = self.wa

            s0 = self.rusb[0][((pos - 39) & 0x3F) >> 1:]
            s1 = self.rusb[1][((pos - 39) & 0x3F) >> 1:]
            out_l = s0[9]
            out_r = s1[9]
        else:
            s0 = self.rusb[0][((pos - 39) & 0x3F) >> 1:]
            s1 = self.rusb[1][((pos - 39) & 0x3F) >> 1:]
            out_l = self._up(s0)
            out_r = self._up(s1)

        self.rd_pos = (pos + 1) & 0x3F
        return out_l, out_r
