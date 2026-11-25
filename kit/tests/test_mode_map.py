#!/usr/bin/env python3
"""Independent byte check for the MAIN.EXE dispatcher model."""
from pathlib import Path
import json
import struct
import sys

_TESTS = Path(__file__).resolve().parent
_KIT = _TESTS.parent
sys.path.insert(0, str(_KIT / "tools"))

import disc  # noqa: E402
import mode_map as MM  # noqa: E402
import event_script_decode as event_decoder  # noqa: E402
from lzss import decode_container  # noqa: E402

MAIN_BASE = 0x800C0800
MAIN_LBA = 17976
MAIN_SIZE = 757760
HEADER = 2048


def main_image():
    return disc.extract(MAIN_LBA, MAIN_SIZE)[HEADER:]


def word(image, va):
    off = va - MAIN_BASE
    assert 0 <= off <= len(image) - 4, f"{va:#x} outside headerless MAIN.EXE"
    return struct.unpack_from("<I", image, off)[0]


def branch_target(image, va):
    raw = word(image, va)
    assert raw >> 26 in {4, 5, 6, 7, 1}, f"{va:#x} is not a branch"
    imm = raw & 0xFFFF
    if imm & 0x8000:
        imm -= 0x10000
    return va + 4 + imm * 4


def disc_file(path):
    files = json.loads((_KIT / "extracted" / "iso_files.json").read_text())
    row = next(row for row in files if row["path"] == path)
    return disc.extract(row["lba"], row["size"])


def check_event_triggers(image):
    va2 = disc_file("DATA/01_AREA.A/VA2.BIN")
    assert va2[0x26430:0x26434] == bytes.fromhex("47 ff 0b 03")
    assert va2[0x267F0:0x267F3] == bytes.fromhex("47 00 fd")
    assert event_decoder.decode_stream(va2, 0x26430, 1)[0][2] == bytes.fromhex("ff 0b")
    assert [word(image, pc) for pc in range(0x80125E5C, 0x80125E88, 4)] == [
        0x8C631BC0, 0, 0x00031880, 0x3C018017, 0x2421F258, 0x00230821,
        0x8C240000, 0x3C018018, 0xAC22C1D0, 0x0C030BBE, 0x3C058001,
    ]
    for selector, path, lba in ((11, "DATA/03_SHIRO/COIN.BIN", 63516),
                                (10, "DATA/05_BATLE/GAMEOVER.BIN", 90627)):
        descriptor = word(image, 0x8016F258 + 4 * selector)
        assert (word(image, descriptor), word(image, descriptor + 4)) == (len(disc_file(path)), lba)

    vc6 = disc_file("DATA/06_AREA.C/VC6.BIN")
    assert struct.unpack_from('<15I', vc6, 0x728) == (
        0x90429AFC, 0, 0x30420002, 0x10400015, 0x34020001, 0xA2020034, 0x34020008,
        0xA2020035, 0x3402000A, 0x3C01801C, 0xAC229BC0, 0x92020037, 0xAE000498,
        0x34420010, 0xA2020037,
    )

    # DRAGON0's uploader consumes this section as compressed texture data.
    dragon = disc_file("DATA/01_AREA.A/DRAGON0.BIN")
    assert struct.unpack_from('<7I', dragon, 0x2B4) == (
        0x3C02800C, 0x34423500, 0x3C018003, 0xAC227D3C, 0x3C048003, 0x2484BD54, 0x0040F809,
    )
    page_table = struct.unpack_from('<I', dragon, 0x1BD5C)[0] - 0x80010000
    page = struct.unpack_from('<I', dragon, page_table + 4)[0] - 0x80010000
    end = page + 4 + struct.unpack_from('<I', dragon, page)[0]
    decoded, consumed = decode_container(dragon[page:end])
    assert (page, end, consumed, len(decoded)) == (0x1C948, 0x1D439, 2801, 16384)
    assert page <= 0x1D041 < end and dragon[0x1D041:0x1D044] == bytes.fromhex("47 fe 0b")


