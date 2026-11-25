#!/usr/bin/env python3
"""Static contracts for the boot prefix, fixed state, heap and save copy."""
import hashlib

from test_canonical_start import assert_main_words, boot_seed
import maindec as M
from mipsdec import jtarget, sx16

GS = 0x801B8000
SAVED_BYTES = 0x1D60


def assert_span(start, end, digest):
    data = M.body()[start - M.MBASE:end - M.MBASE]
    assert hashlib.sha256(data).hexdigest() == digest, hex(start)


def stores(start, end):
    """Read store operands as (PC, base register, displacement, width)."""
    widths = {0x28: 1, 0x29: 2, 0x2B: 4}
    for pc in range(start, end, 4):
        word = M.mword(pc)
        if word >> 26 in widths:
            yield pc, (word >> 21) & 31, sx16(word), widths[word >> 26]


def write_offsets(sites, base):
    return {byte for _, register, offset, width in sites if register == base
            for byte in range(offset, offset + width)}


def calls(start, end):
    return {pc: jtarget(pc, word) for pc in range(start, end, 4)
            if (word := M.mword(pc)) >> 26 == 3}


def check_initializer():
    assert_span(0x800C2BA8, 0x800C2BD4, 'dbb7e99a8593e76940635f27b433d2a98fd568d8b021e9a560a043c00b73b0cc')
    assert_span(0x800C9440, 0x800C9700, '2d209e6ab2da93d932231083d04cceb79981432982e2a4854262cf142bdb6f38')
    assert_span(0x8014AE9C, 0x8014AEB0, '5fe09f0b8bc08dd341e5c87ce9a4359a1b8cca961a724cd3dcc5cc8d98a78032')
    assert_span(0x8014ADE8, 0x8014AE10, 'fcdca7b15c897b6a45abd55123beacedb1f8f0af5beb69053c24be63b3f45784')
    assert_span(0x8014AE10, 0x8014AE38, '83294855578aec9911c4a3aecae4e8458e0c8c56b9a71f37ee944e54cf40bc8a')
    assert_span(0x8014AB0C, 0x8014ABD4, '3a88772c86d58b79f83f1c9835f9a44ee1981e57ca7e95120f28a82325679023')
    assert_span(0x80148250, 0x80148260, '2a3d0228a9c47f9f6fe1135e3d44802455b19f39c1ea9243971399c6160aee32')
    assert_main_words({
        # Callback publication, fixed GS publication and an independent literal consumer.
        0x800C2BB0: (0x3C02800D, 0x24429440, 0x3C018018, 0xAC22DA90),
        0x800C946C: (0x3C02801B, 0x34428000, 0x3C018018, 0xAC22DB24),
        0x800C49CC: (0x3C05801B, 0x34A58000),
        0x8014AE9C: (0x34020009, 0xA0820003, 0x3402002C, 0x03E00008, 0xA0820007),
        # Each column walks two banks. The final XY store is in the branch slot.
        0x800C9548: (0x263100C8,),
        0x800C9598: (0x2A221D5C, 0x1440FFC6, 0xA6090022, 0x26730028,
                     0x26520001, 0x2A420005, 0x1440FFBE, 0x26940040),
        # Tail bytes form 80000000. Mode words are zero and the two pointers are fixed.
        0x800C95C0: (0x34020080, 0xA0621D5F),
        0x800C95D8: (0xA0401D5E,),
        0x800C95F4: (0xA4801D5C, 0xAC801BB8, 0xAC801BBC),
        0x800C960C: (0x3C028016, 0x24425608, 0xAC821BC4, 0x3C028018, 0x2442DA90, 0xAC821BC8),
        # Six 4-byte context pointers, advancing from 8019A000 by 5000.
        0x800C9654: (0xAC851B9C, 0x24A55000, 0x26520001, 0x2A420006, 0x1440FFFB, 0x24840004),
        # Sound is the external dispatch boundary. Volume and callback slot have separate destinations.
        0x800C9678: (0x90421B92, 0, 0x10400003, 0, 0x0C030C41, 0x34040001),
        0x800C969C: (0x90431B93, 0x3C048017, 0x8C84A0E4),
        0x800C96B4: (0xA4830018, 0x00172080, 0x3C03800D, 0x24639700,
                     0x3C018018, 0x2421DA90, 0x00240821, 0xAC230000),
    })
    assert calls(0x800C9440, 0x800C9700) == {
        0x800C9488: 0x800C2EA8, 0x800C94CC: 0x8014AE9C, 0x800C94D8: 0x8014ADE8,
        0x800C94E4: 0x8014AE10, 0x800C94F8: 0x8014AB0C, 0x800C9688: 0x800C3104,
    }
    assert set(calls(0x8014AB0C, 0x8014ABD4).values()) == {0x80148250}
    assert all(base == 29 for _, base, _, _ in stores(0x8014AB0C, 0x8014ABD4))
    assert not list(stores(0x80148250, 0x80148260))
    packet_bytes = write_offsets(stores(0x800C94B8, 0x800C95A4), 16)
    for start, end in [(0x8014AE9C, 0x8014AEB0), (0x8014ADE8, 0x8014AE10), (0x8014AE10, 0x8014AE38)]:
        packet_bytes |= write_offsets(stores(start, end), 4)
    assert packet_bytes == {3, 7, *range(8, 14), *range(16, 30), *range(32, 38)}
    first = M.mword(0x800C94B4) & 0xFFFF
    banks = range(first, sx16(M.mword(0x800C9598)), sx16(M.mword(0x800C9548)))
    columns = range(0, sx16(M.mword(0x800C95AC)) * 0x28, sx16(M.mword(0x800C95A4)))
    assert len(banks) == 2 and len(columns) == 5
    footprint = {bank + column + offset for bank in banks for column in columns for offset in packet_bytes}
    # The tail stores at 95C4/95D8 use separate GS aliases. A0 then holds GS
    # until it advances through the six context slots; later A0 is the UI pointer.
    footprint |= write_offsets(stores(0x800C95C4, 0x800C95C8), 3)
    footprint |= write_offsets(stores(0x800C95D8, 0x800C95DC), 2)
    footprint |= write_offsets(stores(0x800C95F4, 0x800C9624), 4)
    context = next(stores(0x800C9654, 0x800C9658))
    context_count = sx16(M.mword(0x800C9660))
    footprint |= set(range(context[2], context[2] + context[3] * context_count))
    expected = {0x1BCC + column * 0x28 + bank * 0xC8 + byte
                for column in range(5) for bank in range(2) for byte in packet_bytes}
    expected |= {*range(0x1B9C, 0x1BB4), *range(0x1BB8, 0x1BC0), *range(0x1BC4, 0x1BCC),
                 *range(0x1D5C, 0x1D60)}
    assert footprint == expected
    assert len(footprint) == 324
    assert max(footprint) == SAVED_BYTES - 1
    assert [pc for pc, _, _, _ in stores(0x800C9440, 0x800C9700) if pc >= 0x800C966C] == [
        0x800C96B0, 0x800C96B4, 0x800C96D0,
    ]
    x0, y0 = (sx16(M.mword(pc)) for pc in (0x800C94A0, 0x800C9510))
    dx, dy = (sx16(M.mword(pc)) for pc in (0x800C9574, 0x800C9584))
    assert (x0, y0, dx, dy) == (-160, -120, 64, 240)
    assert [x0 + dx * i for i in range(len(columns) + 1)] == [-160, -96, -32, 32, 96, 160]
    context_first = ((M.mword(0x800C95D4) & 0xFFFF) << 16) | (M.mword(0x800C95EC) & 0xFFFF)
    context_step = sx16(M.mword(0x800C9658))
    assert [context_first + i * context_step for i in range(context_count)] == [
        0x8019A000, 0x8019F000, 0x801A4000, 0x801A9000, 0x801AE000, 0x801B3000,
    ]


