#!/usr/bin/env python3
"""Static checks of voice allocation, release, sampling and register flush."""
from functools import reduce
from hashlib import sha256
from operator import and_
from pathlib import Path
import random
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(KIT / 'tools'), str(KIT / 'tools/seq')]
import maindec as M
from spu import allocate_voice, poll_voice_status, reset_voice_history
from test_canonical_start import assert_main_words


def check_source():
    for start, end, digest in (
        (0x80154C8C, 0x80154F08, 'dc299cf02139952e945a196112bccb830e79b276c1d2301fa1a6667fa73c5704'),
        (0x80157BE0, 0x80157DD8, '4ace388a874a16e70b1ce286dfcfeff5414308207f73d3173ea1f1f8467f5e5e'),
        (0x8015735C, 0x80157720, '5435e887698e68bc68b29546690a199175db0b4269af42ff8d264baef3a57f14'),
        (0x8015E11C, 0x8015E390, '4a75107c8ea903630578076a660f12e20687760b9963fa176abb92854b96e294'),
        (0x801552E0, 0x801553E8, '7769377bb6d498252f3eec4b82bb6841130531ac77e2f5561fc1cf3d28df3463'),
        (0x801553E8, 0x80155480, 'b8d028ddec894550c7c1974b65c1015b28aaaee83cdafe2252587d93a91762a3'),
        (0x8015B168, 0x8015B1B8, '4b5db88c6577f92ebcb163761fe5f8aa0900eb727522f97f38d0cfe7ffd57d66'),
        (0x8015B204, 0x8015B2B8, '83e3753d945ff9f40defa98639672297253d3954ddf6e49444e314b2981169ad'),
        (0x80161F30, 0x801620E8, 'db22ee9c1e2b1f2382fe63f8dd15bc58e9931b1cd4682afe5b96d2d0c42f004e'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)
    assert_main_words({
        # The first status-zero and envelope-zero voice wins. The occupied
        # path compares signed priority to the saved unsigned threshold.
        0x80154CE0: (0x90220000, 0, 0x1440000A),
        0x80154CFC: (0x94220000, 0, 0x14400003, 0x30E200FF, 0x08055380, 0x00E08021),
        0x80154D2C: (0x84260000, 0x3184FFFF, 0x00C4102A, 0x1040000D),
        0x80154D84: (0x94240000, 0, 0x0085102B),
        0x80154DC4: (0x84220000, 0, 0x00401821, 0x0102102A),
        0x80154E00: (0x320300FF, 0x34020063, 0x14620005, 0x314200FF, 0x14400003, 0x01208021),
        0x80154E68: (0x94230000, 0x00451021, 0x24630001, 0xA4430002),
        0x80154EA4: (0xA4200000,),
        0x80154EC0: (0xA4230000,),
        0x80154ED4: (0x34020002, 0x14620006, 0x320200FF, 0x3C0500FF, 0x34A5FFFF, 0x0C0582D6, 0x00002021),
        # Release filters original note, program, owner and bank separately.
        # The normal release clears status and sample fields, preserving level.
        0x80157C28: (0x2421A570, 0x00240821, 0x84230000, 0x30E2FFFF, 0x1462005E),
        0x80157C44: (0x2421A576, 0x00240821, 0x84220000, 0, 0x144D0057),
        0x80157C60: (0x2421A572, 0x00240821, 0x84220000, 0, 0x144C0050),
        0x80157C7C: (0x2421A57A, 0x00240821, 0x84220000, 0, 0x144B0049),
        0x80157CFC: (0x2C620010, 0x10400003, 0x006A3004, 0x08055F47, 0x00002821,
                     0x00003021, 0x2462FFF0, 0x004A2804),
        0x80157D34: (0xA0200000,),
        0x80157D54: (0xA4200000, 0x3C018018, 0x2421A568, 0x00220821, 0xA4200000),
        0x80157D78: (0xA423DCDC, 0x00031827, 0x00431024, 0x3C018018, 0xA422AAD0),
        0x80157D9C: (0xA424DCE0, 0x00042027, 0x00441024, 0x3C018018, 0xA422AAD4),
        # Sample envelope before checking 15 history slots. The rotation
        # itself spans all 16 slots, including the last one.
        0x80157394: (0x24420001, 0x3042000F, 0x3C018018, 0xAC22A9E8, 0x00021080,
                     0x00431021, 0x18800018, 0xAC400000),
        0x801573D4: (0x94A2000C, 0, 0xA4820000, 0x94820000, 0, 0x14400005, 0x24840030),
        0x80157414: (0x9042C208, 0, 0x1440002B),
        0x80157430: (0x8C620000, 0x26100001, 0x02429024, 0x2A02000F, 0x1440FFFB, 0x24630004),
        0x80157498: (0x0C0582D6, 0x34A5FFFF),
        0x801574AC: (0xA0200000,),
        # Apply both transition workers before the dirty register flush.
        0x80157530: (0x0C055871,),
        0x80157554: (0x0C0559C2,),
        0x80157564: (0x26100001, 0x2A020018, 0x1440FFE9),
        0x8015759C: (0x30420001, 0x10400009),
        0x801575B8: (0xA4430000, 0x94E30000, 0, 0xA4430002),
        0x801575D0: (0x30420004, 0x10400009),
        0x801575F8: (0xA4430004,),
        0x80157604: (0x30420008, 0x10400009),
        0x8015762C: (0xA4430006,),
        0x80157638: (0x30420010, 0x10400009),
        0x80157654: (0xA4430008, 0x95230000, 0, 0xA443000A),
        0x80157664: (0xA0A00000, 0x24A50001, 0x25290010, 0x25080010,
                     0x24840010, 0x3C028018, 0x2442A568, 0x00A2102A, 0x1440FFC3, 0x24C60010),
        # Previous key-off masks cancel pending key-on bits. Off/on commands
        # clear after flush, while the reverb-send image is retained.
        0x801574E0: (0x00021027, 0x00621824),
        0x80157504: (0x00021027, 0x00621824),
        0x801576C4: (0x3C018018, 0xA420DCDC, 0x3C018018, 0xA420DCE0, 0x3C018018, 0xA420AAD0,
                     0x3C018018, 0xA420AAD4, 0xA443018C, 0xA444018E, 0xA4450188, 0xA446018A,
                     0xA4470198, 0xA448019A),
        0x8015E150: (0x10430082, 0xAFB00020, 0x3C018018, 0xAC23BF78, 0x0C055CD7),
        0x8015E18C: (0x8C63C138, 0x02C21004, 0x00431024, 0x10400068),
        0x8015E1D4: (0x8C420090, 0, 0x30420001, 0x1040002C, 0x02802021, 0x00138C03, 0x0C057A2A),
        0x8015E354: (0x3C018018, 0xAC20BF78),
        # New notes set and cancel pending bits and clear the chosen bit in
        # all histories. Mode bit 4 controls the reverb-send mask.
        0x80155318: (0x30420004, 0x1040000D, 0x00061827),
        0x8015539C: (0x00C31825, 0x3C018018, 0xA423AAD0, 0x00031827, 0x00431024, 0x3C018018, 0xA422DCDC),
        0x801553C0: (0x00A42025, 0x3C018018, 0xA424AAD4, 0x00042027, 0x00441024, 0x3C018018, 0xA422DCE0),
        0x80155444: (0x34037FFF, 0x3C018018, 0x2421A56E, 0x00220821, 0xA4230000),
        0x80155460: (0x8CA30000, 0x00471004, 0x00021027, 0x00431024, 0xACA20000,
                     0x28C20010, 0x1440FFF7, 0x24A50004),
        # Startup configures 22 voices and gives each channel its own program,
        # centered pan and full volume. Master volume uses value * 129.
        0x800C55DC: (0x34040016,),
        0x800C5618: (0x0C056C5A, 0x3405007F),
        0x8015B214: (0x34080040, 0x00042400, 0x00042383, 0x3406007F),
        0x8015B298: (0x02031021, 0xA043002C, 0xA0480017, 0xA486004E,
                     0x24630001, 0x28620010, 0x1440FFF9, 0x24840002),
        0x8015B17C: (0x000411C0, 0x00441021),
        0x8015B190: (0x000511C0, 0x00451021, 0x27A40010, 0xAFBF0038, 0x0C0587CC, 0xA7A20016),
        0x80162008: (0xA4620180,),
        0x801620D4: (0xA4620182,),
    })


def check_allocation():
    rng = random.Random(0x154C8C)
    cases = 0
    for count in (0, 1, 2, 16, 22, 24):
        for _ in range(256):
            states = [dict(status=rng.randrange(3), level=rng.choice((0, 1, 100, 32767, 65535)),
                           priority=rng.choice((0, 1, 15, 99, 127, 255, 65535)),
                           age=rng.choice((0, 1, 32767, 32768, 65535))) for _ in range(count)]
            priority = rng.choice((0, 1, 15, 99, 127, 255))
            free = [i for i, voice in enumerate(states) if voice['status'] == voice['level'] == 0]
            if free:
                chosen = free[0]
            else:
                limit, envelope, age = priority, 65535, 0
                chosen, eligible = 99, False
                for i, voice in enumerate(states):
                    signed_priority = voice['priority'] - 65536 * (voice['priority'] >= 32768)
                    signed_age = voice['age'] - 65536 * (voice['age'] >= 32768)
                    eligible |= signed_priority <= limit
                    if (signed_priority, voice['level'], -signed_age) < (limit, envelope, -age):
                        chosen, limit, envelope = i, voice['priority'], voice['level']
                        # A lower priority/envelope loads age unsigned. A tie compares it signed.
                        age = voice['age']
                if not eligible:
                    chosen = count
            actual = [dict(voice) for voice in states]
            assert allocate_voice(actual, priority) == chosen, (states, priority, chosen)
            if chosen < count:
                for voice in states:
                    voice['age'] = (voice['age'] + 1) % 65536
                states[chosen].update(age=0, priority=priority)
            assert actual == states
            cases += 1
    return cases


def check_history():
    rng = random.Random(0x15735C)
    cases = 0
    for count in (0, 1, 16, 22, 24):
        for index in range(16):
            for inhibit in (False, True):
                for pattern in range(4):
                    history = [0xFFFFFFFF if pattern == 0 else 0 if pattern == 1 else
                               rng.getrandbits(24) for _ in range(16)]
                    if pattern == 3:
                        history = [0xFFFFFFFF] * 15 + [0]
                    levels = [0 if pattern in (0, 3) else rng.choice((0, 1, 32767, 65535)) for _ in range(count)]
                    states = [dict(status=i % 3, level=0xABCD) for i in range(count)]
                    expected_history = list(history)
                    slot = (index + 1) % 16
                    expected_history[slot] = sum(1 << i for i, level in enumerate(levels) if level == 0)
                    quiet = reduce(and_, expected_history[:15], 0xFFFFFFFF)
                    assert poll_voice_status(states, history, index, levels, inhibit) == slot
                    assert history == expected_history
                    assert states == [dict(status=0 if quiet & (1 << i) and not inhibit else i % 3, level=level)
                                      for i, level in enumerate(levels)]
                    cases += 1
    for voice in range(24):
        for pattern in range(4):
            history = [0 if pattern == 0 else 0xFFFFFFFF if pattern == 1 else
                       1 << voice if pattern == 2 else rng.getrandbits(32) for _ in range(16)]
            expected = [mask - (mask & (1 << voice)) for mask in history]
            reset_voice_history(history, voice)
            assert history == expected
    return cases


def check():
    check_source()
    print(f'PASS: {check_allocation()} static allocation cases, {check_history()} sampling cases, '
          '96 history resets, and source checks for note release, register flush and tick order')


if __name__ == '__main__':
    check()
