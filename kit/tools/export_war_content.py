#!/usr/bin/env python3
"""Export deterministic war presentation resources and source composition contracts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

import vab_tones
import vag_extract
import war_graphics
import war_map
import war_strings
import war_text

SCHEMA = "suikoden-war-content/2"
OUTPUTS = ("game/assets/war/content_manifest.json", "game/assets/war/resources.zig", "game/assets/war/resources.bin")
NAMES = {
    "WAR_KUWA.BIN": "pannu_yakuta", "WAR_GARA.BIN": "garan",
    "WAR_SCA1.BIN": "scarleticia_pollen", "WAR_SCA2.BIN": "scarleticia_antidote",
    "WAR_TEO1.BIN": "teo_before_fire_spear", "WAR_TEO2.BIN": "teo_fire_spear",
    "WAR_KITA.BIN": "northern_checkpoint", "WAR_SHAS.BIN": "shasarazade",
    "WAR_LAST.BIN": "gregminster",
}


class ContentError(ValueError):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def serialize(value) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode()


def source_record(name: str) -> dict:
    record = war_strings.war_files()[name]
    raw = war_text.load(name)
    return {"file": war_text.WAR_DIR + name, "lba": record["lba"], "size": len(raw), "sha256": sha256(raw)}


class Resources:
    def __init__(self):
        self.rows = []
        self.by_identity = {}

    def add(self, kind: str, data: bytes, palette: bytes | None, provenance: dict) -> str:
        identity = (kind, sha256(data), sha256(palette) if palette is not None else None)
        if identity in self.by_identity:
            return self.by_identity[identity]
        ident = f"r{len(self.rows) + 1:06d}"
        self.by_identity[identity] = ident
        self.rows.append({"id": ident, "kind": kind, "data": data, "palette": palette,
                          "data_sha256": sha256(data),
                          "palette_sha256": sha256(palette) if palette is not None else None,
                          "provenance": provenance})
        return ident


def map_resource(raw: bytes, name: str, descriptor: dict, resources: Resources) -> dict:
    off = descriptor["off"]
    cells_ptr = struct.unpack_from("<I", raw, off + 20)[0] - war_text.OVERLAY_BASE
    if cells_ptr < 0 or cells_ptr + descriptor["w"] * descriptor["h"] * 2 > len(raw):
        raise ContentError(f"invalid map cell pointer: {name}/{off:#x}")
    cells = list(struct.unpack_from(f"<{descriptor['w'] * descriptor['h']}H", raw, cells_ptr))
    for code in cells:
        if code >> 6 >= len(descriptor["blocks"]):
            raise ContentError(f"map cell references missing page: {name}/{off:#x}: {code:#x}")
    pages = []
    for block_off, pixels in descriptor["blocks"]:
        palette = raw[descriptor["clut_off"]:descriptor["clut_off"] + 512]
        if len(palette) != 512:
            raise ContentError(f"truncated map palette: {name}/{off:#x}")
        pages.append(resources.add("map_page", pixels, palette,
                                   {"file": war_text.WAR_DIR + name, "descriptor_offset": off,
                                    "block_offset": block_off, "clut_offset": descriptor["clut_off"]}))
    return {"descriptor_offset": off, "width": descriptor["w"], "height": descriptor["h"],
            "cell_offset": cells_ptr, "cells": cells, "pages": pages,
            "composition": {"row_stride_cells": descriptor["w"], "page": "code >> 6",
                            "tile": "code & 63", "tile_width": 32, "tile_height": 32,
                            "source_tile_width": 16, "source_tile_height": 16,
                            "page_width": 128, "page_height": 128,
                            "pixel_width": descriptor["w"] * 32, "pixel_height": descriptor["h"] * 32}}


def sprite_poses(raw: bytes, descriptor: dict) -> list[dict]:
    count = descriptor["w"] * descriptor["h"]
    cell_offset = struct.unpack_from("<I", raw, descriptor["off"] + 20)[0] - war_text.OVERLAY_BASE
    if cell_offset < 0 or cell_offset + count * 8 > len(raw):
        raise ContentError(f"invalid sprite script table: {descriptor['off']:#x}")
    poses = []
    for index in range(count):
        script = struct.unpack_from("<I", raw, cell_offset + index * 8)[0]
        if not war_text.OVERLAY_BASE <= script < war_text.OVERLAY_BASE + len(raw):
            continue
        script_offset = script - war_text.OVERLAY_BASE
        cursor = script_offset
        secondary = 0
        while cursor < len(raw):
            opcode = raw[cursor]
            cursor += 1
            if opcode in (1, 3):
                # A zero-initialized descriptor reaches its row limit on the first row end.
                # 80146A90 clamps the row byte to FF and passes extent 8 to 801458C8.
                poses.append({"script_offset": script_offset, "frame": 0, "width": 8,
                              "height": 8, "secondary": secondary, "flags": 255})
                break
            if opcode in (0, 2) or opcode >= 16:
                # A literal reaches the column limit immediately on this zero-width descriptor.
                break
            if opcode in (4, 5, 6, 7, 8):
                operand_count = 2 if opcode == 7 else 1
                operands = raw[cursor:cursor + operand_count]
                if len(operands) != operand_count:
                    raise ContentError(f"truncated sprite descriptor prefix: {script_offset:#x}")
                cursor += operand_count
                if opcode == 4:
                    secondary = operands[0]
                elif opcode == 5:
                    break
                elif opcode in (6, 7):
                    # The extracted descriptor has no bound text. Selector 3 either
                    # skips the empty text or emits a numeric literal on the zero-width row.
                    expected = b"\x03" if opcode == 6 else b"\x03\x01"
                    if operands != expected:
                        raise ContentError(f"unrecognized sprite descriptor text: {script_offset:#x}")
            elif opcode == 15:
                raise ContentError(f"unrecognized sprite descriptor positioning: {script_offset:#x}")
        else:
            raise ContentError(f"unterminated sprite descriptor prefix: {script_offset:#x}")
    return poses


def atlas_resource(raw: bytes, name: str, descriptor: dict, resources: Resources) -> dict:
    block_off, pixels = descriptor["blocks"][0]
    palette = raw[descriptor["clut_off"]:descriptor["clut_off"] + 512]
    return {"descriptor_offset": descriptor["off"], "width": descriptor["w"], "height": descriptor["h"],
            "poses": sprite_poses(raw, descriptor),
            "resource": resources.add("sprite_atlas", pixels, palette,
                                      {"file": war_text.WAR_DIR + name, "descriptor_offset": descriptor["off"],
                                       "block_offset": block_off, "clut_offset": descriptor["clut_off"]})}


def export() -> dict:
    resources = Resources()
    scenarios = []
    for selector, name in enumerate(war_text.SELECTOR_ORDER):
        raw = war_text.load(name)
        descriptors = war_map.descriptors(raw)
        maps = [map_resource(raw, name, d, resources) for d in descriptors if d["kind"] == "map"]
        maps.sort(key=lambda row: (row["width"] < 20, row["descriptor_offset"]))
        atlases = [atlas_resource(raw, name, d, resources) for d in descriptors if d["kind"] == "atlas"]
        portraits = []
        for block in war_graphics.blocks(raw):
            if len(block["indices"]) != 4096:
                raise ContentError(f"portrait size: {name}/{block['index']}")
            palette = raw[block["pal_off"]:block["pal_off"] + 512]
            portraits.append(resources.add("portrait", block["indices"], palette,
                                           {"file": war_text.WAR_DIR + name,
                                            "block_offset": block["off"], "palette_offset": block["pal_off"],
                                            "portrait_index": block["index"]}))
        scenarios.append({
            "selector": selector, "id": NAMES[name], "source": source_record(name),
            "maps": maps, "atlases": atlases, "portraits": portraits,
            "roster": [{"offset": off, "name": text} for off, text in war_text.roster(raw)],
            "quotes": [{"offset": off, "text": text} for off, text in war_text.leader_quotes(raw)],
            "attacks": [{"offset": off, "flags": flags, "name": text} for off, flags, text in war_text.attack_table(raw)],
            "ui": [{"offset": off, "text": text} for off, text in war_text.ui_strings(raw)],
            "script": [{"offset": off, "text": text} for off, text in war_text.script_strings(raw)],
            "terrain_code_pages": [{"descriptor_offset": d["off"],
                                    "block_offsets": [off for off, _buf in d["blocks"]],
                                    "blocks_sha256": [sha256(buf) for _off, buf in d["blocks"]]}
                                   for d in descriptors if d["kind"] == "grid"],
        })
    va = war_text.load("WAR.VA")
    vb = war_text.load("WAR.VB")
    ps, ts, vs = vab_tones.parse_header(va)
    programs = vab_tones.parse_programs(va, ps)[0]
    start, stride, tones = vab_tones.find_tone_table(va, ts, ps, vs, programs)
    parts = vag_extract.split_vb(va, vb)
    if len(parts) != vs:
        raise ContentError("WAR VAB sample count mismatch")
    va_ref = resources.add("vab_header", va, None, source_record("WAR.VA"))
    vb_ref = resources.add("adpcm_bank", vb, None, source_record("WAR.VB"))
    audio = {
        "header": va_ref, "body": vb_ref, "program_count": ps, "tone_count": ts, "sample_count": vs,
        "tone_table": {"offset": start, "stride": stride,
                       "programs": [{"program": index, "tones": rows} for index, rows in enumerate(tones) if rows]},
        "samples": [{"index": index, "blocks": len(blocks), "bytes": sum(len(block) for block in blocks),
                     "sha256": sha256(b"".join(blocks))} for index, blocks in enumerate(parts)],
        "xa2": {"file": "DATA/16_WAR/XA2.", "format": "CD-XA Form2 stereo; source stream identity required by platform adapter; no playback in exporter",
                "channels": [{"index": index, "path": f"xa/xa2_ch{index}.wav"} for index in range(3)]},
    }
    manifest = {
        "schema": SCHEMA, "id": "war_content", "target": "Suikoden I US v1.1 SLUS_002.92",
        "scenarios": scenarios, "audio": audio,
        "resources": [{"id": row["id"], "kind": row["kind"], "data_sha256": row["data_sha256"],
                       "palette_sha256": row["palette_sha256"], "provenance": row["provenance"]}
                      for row in resources.rows],
    }
    raw = bytearray()
    spans: dict[bytes, tuple[int, int]] = {}

    def pack(data: bytes) -> tuple[int, int]:
        span = spans.get(data)
        if span is None:
            span = (len(raw), len(data))
            spans[data] = span
            raw.extend(data)
        return span

    zig = [
        'const raw = @embedFile("resources.bin");\n',
        "pub const Entry = struct { id: []const u8, kind: []const u8, data: []const u8, palette: ?[]const u8 };\n",
        "pub const entries = [_]Entry{\n",
    ]
    for row in resources.rows:
        d_off, d_len = pack(row["data"])
        if row["palette"] is not None:
            p_off, p_len = pack(row["palette"])
            pal_expr = f"raw[{p_off}..{p_off + p_len}]"
        else:
            pal_expr = "null"
        zig.append(
            f'    .{{ .id = "{row["id"]}", .kind = "{row["kind"]}", .data = raw[{d_off}..{d_off + d_len}], .palette = {pal_expr} }},\n'
        )
    zig.append("};\n")
    return {"manifest": manifest, "zig": "".join(zig).encode(), "bin": bytes(raw), "resource_count": len(resources.rows)}


def output_bytes(exported: dict) -> dict[str, bytes]:
    return {
        "game/assets/war/content_manifest.json": serialize(exported["manifest"]),
        "game/assets/war/resources.zig": exported["zig"],
        "game/assets/war/resources.bin": exported["bin"],
    }


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        exported = export()
        expected = output_bytes(exported)
        mismatches = []
        for relative, data in expected.items():
            path = args.output_root.resolve() / relative
            if args.check:
                if not path.is_file():
                    mismatches.append(f"missing {relative}")
                elif path.read_bytes() != data:
                    mismatches.append(f"stale {relative}")
            else:
                atomic_write(path, data)
        if mismatches:
            for row in mismatches:
                print(row, file=sys.stderr)
            return 1
        print(("checked" if args.check else "generated") + f" {len(expected)} war content outputs; scenarios 9; resources {len(exported['manifest']['resources'])}")
        return 0
    except (ContentError, OSError, KeyError, IndexError, TypeError, ValueError) as error:
        print(f"war content export failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
