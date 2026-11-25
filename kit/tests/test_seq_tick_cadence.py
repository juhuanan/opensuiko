#!/usr/bin/env python3
"""Static MAIN checks of the audio callback registration and catch-up routes."""
from hashlib import sha256
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import maindec as M
from test_canonical_start import assert_main_words


def check():
    for start, end, digest in (
        (0x800C2988, 0x800C29CC, '03761f17a747eea05940b76b153ddd94c3c02d2070e22b01a158bd7683f16ee8'),
        (0x801547FC, 0x80154928, 'a934552b6ee93efdf6ec6547d0f41ca1fcef208bad01a1aa57b10da616abbbe4'),
        (0x800C2948, 0x800C2974, 'c8d7a28d97180eac32a76506b390abdbfb0a49b9358daa27ed2f9a461dfd9c20'),
        (0x800C9388, 0x800C93C4, '6b1c378f08327bf1d107717567e178fa5a1caa8a7feb0154253126f6eb25be19'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Main passes the audio callback. The device wrapper sends it to slot 0
        # through the registration function installed by the SDK initializer.
        0x800C2700: (0x3C04800C, 0x24842988, 0x0C054F5E, 0),
        0x80153D7C: (0x3C028018, 0x8C428398, 0x00802821, 0xAFBF0010, 0x8C420014, 0, 0x0040F809, 0x00002021),
        0x80153F14: (0x0C0551FF, 0xA602FFC4, 0x3C038018, 0x8C638398, 0x0C055155, 0xAC620014),
        0x80154800: (0x3C048018, 0x248483D8),
        0x80154824: (0x0C05523F, 0x34050008, 0x3C058015, 0x24A54854, 0x0C054F46,
                     0x00002021, 0x3C028015, 0x244248D0),
        0x8015486C: (0x3C108018, 0x261083D8),
        0x80154890: (0x8E020000, 0, 0x10400003, 0x26100004, 0x0040F809, 0, 0x26310001, 0x2A220008, 0x1440FFF6),
        0x801548D0: (0x3C028018, 0x244283D8, 0x00042080, 0x00822021),
        0x801548F0: (0xAC850000,),
        0x8015490C: (0xAC800000, 0x2442FFFF, 0x1443FFFD, 0x24840004),
        # The loop clears the flag. The callback ticks only on flag == 1;
        # both callback branches set the flag. The main tail ticks every time.
        0x800C2880: (0x3C018018, 0xAC208F50),
        0x800C2988: (0x3C028018, 0x8C428F50),
        0x800C299C: (0x34100001, 0x14500003, 0, 0x0C030C49, 0, 0x3C018018, 0xAC308F50, 0x2402FFFF),
        0x800C2964: (0x0C030C49, 0, 0x080309C6, 0),
        # Both routes reach the worker. Only extra flag 1 calls the optional
        # routine. Its second argument comes from the call's delay slot.
        0x800C312C: (0x0C0324E2, 0),
        0x800C9390: (0x0C057847, 0, 0x3C038018, 0x90639BF6, 0x34020001, 0x14620003,
                     0x34040001, 0x0C058B26, 0x3C0500C0),
    })
    assert M.mword(0x80178398) == 0x80178378
    print('PASS: static audio registration, eight-slot dispatch, callback flag and unconditional main-tail tick')


if __name__ == '__main__':
    check()
