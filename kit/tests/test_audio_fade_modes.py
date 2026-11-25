#!/usr/bin/env python3
"""Static queue, fade timing and audio register contracts from MAIN.EXE."""
from hashlib import sha256
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import maindec as main
from export_defeat_audio import contract as defeat_contract


def check_words(words):
    for address, expected in words.items():
        assert main.mword(address) == expected, hex(address)


def check_spans(spans):
    image = main.body()
    for start, end, expected in spans:
        assert sha256(image[start - main.MBASE:end - main.MBASE]).hexdigest() == expected, hex(start)


def jump_target(pc, opcode):
    word = main.mword(pc)
    assert word >> 26 == opcode, hex(pc)
    return ((pc + 4) & 0xF0000000) | ((word & 0x03FFFFFF) << 2)


def check_dispatch():
    check_spans((
        (0x800C8B70, 0x800C8C74, 'f499f59b16c7d19b0b06244615b66f7943e8790336a5cadbc8e220cc334814d4'),
        (0x800C4FE0, 0x800C50E4, 'eb3df1f34b5a581b35190f6108e22c63d8d4c3c3a0d9bbfa43a8ad88572eaabd'),
        (0x800C70A4, 0x800C71B0, '1c4f38ab975c3bec424a0740d8205cd6db93b8547d253bddcba36c56e77983d1'),
        (0x800C71B0, 0x800C7228, '58cc40a8f86b123e7bc9c560944296eb3a89abd85814ba2376eecf92f10f7f8b'),
    ))
    check_words({
        0x800C8B74: 0x90639CB8, 0x800C8B8C: 0x3402000C, 0x800C8B90: 0x0043102B,
        0x800C8B94: 0x14400037, 0x800C8BA4: 0x24210D50, 0x800C8BB4: 0x00400008,
        0x800C30CC: 0x0C0322DC, 0x800C5598: 0x0C0322DC,
        0x800C4FE4: 0x00041202, 0x800C4FE8: 0x304300FF, 0x800C5004: 0x24210800,
        0x800C0840: 0x800C50A8, 0x800C0880: 0x800C50C0,
        0x800C50B4: 0x34050001, 0x800C50C8: 0x34050001, 0x800C50D0: 0x34060001,
    })
    workers = (0x800C6174, 0x800C6440, 0x800C7A24, 0x800C6288, 0x800C67C0, 0x800C881C,
               0x800C74B0, 0x800C728C, 0x800C693C, 0x800C6A38, 0x800C6DC0, 0x800C6DF0)
    epilogue = 0x800C8C74
    entries = [main.mword(0x800C0D50 + 4 * i) for i in range(13)]
    assert entries[0] == epilogue
    for entry, worker in zip(entries[1:], workers, strict=True):
        assert jump_target(entry, 3) == worker
        if entry + 8 != epilogue:
            assert jump_target(entry + 8, 2) == epilogue
    # Decode the unsigned default branch from the dispatch guard.
    assert 0x800C8B98 + 4 * (main.mword(0x800C8B94) & 0xFFFF) == epilogue

    # Command 0012 reaches mode 5 through family zero's argument table.
    check_words({
        0x800C0800: 0x800C501C, 0x800C513C: 0x2484FFFF, 0x800C5160: 0x24210888,
        0x800C5170: 0x00400008, 0x800C0888 + 4 * (0x12 - 1): 0x800C51B8,
    })
    assert jump_target(0x800C5020, 3) == 0x800C512C
    for caller, initializer, queue_call, mode in (
        (0x800C51B8, 0x800C67A0, 0x800C67A8, 5),
        (0x800C50B0, 0x800C690C, 0x800C6924, 9),
        (0x800C50CC, 0x800C6A00, 0x800C6A20, 10),
    ):
        assert jump_target(caller, 3) == initializer
        assert jump_target(queue_call, 3) == 0x800C70A4
        assert main.mword(queue_call + 4) == (0x34040000 | mode)


