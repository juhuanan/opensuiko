#!/usr/bin/env python3
"""The engine's sine table and trig API — regression guard.

The battle is pseudo-3D (user: "there is going to be some trigonometry that gets
done to make the 2d art look 3d"), so the trig primitive is load-bearing
knowledge for the port. Three table values pin the scale exactly against
math.sin, which is what makes "angle unit 0x1000 = full turn, 4096 = 1.0" a
measurement rather than a reading.

Run directly:  .venv/bin/python kit/tests/test_engine_trig.py
"""
import math
import os
import struct
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FAILED = []
CHECKS = [0]


def check(name, cond, detail=""):
    CHECKS[0] += 1
    if cond:
        print("ok   %s" % name)
    else:
        print("FAIL %s %s" % (name, detail))
        FAILED.append(name)


def table():
    with open(os.path.join(KIT, "work", "mainexe_code.bin"), "rb") as f:
        body = f.read()
    off = 0x801765BC - 0x800C0800
    return [struct.unpack_from("<h", body, off + 2 * i)[0] for i in range(1025)]


def test_sine_table_is_a_quarter_wave_amplitude_4096():
    v = table()
    check("1025 entries, first is 0", v[0] == 0, v[0])
    check("90 deg (index 1024) is 4096", v[1024] == 4096, v[1024])
    check("monotone non-decreasing", all(v[i] >= v[i - 1] for i in range(1, 1025)))
    check("never exceeds the amplitude", max(v) == 4096, max(v))
    for idx, deg in ((256, 22.5), (512, 45.0), (768, 67.5), (1024, 90.0)):
        want = round(4096 * math.sin(math.radians(deg)))
        check("index %d (%g deg) == %d" % (idx, deg, want), v[idx] == want,
              "%d vs %d" % (v[idx], want))


def test_trig_api_shape():
    """0x80150810 handles the sign; 0x8015084C is the folded lookup."""
    with open(os.path.join(KIT, "work", "mainexe_code.bin"), "rb") as f:
        body = f.read()

    def word(addr):
        return struct.unpack_from("<I", body, addr - 0x800C0800)[0]

    check("0x80150810 opens with a stack frame",
          word(0x80150810) == 0x27BDFFE8, hex(word(0x80150810)))
    check("0x80150810 branches on a negative angle",
          word(0x80150814) >> 26 == 0x01 and ((word(0x80150814) >> 16) & 0x1F) == 0,
          hex(word(0x80150814)))
    check("0x8015084C is the raw lookup (reads the table)",
          word(0x80150860) == 0x3C018017, hex(word(0x80150860)))
    check("the lookup masks the angle to 12 bits",
          word(0x80150820) == 0x30840FFF, hex(word(0x80150820)))


if __name__ == "__main__":
    test_sine_table_is_a_quarter_wave_amplitude_4096()
    test_trig_api_shape()
    print()
    print("%d passed, %d failed" % (CHECKS[0] - len(FAILED), len(FAILED)))
    sys.exit(1 if FAILED else 0)
