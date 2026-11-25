#!/usr/bin/env python3
"""Static VB2 controller, dice score resolution and text-box contracts."""
import hashlib
from pathlib import Path
import struct
import sys

KIT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(KIT / 'tools'))
import data_overlays as D
import maindec as M
from mipsdec import jtarget, sx16

BASE = 0x80010000
GS, UI = 0x801B8000, 0x80200000


def __getattr__(name):
    # Remaining legacy callers import these names here. Keep the static gate
    # independent of the fixture while those callers are converted.
    if name in ('OverlayInstructions', 'Writes', 'run_with_sentinel'):
        import legacy_instruction_fixture
        return getattr(legacy_instruction_fixture, name)
    raise AttributeError(name)


def source():
    return D.read('DATA/02_AREA.B/VB2.BIN')


def word(data, pc):
    return struct.unpack_from('<I', data, pc - BASE)[0]


def assert_words(data, spans):
    for pc, expected in spans.items():
        assert struct.unpack_from(f'<{len(expected)}I', data, pc - BASE) == expected, hex(pc)


def check_dispatch(data):
    for table, limit_pc, expected in [
        (0xA4, 0x80012F2C, (0x12F5C, 0x1349C, 0x148B8, 0x13450, 0x14904)),
        (0xBC, 0x800135A4, (0x135D4, 0x139C8, 0x13BC4, 0x13CE0, 0x147E4, 0x140A0, 0x14194,
                            0x14240, 0x14524, 0x136E8, 0x137E0, 0x13930, 0x13844)),
        (0xF4, 0x80017730, (0x1775C, 0x178A4, 0x178D4, 0x1799C, 0x17A18, 0x17AB4)),
    ]:
        count = sx16(word(data, limit_pc)) + 1
        assert count == len(expected)
        assert word(data, limit_pc + 4) == 0x0043102B
        assert struct.unpack_from(f'<{count}I', data, table) == tuple(0x80000000 + p for p in expected)
    assert_words(data, {
        # Publish the UI object and the definition reached through UI+48.
        0x80012F10: (0x8C820048, 0x3C12801B, 0x3C018006, 0xAC244540, 0x3C018006, 0xAC224548, 0x90830001),
        0x80012F44: (0x242100A4, 0x00220821, 0x8C220000, 0, 0x00400008, 0),
        # Publish the context pointer and copy the configured game mode and text group.
        0x80012F78: (0x3C028006, 0x24424550, 0x3C018006, 0xAC224A98, 0xA0760001),
        0x80012F9C: (0x90420002, 0x3404000A, 0x2406FFEC, 0xA0620542),
        0x80012FC0: (0x90420004, 0x2415FFB0, 0x34130001, 0xA0620543),
        0x80013594: (0x3C028006, 0x8C424548, 0, 0x90430000),
        0x800135BC: (0x242100BC, 0x00220821, 0x8C220000, 0, 0x00400008, 0),
        0x80017728: (0x3C038006, 0x90634BC0, 0x34020005, 0x0043102B),
        0x80017744: (0x242100F4, 0x00220821, 0x8C220000, 0, 0x00400008, 0),
    })