def check_fade_consumers():
    check_spans((
        (0x800C67A0, 0x800C690C, 'c1b7247f73749193ae5b5c33e8176c5b5d82ca27d331a1a5b2c6e2ce97f5034e'),
        (0x800C690C, 0x800C6A00, 'f0a3b21133563590c412384e9cb00898bc181bd32b4c62a5b01a7107de89c20d'),
        (0x800C6A00, 0x800C6C20, 'f06328ad7ae2cd56ecb671dc5ec1bae6ab70fc03cc01cd7406ca3f87bc9a5349'),
        (0x8015F61C, 0x8015F6D0, '99254fa0aaac058a669e942dcd29da67b06dcb68b3deafc9bfe261494cf555d3'),
        (0x8015F6F8, 0x8015FA00, '053d50dde70318d43151fcca67e0dbaa4a57d0fb6184c1a451e67578bd227e83'),
        (0x8016211C, 0x80162218, '8d1928b40e80afbf5f8c0eb9fe2b96a48026b9c67969200f5003f6371c68842d'),
    ))
    check_words({
        # Mode 5 sets busy, steps toward mute, disables mixing, polls and clears ownership.
        0x800C67DC: 0x90820000, 0x800C67E4: 0x10400041, 0x800C67FC: 0xA0329BEE,
        0x800C6850: 0x24A5FFFC, 0x800C6860: 0x0C057774, 0x800C6870: 0x28420002,
        0x800C6888: 0xA4209C08, 0x800C6894: 0x0C057774, 0x800C68A4: 0x0C057D87,
        0x800C68B8: 0x34040009, 0x800C68C0: 0x0C0324F1, 0x800C68C8: 0x304200FF,
        0x800C68E0: 0xA0209BEE, 0x800C68E4: 0xA0800000, 0x800C68E8: 0xA2200000,
        0x800C68EC: 0x0C031C6C, 0x8015F638: 0x34020200, 0x80162178: 0x31020200,
        0x801621C4: 0xA44301AA,
        # Mode 9 uses signed progress, a strict residual test and two ordered step arms.
        0x800C6918: 0xA0249BEF, 0x800C6920: 0xA0259BF7, 0x800C6954: 0x84A70000,
        0x800C6970: 0x0043102A, 0x800C697C: 0x0C031C6C, 0x800C69A0: 0x01021023,
        0x800C69A8: 0x84A20000, 0x800C69B4: 0x0043102A, 0x800C69C8: 0x00441021,
        0x800C69DC: 0xA4259C0A, 0x800C69E8: 0x0C057774,
        # Mode 10 leaves the adjacent byte alone, selects voices 22/23 and checks again after writing.
        0x800C6A0C: 0xA0249BF5, 0x800C6A14: 0xA0259BF7, 0x800C6A1C: 0xA0269BF8,
        0x800C6A6C: 0x84A20000, 0x800C6A8C: 0x0044102A, 0x800C6A98: 0x0C031C6C,
        0x800C6AAC: 0x90429BF7, 0x800C6AB4: 0x18400050, 0x800C6B18: 0xA6820000,
        0x800C6B20: 0x90639BE8, 0x800C6B24: 0x3402000F, 0x800C6B30: 0x3C020040,
        0x800C6B38: 0x3C020080, 0x800C6B68: 0x000211C0, 0x800C6B84: 0x00021180,
        0x800C6BA0: 0x0C057DB4, 0x800C6BB0: 0x0C057DB4, 0x8015F6E0: 0x0C057DBE,
        0x800C6BD8: 0x0044102A,
        0x800C6BDC: 0x14400006, 0x800C6BEC: 0x0202102A, 0x800C6BF0: 0x1440FFBA,
    })