def check_mode2_request_and_selector(image):
    # Event opcode 0x42's command 3 requests the context+0x37 mode-2 arm. The
    # second selector byte is supplied by field_counter_driver's matched row.
    assert word(image, 0x80171718 + 0x42 * 4) == 0x801398F8
    assert word(image, 0x80139914) == 0x90640000  # consume command operand
    assert word(image, 0x80139918) == 0x0C050605  # jal ui_state_dispatcher
    assert word(image, 0x800C1AC0 + 3 * 4) == 0x801418E0
    assert word(image, 0x801418EC) == 0x34420002  # request bit in UI flag byte
    assert word(image, 0x801418F4) == 0xA022159B
    assert word(image, 0x801326E0) == 0x30420002  # callback consumes request bit
    assert word(image, 0x80132708) == 0x34020002
    assert word(image, 0x8013270C) == 0xA0620037
    assert word(image, 0x80132718) == 0x34020004
    assert word(image, 0x8013271C) == 0xA0620035
    assert word(image, 0x80132754) == 0x38420002  # consume the latched bit
    assert word(image, 0x8013275C) == 0xA022159B
    assert word(image, 0x80132768) == 0x3C028013
    assert word(image, 0x8013276C) == 0x24422898
    assert word(image, 0x8013277C) == 0xAC220000  # install transition callback

    # field_counter_driver numbers its 14-byte descriptor rows from zero and
    # stores the matched index as gs+0 before installing battle_arm_trigger_a.
    assert word(image, 0x801280F4) == 0x8E73DB24  # gs pointer in $s3
    assert word(image, 0x80128194) == 0x00009021  # s2 = 0
    assert word(image, 0x8012819C) == 0x26B5F37C  # callback table 0x8016F37C
    assert word(image, 0x80128218) == 0x0040F809  # indexed callback
    assert branch_target(image, 0x80128220) == 0x801284BC
    assert word(image, 0x80128238) == 0x2631000E  # descriptor stride
    assert word(image, 0x8012824C) == 0x26520001  # next zero-based index
    assert word(image, 0x801284C0) == 0xA2720000  # gs+0 = matched index


