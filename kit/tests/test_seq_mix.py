#!/usr/bin/env python3
"""Static voice setup and update checks, with independent fixed-point arithmetic."""
from hashlib import sha256
from itertools import product
from pathlib import Path
import random
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
import maindec as M
from spu import voice_levels
from test_canonical_start import assert_main_words


def source_levels():
    for start, end, digest in (
        (0x80154F08, 0x80155264, '9c0b800169a7fcdc41d45aaa0425eed2122bc68ebdf8bd046cad447759d54fd5'),
        (0x80158460, 0x80158824, '23a7b398425eb0f8e08747bb652109a8097540849016861b265d398c0b1b8c21'),
        (0x80159A80, 0x80159B54, '83f76aebc59c07823ff8c3fa47418239d33e02abde4c358a62aa9ce2e8145137'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Sequence 0x21 keeps the unscaled level on both sides.
        0x80154FF8: (0x34020021, 0x10A20017, 0x00E03021, 0x94620074),
        0x80155024: (0x94620076,),
        # The setup stores pitch and both volume halfwords with a 16-byte stride.
        0x80155210: (0x3C048018, 0x2484A3D4, 0x2482FFFC, 0x2484FFFE, 0x3123FFFF, 0x00031840),
        0x80155238: (0xA4280000,),
        0x80155248: (0xA4460000,),
        0x80155260: (0xA4650000,),
        # The bank helper refreshes pointers and rank. Update reads the existing
        # scratch gains and pans, with the voice's tone index written separately.
        0x801584F0: (0x0C0566A0, 0x0043B021),
        0x801585D8: (0x91640000,),
        0x801585F8: (0x91620003,),
        0x80159B20: (0xAC22BFF4,),
        0x80159B30: (0xAC23BFF0,),
        0x80159B48: (0xA023C14B,),
        # Each update mismatch jumps directly to the next voice, past both stores.
        0x80158544: (0x314200FF, 0x00021840, 0x00621821, 0x00034900),
        0x80158558: (0x2421A572, 0x00290821, 0x84220000, 0, 0x1453009A),
        0x80158574: (0x2421A57A, 0x00290821, 0x84220000, 0, 0x14500093),
        0x80158590: (0x2421A576, 0x00290821, 0x84220000, 0, 0x1446008C),
        0x80158670: (0xA1620002,),
        0x80158784: (0x00051900, 0x006F1021, 0x00711821, 0xA4480000),
        0x801587A8: (0xA4640000, 0x3C018018, 0x2421A550, 0x00250821,
                     0x90220000, 0x26940001, 0x34420003),
        0x801587D0: (0xA0220000, 0x254A0001, 0x3C038018, 0x9063C0E4, 0x314200FF,
                     0x0043102B, 0x1440FF57, 0x314200FF, 0x02801021),
    })

    # Use the source's multiply-high constants rather than the renderer's divisors.
    def immediate_pair(pc):
        upper, lower = M.mword(pc), M.mword(pc + 4)
        assert upper >> 26 == 0x0F and lower >> 26 == 0x0D
        return ((upper & 0xFFFF) << 16) | (lower & 0xFFFF)

    def shift(pc):
        return (M.mword(pc) >> 6) & 31

    full = (1 << shift(0x80154F20)) - 1
    signed_magic = immediate_pair(0x80154F30) - (1 << 32)
    gain_magic = immediate_pair(0x80154F74)
    sequence_magic = immediate_pair(0x80155014)
    stereo_magic = immediate_pair(0x80155078)
    square_magic = immediate_pair(0x801551E4)
    signed_shift, gain_shift, sequence_shift, stereo_shift, square_shift = (
        shift(pc) for pc in (0x80154F4C, 0x80154FA4, 0x80155044, 0x80155098, 0x8015520C)
    )
    update_shift = shift(0x801586B0)
    midpoint = M.mword(0x80155068) & 0xFFFF
    max_pan = M.mword(0x8015509C) & 0xFFFF
    assert (signed_magic + (1 << 32), gain_magic, sequence_magic, square_magic) == tuple(
        immediate_pair(pc) for pc in (0x801585CC, 0x80158608, 0x80158524, 0x80158530))
    assert (gain_shift, sequence_shift, update_shift, square_shift, midpoint, max_pan) == (13, 6, 6, 13, 64, 127)

    def unsigned_quotient(numerator, multiplier, bits):
        high = numerator * multiplier >> 32
        return (high + ((numerator - high) >> 1)) >> bits

    def levels(volumes, pans, stereo=True, sequence=(127, 127), direct=False, *, update=False):
        header, level, program, tone = volumes
        first = header * full * level
        gain = (first + (first * signed_magic >> 32)) >> signed_shift
        gain = unsigned_quotient(gain * program * tone, gain_magic, gain_shift)
        left, right = (gain, gain) if direct else tuple(
            unsigned_quotient(gain * value, sequence_magic, sequence_shift) for value in sequence)
        for pan in pans:
            if pan < midpoint:
                product = right * pan
                right = product >> update_shift if update else unsigned_quotient(product, stereo_magic, stereo_shift)
            else:
                product = left * (max_pan - pan)
                left = product >> update_shift if update else unsigned_quotient(product, stereo_magic, stereo_shift)
        if not stereo:
            left = right = max(left, right)
        return tuple(unsigned_quotient(value * value, square_magic, square_shift) for value in (left, right))

    return levels


def check():
    levels = source_levels()
    cases=0
    def compare(*args):
        nonlocal cases
        actual,expected=levels(*args),voice_levels(*args)
        assert actual==expected,(args,actual,expected)
        cases+=1
    for volumes in product((0,1,31,63,64,65,126,127),repeat=4):
        compare(volumes,(64,64,64))
    for stage in range(3):
        for value in range(128):
            pans=[64]*3;pans[stage]=value
            for stereo,direct in product((False,True),repeat=2):
                compare((117,101,89,73),pans,stereo,(37,91),direct)
    rng=random.Random(0x154F08)
    for _ in range(512):
        compare(tuple(rng.randrange(128) for _ in range(4)),
                tuple(rng.randrange(128) for _ in range(3)),
                bool(rng.randrange(2)),tuple(rng.randrange(128) for _ in range(2)),
                bool(rng.randrange(2)))
    updates=0
    for stage in range(3):
        for value in range(128):
            pans=[64]*3;pans[stage]=value
            for stereo in (False,True):
                args=((117,101,89,73),pans,stereo,(37,91))
                assert levels(*args,update=True)==voice_levels(*args,update=True),args
                updates+=1
    for _ in range(512):
        args=(tuple(rng.randrange(128) for _ in range(4)),
              tuple(rng.randrange(128) for _ in range(3)),
              bool(rng.randrange(2)),tuple(rng.randrange(128) for _ in range(2)))
        assert levels(*args,update=True)==voice_levels(*args,update=True),args
        updates+=1
    assert levels((127,)*4,(64,)*3)==(16383,16383)
    assert levels((127,)*4,(64,)*3,update=True)==(14903,16383)
    print(f'PASS: {updates} static update and {cases} setup formula cases. '
          'Source checks cover voice filtering, pitch, volume and dirty-bit stores.')


if __name__=='__main__':check()
