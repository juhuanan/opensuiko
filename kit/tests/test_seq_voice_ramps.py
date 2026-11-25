#!/usr/bin/env python3
"""Static voice ramp checks and independent integer transition cases."""
from hashlib import sha256
from itertools import product
from pathlib import Path
import random
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import maindec as M
from test_canonical_start import assert_main_words


def signed(value):
    return ((value + 32768) & 65535) - 32768


def quotient(a, b):
    return (abs(a) // abs(b)) * (-1 if (a < 0) != (b < 0) else 1)


def setup(previous, start, target, duration):
    if start == target:
        return list(previous)
    if abs(start - target) < duration:
        period = quotient(duration, start - target)
        return [1, 1, period, period, start, target]
    return [1, quotient(start - target, duration), 0, previous[3], start, target]


def step(fields):
    _, delta, period, count, current, target = fields
    if period:
        fields[3] = signed(count - 1)
        if count > 0:
            return False
        fields[3] = period
    current = signed(current + delta)
    if (delta > 0 and current >= target) or (delta < 0 and current <= target):
        current = target
        fields[0] = 0
    fields[4] = current
    return True


def registers(level, pan, volumes, pans, mono):
    bank, program, tone = volumes
    value = bank * 16383 * level // 16129
    value = value * program * tone // 16129
    left = right = value
    for p in (*pans, pan):
        if p < 64:
            right = right * p // 64
        else:
            left = left * (127 - p) // 64
    if mono:
        left = right = max(left, right)
    return left, right



def check_source():
    for start, end, digest in (
        (0x801597E0, 0x80159888, 'c1d158df5148952d42ebc44f34b4f00aa8a418a086cfa39cd2808bbd8e6ad965'),
        (0x8015600C, 0x801561C4, 'b5500ac527e109a5867ef6b19f78f8a6ce1215112c8e81f043af80e09e4c5351'),
        (0x80156550, 0x80156708, '5c300c81ef48d30b1d2129b13f6cfa1f2fa43e5ed4230f2d4d2f52b3b2d1b667'),
        (0x801561C4, 0x80156550, 'f480705533158fbf2ebcf4a8ac43c52cb27f6c3cfa1ce5905b540c76ef0f6b7a'),
        (0x80156708, 0x80156A88, '3ac4dc30d371b11579326e58b68fa3be5852e1717b688e03094466255d25277c'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # Both wrappers accept voices 0..23 and sign-extend the endpoints and duration.
        0x801597E4: (0x3082FFFF, 0x2C420018, 0x14400003, 0xAFBF0010, 0x08056609, 0x2402FFFF),
        0x80159818: (0x0C055803, 0x00073C03, 0x00001021),
        0x80159838: (0x3082FFFF, 0x2C420018, 0x14400003, 0xAFBF0010, 0x0805661E, 0x2402FFFF),
        0x8015986C: (0x0C055954, 0x00073C03, 0x00001021),
        # Equal endpoints skip all writes. Both writer paths distinguish
        # abs(start-target) from the signed start-minus-target quotient.
        0x80156028: (0x10A60064,),
        0x80156080: (0x00A61023, 0x04400005, 0x0043102A),
        0x801560C0: (0x00621823, 0x0083001A),
        0x8015656C: (0x10A60064,),
        0x801565C4: (0x00A61023, 0x04400005, 0x0043102A),
        0x80156604: (0x00621823, 0x0083001A),
        # A zero duration with unequal endpoints reaches the divide-by-zero trap.
        0x8015615C: (0x0082001A, 0x14400002, 0, 0x0007000D),
        0x801566A0: (0x0082001A, 0x14400002, 0, 0x0007000D),
        # Both use the old signed countdown for the wait decision.
        0x80156210: (0x2443FFFF, 0x00021400, 0x3C018018, 0x2421A586,
                     0x00250821, 0xA4230000, 0x1C4000C6),
        0x80156754: (0x2443FFFF, 0x00021400, 0x3C018018, 0x2421A592,
                     0x00250821, 0xA4230000, 0x1C4000C3),
        0x801562B8: (0x0043102A, 0x14400017),
        0x801567FC: (0x0043102A, 0x14400017),
        # Store scratch and both linear volume halfwords, then set both dirty bits.
        0x8015634C: (0xA023C148,),
        0x80156890: (0xA027C149,),
        0x8015650C: (0xA4260000,),
        0x8015652C: (0xA4250000, 0x34420003),
        0x80156A44: (0xA4260000,),
        0x80156A64: (0xA4250000, 0x34420003),
        # The sampler calls volume, then pan, then consumes the dirty bits.
        0x80157530: (0x0C055871,),
        0x80157554: (0x0C0559C2,),
        0x80157564: (0x26100001, 0x2A020018, 0x1440FFE9),
        0x80157594: (0x90A20000,),
    })


def check_timing():
    updates = waits = cases = 0
    examples = ((0, 100), (100, 0), (0, 10), (10, 0), (63, 64), (64, 63), (80, 80))
    for (start, target), duration in product(examples, (-100, -10, 1, 10, 100)):
        previous = [7, -3, 2, 19, 55, 44]
        fields = setup(previous, start, target, duration)
        cases += 1
        if start == target:
            assert fields == previous
            continue
        remaining = start - target
        slow = abs(remaining) < duration
        period = int(duration / remaining) if slow else 0
        delta = 1 if slow else int(remaining / duration)
        assert fields == [1, delta, period, period if slow else previous[3], start, target]
        stride = max(0, period) + 1
        for elapsed in range(1, 161):
            changed = step(fields)
            advances, position = divmod(elapsed, stride)
            current = signed(start + advances * delta)
            clamped = advances > 0 and delta != 0 and (current - target) * delta >= 0
            assert changed == (position == 0)
            countdown = fields[3]
            if period > 0:
                assert countdown == period - position
            else:
                assert countdown == (period if period else previous[3])
            assert fields == [int(not clamped), delta, period, countdown, target if clamped else current, target]
            updates += 1
            waits += int(not changed)
            if clamped:
                break
    # The first shared update uses the new volume and then the new pan.
    volume = setup([0] * 6, 100, 80, -10)
    pan = setup([0] * 6, 64, 100, -10)
    assert step(volume) and step(pan) and (volume[4], pan[4]) == (98, 67)
    return cases, updates, waits


def check_linear_levels():
    def constant(pc):
        return ((M.mword(pc) & 0xFFFF) << 16) | (M.mword(pc + 4) & 0xFFFF)

    rng = random.Random(0x1561C4)
    for first, second, pan_left, pan_right in (
        (0x8015636C, 0x801563B0, 0x801563F4, 0x8015640C),
        (0x801568B0, 0x801568F4, 0x80156938, 0x80156950),
    ):
        signed_factor = constant(first) - (1 << 32)
        unsigned_factor = constant(second)
        shift = (M.mword(pan_left) >> 6) & 31
        assert (M.mword(pan_right) >> 6) & 31 == shift == 6
        for _ in range(256):
            volumes = tuple(rng.randrange(128) for _ in range(3))
            tone_pan, program_pan, pan = (rng.randrange(128) for _ in range(3))
            level, mono = rng.randrange(128), bool(rng.randrange(2))
            bank, program, tone = volumes
            amount = bank * 16383 * level
            gain = (amount + (amount * signed_factor >> 32)) >> 13
            amount = gain * program * tone
            high = amount * unsigned_factor >> 32
            gain = (high + ((amount - high) >> 1)) >> 13
            left = right = gain
            for p in (tone_pan, program_pan, pan):
                if p < 64:
                    right = (right * p) >> shift
                else:
                    left = (left * (127 - p)) >> shift
            actual = (max(left, right),) * 2 if mono else (left, right)
            assert actual == registers(level, pan, volumes, (tone_pan, program_pan), mono)


def check():
    check_source()
    cases, updates, waits = check_timing()
    check_linear_levels()
    print(f'PASS: static ramp writer and worker paths, {cases} setup inputs, '
          f'{updates} modeled transitions ({waits} waits), and 512 linear gain cases')


if __name__ == '__main__':
    check()