def check_cd_gain():
    check_words({
        0x8015DDEC: 0x340200C0, 0x8015DDFC: 0x28420080, 0x8015DE08: 0x3407007F,
        0x8015DE10: 0x28420080, 0x8015DE1C: 0x3408007F, 0x8015DE2C: 0x000223C0,
        0x8015DE30: 0x00822023, 0x8015DE34: 0x00860018, 0x8015DE50: 0x00441021,
        0x8015DE54: 0x00021183, 0x8015DE58: 0x000427C3, 0x8015DE5C: 0x00441023,
        0x8015DE60: 0xA7A20020, 0x8015DE44: 0x00032BC0, 0x8015DE48: 0x00A32823,
        0x8015DE4C: 0x00A60018, 0x8015DE68: 0x00451021, 0x8015DE6C: 0x00021183,
        0x8015DE70: 0x00052FC3, 0x8015DE74: 0x00451023, 0x8015DE78: 0xA7A20022,
        0x8015DF18: 0x0C0587CC,
        0x801620F8: 0xA46201B0, 0x8016211C: 0xA46201B2,
    })
    # Recover the division multiplier from its LUI/ORI pair.
    upper, lower = main.mword(0x8015DE18) & 0xFFFF, main.mword(0x8015DE20) & 0xFFFF
    multiplier = (upper << 16 | lower) - (1 << 32)
    for volume in range(-32768, 32768):
        clamped = min(volume, 127)
        numerator = clamped * 32767
        high = (numerator * multiplier) >> 32
        reconstructed = ((high + numerator) >> 6) - (numerator >> 31)
        expected = abs(numerator) // 127
        assert reconstructed == (-expected if numerator < 0 else expected), volume


def check_defeat_and_frame_order():
    check_spans((
        (0x800C8CDC, 0x800C8DAC, 'f4c6ae020be4dae3db15ac065a0267ff9aa0a79229d2e3379ee08c5cd647f105'),
        (0x800C2948, 0x800C2978, '460eddb5491a4fcb003dfd71735d2719c0d2897052cbceacf77698d1ea2e4d16'),
    ))
    check_words({
        0x800C8C94: 0x90429BEB, 0x800C8C9C: 0x10400044, 0x800C8CB0: 0x1040003F,
        0x800C8CD0: 0x00431023, 0x800C8CDC: 0x0082202B, 0x800C8CE0: 0x10800033,
        0x800C8CEC: 0x90429BED, 0x800C8CF4: 0x14400021,
        # The no-repeat watchdog suppresses another stop already waiting behind the head.
        0x800C8D10: 0x24C69CB8, 0x800C8D14: 0x34050005, 0x800C8D2C: 0x90420000,
        0x800C8D34: 0x14450003, 0x800C8D4C: 0x2842001E, 0x800C8D64: 0x14400010,
        0x800C8D6C: 0x0C031C29, 0x800C8D70: 0x34040005,
        0x800C8DA0: 0x0C031C29, 0x800C8DA4: 0x34040002,
        0x800C295C: 0x0C030C31, 0x800C30CC: 0x0C0322DC,
        0x800C2964: 0x0C030C49, 0x800C312C: 0x0C0324E2,
        0x800C9390: 0x0C057847, 0x8015E160: 0x0C055CD7,
    })
    defeat = defeat_contract()
    assert (defeat['command'], defeat['timeout_ticks'], defeat['repeat']) == (0x0303, 768, False)
    active_after_timeout = [tick for tick in (767, 768, 769) if defeat['timeout_ticks'] < tick]
    assert active_after_timeout == [769]


def check_reference_dispatch_counts():
    # Start at 127 and count writes and the separate queue retirement dispatch.
    cd_step = main.mword(0x800C50B4) & 0xFFFF
    cd_writes = range(127 - cd_step, -1, -cd_step)
    assert (cd_writes[0], cd_writes[-1], len(cd_writes) + 1) == (126, 0, 128)

    stream_step = main.mword(0x800C50D0) & 0xFFFF
    gains = range(127 - stream_step, -1, -stream_step)
    updates_per_dispatch = 4
    batches = (len(gains) + updates_per_dispatch - 1) // updates_per_dispatch
    assert (batches + 1, len(gains) * 2) == (33, 254)

    delta = (main.mword(0x800C6850) & 0xFFFF) - 65536
    threshold = main.mword(0x800C6870) & 0xFFFF
    progress = 127
    gains = []
    while progress >= threshold:
        progress += delta
        gains.append(progress)
    assert (len(gains), gains[0], gains[-1]) == (32, 123, -1)
    polls = (1, 255, 0)  # Retained asynchronous readiness sequence.
    assert len(gains) + 1 + (polls.index(0) + 1) + 1 == 37


if __name__ == '__main__':
    check_dispatch()
    check_fade_consumers()
    check_cd_gain()
    check_defeat_and_frame_order()
    check_reference_dispatch_counts()
    print('PASS: 13 static audio routes, three fade workers, 65536 signed CD gain inputs, '
          'defeat timeout and frame ordering')