def check_bets_and_continuations(data):
    assert_words(data, {
        # State 0 admits a 100-or-more balance. Yes advances to the rules prompt.
        0x80013644: (0x28420064, 0x1040000A, 0x34020003),
        0x80013694: (0x34020009, 0x080051F9, 0xA0620000),
        # Rules close forwards to the appropriate mode path. A submitted rules
        # message changes state 10 to 12; state 11 resets the wager increment.
        0x800137B0: (0x3402000B, 0x080051F9, 0xA0820000),
        0x800137D8: (0x08004FD0, 0x34020020),
        0x80013838: (0x3402000C, 0x080051F9, 0xA0620000),
        0x800138BC: (0x3402000A, 0x080051F9, 0xA0620000),
        0x80013900: (0x3402000B, 0x080051F9, 0xA0620000),
        0x80013994: (0x34020064, 0x3C018006, 0xAC224AA0),
        # Wager controls compare the masked input as a word. Adds wrap at
        # 9901; negative subtracts wrap to 9900. Left/right change the step.
        0x80013A48: (0x3043F065, 0x34021000, 0x10620019),
        0x80013ACC: (0xACA20528, 0x284226AD, 0x14400343, 0, 0x080051F9, 0xACA00528),
        0x80013AF4: (0x00431023, 0x0441033A, 0xACA20528, 0x340226AC, 0x080051F9, 0xACA20528),
        0x80013B18: (0x00041880, 0x00641821, 0x00031840),
        0x80013B34: (0x34022710, 0x1462032A, 0x34020064, 0x3C018006, 0xAC224AA0),
        0x80013B60: (0x0064001A,),
        0x80013B88: (0x00001812,),
        0x80013BA0: (0xAC234AA0, 0x1464030F, 0x34020058, 0xA4A204B4, 0x340203E8, 0x3C018006, 0xAC224AA0),
        # Confirm advances only with a nonzero wager at or below the balance.
        0x80013C38: (0x0043102A, 0x1040000A, 0x34020003),
        0x80013C68: (0x1460000F,),
        0x80013CD4: (0x34020003, 0x080051F9, 0xAC620538),
        # Continuation 82 calls the score resolver. Controller state 5
        # checks mode and side before retrying high-bit scores.
        0x80013E18: (0x34020082, 0x10620016),
        0x80014104: (0x90420460, 0, 0x144001B5),
        0x80014130: (0x90640542, 0x34020001, 0x1482000A, 0, 0x9062053E, 0, 0x14440006, 0,
                     0x9062043A, 0, 0x304200F8, 0x1440FFEF),
        0x80014170: (0x9043053E, 0x9044043A, 0x00431021, 0xA044053C),
        0x80014234: (0x34020082, 0x080051F9, 0xAC620538),
        # Re-bet copies retained winnings into the wager field.
        0x80014654: (0xAC620528,),
        # The major exit waits for slot 22C before queueing 42B and setting UI state 4.
        0x800148C0: (0x8C42022C, 0, 0x0040F809, 0, 0x1440004C),
        0x800148E0: (0x8C4200AC, 0, 0x0040F809, 0x3404042B),
        0x800148F8: (0x34020004, 0x08005281, 0xA0620001),
    })
    for pc, target in [
        (0x80013D8C, 0x800147D4), (0x80013D9C, 0x80013E90), (0x80013DAC, 0x80013E2C),
        (0x80013DB4, 0x80013E68), (0x80013DC8, 0x80013EBC), (0x80013DD0, 0x80013ED8),
        (0x80013DE4, 0x80013FB8), (0x80013DF4, 0x80013F58), (0x80013E00, 0x80013F7C),
        (0x80013E14, 0x80013FF4), (0x80013E1C, 0x80013E78),
    ]:
        branch = word(data, pc)
        assert branch >> 26 == 4 and pc + 4 + 4 * sx16(branch) == target, hex(pc)
    assert jtarget(0x80013E80, word(data, 0x80013E80)) == 0x80017CC0


def check_payout(data):
    assert_words(data, {
        # Confirm consumes the full bet times the multiplier. The other
        # branch subtracts one unit of wager and applies one multiplier.
        0x800142B8: (0x30420041, 0x1040001E, 0x2482FFFF, 0x90A20541, 0, 0x00440018),
        0x800142D0: (0x90A20540, 0x00002012),
        0x80014300: (0x3C02000F, 0x3442423F, 0x080050CA, 0xACA20530),
        0x80014318: (0x00441023, 0x1C400002, 0xACA20530, 0xACA00530),
        0x80014330: (0x080051F9, 0xAC400528),
        0x80014338: (0x90A30540, 0, 0x1460000D, 0xACA20528, 0x90A20541),
        0x80014368: (0x3C02000F, 0x3442423F, 0x080051F9, 0xACA20530),
        0x80014384: (0x00431023, 0x1C400116, 0xACA20530, 0x080051F9, 0xACA00530),
        # Mode 1 publishes a flag on wins. Mode 2 compares profit to 5000.
        0x80014464: (0x90420540, 0, 0x144000DD, 0, 0x9242019C, 0, 0x34420001, 0x080051F9, 0xA242019C),
        0x80014488: (0x8E42001C, 0, 0x00821023, 0x28421388, 0x1440000A),
        0x800144B0: (0x92420252, 0, 0x34420002, 0x080051F9, 0xA2420252),
        # Score zero checks attempt counter against two prior failures.
        0x80017DA0: (0x14400005, 0x34020002, 0x9083053F, 0, 0x14620010),
        0x80017F1C: (0x10600017, 0x34020002),
        0x80017F7C: (0x9083053F, 0, 0x14620025),
        # Ordinary scores compare unsigned; equality takes the tie branch.
        0x80017F24: (0x9085053D, 0, 0x00A3102B, 0x1040000E),
        0x80017F6C: (0x1065001D, 0x34030001),
        # An ordinary win or loss resumes at 4. A tie resumes at 5.
        0x80017FD8: (0x34020004, 0x08006017, 0xAC620538),
        0x80018010: (0x34020005, 0x08006017, 0xAC620538),
        # The special results share the exact stores for double and triple.
        0x80017D80: (0x34020001, 0x08005FB8, 0xA0820540, 0x34020001, 0x08005FC0, 0xA0820540),
        0x80017ED0: (0x34020001, 0x08005FB8, 0xA0820540, 0xA0800540),
        0x80017EE8: (0x34020002, 0x08006017, 0xA0620541),
        0x80017EF4: (0x08005FC0, 0xA0820540, 0xA0800540),
        0x80017F08: (0x34020003, 0x08006017, 0xA0620541),
    })
    cap = (sx16(word(data, 0x80014300)) << 16) | (word(data, 0x80014304) & 0xFFFF)
    assert cap == 999_999