def check_callback_alias_reads(image):
    loads = {0x20, 0x21, 0x23, 0x24, 0x25}
    address_ops = {0x08, 0x09, 0x0D}  # addi/addiu/ori with a nonzero base
    slot_mem_ops = loads | {0x28, 0x29, 0x2B}
    direct_uses = []
    for i in range(len(image) // 4):
        raw = struct.unpack_from("<I", image, i * 4)[0]
        if raw >> 26 in loads | address_ops and raw & 0xFFFF == 0x1BC8 \
                and (raw >> 21) & 31:
            direct_uses.append(("MAIN", MAIN_BASE + i * 4))

    inventory = {
        row["file"]: row["regions"]
        for row in json.loads((_KIT / "extracted" / "bin_overlay_inventory.json").read_text())
    }
    entries = json.loads((_KIT / "extracted" / "overlay_lba_table.json").read_text())[
        "static_table"]["entries"]
    slot_lookalikes = []
    for entry in entries:
        data = disc.extract(entry["lba"], entry["size"])
        regions = inventory.get(entry["path"], [])
        for off in range(0, len(data) - 3, 4):
            raw = struct.unpack_from("<I", data, off)[0]
            if raw >> 26 in slot_mem_ops and raw & 0xFFFF in (0xDA90, 0xDA94) \
                    and (raw >> 21) & 31 and any(
                        int(region["start"], 16) <= off <= int(region["end"], 16)
                        for region in regions):
                slot_lookalikes.append((entry["path"], off, raw))
            if raw >> 26 not in loads | address_ops or raw & 0xFFFF != 0x1BC8 \
                    or not (raw >> 21) & 31:
                continue
            if any(int(region["start"], 16) <= off <= int(region["end"], 16)
                   for region in regions):
                direct_uses.append((entry["path"], off))
    assert direct_uses == [], direct_uses
    # The only low-offset lookalikes use VD6's local 0x8007 base. Their data
    # words are unaligned/non-address values, not MAIN's 0x8017DA90/DA94 slots.
    assert slot_lookalikes == [
        ("DATA/07_AREA.D/VD6.BIN", 0x427C, 0x8CA5DA90),
        ("DATA/07_AREA.D/VD6.BIN", 0x4300, 0x8CA5DA94),
    ], slot_lookalikes
    vd6 = disc_file("DATA/07_AREA.D/VD6.BIN")
    for off, access in [(0x427C, 0x8CA5DA90), (0x4300, 0x8CA5DA94)]:
        assert struct.unpack_from("<I", vd6, off - 4)[0] == 0x3C058007
        assert struct.unpack_from("<I", vd6, off)[0] == access
    assert struct.unpack_from("<I", vd6, 0x6DA90)[0] == 0xFC071207
    assert struct.unpack_from("<I", vd6, 0x6DA94)[0] == 0xF4001007
    assert word(image, 0x800C9620) == 0xAC821BC8  # initializer is the writer
    records = json.loads((_KIT / "work" / "gs_recs.json").read_text())
    alias_records = [row for row in records
                     if row[0] == "indirect" and row[6] == "gs+0x1BC8"]
    assert alias_records == [["indirect", 0x800C9620, "gpu_heap_init",
                              "sw", 4, "W", "gs+0x1BC8"]]


def check_setter_caller_guards(image):
    # A's direct registration requires the H2DA latch to equal 1.
    assert branch_target(image, 0x8012814C) == 0x80128174
    assert word(image, 0x80128144) == 0x8C63A0C0
    assert word(image, 0x80128148) == 0x34020001
    assert word(image, 0x80128168) == 0xAC220000

    # A's second registration follows coordinate matches and a nonzero
    # descriptor-indexed callback result.
    assert branch_target(image, 0x801281D4) == 0x801281E4  # exact X match
    assert branch_target(image, 0x801281DC) == 0x80128228  # X may be +1
    assert branch_target(image, 0x801281F0) == 0x80128200  # exact Y match
    assert branch_target(image, 0x801281F8) == 0x80128228  # Y may be +1
    assert word(image, 0x80128218) == 0x0040F809
    assert branch_target(image, 0x80128220) == 0x801284BC
    assert word(image, 0x801284F4) == 0xAC230000

    # B's wrapper is installed only after its three caller-side guards pass.
    assert branch_target(image, 0x8012841C) == 0x80128464  # ctx+0x38 >= 0 skips
    assert word(image, 0x80128424) == 0x0C04982E  # field_state_gate_driver
    assert branch_target(image, 0x8012842C) == 0x80128464  # zero result skips
    assert word(image, 0x80128438) == 0x8C42BDCC
    assert word(image, 0x80128440) == 0x30420200
    assert branch_target(image, 0x80128444) == 0x80128464  # bit 0x200 skips
    assert word(image, 0x80128460) == 0xAC220000  # installs wrapper 0x801285A4
    assert word(image, 0x801285A4) == 0x3C028018
    assert word(image, 0x801285A8) == 0x8C42A0B8

    # H2DA invokes its setter only when the source object's byte is exactly 1.
    assert branch_target(image, 0x800D13C4) == 0x800D13F4
    assert word(image, 0x800D13CC) == 0x0C04A34E


def check_flag_modes(image):
    # Each zero-bit branch skips the mode assignment and advances to the
    # next mask. The taken mode is written in the jump delay slot.
    ladder = (
        (0x80131EEC, 0x80131F34, 2, 2, 0x34020004),
        (0x80131F4C, 0x80131F50, 4, 3, 0x34020003),
        (0x80131F68, 0x80131F6C, 8, 4, 0x00001021),
        (0x80131F84, 0x80131F88, 16, 5, 0x00001021),
    )
    choices = []
    for (mask_site, branch, mask, mode, delay), next_site in zip(
            ladder, (0x80131F4C, 0x80131F68, 0x80131F84, 0x80131FA0)):
        selector = word(image, mask_site)
        assert selector == 0x30620000 | mask
        assert word(image, branch) == 0x10400005
        assert branch_target(image, branch) == next_site
        assignment = word(image, branch + 20)
        assert assignment == 0x34030000 | mode
        assert tuple(word(image, branch + offset) for offset in (4, 8, 12, 16)) == (
            delay, 0x3C048018, 0x8C84DB24, 0x0804C80C)
        choices.append((selector & 0xFFFF, assignment & 0xFFFF))
    assert word(image, 0x80131FA0) == 0x90820035  # default route reads gs+0x35
    assert word(image, 0x80132030) == 0xAC831BBC
    expected = (None, 2, 3, 2, 4, 2, 3, 2, 5, 2, 3, 2, 4, 2, 3, 2)
    assert tuple(next((mode for mask, mode in choices if flags & mask), None)
                 for flags in range(0, 32, 2)) == expected
    # gs+2 selects commands, and both arms join the SAME mode-1 assignment.
    assert word(image, 0x80131FFC) == 0x34040201
    assert word(image, 0x8013200C) == 0x34040202
    assert word(image, 0x80132000) == 0x0804C804
    assert word(image, 0x80132020) == 0x34030001
    assert word(image, 0x8013202C) == 0x34030002


def check_duel_chain(image):
    # Derive the signed table address independently of the model's prose.
    table = (word(image, 0x80130F54) & 65535) << 16
    low = word(image, 0x80130F58) & 65535
    table += low - 0x10000 if low >= 0x8000 else low
    assert table == 0x8016F67C
    chain = word(image, table + 2 * 4)
    record = word(image, chain + 5 * 4)
    size, lba = word(image, record), word(image, record + 4)
    assert (size, lba) == (458752, 99160)  # VC6.BIN
    vc6 = disc.extract(lba, size)
    vw = lambda pc: struct.unpack_from("<I", vc6, pc - 0x80010000)[0]
    group0 = word(image, 0x8016B358)
    # Each VC6 wrapper indexes resource group 0 and calls vtable loader +0x10.
    for start, index, expected_lba in [(0x800101F4, 4, 161871),
                                      (0x80010258, 5, 162008),
                                      (0x8001049C, 6, 161940)]:
        assert vw(start + 0x18) == 0x3C02801C
        assert vw(start + 0x1C) == 0x8C42B4B8
        assert vw(start + 0x24) == 0x8C420000
        assert vw(start + 0x30) == 0x8C440000 | index * 4
        assert vw(start + 0x34) == 0x8C620010
        assert vw(start + 0x3C) == 0x0040F809
        assert vw(start + 0x40) == 0x3C058008
        rec = word(image, group0 + index * 4)
        assert word(image, rec + 4) == expected_lba
        duel = disc.extract(expected_lba, word(image, rec))
        dw = lambda pc: struct.unpack_from("<I", duel, pc - 0x80080000)[0]
        assert dw(0x80081058) == 0x8C84B4B8
        selectors = [dw(pc) & 65535 for pc in [0x80081050, 0x80081060]]
        indices = [struct.unpack_from("<I", duel, offset)[0] for offset in selectors]
        assert indices == {161871: [9, 10], 162008: [13, 14], 161940: [11, 12]}[expected_lba]
    header = vw(0x80010000)
    assert header == 0x800176A4
    assert vw(header + 0x10) == 0x800175F4
    assert vw(0x800175F4 + 3 * 4) == 0x8001049C  # selector 0x80, index 3
    assert vc6[0x3E319:0x3E31C] == bytes.fromhex("43 80 03")
    command = event_decoder.decode_stream(vc6, 0x3E319, 1)[0]
    assert (command[1], command[2]) == (0x43, bytes.fromhex("80 03"))
    assert word(image, 0x8013987C) == 0x90620000  # fetch index operand
    assert word(image, 0x80139880) == 0x8C830010  # direct callback table
    assert word(image, 0x8013988C) == 0x8C420000  # selected table word
    assert word(image, 0x80139894) == 0xACA20498  # one-shot callback field
    assert word(image, 0x80132C28) == 0x8C820498  # consumer loads it
    assert word(image, 0x80132C40) == 0x0040F809  # consumer jalr
    assert vw(0x800105C8) == 0x8C630000           # loaded module entry
    assert vw(0x800105E0) == 0xAE430494           # install entry
    assert vw(0x80010610) == 0x8E020494
    assert vw(0x80010624) == 0x0040F809           # invoke entry

    # VB7D's event callback table points its two Teo duel commands at the
    # PAN_TEO and SHU_TEO wrappers. The top-level word is a header pointer;
    # header+0x10 points to the indexed callback table.
    vb7d = disc_file("DATA/02_AREA.B/VB7D.BIN")
    bw = lambda va: struct.unpack_from("<I", vb7d, va - 0x80010000)[0]
    header = bw(0x80010000)
    callback_table = bw(header + 0x10)
    assert header == 0x80013E98
    assert callback_table == 0x80013DE8
    assert [bw(callback_table + i * 4) for i in (3, 4)] == [
        0x80010130, 0x80010194]
    assert vb7d[0xC1BB:0xC1BE] == bytes.fromhex("43 80 03")
    assert vb7d[0xC5FD:0xC600] == bytes.fromhex("43 80 04")
    assert vb7d[0xC615:0xC618] == bytes.fromhex("43 80 04")

    # These per-area wrappers select group-0 file records 4 and 5, load them
    # to 0x80080000 through vtable+0x10, then schedule their shared continuation.
    for start, group_index, record_offset, expected_lba in [
            (0x80010130, 4, 0x10, 161871),
            (0x80010194, 5, 0x14, 162008)]:
        assert bw(start + 0x10) == 0x0C004037   # prepare duel load
        assert bw(start + 0x14) == 0x34040000 | group_index
        assert bw(start + 0x1C) == 0x8C42B4B8   # resource-group directory
        assert bw(start + 0x24) == 0x8C420000   # group 0
        assert bw(start + 0x30) == 0x8C440000 | record_offset
        assert bw(start + 0x34) == 0x8C620010   # vtable loader slot
        assert bw(start + 0x3C) == 0x0040F809   # jalr loader
        assert bw(start + 0x40) == 0x3C058008   # destination 0x80080000
        assert bw(start + 0x4C) == 0xAE020498   # continuation at area+0x498
        rec = word(image, group0 + group_index * 4)
        assert (word(image, rec), word(image, rec + 4)) == (
            {4: 140104, 5: 138712}[group_index], expected_lba)


def run():
    image = main_image()
    for va, expected in MM.ANCHOR_WORDS.items():
        assert word(image, va) == expected, f"instruction moved at {va:#x}"

    check_flag_modes(image)
    check_event_triggers(image)
    check_mode2_request_and_selector(image)
    check_callback_alias_reads(image)
    check_setter_caller_guards(image)
    check_duel_chain(image)
    model = MM.model(image)
    installs = model["callback_install_census"]
    sites = [row["site"] for row in installs]
    assert len(sites) == 160 and len(set(sites)) == 160
    for row in installs:
        actual = word(image, row["site"])
        assert actual == row["word"], f"install word moved at {row['site']:#x}"
        assert actual >> 26 == 0x2B
        if row['site'] == 0x800C2BBC:
            assert actual == 0xAC22DA90
            assert (row['table_base'], row['handler'], row['role']) == (
                0x8017DA90, 0x800C9440, 'root_bootstrap')
        else:
            assert actual & 0xFFFF == 0
            assert row["role"] in {"mode_route", "root_lifecycle", "subordinate_callback"}
        assert len(row["handler_source_sites"]) == len(row["handler_source_words"])
        for source, expected in zip(row["handler_source_sites"],
                                    row["handler_source_words"]):
            assert word(image, source) == expected, f"handler source moved at {source:#x}"
        _, fields = MM.mipsdec.dec(row["site"], actual)
        handler, _ = MM.resolve_reg(
            row["site"], fields["rt"], reader=lambda va: word(image, va))
        assert handler == row["handler"], f"handler target changed at {row['site']:#x}"
    assert {r["site"] for r in installs if r["role"] == "mode_route"} == MM.ROUTE_INSTALLS

    mode_stores = model["mode_word_store_sites"]
    assert len(mode_stores) == 12
    for va in mode_stores:
        raw = word(image, va)
        assert raw >> 26 == 0x2B and raw & 0xFFFF == 0x1BBC
    tracked_writers = {
        row[1] for row in json.loads((_KIT / "work" / "gs_recs.json").read_text())
        if row[0] == "indirect" and row[4] == 4 and row[5] == "W"
        and row[6] == "gs+0x1BBC"
    }
    assert set(mode_stores) == tracked_writers, \
        "direct mode-word stores disagree with tracked game-state writer census"
    transitions = model["mode_word_transitions"]
    assert {row["site"] for row in transitions} == set(mode_stores)
    assert [word(image, MM.MODE_SWITCH_TABLE + i * 4) for i in range(9)] == \
        MM.MODE_SWITCH_WORDS

    # Independent route targets decoded from the actual lui/addiu words.
    assert word(image, 0x800C9A9C) == 0x3C028012
    assert word(image, 0x800C9AA0) == 0x244279E8       # mode 1
    assert word(image, 0x800C9AAC) == 0x3C028013
    assert word(image, 0x800C9AB0) == 0x24420EC4       # mode 2
    assert word(image, 0x800C9ABC) == 0x3C02800E
    assert word(image, 0x800C9AC0) == 0x2442DF98       # mode 3
    assert word(image, 0x800C9ADC) == 0x3C028012
    assert word(image, 0x800C9AE0) == 0x24425DC0       # modes 4, 5, 99

    # BATTLE.BIN's boot-time destination is 0x800AA000, not a code overlay.
    assert word(image, 0x800C9D1C) == 0x0C030BBE       # cd_read_sectors_struct
    assert word(image, 0x800C9D20) == 0x34A5A000       # $a1 = 0x800AA000
    open_items = " ".join(model["still_open"])
    assert "context+0x35" in open_items
    assert "callback pointer" in open_items
    print(f"PASS: mode_map ({len(MM.ANCHOR_WORDS)} anchors, 160 callback stores "
          "and targets, 12 mode-word stores)")


if __name__ == "__main__":
    run()
