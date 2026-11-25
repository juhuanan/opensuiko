#!/usr/bin/env python3
"""Export source dice faces and decoded model for review; never promote art."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct

from PIL import Image

import area_scene as scene
import battle_mock
from export_first_room import source
import psx_vram as gpu
import opening_audience
import war_text
from spell_scene_objects import destination
from export_opening_scene import portrait_payload
from parse_04play import Parser
from mipsdec import sx16

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / "kit/data/reports/dice_presentation.json"
SOURCE_SHA256 = "cff3f996221e90b6b2571570e8ecda957ed24f4153e438bd255dcf879db0d442"
MAIN_SHA256 = "439a166609dab8cde26249bd7661a835e4d55e79bb37a964761c981524e89d95"


def draw_evidence(main: bytes, geometry: dict, faces: list, poses: list) -> dict:
    base = struct.unpack_from("<I", main, 0x18)[0]
    def word(address):
        return struct.unpack_from("<I", main, 2048 + address - base)[0]
    anchors = {
        0x800c2be8: 0x34040140, 0x800c2bec: 0x340500f0,
        0x8014c8ac: 0x8c640000, 0x8014c8b4: 0xae040000, 0x8014c8bc: 0xac700000,
        0x8014ce98: 0x8c840010, 0x8014d9e0: 0xacc20010,
        0x801496e4: 0x3c031100, 0x801496f4: 0x34630002,
    }
    if any(word(address) != expected for address, expected in anchors.items()):
        raise ValueError("dice ordering/viewport source changed")
    heads, links, depths = [None] * 512, {}, {}
    for die, pose in enumerate(poses):
        rotation = battle_mock.rot_matrix(pose["angles"])
        z = [sum(rotation[6 + j] * v[j] for j in range(3)) >> 12 for v in geometry["vertices"]]
        divisor = geometry["coordinate_divisor"]
        z = [geometry["depth_origin"] + (value // divisor if value >= 0 else -((-value) // divisor)) for value in z]
        for face, corners in enumerate(faces):
            key = min(z[index] for index in corners)
            node = die, face
            links[node], heads[key], depths[node] = heads[key], node, key
    order = []
    for head in reversed(heads):
        while head is not None:
            order.append(list(head))
            head = links[head]
    expected = sorted(depths, key=lambda node: (depths[node], node[0], node[1]), reverse=True)
    if order != [list(node) for node in expected]:
        raise ValueError("packet links disagree with painter ordering")
    return {"viewport": [320, 240], "source_center": [160, 120],
            "order": "descending depth; equal keys reverse submission order",
            "initial_order": order, "scope": "18 dice faces; HUD/text composition excluded",
            "source": ["MAIN 0x8014C850", "MAIN 0x8014D9AC", "MAIN 0x80149688", "MAIN 0x8014CE90", "MAIN 0x800C2BE8"]}


def decoded_message(data: bytes, group: int, index: int, name: str) -> tuple[dict, dict]:
    offset = scene.ptr_at(data, group + index * 4)
    tokens, end = opening_audience.text(data, offset)
    raw = data[offset:end]
    parts, consumed = [], 0
    for segment in raw.split(b"\x06\0"):
        decoded, used = war_text.decode(segment)
        if used != len(segment):
            raise ValueError("partial dice text decode")
        parts.append(decoded)
        consumed += used
    decoded = "{player_name}".join(parts)
    consumed += 2 * (len(parts) - 1)
    independent = "".join(token.get("text", "") if token["kind"] == "glyph" else
                          "\n" if token["kind"] == "newline" else "\n[---]\n"
                          if token["kind"] == "page" else "{player_name}"
                          if token["kind"] == "player_name" else "<unsupported>" for token in tokens)
    if decoded != independent or consumed != end - offset:
        raise ValueError("dice message decoders disagree")
    return {"id": "dice_" + name, "tokens": tokens}, {"group": 4, "index": index,
            "offset": offset, "bytes": consumed, "sha256": hashlib.sha256(raw).hexdigest()}


def entry_messages(data: bytes) -> tuple[dict, dict]:
    anchors = {0x32ec: 0x1213001a, 0x3368: 0x34020009, 0x338c: 0xac304aa0,
               0x37d8: 0x08004fd0, 0x37dc: 0x34020020, 0x3810: 0x34020001,
               0x3828: 0xac204aa0, 0x3838: 0x3402000c,
               0x38bc: 0x3402000a, 0x3f40: 0xa0620534, 0x3f4c: 0x34020009,
               0x4764: 0x34020001, 0x4784: 0x3c018006}
    if any(scene.u32(data, offset) != expected for offset, expected in anchors.items()):
        raise ValueError("dice entry controller changed")
    root = scene.ptr_at(data, 0)
    tables = scene.ptr_at(data, root + 0x14)
    group = scene.ptr_at(data, tables + 4 * 4)
    messages, proof = {}, {}
    for name, index in (("rules_question", 0x18), ("rules", 0x1f), ("fixed_notice", 0x20)):
        messages[name], proof[name] = decoded_message(data, group, index, name)
    return messages, proof


def result_messages(data: bytes) -> tuple[dict, dict]:
    root = scene.ptr_at(data, 0)
    tables = scene.ptr_at(data, root + 0x14)
    group = scene.ptr_at(data, tables + 16)
    messages, proof = {}, {}
    for side, start in (("player_hands", 0), ("dealer_hands", 6)):
        messages[side], proof[side] = [], []
        for pip in range(6):
            message, origin = decoded_message(data, group, start + pip, side + "_" + str(pip + 1))
            messages[side].append(message)
            proof[side].append(origin)
    for name, index in (("escaped", 0x0c), ("straight_receive", 0x0d), ("straight_pay", 0x0e),
                        ("storm_pay", 0x0f), ("storm_receive", 0x10), ("zero_score", 0x11),
                        ("player_turn", 0x12), ("dealer_turn", 0x13), ("farewell", 0x1a),
                        ("player_win", 0x1b), ("dealer_win", 0x1c), ("draw", 0x1d),
                        ("bankrupt", 0x1e), ("tie_notice", 0x22),
                        ("player_straight_pay", 0x26), ("player_straight_receive", 0x27)):
        messages[name], proof[name] = decoded_message(data, group, index, name)
    anchors = {0x4234: 0x34020082, 0x3e18: 0x34020082, 0x7dd4: 0x34020012,
               0x7e2c: 0x34020013, 0x7fc8: 0x3402001c, 0x7ffc: 0x3402001d,
               0x3f3c: 0x34020022, 0x3fd8: 0x34020013, 0x43c4: 0x3402001e,
               0x46bc: 0x3402001a, 0x6f48: 0x34020027, 0x7010: 0x34020026}
    # Other producer/resolver bodies are pinned by the full overlay identity.
    if any(scene.u32(data, offset) != expected for offset, expected in anchors.items()):
        raise ValueError("dice result continuation changed")
    special_offsets = {"natural": ((8, 0x72a4), (16, 0x7284), (32, 0x722c), (64, 0x71f4)),
                       "forced_player": ((8, 0x6d5c), (16, 0x6e68), (32, 0x6f48), (64, 0x7010)),
                       "forced_dealer": ((8, 0x6d60), (16, 0x6e6c), (32, 0x6f4c), (64, 0x7014))}
    special_reports = {kind: {str(score): scene.u32(data, offset) & 0xffff for score, offset in locations}
                       for kind, locations in special_offsets.items()}
    if special_reports != {"natural": {"8": 15, "16": 16, "32": 14, "64": 13},
                           "forced_player": {"8": 16, "16": 15, "32": 39, "64": 38},
                           "forced_dealer": {"8": 15, "16": 16, "32": 14, "64": 13}}:
        raise ValueError("special report immediates disagree with source branches")
    proof["special_reports"] = special_reports
    proof["controller"] = {"hand_continuation": "0x80014234/0x80013E18",
                           "resolution": "0x80017CC0..0x8001813C",
                           "fixed_tie": "0x80013ED8..0x80013FB4",
                           "payout_exit": "0x80014398..0x80014484/0x800148B8"}
    return messages, proof


def entry_layout(data: bytes, main: bytes) -> tuple[dict, dict]:
    def imm(offset):
        return sx16(scene.u32(data, offset))
    base = struct.unpack_from("<I", main, 0x18)[0]
    def word(address):
        return struct.unpack_from("<I", main, 2048 + address - base)[0]
    anchors = {0x80145224: 0xa2020011, 0x8014522c: 0x3402000c,
               0x80145a70: 0x2442ffff, 0x80145ab4: 0x2442ffff,
               0x80144cc0: 0x2451fff8, 0x80144cc4: 0x2470fff8,
               0x8013f718: 0x30420065, 0x8013f750: 0x30420041,
               0x8013f780: 0x2c42001f, 0x8013f7c0: 0x30420065}
    if any(word(a) != w for a, w in anchors.items()):
        raise ValueError("dice text/window consumer changed")
    cell = [word(0x80145204) & 0xffff,
            word(0x8014522c) & 0xffff]
    origin = [imm(0x77a8) + 160, imm(0x77ac) + 120]
    extent = [imm(0x77b4) * cell[0], imm(0x77bc) * cell[1]]
    transition = imm(0x7824)
    choice_pointer = scene.ptr_at(data, 0x53c70 + 3 * 4)
    tokens, end = opening_audience.text(data, choice_pointer)
    choices = "".join(t.get("text", "") if t["kind"] == "glyph" else "\n" for t in tokens)
    decoded, used = war_text.decode(data, choice_pointer)
    if choices != decoded or used != end - choice_pointer:
        raise ValueError("dice choices disagree between decoders")
    offset = 2048 + 0x80171884 - base
    pacing = [{"normal": main[offset + 4 * i + 1], "pressed": main[offset + 4 * i]} for i in range(3)]
    layout = {"box": {"x": origin[0], "y": origin[1], "width": extent[0], "height": extent[1]},
              "transition_ticks": transition,
              "choices": {"x": imm(0x2fc4) + 160, "y": imm(0x31b8) + 120,
                          "width": imm(0x31ec) * cell[0], "height": imm(0x3204) * cell[1], "text": choices},
              "pacing": pacing}
    if layout != {"box": {"x": 82, "y": 34, "width": 240, "height": 48},
                  "transition_ticks": 14,
                  "choices": {"x": 80, "y": 190, "width": 40, "height": 24, "text": " YES\n NO"},
                  "pacing": [{"normal": 1, "pressed": 0}, {"normal": 3, "pressed": 1}, {"normal": 5, "pressed": 2}]}:
        raise ValueError("dice layout disagrees with independent source parameters")
    return layout, {"box": "VB2 0x800177A8..0x80017824; MAIN 0x80145194/0x80147568",
                    "choices": "VB2 0x800131A8..0x8001327C/0x8001762C/0x80017BC4",
                    "choice_text_offset": choice_pointer,
                    "pacing": "MAIN 0x80171884/0x8013F6F8",
                    "page_hold_updates": 31}


def hud_and_cursor(data: bytes, main: bytes) -> tuple[dict, dict, dict]:
    def imm(offset):
        return sx16(scene.u32(data, offset))
    labels = []
    for index in (1, 2):
        offset = scene.ptr_at(data, 0x53c70 + index * 4)
        tokens, end = opening_audience.text(data, offset)
        label = "".join(t.get("text", "") for t in tokens)
        decoded, used = war_text.decode(data, offset)
        if label != decoded or used != end - offset:
            raise ValueError("HUD labels disagree between decoders")
        labels.append(label)
    hud = {"box": {"x": imm(0x2fa0) + 160, "y": imm(0x3228) + 120,
                   "width": imm(0x3238) * 8, "height": imm(0x31dc) * 12},
           "bet_label": labels[0], "money_label": labels[1], "number_columns": imm(0x7594)}
    colors = {}
    for offset in range(0x5c38, 0x5cf0, 4):
        word = scene.u32(data, offset)
        if word >> 26 != 40:
            continue
        field, register = word & 0xffff, word >> 16 & 31
        if register not in (0, 3):
            raise ValueError("unsupported cursor colour store")
        colors[field] = 255 if register == 3 else 0
    cursor = {"offsets": [[0, 0], [0, 0], [imm(0x601c), imm(0x602c)], [imm(0x6034), imm(0x603c)]],
              "colors": [[colors[base + channel] for channel in range(3)] for base in (0x440, 0x448, 0x450, 0x458)]}
    if hud != {"box": {"x": 170, "y": 190, "width": 112, "height": 24},
               "bet_label": "BET     ", "money_label": "MONEY   ", "number_columns": 6} or cursor != {
                   "offsets": [[0, 0], [0, 0], [-6, 8], [6, 8]],
                   "colors": [[255, 0, 0], [255, 0, 0], [0, 0, 0], [0, 0, 0]]}:
        raise ValueError("HUD/cursor extraction disagrees with independent source layout")
    base = struct.unpack_from("<I", main, 0x18)[0]
    def mword(address):
        return struct.unpack_from("<I", main, 2048 + address - base)[0]
    for address, expected in {0x80165658: 0x8014aeb0, 0x80165660: 0x8014886c,
                              0x8014aeb8: 0x34020038, 0x80146ff4: 0x34050010,
                              0x80147010: 0x34020045, 0x80147060: 0x30c600ff}.items():
        if mword(address) != expected:
            raise ValueError("HUD/cursor shared consumer changed")
    return hud, cursor, {"hud": "VB2 0x800131D8..0x80013248/0x80017514..0x8001762C; MAIN 0x80146FE8",
                          "cursor": "VB2 0x80015C08..0x80015D08/0x80016014..0x800161F4; MAIN 0x8014AEB0/0x8014886C",
                          "hud_body_sha256": hashlib.sha256(data[0x7514:0x762c]).hexdigest(),
                          "cursor_init_sha256": hashlib.sha256(data[0x5c08:0x5d08]).hexdigest(),
                          "timing": "HUD capture precedes per-update wallet/wager mutation; cursor coordinates advance before its draw and freeze during roll motion"}


def settled_angles(data: bytes) -> list:
    constants, stores = {0: 0}, {}
    for offset in range(0x2f78, 0x3198, 4):
        word = scene.u32(data, offset)
        op, rs, rt, imm = word >> 26, word >> 21 & 31, word >> 16 & 31, word & 65535
        value = None
        if op == 41 and rs in constants and rt in constants:
            stores[constants[rs] + sx16(imm)] = constants[rt]
        if op == 15:
            value = imm << 16
        elif op in (9, 13) and rs in constants:
            value = constants[rs] + sx16(imm) if op == 9 else constants[rs] | imm
        written = destination(word)
        if written not in (None, 0):
            constants.pop(written, None)
            if value is not None:
                constants[written] = value & 0xffffffff
    bias = sx16(scene.u32(data, 0x6444))
    angles = [[sx16(stores[base + i * 2]) + (bias if axis == 0 else 0)
               for axis, base in enumerate((0x80064b28, 0x80064b38, 0x80064b48))] for i in range(6)]
    if angles != [[-256, 0, 0], [-256, 3072, 0], [768, 0, 0], [2816, 0, 0], [-256, 1024, 0], [1792, 0, 0]]:
        raise ValueError("settled poses disagree with independent source table")
    return angles


def model(data: bytes, main: bytes) -> tuple[dict, list, list]:
    def immediate(offset):
        word = scene.u32(data, offset)
        if word >> 26 != 13 or (word >> 21) & 31:
            raise ValueError("expected source constant")
        return word & 0xffff

    corners = [immediate(o) for o in (0x2fd0, 0x2fdc, 0x2fe8, 0x2ff4)]
    layers = [immediate(o) for o in (0x3000, 0x300c)]
    radius = immediate(0x5220)
    image_base = struct.unpack_from("<I", main, 0x18)[0]
    def sin_cos(angle):
        return struct.unpack_from("<hh", main, 2048 + 0x801725bc - image_base + angle * 4)
    vertices = []
    for latitude in layers:
        sine, cosine = sin_cos(latitude)
        x, z = cosine * radius >> 12, -sine * radius >> 12
        for angle in corners:
            sine, cosine = sin_cos(angle)
            point = [x * cosine >> 12, x * sine >> 12, z]
            # Independent full matrix construction checks the reduced two-axis form.
            check = [radius, 0, 0]
            for rotation in ([0, latitude, 0], [0, 0, angle]):
                matrix = battle_mock.rot_matrix(rotation)
                check = [sum(matrix[i * 3 + j] * check[j] for j in range(3)) >> 12 for i in range(3)]
            if point != check:
                raise ValueError("dice vertex constructions disagree")
            vertices.append(point)
    registers, stores = {}, {}
    for offset in range(0x5468, 0x5884, 4):
        word = scene.u32(data, offset)
        op, base, register, imm = word >> 26, word >> 21 & 31, word >> 16 & 31, word & 65535
        if op == 41 and base in (2, 3) and register in registers:
            face, field = divmod(imm, 40)
            if face < 6 and field in (8, 10, 16, 18, 24, 26, 32, 34):
                stores[face, field] = registers[register]
        written = destination(word)
        if written is not None:
            registers.pop(written, None)
        if op == 37 and base == 29:
            registers[register] = imm
    stack_x = {0x20 + i * 2: i for i in range(4)} | {0x38 + i * 2: i + 4 for i in range(4)}
    faces = []
    for face in range(6):
        indices = []
        for field in (8, 16, 24, 32):
            x, y = stores[face, field], stores[face, field + 2]
            if y != x + 8:
                raise ValueError("dice face coordinates disagree")
            indices.append(stack_x[x])
        faces.append(indices)
    if faces != [[0, 1, 2, 3], [4, 0, 6, 2], [4, 5, 0, 1], [2, 3, 6, 7], [1, 5, 3, 7], [4, 5, 6, 7]]:
        raise ValueError("face stores disagree with independent corner mapping")
    poses = [{"center_x": immediate(x), "center_y": immediate(y), "angles": [0, 0, 0]}
             for x, y in zip((0x3018, 0x3024, 0x3030), (0x303c, 0x303c, 0x3050), strict=True)]
    divisor = immediate(0x5300)
    depth_word = scene.u32(data, 0x5448)
    if divisor != immediate(0x54c8) or depth_word >> 16 != 0x2442:
        raise ValueError("dice screen transform changed")
    return {"vertices": vertices, "coordinate_divisor": divisor, "depth_origin": depth_word & 65535}, faces, poses


def participant_portraits(data: bytes, main: bytes) -> tuple[list, dict, Image.Image]:
    hero, hero_source = source('/SHU.BIN')
    if hero[0] != 8 or hero_source['sha256'] != 'e9fdbee8391cc74349a091428767e208a4255960eeb4a118952cb612088b2428':
        raise ValueError('unsupported hero portrait identity')
    direct = struct.unpack_from('<II', hero, 44)
    header = Parser(hero, 0).parse_header()
    parsed = tuple(header['slots'][i]['raw_file_offset'] for i in (3, 4))
    if direct != parsed:
        raise ValueError('hero portrait references disagree between header parsers')
    section = scene.section_off(data, scene.room_record(data, 8)['section'])
    table = scene.ptr_at(data, section + 0x34)
    custom = {}
    for index in range(scene.MAX_CONTEXTS):
        record = scene.ptr_at(data, table + index * 4)
        if record is None:
            break
        custom[scene.u32(data, record)] = record
    else:
        raise ValueError('unterminated dice custom-image table')
    if 32 not in custom or 8 in custom:
        raise ValueError('fixed dice custom/party lookup changed')
    record = custom[32]
    items = (("opponent", data, scene.ptr_at(data, record + 4), scene.ptr_at(data, record + 8)),
             ("hero", hero, direct[0], direct[1]))
    def imm(offset):
        return sx16(scene.u32(data, offset))
    size, pivot = imm(0x4b70), imm(0x4b84)
    scale_x, scale_y = imm(0x4da8), imm(0x4ba0)
    centers = [(imm(0x4d80) + 160, imm(0x4d8c) + 120),
               (imm(0x4d98) + 160, imm(0x4da0) + 120)]
    if (size, pivot, scale_x, scale_y, imm(0x4dcc)) != (64, 32, -4096, 4096, 1):
        raise ValueError('portrait sprite parameters changed')
    atlas = Image.new('RGBA', (128, 64))
    rows, proof = [], []
    for slot, (name, raw, pixels, palette) in enumerate(items):
        plane, colors, compressed = portrait_payload(raw, pixels, palette)
        vram = gpu.PsxVram()
        vram.upload_rect(896 + slot * 32, 384, 32, 64, plane)
        vram.upload_rect(0, 510 + slot, 256, 1, raw[palette:palette + 512])
        page = gpu.texpage_encode(896, 256, gpu.TP_8BIT)
        clut = gpu.clut_encode(0, 510 + slot)
        image = Image.new('RGBA', (64, 64))
        for y in range(64):
            for x in range(64):
                index = plane[y * 64 + x]
                direct_color = (*gpu.rgb555(colors[index]), 0 if colors[index] == 0 else 255)
                sampled = vram.sample_texel(page, slot * 64 + x, 128 + y)
                word = vram.get_word(sampled, 510 + slot)
                independent = (*vram.sample_color(page, clut, slot * 64 + x, 128 + y), 0 if word == 0 else 255)
                if direct_color != independent:
                    raise ValueError('portrait decode disagrees with independent VRAM sampling')
                image.putpixel((x, y), direct_color)
        atlas.paste(image, (slot * 64, 0))
        rows.append({"role": name, "x": slot * 64, "y": 0, "width": 64, "height": 64,
                     "screen": {"x": centers[slot][0] - pivot, "y": centers[slot][1] - pivot, "width": size, "height": size},
                     "mirror": True, "depth_key": 1})
        proof.append({"role": name, "source": "VB2.BIN" if slot == 0 else "SHU.BIN",
                      "resource_id": 32 if slot == 0 else 8, "image_offset": pixels,
                      "compressed_bytes": compressed, "palette_offset": palette,
                      "plane_sha256": hashlib.sha256(plane).hexdigest(),
                      "rgba_sha256": hashlib.sha256(image.tobytes()).hexdigest()})
    # Independently apply the shared zero-angle Q12 scale/translate path to each corner.
    matrix = battle_mock.rot_matrix([0, 0, 0])
    for slot, row in enumerate(rows):
        points = []
        for x, y in ((-32, -32), (32, -32), (-32, 32), (32, 32)):
            vector = [x * scale_x >> 12, y * scale_y >> 12, 0]
            transformed = [sum(matrix[axis * 3 + j] * vector[j] for j in range(3)) >> 12 for axis in range(2)]
            points.append((transformed[0] + centers[slot][0], transformed[1] + centers[slot][1]))
        bounds = {"x": min(p[0] for p in points), "y": min(p[1] for p in points),
                  "width": max(p[0] for p in points) - min(p[0] for p in points),
                  "height": max(p[1] for p in points) - min(p[1] for p in points)}
        if bounds != row['screen'] or points[0][0] <= points[1][0]:
            raise ValueError('portrait placement disagrees with shared transform')
    return rows, {"hero_source": hero_source, "images": proof,
                  "decoder": "opening portrait_payload/lzss.py decode_strict; 4096-byte8bpp; 256RGB555",
                  "lookup": "VB2 0x80013358/0x80014BC4..0x80014D2C: custom32 then active-party8",
                  "upload": "VB2 0x80014A2C..0x80014B04: two32-word x64-row uploads and separate256-entry CLUTs",
                  "draw": "VB2 0x80014D2C..0x80014DE0; MAIN 0x8014C8E4..0x8014CDBC: mirrored Q12 unit scale, pivot32, depth1",
                  "verification": "two hero-header parsers, complete portrait decoder consumption, 8192 independent RGBA VRAM samples, and Q12 corner transform bounds agree",
                  "rgba_sha256": hashlib.sha256(atlas.tobytes()).hexdigest()}, atlas


def build() -> tuple[dict, Image.Image, Image.Image]:
    data, provenance = source("/VB2.BIN")
    if provenance["sha256"] != SOURCE_SHA256:
        raise ValueError("unsupported VB2 source identity")
    main, main_provenance = source("MAIN.EXE")
    if main_provenance["sha256"] != MAIN_SHA256:
        raise ValueError("unsupported MAIN source identity")
    geometry, topology, poses = model(data, main)
    portraits, portrait_proof, portrait_image = participant_portraits(data, main)
    room = scene.room_record(data, 8)
    section = scene.section_off(data, room["section"])
    table = scene.ptr_at(data, section + 0x34)
    matches = []
    for index in range(scene.MAX_CONTEXTS):
        pointer = scene.u32(data, table + 4 * index)
        if pointer == 0:
            break
        record = scene.to_file(data, pointer)
        if record is None:
            raise ValueError("invalid dice resource pointer")
        if scene.u32(data, record) == 109:
            matches.append(record)
    else:
        raise ValueError("unterminated dice resource table")
    if len(matches) != 1:
        raise ValueError("expected one dice resource")
    record, = matches
    pixels = scene.ptr_at(data, record + 4)
    palette = scene.ptr_at(data, record + 8)
    if pixels is None or palette is None:
        raise ValueError("missing dice texture or palette")
    plane, clut = data[pixels:pixels + 4096], data[palette:palette + 32]
    if len(plane) != 4096 or len(clut) != 32:
        raise ValueError("truncated dice upload")
    words = struct.unpack("<16H", clut)
    if words[0] != 0 or 0 in words[1:]:
        raise ValueError("dice transparency assignment changed")
    vram = gpu.PsxVram()
    vram.upload_rect(832, 256, 32, 64, plane)
    vram.upload_rect(832, 320, 16, 1, clut)
    page, colors = gpu.texpage_encode(832, 256, gpu.TP_4BIT), gpu.clut_encode(832, 320)
    independent = vram.sample_piece(page, colors, 0, 0, 96, 16, transparent_index=0)
    image = Image.new("RGBA", (96, 16))
    for y in range(16):
        for x in range(96):
            index = (plane[y * 64 + x // 2] >> (4 * (x & 1))) & 15
            color = (*gpu.rgb555(words[index]), 255) if index else (0, 0, 0, 0)
            if color != independent[y][x]:
                raise ValueError("direct decode disagrees with upload/sample")
            image.putpixel((x, y), color)
    messages, message_proof = entry_messages(data)
    results, result_proof = result_messages(data)
    layout, layout_proof = entry_layout(data, main)
    hud, cursor, hud_proof = hud_and_cursor(data, main)
    report = {
        "schema": "suikoden-dice-presentation/8",
        "decoder": "export_dice_presentation/8",
        "source": provenance,
        "main_source": main_provenance,
        "room": 8,
        "section": room["section"],
        "resource_id": 109,
        "resource_record_offset": record,
        "pixels": {"offset": pixels, "bytes": 4096, "width": 128, "height": 64, "bits_per_pixel": 4},
        "palette": {"offset": palette, "entries": 16, "format": "rgb555"},
        "image": "faces.png",
        "rgba_sha256": hashlib.sha256(image.tobytes()).hexdigest(),
        "faces": [{"id": i + 1, "x": i * 16, "y": 0, "width": 16, "height": 16, "vertices": topology[i]} for i in range(6)],
        "model": geometry,
        "initial_poses": poses,
        "portraits": portraits,
        "portrait_evidence": portrait_proof,
        "entry_messages": messages,
        "result_messages": results,
        "result_message_evidence": result_proof,
        "entry_layout": layout,
        "hud": hud,
        "cursor": cursor,
        "hud_cursor_evidence": hud_proof,
        "entry_layout_evidence": layout_proof,
        "entry_message_evidence": message_proof,
        "settled_angles": settled_angles(data),
        "draw_evidence": draw_evidence(main, geometry, topology, poses),
        "animation_evidence": {
            "flight_init": {"address": "0x800161F4", "sha256": hashlib.sha256(data[0x61f4:0x6400]).hexdigest()},
            "face_alignment": {"address": "0x80016400", "sha256": hashlib.sha256(data[0x6400:0x647c]).hexdigest()},
            "motion": {"address": "0x8001647C", "sha256": hashlib.sha256(data[0x647c:0x6c58]).hexdigest()},
            "spin": {"address": "0x80015B7C", "sha256": hashlib.sha256(data[0x5b7c:0x5c08]).hexdigest()},
        },
        "model_evidence": {"vertices": "0x80014F78..0x80015108", "transform": "0x800152BC..0x800158A8", "depth": "0x800158A8..0x80015954", "matrix": "MAIN.EXE 0x80142DB0/0x8014FCB4; battle_mock.rot_matrix", "verification": "two-axis formula agrees with full matrix rotation; coordinate-store walk agrees with independent face mapping"},
        "evidence": {"select": "0x80013290", "lookup": "0x80014DE0", "upload": "0x80014EA8", "face_uv": "0x80015108..0x800151C8", "draw": "0x800158A8"},
        "independent_verification": "direct nibble decode agrees with PsxVram upload/sample for all 1536 RGBA pixels",
        "media_review": "pending",
    }
    return report, image, portrait_image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "kit/work/build/review/dice")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    report, image, portraits = build()
    encoded = json.dumps(report, indent=2) + "\n"
    if args.check:
        if REPORT.read_text() != encoded:
            raise SystemExit("dice presentation report is stale")
    else:
        args.output.mkdir(parents=True, exist_ok=True)
        image.save(args.output / "faces.png")
        portraits.save(args.output / "portraits.png")
        image.resize((768, 128), Image.Resampling.NEAREST).save(args.output / "review.png")
        (args.output / "manifest.json").write_text(encoded)
        REPORT.write_text(encoded)
    print("PASS: dice faces, portraits, model and dialogue independently decoded; media acceptance pending")


if __name__ == "__main__":
    main()