def check_text_box(data):
    assert_words(data, {
        # Box initialization sets the handshake and phase. Open, busy/idle
        # polling, and submit each have their own imported services.
        0x800176F8: (0x90620488, 0x3C11801B, 0x14400009, 0x36318000, 0x34020001, 0xA0620488),
        0x8001771C: (0xA0400489, 0x3C018006, 0xA0204BC0),
        0x800177A8: (0x2404FFB2, 0x2405FFAA, 0x8C420094, 0x3406001E, 0x0040F809, 0x34070004),
        0x80017890: (0x34040501, 0x3C018006, 0xA0304BC0),
        0x800178BC: (0x14400089, 0x34020002, 0x3C018006, 0xA0224BC0),
        0x800178E4: (0x8C440030, 0x8C450034, 0x90620543, 0x00008021, 0x8C830014, 0x340700FF),
        # NUL ends text only if the preceding byte is >=16. The byte
        # counter has a separate limit, and the submit call uses that count.
        0x8001792C: (0x14400003, 0x2CE20010, 0x1040000A, 0),
        0x80017944: (0xA0A20000, 0x90670000, 0x24C60001, 0x24630001, 0x28C20385, 0x1440FFF1, 0x24A50001),
        0x80017978: (0x8C6200B0, 0, 0x0040F809, 0x00C02821, 0x34020003, 0x3C018006, 0xA0224BC0),
        0x800179AC: (0x0040F809, 0, 0x14400005, 0x34020001),
        0x800179C8: (0xA0620489,),
        0x800179DC: (0x0040F809, 0, 0x1440003F),
        0x800179F8: (0x90430488, 0x34020002, 0x14620038, 0x34020004, 0x3C018006, 0xA0224BC0),
        0x80017A3C: (0x8C6200B4, 0, 0x0040F809, 0x3405000E),
        0x80017AA0: (0x34020005, 0x3C018006, 0xA0224BC0),
        0x80017ACC: (0x14400005, 0, 0x3C028006, 0x8C424A98, 0, 0xA0400488),
    })
    imports = {
        0x78: 0x8013F0C0, 0x94: 0x800C4CC8, 0xA4: 0x800C4DB4, 0xAC: 0x800C3104,
        0xB0: 0x8013F9B0, 0xB4: 0x80145644, 0x22C: 0x800C30E4, 0x270: 0x80145148,
    }
    assert {slot: M.mword(0x80165608 + slot) for slot in imports} == imports
    limit = sx16(word(data, 0x80017954))
    threshold = sx16(word(data, 0x80017930))
    assert (limit, threshold) == (901, 16)
    for sample, expected in [(b'\0', 0), (b'\x11\0', 1), (b'\x05\0\x21\0', 3),
                             (b' ' * 900 + b'\0', 900), (b' ' * 902, 901)]:
        stop = next((i for i, (byte, previous) in enumerate(zip(sample[:limit], b'\xff' + sample))
                     if byte == 0 and previous >= threshold), limit)
        assert stop == expected


