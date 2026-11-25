#!/usr/bin/env python3
"""Static source checks and independent gain vectors for the complete level-up helper."""
from hashlib import sha256
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import character_table as CT
import growth_rules as GR
import maindec as M
from mipsdec import jtarget
from test_canonical_start import assert_main_words


def growth_source_tables():
    body = M.body()
    start, end = 0x800E9CC4, 0x800E9E90
    selector = body[0x800E9C28-M.MBASE:start-M.MBASE]
    level_up = body[start-M.MBASE:end-M.MBASE]
    assert sha256(selector).hexdigest() == '2875529b647e36baa90d98db3fec89ab04e7a717afd8ae545ee71cc9a08d9fc7'
    assert sha256(level_up).hexdigest() == 'd0af65bb87a3dbb927152e538f023b9088ee1202ff941c09cbd7567bb46f26d3'

    assert_main_words({
        # The tier helper distinguishes rates 9–10 and 14 from the ordinary tiers.
        0x800E9C28: (0x28A20009, 0x14400017, 0x28820014, 0x28A2000B, 0x14400006,
                     0x2882000F, 0x3402000E, 0x10A2000A, 0x2882003C),
        0x800E9C70: (0x14400012, 0x3402002A, 0x28820050, 0x1440000F, 0x3402002B),
        # Stop at 99 before making a draw or writing any record bytes.
        0x800E9CE8: (0x00809821, 0x9262000D, 0, 0x2C420063, 0x1040005B, 0x00009021),
        # S3 retains the record pointer. S1 advances once per stat for six stats.
        0x800E9D0C: (0x92740018, 0x02608821, 0x24420001, 0xA262000D, 0x9275000D, 0x92250018),
        0x800E9DA8: (0xA2220010, 0x26520001, 0x2A420006, 0x1440FFDA, 0x26310001),
        # Positive RNG draws use the low eight bits for stats and nine for HP.
        0x800E9D58: (0x00051203, 0x8C630000, 0x00021200, 0x00821023, 0x00431021),
        0x800E9E18: (0x00051243, 0x8C630000, 0x00021240, 0x00821023, 0x00431021),
    })
    calls, reads, writes = [], [], []
    for address, (word,) in zip(range(start, end, 4), struct.iter_unpack('<I', level_up), strict=True):
        op, base, off = word >> 26, (word >> 21) & 31, word & 0xFFFF
        if op == 3:
            calls.append((address, jtarget(address, word)))
        if base in (17, 19):  # S1 is the indexed record alias and S3 holds the base.
            if 0x20 <= op <= 0x26:
                reads.append((base, off))
            if 0x28 <= op <= 0x2E:
                writes.append((base, off))
    assert calls == [(0x800E9D24, 0x800E9C28), (0x800E9D2C, 0x80147E38), (0x800E9DF0, 0x80147E38)]
    assert reads == [(19, 13), (19, 13), (19, 24), (19, 13), (17, 24), (17, 16), (17, 16),
                     (19, 4), (19, 6)]
    assert writes == [(19, 13), (17, 16), (19, 4), (19, 6)]
    stats = struct.unpack_from('<48I', body, 0x8016BEC8-M.MBASE)
    hp = struct.unpack_from('<48I', body, 0x8016BE08-M.MBASE)
    return stats, hp


def source_level_up(raw, randoms, stats, hp):
    out = bytearray(raw)
    if raw[13] >= 99:
        return out
    level = raw[13] + 1
    out[13] = level
    for i in range(6):
        rate = raw[24 + i]
        lower, upper = (60, 80) if rate == 14 else (15, 60) if rate in (9, 10) else (20, 60)
        tier = int(level >= lower) + int(level >= upper)
        gain = (stats[3*rate + tier] + (randoms[i] & 255)) // 256
        out[16 + i] = min(255, raw[16 + i] + gain)
    rate = raw[24]
    tier = int(level >= 20) + int(level >= 60)
    gain = (hp[3*rate + tier] + (randoms[6] & 511)) // 256
    for off in (4, 6):
        value = (int.from_bytes(raw[off:off+2], 'little') + gain) & 65535
        out[off:off+2] = value.to_bytes(2, 'little')
    return out


def check():
    stats, hp = growth_source_tables()
    cases = 0

    def run(raw, randoms):
        nonlocal cases
        actual = bytearray(raw)
        values = iter(randoms)
        GR.level_up(actual, lambda: next(values))
        assert actual == source_level_up(raw, randoms, stats, hp), (raw[13], list(raw[24:31]))
        assert list(values) == (randoms if raw[13] >= 99 else [])
        allowed = {13, *range(4, 8), *range(16, 22)} if raw[13] < 99 else set()
        assert all(actual[i] == raw[i] for i in range(80) if i not in allowed)
        cases += 1

    # All growth classes and every valid level cover every tier and both clamps.
    for rate in range(16):
        for level in range(1, 100):
            for random in (0, 255, 32767):
                raw = bytearray(range(80))
                raw[13] = level
                raw[16:22] = bytes((0, 1, 127, 250, 254, 255))
                raw[24:30] = bytes((rate, (rate+1) % 16, (rate+2) % 16,
                                    (rate+3) % 16, (rate+4) % 16, (rate+5) % 16))
                raw[23], raw[30], raw[78], raw[79] = 0xA5, 0xFF, 0x34, 0x12
                run(raw, [random] * 7)

    # Real records, independently sliced; vary each disputed byte through all values.
    image = CT.image()
    randoms = [0, 1, 127, 255, 256, 32767, 511]
    for row in range(78):
        raw = image[CT.IMAGE_OFF + 80*row:CT.IMAGE_OFF + 80*(row+1)]
        run(raw, randoms)
    raw = bytearray(image[CT.IMAGE_OFF:CT.IMAGE_OFF + 80])
    for off in (23, 30, 78, 79):
        for value in range(256):
            changed = raw[:]
            changed[off] = value
            run(changed, randoms)
    print(f'PASS: static level-up access and RNG audit, {cases} independent 80-byte vectors')


if __name__ == '__main__':
    check()
