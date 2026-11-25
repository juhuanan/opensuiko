#!/usr/bin/env python3
"""Static accuracy and damage checks with independent arithmetic."""
from hashlib import sha256
from itertools import product
from math import trunc
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import battle_formulas as BF
import maindec as M
from battle_remainder import magic_jump_table


def check_source():
    for start, end, digest in (
        (0x800F7D5C, 0x800F7E90, 'f8633a0377c7ff4d4e6c9bd0538835521cef6d3d95b22c9bc882ea84d58c96f8'),
        (0x800F7E90, 0x800F8174, 'a78631c956365dcb5221cbc934a4573e64bf4208cb29ade3ffdce475a75521b8'),
        (0x800F8174, 0x800F835C, '868799f614b7e240e12bcad1a41c71033eb6675a98f8cae6b51a316b12ce3f8c'),
    ):
        assert sha256(M.body()[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)

    for pc, word in {
        # Accuracy uses the skill halfwords, clamps before halving, and compares draw % 100.
        0x800F7DA8: 0x94420026, 0x800F7DAC: 0x95030026, 0x800F7DB0: 0x2442FFB0,
        0x800F7DB4: 0x00628023, 0x800F7DC4: 0x3410003C, 0x800F7DD4: 0x34100063,
        0x800F7E08: 0x9043004C, 0x800F7E0C: 0x34020012, 0x800F7E28: 0x30420010,
        0x800F7E38: 0x00108043, 0x800F7E3C: 0x0C051F8E, 0x800F7E44: 0x34030064,
        0x800F7E48: 0x0043001A, 0x800F7E70: 0x00001010, 0x800F7E78: 0x0050102A,
        # Both damage routines choose one of two variance branches and consume one draw.
        0x800F7EF4: 0x94630030, 0x800F7EF8: 0x94420032, 0x800F7F00: 0x00628023,
        0x800F7F04: 0x2A02000A, 0x800F7F08: 0x1040000C, 0x800F7F10: 0x0C051F8E,
        0x800F7F20: 0x26030001, 0x800F7F38: 0x00628023, 0x800F7F3C: 0x0C051F8E,
        0x800F7F44: 0x0050001A, 0x800F7F6C: 0x00001810, 0x800F7F78: 0x00021043,
        0x800F7F7C: 0x00431023, 0x800F7F80: 0x34030005, 0x800F7F84: 0x0043001A,
        0x800F7FB4: 0x02028021, 0x800F81DC: 0x9465002C, 0x800F81E4: 0x9442002C,
        0x800F81EC: 0x00458023, 0x800F81F0: 0x2A02000A, 0x800F81F4: 0x1040000C,
        0x800F81FC: 0x0C051F8E, 0x800F820C: 0x26040001, 0x800F8224: 0x00828023,
        0x800F8228: 0x0C051F8E, 0x800F8230: 0x0050001A, 0x800F8258: 0x00001810,
        0x800F8264: 0x00021043, 0x800F8268: 0x00431023, 0x800F826C: 0x34030005,
        0x800F8270: 0x0043001A, 0x800F82A0: 0x02028021,
        # Physical modifiers apply after variance: party Defend, weakness, fragments, floor.
        0x800F7FD0: 0x1440000C, 0x800F7FEC: 0x80430047, 0x800F7FF4: 0x14620003,
        0x800F7FFC: 0x02028021, 0x800F8000: 0x00108043, 0x800F801C: 0x14400048,
        0x800F8068: 0x90840046, 0x800F8078: 0x2C420005, 0x800F809C: 0x90620055,
        0x800F80A8: 0x2C620005, 0x800F80B4: 0x90430020, 0x800F80C4: 0x14620006,
        0x800F80D8: 0x02028021, 0x800F80E0: 0x10820003, 0x800F80E8: 0x14820015,
        0x800F80F0: 0x34020014, 0x800F8124: 0x90630002, 0x800F812C: 0x00430018,
        0x800F813C: 0x02028021, 0x800F8140: 0x1E000003, 0x800F8148: 0x34100001,
        # The unsigned rune-1 bound is inclusive. Both selector inputs are byte-masked.
        0x800F81E8: 0x9072004C, 0x800F82A4: 0x2643FFFF, 0x800F82A8: 0x3402001E,
        0x800F82AC: 0x0043102B, 0x800F82B0: 0x14400017, 0x800F82B4: 0x326200FF,
        0x800F82C0: 0x24211414, 0x800F82D0: 0x00400008, 0x800F830C: 0x326200FF,
        0x800F8310: 0x322300FF, 0x800F8314: 0x10430003, 0x800F8318: 0x34020007,
        0x800F831C: 0x14620004, 0x800F832C: 0x00108043, 0x800F8338: 0x34100001,
    }.items():
        assert M.mword(pc) == word, hex(pc)

    pointers = [M.mword(0x800C1414 + 4 * i) for i in range(31)]
    assert pointers == magic_jump_table()
    arms = {0x800F830C: None, 0x800F8308: 7}
    assert M.mword(0x800F8308) == 0x34110007
    for selector, address in enumerate(range(0x800F82D8, 0x800F8308, 8), 1):
        assert M.mword(address) == 0x0803E0C3
        assert M.mword(address + 4) == 0x34110000 + selector
        arms[address] = selector
    selectors = [arms[address] for address in pointers]
    assert selectors == [7, 1, 2, 5, 4, 3, 6] + [None] * 19 + [1, 2, 5, 3, 4]
    return selectors


def variance(delta, draw):
    if delta < 10:
        return delta + 1 - (draw & 3)
    return delta + trunc((delta // 2 - draw % delta) / 5)


def physical_reference(delta, draw, *, party_defend=False, weakness=False, fragments=0):
    damage = variance(delta, draw)
    if party_defend:
        damage = trunc(damage / 2)
    if weakness:
        damage += trunc(damage / 2)
    return max(1, damage + trunc(damage / 20) * fragments)


def hit_reference(skill, target_skill, draw):
    threshold = min(99, max(60, skill + 80 - target_skill))
    return draw % 100 < threshold


def check():
    selectors = check_source()
    deltas = (-65535, -1, 0, 1, 9, 10, 11, 99, 100, 65535)
    draws = (0, 1, 32767)
    for delta, draw, target_party, attacker_party, kind, flag, bonus, defending in product(
            deltas, draws, (False, True), (False, True), (0, 1, 3), (0, 1, 2), (0, 3), (False, True)):
        attack, defense = max(0, delta), max(0, -delta)
        expected = physical_reference(delta, draw, party_defend=target_party and defending,
                                      weakness=attacker_party and flag == 1,
                                      fragments=bonus if attacker_party and kind in (1, 3) else 0)
        actual = BF.physical_damage(attack, defense, draw, element_type=kind, target_action=int(defending),
                                   element_index_valid=True, element_match_flag=flag, element_bonus=bonus,
                                   target_is_party=target_party, attacker_is_party=attacker_party)
        assert actual == expected, (delta, draw, target_party, attacker_party, kind, flag, bonus, defending)

    # Out-of-range rune bytes and retaining entries preserve the caller byte used by the comparison.
    for delta, draw, rune, element, incoming in product(
            (-100, 0, 9, 10, 11, 99, 65535), draws, range(33), (0, 1, 5, 7, 0x107), (0, 3, 0x107)):
        selected = selectors[rune - 1] if 1 <= rune <= len(selectors) else None
        index = incoming & 255 if selected is None else selected
        damage = variance(delta, draw)
        expected = max(1, trunc(damage / 2) if index in (7, element & 255) else damage)
        assert BF.magic_damage(max(0, delta), max(0, -delta), draw, element,
                               incoming if selected is None else selected) == expected, (delta, draw, rune, element, incoming)
    assert BF.magic_damage(100, 0, 0, 12, 0x107) == 55
    assert BF.physical_damage(100, 0, 0, element_index_valid=False, element_type=3,
                              element_match_flag=1, element_bonus=9) == physical_reference(100, 0, fragments=9)
    print('PASS: static accuracy, physical and magic instruction spans and full rune-selector table')
    print('PASS: 4320 physical and 10395 magic cases against independent arithmetic')


if __name__ == '__main__':
    check()
