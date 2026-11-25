"""Strict 4-bit stereo CD-XA sound groups, 112 samples/channel/group.

Four interleaved byte columns carry low-nibble left/high-nibble right samples.
Predictor history continues between columns, groups and sectors of one stream.
"""
FILTERS = [(0, 0), (60, 0), (115, -52), (98, -55), (122, -60)]
VERSION = 'xa-stereo-4bit-v2'


class XADecoder:
    def __init__(self):
        self.s = [0, 0, 0, 0]  # latest/previous left, latest/previous right

    def decode_group(self, group):
        if len(group) != 128:
            raise ValueError('XA sound group must contain 128 bytes')
        if group[:4] != group[4:8] or group[8:12] != group[12:16]:
            raise ValueError('XA parameter copies disagree')
        params = group[4:12]
        if any(p >> 4 >= len(FILTERS) or p & 15 > 12 for p in params):
            raise ValueError('unsupported XA predictor or shift')
        channels = [[], []]
        for column in range(4):
            for channel in range(2):
                param = params[column * 2 + channel]
                f0, f1 = FILTERS[param >> 4]
                latest, previous = self.s[channel * 2:channel * 2 + 2]
                for byte in group[16 + column::4]:
                    nibble = (byte >> (channel * 4)) & 15
                    signed = nibble - 16 if nibble & 8 else nibble
                    sample = (signed << (12 - (param & 15))) + ((latest * f0 + previous * f1 + 32) >> 6)
                    sample = max(-32768, min(32767, sample))
                    channels[channel].append(sample)
                    previous, latest = latest, sample
                self.s[channel * 2:channel * 2 + 2] = latest, previous
        return tuple(channels)

    def decode_sector(self, payload2324):
        if len(payload2324) != 2324:
            raise ValueError('XA Form 2 payload must contain 2324 bytes')
        before = self.s[:]
        left, right = [], []
        try:
            for offset in range(0, 2304, 128):
                l, r = self.decode_group(payload2324[offset:offset + 128])
                left.extend(l)
                right.extend(r)
        except ValueError:
            self.s = before
            raise
        return left, right