def check_heap():
    assert_span(0x800C2D30, 0x800C2DC0, 'e097a2410cdcabb986f6e2b22bcc620b8195180ee749afb2b7ea26377b617cf4')
    assert_span(0x800C2EA8, 0x800C2EF8, 'f87a47fb9b3074142ec00a979782b62f280811671bcf7be232afab45d2037d6e')
    assert_main_words({
        0x800C2BC0: (0x3C048018, 0x34842000, 0x3C050001, 0x0C030BAA, 0x34A58000),
        0x800C947C: (0x3C048018, 0x34842000, 0x3C050001, 0x0C030BAA, 0x34A58000),
        0x800C9A00: (0x0C030BB0, 0, 0x3C030001, 0x34638000, 0x10430005,
                     0x3C048018, 0x34842000, 0x3C050001, 0x0C030BAA, 0x34A58000),
        0x800C2EA8: (0x3C018016, 0xAC243D58, 0xAC840000, 0x000528C2, 0x03E00008, 0xAC850004),
        0x800C2EF0: (0x03E00008, 0x000410C0),
    })
    assert list(stores(0x800C2EA8, 0x800C2EF8)) == [
        (0x800C2EAC, 1, 0x3D58, 4), (0x800C2EB0, 4, 0, 4), (0x800C2EBC, 4, 4, 4),
    ]
    # For the one free block established by reset, allocation removes a
    # rounded payload and one header unit. The query traverses that same list.
    heap_base = 0x80182000
    shift = (M.mword(0x800C2EB4) >> 6) & 31
    size = 0x18000
    assert heap_base + size <= GS
    assert size >> shift == 0x3000
    align = sx16(M.mword(0x800C2D30))
    header = sx16(M.mword(0x800C2D40))
    for size_requested, free in [(0, 0x17FF8), (1, 0x17FF0), (0x100, 0x17EF8), (0x1000, 0x16FF8)]:
        used = ((size_requested + align) >> shift) + header
        assert size - (used << shift) == free
        assert heap_base + free + 8 == heap_base + size - 8 * ((size_requested + 7) // 8)


def check_party_and_save():
    assert_span(0x800C4AFC, 0x800C4B94, '3d5eac65e5999716536f69547e951df3497b6a186c1b721a767283ff62f0e946')
    assert_span(0x800C4BFC, 0x800C4CC8, '7216778ee808c2b3008a7efc5cb7a29d5f0ffd7b60196a674dd0556dd3258ba7')
    assert_main_words({
        # Both removals compare against the order list, shift from the following byte,
        # and decrement only on a match. Only 4AFC clears the occupant slot.
        0x800C4B1C: (0x9042000E, 0, 0x1482000D, 0x24A60001, 0x00C7102A, 0x10400010),
        0x800C4B38: (0x9043000F, 0x00C02821, 0x24A60001, 0xA043000E, 0x00C7102A, 0x1440FFFA),
        0x800C4B6C: (0x080312E3, 0x2402FFFF, 0x24E7FFFF, 0xA1070003, 0x01041821, 0x2402FFFF, 0xA0620008),
        0x800C4C50: (0x9042000E, 0, 0x1482000E, 0, 0x24A40001, 0x0086102A, 0x10400010),
        0x800C4C70: (0x9043000F, 0x00802821, 0x24A40001, 0xA043000E, 0x0086102A, 0x1440FFFA),
        0x800C4CA4: (0x08031330, 0x2402FFFF, 0x90E20003, 0, 0x2442FFFF, 0xA0E20003, 0x304200FF),
        # Append increments the count before indexing at +0D (old count +0E).
        0x800C4C08: (0x24420001, 0x3C01801C, 0xA0228003, 0x3C02801C, 0x90428003, 0x3C03801B,
                     0x34638000, 0x00431821, 0x03E00008, 0xA064000D),
        # Save first copies UI volume into GS, then uses an unsigned index
        # bound. The back edge advances the source pointer in its delay slot.
        0x80129CB0: (0x34061D60, 0x3C028017, 0x8C42A0E4, 0x00002021, 0x3C038018, 0x8C63DB24,
                     0x90420018, 0x3C05801B, 0x34A58000, 0xA0621B93, 0x90A20000, 0x3C038018,
                     0x8C63A0D8, 0, 0x00831821, 0xA0620284, 0x24840001, 0x0086102B,
                     0x1440FFF7, 0x24A50001),
    })
    assert [(pc, offset) for pc, base, offset, _ in stores(0x800C4AFC, 0x800C4B94) if base != 29] == [
        (0x800C4B44, 0xE), (0x800C4B78, 3), (0x800C4B84, 8),
    ]
    assert [(pc, offset) for pc, base, offset, _ in stores(0x800C4BFC, 0x800C4CC8) if base != 29] == [
        (0x800C4C10, -0x7FFD), (0x800C4C2C, 0xD), (0x800C4C7C, 0xE), (0x800C4CB8, 3),
    ]
    prefix = M.mword(0x80129CB0) & 0xFFFF
    dest = sx16(M.mword(0x80129CEC))
    assert prefix == SAVED_BYTES
    assert GS + prefix == 0x801B9D60
    assert (dest, dest + prefix - 1) == (0x284, 0x1FE3)
    assert sx16(M.mword(0x80129CD4)) < prefix


def check():
    seed = boot_seed()
    assert len(seed) == SAVED_BYTES
    assert hashlib.sha256(seed).hexdigest() == 'ae222f2b92040fdf7c6bf8068120d044633cf8bde27669aaa7fecdeef1cb58e7'
    check_initializer()
    check_heap()
    check_party_and_save()
    print('PASS: static boot prefix, 324 GS initializer byte offsets, heap reset, party mutators and save window')


if __name__ == '__main__':
    check()