def check():
    data = source()
    assert len(data) == 347104
    for start, end, expected in [
        (0x80012EEC, 0x80014A2C, 'abc87e21a6366d041cbfd0f6d412fa663a64ee4d0fba0f904921820bac3bda0b'),
        (0x800176DC, 0x80017AF8, '48077b916ea707f7e833dd1162ddad1673472dc431bd2308b9a8cbcb1d66e02b'),
        (0x80017CC0, 0x8001813C, 'aa572d5ef6536d40ab3148a90b759f989231bdf4fb4985d2b031c38571a2666f'),
        (0x80016C58, 0x80017394, '7010e797d337830c2029f0fd464e233eaf9f9f1aa3188842519a4f8fa0caf6dc'),
        (0x80017394, 0x80017414, 'ae5ac3b29236cf0acc978f5e8425fc24e11f68f5a84317b3e0052720ba94c290'),
        (0x80015A50, 0x80015B7C, '23df500a8eb112cbc06abe8d00c720d41862034fbf220e031a4203f35a952754'),
        (0x80015D08, 0x800160F0, '16b998d2b0cf7b4fc56cb44561d85fb9e43d5de1eeb6abc93863e3187ac3943c'),
    ]:
        assert hashlib.sha256(data[start - BASE:end - BASE]).hexdigest() == expected, hex(start)
    check_dispatch(data)
    check_bets_and_continuations(data)
    check_payout(data)
    check_text_box(data)
    assert word(data, 0x80018230) == 0x80012EEC
    import json
    ledger = json.loads((KIT.parent / 'game/assets/hq/optional_games.json').read_text())
    dice = next(family for family in ledger['families'] if family['game'] == 'dice')
    assert dice['entry_status'] == 'proven'
    callers = [(0x2D0BC, 1), (0x2D0CC, 2)]
    assert [(caller['site'], caller['dice_variant']) for caller in dice['callers']] == callers
    for pc, expected in ((0x80144164, 0x26100028), (0x8014417C, 0x00108080),
                         (0x80144184, 0x8E020000), (0x80144194, 0x0040F809),
                         (0x800C2A70, 0x00852026), (0x800C2A74, 0x00852024),
                         (0x8013CBF0, 0x90820190), (0x8013CC00, 0xA0820190),
                         (0x80142D8C, 0xA020DA41), (0x80142D94, 0xA020DA42)):
        assert M.mword(pc) == expected, hex(pc)
    assert M.mword(0x80165608 + 0x18) == 0x80142D78
    assert_words(data, {
        0x80015A7C: (0x34020004,),
        0x80015A88: (0x34020020,),
        0x80015AE4: (0x28420060,),
        0x80015B30: (0x28420021,),
        0x80015DB0: (0x3C018006, 0xA0224B20, 0x34020075),
        0x80015DE0: (0x3C028006, 0x90424B10),
        0x80015F58: (0x85660466, 0x3405000A, 0x00C5001A),
        0x80016094: (0x2442FFFF, 0xA1620544),
        0x80014158: (0x304200F8, 0x1440FFEF),
    })
    assert_words(data, {
        0x80016C80: (0x284200A0,),
        0x80016C8C: (0x34020090,),
        0x80016C98: (0x2472FF50,),
        0x80016CB8: (0x2610FFE0,),
        0x800173C4: (0x8E031B8C,),
        0x800173CC: (0x00431021, 0x34030064, 0x0043001B),
        0x800173EC: (0x02238821, 0x322300FF, 0x2C620006),
        0x800171C0: (0x34020007,),
        0x800171F8: (0x34020038,),
    })
    assert_words(data, {
        0x80012F14: (0x3C12801B,),
        0x80012F38: (0x36528000,),
        0x800132E0: (0x8E43001C,),
        0x800132E8: (0xAC430530,),
        0x800149D8: (0x8C420530,),
        0x800149E0: (0xAE42001C,),
    })
    from event_script_reachability import walk
    for site, variant in callers:
        request_end = site + 6
        wait_end = request_end + 2
        assert data[site:request_end] == bytes((0x3D, 0x12, 0x03, 0x02, variant, 0x04))
        nodes = {row['offset']: row for row in walk(data, [site])['nodes']}
        assert nodes[site]['end'] == request_end
        assert nodes[site]['callback'] == {'target': 0x80012258, 'operands': 4, 'retry': False}
        assert nodes[request_end]['end'] == wait_end
        assert nodes[request_end]['next'] == [request_end, wait_end]
        assert data[wait_end:wait_end + 5] == bytes.fromhex('03 06 12 0F FD')
    print('PASS: VB2 major dispatch, 13 dice states, six text phases, score and payout source contracts')


if __name__ == '__main__':
    check()
