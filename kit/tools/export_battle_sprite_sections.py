#!/usr/bin/env python3
"""Decode the shared 04_PLAY battle sprite/animation section contract.

The decoder is a guarded candidate for the accepted subset in
``export_battle_trial.section_art``. It reads the section tables named by
``0x800E211C``, resolves the source page/palette/UV/flip conventions, and
emits one named runtime manifest plus a candidate atlas.  The module does not
render a battle scene and does not modify any caller.

Source formats
--------------
Section header (18 bytes, two pointer conventions):

    +0x00 u16 e_count
    +0x02 u16 f_count
    +0x04 u8  c_count
    +0x05 u8  d_flags       bits 7-6 palette band, bits 5-0 palette count
    +0x06 u8  slot base     runtime setter value; 0 in the 04_PLAY files
    +0x07 u8  palette row base
    +0x08 u32 c table       [u32 comp_len][LZSS 128x128 8-bit page]
    +0x0C u32 d table       32 or 256 RGB555 words per palette
    +0x10 u32 e table       pose records
    +0x14 u32 f table       animation records

Pose record: ``u8 count, u8 reserved, u8 width, u8 height, u8 anchor_x,
u8 anchor_y, u16 reserved`` followed by ``count`` eight-byte sub-pieces:

    x, y, page delta, packed u/v tile, UV width span, UV height span, palette delta, flags

Animation record: ``u8 count, u8 flags, u8 draw_capacity, u8 reserved`` then
``count`` pairs of ``(e index, duration)``.

The source consumer at ``0x800E211C`` adds ``section[6]`` to the page delta and
``section[7]`` to the palette delta, computes the page slot from the source
upload formula, forms the UV start from the packed tile byte, and applies the
flags.  The accepted subset in ``section_art`` omitted the page/palette bases,
ignored the bit-7 reflection flag, and rejected a one-pixel page-edge sample.
Unsupported control flow, unresolved poses and unavailable neighboring pages
are refused; this candidate is not connected to the existing callers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

from actor_script import OP_LEN_HW  # noqa: E402
from export_first_room import ROOT, source  # noqa: E402
from lzss import decode_strict  # noqa: E402
from psx_vram import rgb555_to_rgb888  # noqa: E402

SCHEMA = "suikoden-battle-sprite-sections/1"
PROOF_SCHEMA = "suikoden-battle-sprite-sections-proof/1"
DEFAULT_CHARACTERS = (
    "ted", "odessa", "stallion", "humphrey", "luc", "blackman", "kirke",
    "lester", "sonya", "cleo", "juppo", "sydonia", "hero",
)
C_REPORT_SHA256 = "6accfeb5be8ede1a0d2c1abe1eb4fa9c8bf35cae00ac983bbc43bcb25f15d71f"
DEFAULT_CATALOGUE = ROOT / "game/assets/party_session/catalogue.json"
PAGE_SIZE = 128
PAGE_BYTES = PAGE_SIZE * PAGE_SIZE
ATLAS_WIDTH = 4096
ATLAS_MAX_HEIGHT = 4096


class SectionError(ValueError):
    """A precise, source-qualified format refusal."""

    def __init__(self, code: str, detail: str, *, address: int | None = None,
                 character: str | None = None):
        self.code = code
        self.detail = detail
        self.address = address
        self.character = character
        prefix = f"{character}: " if character else ""
        suffix = f" at 0x{address:08x}" if address is not None else ""
        super().__init__(f"{prefix}{code}: {detail}{suffix}")


@dataclass
class Page:
    index: int
    slot: int
    source_offset: int
    comp_len: int
    raw: bytes
    raw_sha256: str
    vram_x_words: int
    vram_y: int


@dataclass
class Palette:
    index: int
    source_offset: int
    words: tuple[int, ...]
    colors: tuple[tuple[int, int, int], ...]


@dataclass
class Piece:
    source_offset: int
    x: int
    y: int
    page: int
    tile: int
    u: int
    v: int
    width: int
    height: int
    palette: int
    flip_x: bool
    flip_y: bool
    outside_samples: int
    cross_page_samples: int
    edge_samples: tuple[dict[str, Any], ...]


@dataclass
class Pose:
    index: int
    source_offset: int
    header_width: int
    header_height: int
    anchor_x: int
    anchor_y: int
    image: Image.Image
    pieces: tuple[Piece, ...]


@dataclass
class Animation:
    index: int
    source_offset: int
    pairs: tuple[tuple[int, int], ...]
    ticks_total: int
    resolved: bool
    missing_poses: tuple[int, ...]
    used_by_scripts: tuple[int, ...]


@dataclass
class Section:
    character_id: str
    resource: str
    resource_sha256: str
    section_offset: int
    base: int
    e_count: int
    f_count: int
    c_count: int
    d_flags: int
    slot_base: int
    palette_base: int
    pages: tuple[Page, ...]
    palettes: tuple[Palette, ...]
    poses: tuple[Pose, ...]
    animations: tuple[Animation, ...]
    scripts: dict[int, tuple[int, ...]]
    table_offsets: dict[str, int]
    pointer_values: dict[str, int]


class ShelfAtlas:
    """Deterministic shelf packer; no catalogue of its own."""

    def __init__(self, width: int = ATLAS_WIDTH, max_height: int = ATLAS_MAX_HEIGHT):
        self.image = Image.new("RGBA", (width, max_height))
        self.x = self.y = self.row_height = 0

    def add(self, image: Image.Image) -> dict[str, int]:
        w, h = image.size
        if w > self.image.width or h > self.image.height:
            raise SectionError("atlas_image_too_large", f"{w}x{h}")
        if self.x + w > self.image.width:
            self.x = 0
            self.y += self.row_height + 1
            self.row_height = 0
        if self.y + h > self.image.height:
            raise SectionError("atlas_capacity_exceeded", f"needs y={self.y + h}")
        rect = {"x": self.x, "y": self.y, "w": w, "h": h}
        self.image.paste(image, (self.x, self.y))
        self.x += w + 1
        self.row_height = max(self.row_height, h)
        return rect

    def finish(self) -> Image.Image:
        height = self.y + self.row_height
        if height <= 0:
            return Image.new("RGBA", (1, 1))
        return self.image.crop((0, 0, self.image.width, height))


def _u8(data: bytes, offset: int, label: str, character: str | None = None) -> int:
    if not 0 <= offset < len(data):
        raise SectionError("truncated_table", label, address=offset, character=character)
    return data[offset]


def _u16(data: bytes, offset: int, label: str, character: str | None = None) -> int:
    if not 0 <= offset + 2 <= len(data):
        raise SectionError("truncated_table", label, address=offset, character=character)
    return struct.unpack_from("<H", data, offset)[0]


def _u32(data: bytes, offset: int, label: str, character: str | None = None) -> int:
    if not 0 <= offset + 4 <= len(data):
        raise SectionError("truncated_table", label, address=offset, character=character)
    return struct.unpack_from("<I", data, offset)[0]


def _pointer(data: bytes, offset: int, base: int, label: str,
             character: str | None = None) -> tuple[int, int]:
    raw = _u32(data, offset, label, character)
    target = raw - base
    if not 0 <= target < len(data):
        raise SectionError("pointer_outside_source", f"{label} -> 0x{raw:08x}",
                           address=offset, character=character)
    return target, raw


def _table(data: bytes, section: int, field: int, count: int, base: int,
           label: str, character: str | None) -> tuple[list[int], int, list[int]]:
    table, raw_table = _pointer(data, section + field, base, f"{label} table", character)
    if count < 0 or count > 4096:
        raise SectionError("invalid_table_count", f"{label}={count}", address=section + field,
                           character=character)
    if table + 4 * count > len(data):
        raise SectionError("truncated_table", f"{label} table", address=table, character=character)
    offsets: list[int] = []
    raws: list[int] = []
    for i in range(count):
        target, raw = _pointer(data, table + 4 * i, base, f"{label}[{i}]", character)
        offsets.append(target)
        raws.append(raw)
    return offsets, table, raws


def _decode_page(data: bytes, blob_offset: int, index: int, character: str | None) -> Page:
    length = _u32(data, blob_offset, f"c[{index}] length", character)
    if length <= 0 or blob_offset + 4 + length > len(data):
        raise SectionError("truncated_c_page", f"c[{index}] len={length}",
                           address=blob_offset, character=character)
    try:
        raw = decode_strict(data[blob_offset + 4:blob_offset + 4 + length])
    except Exception as exc:  # decode_strict raises its own type; keep the source address
        raise SectionError("c_page_decode_failed", f"c[{index}]: {exc}",
                           address=blob_offset, character=character) from exc
    if len(raw) != PAGE_BYTES:
        raise SectionError("c_page_size", f"c[{index}] decoded {len(raw)} != {PAGE_BYTES}",
                           address=blob_offset, character=character)
    return Page(index=index, slot=0, source_offset=blob_offset, comp_len=length, raw=raw,
                raw_sha256=hashlib.sha256(raw).hexdigest(), vram_x_words=0, vram_y=0)


def _palette(data: bytes, pointer_offset: int, index: int, words: int,
             character: str | None) -> Palette:
    target, _ = _pointer(data, pointer_offset, 0, f"d[{index}]", character)
    # d pointers are resolved by the caller's base; this helper is only used
    # after the caller supplies a file-relative target.
    if target + words * 2 > len(data):
        raise SectionError("truncated_palette", f"d[{index}] words={words}",
                           address=target, character=character)
    values = struct.unpack_from("<" + "H" * words, data, target)
    colors = tuple(rgb555_to_rgb888(word) for word in values)
    return Palette(index=index, source_offset=target, words=tuple(values), colors=colors)


def _palette_at(data: bytes, target: int, index: int, words: int,
                character: str | None) -> Palette:
    if target + words * 2 > len(data):
        raise SectionError("truncated_palette", f"d[{index}] words={words}",
                           address=target, character=character)
    values = struct.unpack_from("<" + "H" * words, data, target)
    colors = tuple(rgb555_to_rgb888(word) for word in values)
    return Palette(index=index, source_offset=target, words=tuple(values), colors=colors)


def _resolve_script_animations(data: bytes, table_offset: int, character: str | None) -> dict[int, tuple[int, ...]]:
    """Read the action-script table only to know which animations are used.

    The table at character +0x20 is an array of eight or more script pointers.
    We walk a bounded number of entries until a pointer leaves the source; the
    decoder itself never assumes an animation number implies a script.
    """
    if not 0 <= table_offset + 4 <= len(data):
        raise SectionError("script_table_outside_source", "", address=table_offset,
                           character=character)
    scripts: dict[int, tuple[int, ...]] = {}
    for index in range(16):
        if table_offset + 4 * index + 4 > len(data):
            break
        cursor = _u32(data, table_offset + 4 * index, f"script[{index}]", character)
        if not 0 < cursor < len(data):
            break
        used: list[int] = []
        seen: set[int] = set()
        for _ in range(512):
            if cursor in seen:
                raise SectionError("script_cycle", f"script[{index}]", address=cursor,
                                   character=character)
            seen.add(cursor)
            if cursor + 2 > len(data):
                raise SectionError("truncated_script", f"script[{index}]", address=cursor,
                                   character=character)
            op = struct.unpack_from("<h", data, cursor)[0]
            if op in (0, 1):
                break
            if op == 42:
                if cursor + 4 > len(data):
                    raise SectionError("truncated_script", f"script[{index}] op={op}",
                                       address=cursor, character=character)
                count = struct.unpack_from("<h", data, cursor + 2)[0]
                if count < 0:
                    raise SectionError("unsupported_script_control_flow", f"script[{index}] op={op}",
                                       address=cursor, character=character)
                length = 2 + count
            else:
                length = OP_LEN_HW.get(op)
                if length is None or length <= 0:
                    raise SectionError("unsupported_script_control_flow", f"script[{index}] op={op}",
                                       address=cursor, character=character)
            if cursor + 2 * length > len(data):
                raise SectionError("truncated_script", f"script[{index}] op={op}",
                                   address=cursor, character=character)
            args = struct.unpack_from("<" + "h" * (length - 1), data, cursor + 2)
            if op == 4:
                used.append(args[0])
            cursor += 2 * length
        else:
            raise SectionError("runaway_script", f"script[{index}]", address=cursor,
                               character=character)
        scripts[index] = tuple(used)
    return scripts


def _page_coords(slot: int) -> tuple[int, int]:
    return 64 * (5 * (slot // 20) + (slot % 5)) + 0x140, 128 * ((slot % 20) // 5)


def _sample_pixel(pages: tuple[Page, ...], page: int, u: int, v: int) -> tuple[int, int, bool]:
    """Return (page index, index, outside) for a source UV.

    The uploader places c pages in 64-word columns, five per 128-row band.  A
    sub-piece may reach one texel past the 128-pixel page.  The original quad
    consumer keeps that UV rather than clipping it.  We model the adjacent
    uploaded page when it is in the same row; otherwise the sample is outside
    the decoded source and is refused by the caller. This is not a coordinate clamp.
    """
    outside = False
    if u >= PAGE_SIZE:
        if page % 5 == 4:
            outside = True
        else:
            page += 1
            u -= PAGE_SIZE
    if v >= PAGE_SIZE:
        page += 5
        v -= PAGE_SIZE
    if outside or not 0 <= page < len(pages) or not 0 <= u < PAGE_SIZE or not 0 <= v < PAGE_SIZE:
        raise SectionError("unavailable_adjacent_page", f"page={page} u={u} v={v}")
    return page, pages[page].raw[v * PAGE_SIZE + u], False


def _pose_image(section: Section, pose_offset: int, index: int,
                character: str | None, axis_aligned_packet: bool = False) -> Pose:
    count = _u8(section_data(section), pose_offset, f"e[{index}] count", character)
    data = section_data(section)
    if count == 0:
        raise SectionError("empty_pose", f"e[{index}]", address=pose_offset,
                           character=character)
    if pose_offset + 8 + 8 * count > len(data):
        raise SectionError("truncated_pose", f"e[{index}] count={count}",
                           address=pose_offset, character=character)
    header_width = data[pose_offset + 2]
    header_height = data[pose_offset + 3]
    anchor_x = data[pose_offset + 4]
    anchor_y = data[pose_offset + 5]
    width = header_width
    height = header_height
    pieces: list[Piece] = []
    for k in range(count):
        off = pose_offset + 8 + 8 * k
        x, y, page_delta, tile, wm, hm, pal_delta, flags = data[off:off + 8]
        if page_delta >= len(section.pages):
            raise SectionError("piece_page_out_of_range",
                               f"e[{index}] pic={k} page={page_delta} pages={len(section.pages)}",
                               address=off, character=character)
        if pal_delta >= len(section.palettes):
            raise SectionError("piece_palette_out_of_range",
                               f"e[{index}] pic={k} palette={pal_delta} palettes={len(section.palettes)}",
                               address=off, character=character)
        if flags & ~0x83:
            raise SectionError("unsupported_piece_flags",
                               f"e[{index}] pic={k} flags=0x{flags:02x}",
                               address=off, character=character)
        # Bit 7 is a page-phase reflection in the original consumer; the
        # accepted formats in this family use bits 1/0.  Do not invent its
        # semantics for data that has not been compared to the walker.
        if flags & 0x80:
            raise SectionError("unsupported_page_reflection",
                               f"e[{index}] pic={k} flags=0x{flags:02x}",
                               address=off, character=character)
        u = (tile & 15) * 8
        v = (tile >> 4) * 8
        if axis_aligned_packet and (flags & 3 or wm == 0 or hm == 0):
            raise SectionError("unsupported_packet_footprint", f"e[{index}] pic={k}", address=off, character=character)
        # Zero-rotation packets exclude their lower-right XY/UV endpoints.
        w = wm if axis_aligned_packet else wm + 1
        h = hm if axis_aligned_packet else hm + 1
        width = max(width, x + w)
        height = max(height, y + h)
        part = Image.new("RGBA", (w, h))
        outside = 0
        crossed = 0
        edges: list[dict[str, Any]] = []
        edge_keys: set[tuple[int, int]] = set()
        for py in range(h):
            for px in range(w):
                actual_page, value, is_outside = _sample_pixel(section.pages, page_delta, u + px, v + py)
                if actual_page != page_delta:
                    crossed += 1
                if is_outside:
                    outside += 1
                if actual_page != page_delta or is_outside:
                    key = (px, py)
                    if key not in edge_keys:
                        edge_keys.add(key)
                        edges.append({"u": u + px, "v": v + py, "row": py, "col": px})
                if is_outside:
                    raise SectionError("unavailable_adjacent_page",
                                       f"e[{index}] pic={k} u={u + px} v={v + py}",
                                       address=off, character=character)
                palette = section.palettes[pal_delta]
                if value >= len(palette.words):
                    raise SectionError("palette_index_out_of_range",
                                       f"e[{index}] pic={k} index={value} words={len(palette.words)}",
                                       address=off, character=character)
                word = palette.words[value]
                part.putpixel((px, py), (*rgb555_to_rgb888(word), 0 if word == 0 else 255))
        if flags & 0x02:
            part = part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if flags & 0x01:
            part = part.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        pieces.append(Piece(source_offset=off, x=x, y=y, page=page_delta, tile=tile,
                            u=u, v=v, width=w, height=h, palette=pal_delta,
                            flip_x=bool(flags & 0x02), flip_y=bool(flags & 0x01),
                            outside_samples=outside, cross_page_samples=crossed, edge_samples=tuple(edges)))
    image = Image.new("RGBA", (width, height))
    for piece in pieces:
        # Rebuild the part from the same source; this keeps compositing separate
        # from the semantic record above and avoids storing mutable images.
        part = Image.new("RGBA", (piece.width, piece.height))
        for py in range(piece.height):
            for px in range(piece.width):
                _, value, is_outside = _sample_pixel(section.pages, piece.page,
                                                     piece.u + px, piece.v + py)
                if is_outside:
                    raise SectionError("unavailable_adjacent_page", "", address=piece.source_offset,
                                       character=character)
                palette = section.palettes[piece.palette]
                if value >= len(palette.words):
                    raise SectionError("palette_index_out_of_range", "", address=piece.source_offset,
                                       character=character)
                word = palette.words[value]
                part.putpixel((px, py), (*rgb555_to_rgb888(word), 0 if word == 0 else 255))
        if piece.flip_x:
            part = part.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if piece.flip_y:
            part = part.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        image.alpha_composite(part, (piece.x, piece.y))
    return Pose(index=index, source_offset=pose_offset, header_width=header_width,
                header_height=header_height, anchor_x=anchor_x, anchor_y=anchor_y,
                image=image, pieces=tuple(pieces))


# The helper above needs the Section before it exists; keep the raw bytes in a
# tiny context-local attribute to avoid a second decoding path.
def section_data(section: Section) -> bytes:
    return section._data  # type: ignore[attr-defined]


def decode_section(data: bytes, section_offset: int, *, base: int = 0,
                   character_id: str | None = None,
                   resource: str = "", resource_sha256: str = "",
                   parse_scripts: bool = False, axis_aligned_packet: bool = False) -> Section:
    """Default inclusive inspection; opt in to the unflipped, zero-rotation packet footprint."""
    if not 0 <= section_offset + 24 <= len(data):
        raise SectionError("truncated_section", "", address=section_offset,
                           character=character_id)
    e_count, f_count = struct.unpack_from("<HH", data, section_offset)
    c_count, d_flags = data[section_offset + 4], data[section_offset + 5]
    slot_base, palette_base = data[section_offset + 6], data[section_offset + 7]
    if slot_base != 0 or palette_base != 0:
        raise SectionError("unsupported_page_or_palette_base", "nonzero bases require source-backed residency",
                           address=section_offset + 6, character=character_id)
    if c_count == 0:
        raise SectionError("no_c_pages", "", address=section_offset, character=character_id)
    palette_count = d_flags & 0x3F
    if palette_count == 0:
        raise SectionError("no_d_palettes", "", address=section_offset, character=character_id)
    c_offsets, c_table, _ = _table(data, section_offset, 8, c_count, base, "c", character_id)
    d_offsets, d_table, _ = _table(data, section_offset, 12, palette_count, base, "d", character_id)
    e_offsets, e_table, _ = _table(data, section_offset, 16, e_count, base, "e", character_id)
    f_offsets, f_table, _ = _table(data, section_offset, 20, f_count, base, "f", character_id)

    pages: list[Page] = []
    for i, off in enumerate(c_offsets):
        page = _decode_page(data, off, i, character_id)
        slot = (slot_base + i) & 0xFF
        x, y = _page_coords(slot)
        page.slot = slot
        page.vram_x_words = x
        page.vram_y = y
        pages.append(page)

    words = 32 if d_flags & 0xC0 else 256
    palettes = [_palette_at(data, off, i, words, character_id) for i, off in enumerate(d_offsets)]

    section = Section(character_id=character_id or "", resource=resource,
                      resource_sha256=resource_sha256,
                      section_offset=section_offset, base=base,
                      e_count=e_count, f_count=f_count, c_count=c_count, d_flags=d_flags,
                      slot_base=slot_base, palette_base=palette_base,
                      pages=tuple(pages), palettes=tuple(palettes), poses=(),
                      animations=(), scripts={}, table_offsets={"c": c_table, "d": d_table,
                                                                  "e": e_table, "f": f_table},
                      pointer_values={"c": struct.unpack_from("<I", data, section_offset + 8)[0],
                                      "d": struct.unpack_from("<I", data, section_offset + 12)[0],
                                      "e": struct.unpack_from("<I", data, section_offset + 16)[0],
                                      "f": struct.unpack_from("<I", data, section_offset + 20)[0]})
    # Internal raw bytes are never serialized.  The context keeps the rendering
    # helper readable without threading the whole file through every call.
    object.__setattr__(section, "_data", data)

    poses: list[Pose] = []
    for i, off in enumerate(e_offsets):
        poses.append(_pose_image(section, off, i, character_id, axis_aligned_packet))
    section.poses = tuple(poses)

    animations: list[Animation] = []
    script_table = _u32(data, 32, "script table", character_id) if parse_scripts and len(data) >= 36 else 0
    scripts = _resolve_script_animations(data, script_table, character_id) if script_table else {}
    for i, off in enumerate(f_offsets):
        count = _u8(data, off, f"f[{i}] count", character_id)
        if off + 4 + 2 * count > len(data):
            raise SectionError("truncated_animation", f"f[{i}] count={count}",
                               address=off, character=character_id)
        pairs = tuple((data[off + 4 + 2 * k], data[off + 5 + 2 * k]) for k in range(count))
        missing = tuple(sorted({pose for pose, _ in pairs if pose >= len(poses)}))
        used = tuple(sorted(script for script, anims in scripts.items() if i in anims))
        animations.append(Animation(index=i, source_offset=off, pairs=pairs,
                                    ticks_total=sum(duration or 256 for _, duration in pairs),
                                    resolved=not missing, missing_poses=missing,
                                    used_by_scripts=used))
    section.animations = tuple(animations)
    section.scripts = scripts
    return section


def section_art_compatible(data: bytes, section: int, base: int = 0):
    """Refuse candidate sections until source and residency admission is complete."""
    decoded = decode_section(data, section, base=base, parse_scripts=True)
    unresolved = _section_summary(decoded)["unresolved"]
    if unresolved:
        raise SectionError("unresolved_animation_pose", str(unresolved), address=section)
    raise SectionError("section_not_admitted", "source and neighboring residency require independent verification",
                       address=section)


def _section_summary(section: Section) -> dict[str, Any]:
    unresolved: list[dict[str, Any]] = []
    for animation in section.animations:
        for pose in animation.missing_poses:
            unresolved.append({
                "kind": "animation_pose_reference",
                "animation": animation.index,
                "pose": pose,
                "used_by_scripts": list(animation.used_by_scripts),
                "required": True,
            })
    hard_unresolved = [row for row in unresolved if row["required"]]
    return {
        "status": "incomplete",
        "unresolved": unresolved,
        "required_unresolved": hard_unresolved,
    }


def _page_manifest(page: Page) -> dict[str, Any]:
    return {
        "index": page.index,
        "slot": page.slot,
        "dimensions": {"width": PAGE_SIZE, "height": PAGE_SIZE},
        "source_sha256": page.raw_sha256,
        "compressed_length": page.comp_len,
        "vram": {"x_words": page.vram_x_words, "y": page.vram_y},
    }


def _pose_manifest(pose: Pose, rect: dict[str, int]) -> dict[str, Any]:
    return {
        "index": pose.index,
        "rect": rect,
        "size": {"width": pose.image.width, "height": pose.image.height},
        "anchor": {"x": pose.anchor_x, "y": pose.anchor_y},
        "pieces": [{
            "x": p.x, "y": p.y, "page": p.page,
            "u": p.u, "v": p.v, "width": p.width, "height": p.height,
            "palette": p.palette, "flip_x": p.flip_x, "flip_y": p.flip_y,
            "uv": {"u0": p.u, "v0": p.v, "u1": p.u + p.width - 1,
                    "v1": p.v + p.height - 1},
            "outside_samples": p.outside_samples,
            "cross_page_samples": p.cross_page_samples,
            "edge_samples": list(p.edge_samples),
        } for p in pose.pieces],
    }


def _animation_manifest(animation: Animation) -> dict[str, Any]:
    return {
        "index": animation.index,
        "pairs": [{"pose": pose, "ticks": duration or 256, "source_ticks": duration}
                  for pose, duration in animation.pairs],
        "ticks_total": animation.ticks_total,
        "resolved": animation.resolved,
        "missing_poses": list(animation.missing_poses),
        "used_by_scripts": list(animation.used_by_scripts),
    }


def _character_manifest(section: Section, atlas: ShelfAtlas) -> dict[str, Any]:
    summary = _section_summary(section)
    poses = []
    for pose in section.poses:
        poses.append(_pose_manifest(pose, atlas.add(pose.image)))
    return {
        "id": section.character_id,
        "resource": section.resource,
        "resource_sha256": section.resource_sha256,
        "status": summary["status"],
        "pages": [_page_manifest(page) for page in section.pages],
        "palettes": [{"index": p.index, "colors": [list(c) for c in p.colors]} for p in section.palettes],
        "poses": poses,
        "animations": [_animation_manifest(a) for a in section.animations],
        "unresolved": summary["unresolved"],
    }


def _canonical_json(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def _load_catalogue(path: Path) -> tuple[dict[str, Any], str, str]:
    raw = path.read_bytes()
    catalogue = json.loads(raw)
    if catalogue.get("schema") != "suikoden-party-source-facts/1":
        raise SectionError("catalogue_schema", str(catalogue.get("schema")))
    characters = catalogue.get("characters")
    if not isinstance(characters, list) or len(characters) != 78:
        raise SectionError("catalogue_count", f"expected 78, got {len(characters or [])}")
    ids = [row.get("id") for row in characters]
    if len(set(ids)) != 78 or any(not isinstance(name, str) or not name for name in ids):
        raise SectionError("catalogue_ids", "expected 78 unique stable IDs")
    exact = hashlib.sha256(raw).hexdigest()
    canonical = hashlib.sha256(json.dumps(catalogue, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return catalogue, exact, canonical


def _select_ids(catalogue: dict[str, Any], requested: str | None) -> list[str]:
    known = [row["id"] for row in catalogue["characters"]]
    if requested is None or requested.strip().lower() == "all":
        return known
    ids = [name.strip() for name in requested.split(",") if name.strip()]
    if not ids:
        raise SectionError("empty_selection", "")
    unknown = [name for name in ids if name not in known]
    if unknown:
        raise SectionError("unknown_character", ", ".join(unknown))
    if len(set(ids)) != len(ids):
        raise SectionError("duplicate_character", "")
    return ids


def export(characters: str | None = None, *, catalogue_path: Path = DEFAULT_CATALOGUE,
           out: Path | None = None, report: Path | None = None,
           c_report: Path | None = None,
           axis_aligned_fallback: bool = False) -> dict[str, Any]:
    catalogue_path = Path(catalogue_path).resolve()
    catalogue, catalogue_sha, catalogue_canonical = _load_catalogue(catalogue_path)
    ids = _select_ids(catalogue, characters)
    by_id = {row["id"]: row for row in catalogue["characters"]}
    if c_report is not None:
        c_bytes = Path(c_report).read_bytes()
        if hashlib.sha256(c_bytes).hexdigest() != C_REPORT_SHA256:
            raise SectionError("c_report_digest", "does not match the pinned C package")

    atlas = ShelfAtlas()
    manifests: list[dict[str, Any]] = []
    proofs: list[dict[str, Any]] = []
    complete: list[str] = []
    incomplete: list[str] = []
    failed: list[dict[str, str]] = []
    for character_id in sorted(ids):
        row = by_id[character_id]
        try:
            data, provenance = source("/" + row["resource"])
            digest = hashlib.sha256(data).hexdigest()
            if digest != row["resource_sha256"]:
                raise SectionError("resource_digest_mismatch",
                                   f"catalogue={row['resource_sha256']} actual={digest}")
            section_offset = struct.unpack_from("<I", data, 36)[0]
            try:
                section = decode_section(data, section_offset, base=0, character_id=character_id,
                                         resource=row["resource"], resource_sha256=digest,
                                         parse_scripts=True)
            except SectionError as exc:
                if not (axis_aligned_fallback and exc.code == "unavailable_adjacent_page"):
                    raise
                section = decode_section(data, section_offset, base=0, character_id=character_id,
                                         resource=row["resource"], resource_sha256=digest,
                                         parse_scripts=True, axis_aligned_packet=True)
            manifest = _character_manifest(section, atlas)
            manifests.append(manifest)
            if manifest["status"] == "complete":
                complete.append(character_id)
            else:
                incomplete.append(character_id)
            proofs.append({
                "id": character_id,
                "name": row.get("name"),
                "source_character_id": row.get("source_character_id"),
                "resource": row["resource"],
                "resource_sha256": digest,
                "resource_provenance": provenance,
                "section_offset": section_offset,
                "section_base": 0,
                "header": {"e_count": section.e_count, "f_count": section.f_count,
                            "c_count": section.c_count, "d_flags": section.d_flags,
                            "slot_base": section.slot_base, "palette_base": section.palette_base},
                "tables": section.table_offsets,
                "pointer_values": section.pointer_values,
                "page_offsets": [p.source_offset for p in section.pages],
                "palette_offsets": [p.source_offset for p in section.palettes],
                "pose_offsets": [p.source_offset for p in section.poses],
                "animation_offsets": [a.source_offset for a in section.animations],
                "scripts": {str(k): list(v) for k, v in section.scripts.items()},
                "consumer": {"walker": "0x800E211C", "reference_test": "kit/tests/test_battle_trial_export.py::native_pose",
                              "page_base": "0x800E21E0", "uv": "0x800E22D8", "clut": "0x800E229C",
                              "flip": "0x800E2334"},
                "status": manifest["status"],
                "unresolved": manifest["unresolved"],
                "pose_pixel_sha256": [hashlib.sha256(p.image.tobytes()).hexdigest() for p in section.poses],
            })
        except SectionError as exc:
            failed.append({"id": character_id, "code": exc.code, "detail": exc.detail})
        except (KeyError, IndexError, struct.error) as exc:
            failed.append({"id": character_id, "code": "section_parse_error", "detail": str(exc)})

    if failed:
        # A requested malformed section is a public refusal: do not emit a
        # plausible partial packet.  Unresolved references are reported as
        # incomplete in the manifest instead; structural failures abort.
        raise SectionError("character_export_failed", json.dumps(failed, sort_keys=True))

    atlas_image = atlas.finish()
    atlas_bytes = _png_bytes(atlas_image)
    atlas_sha = hashlib.sha256(atlas_bytes).hexdigest()
    coverage = {
        "requested": sorted(ids),
        "decoded": sorted(m["id"] for m in manifests),
        "complete": sorted(complete),
        "incomplete": sorted(incomplete),
        "failed": [],
    }
    manifest = {
        "schema": SCHEMA,
        "atlas": {"file": "battle_sprite_sections.png", "sha256": atlas_sha,
                   "width": atlas_image.width, "height": atlas_image.height},
        "characters": sorted(manifests, key=lambda row: row["id"]),
        "coverage": coverage,
    }
    manifest_bytes = _canonical_json(manifest)
    manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
    proof = {
        "schema": PROOF_SCHEMA,
        "exporter": {"path": "kit/tools/export_battle_sprite_sections.py", "version": "1.0.0",
                      "schema": SCHEMA},
        "input": {
            "catalogue_path": str(catalogue_path.relative_to(ROOT)) if catalogue_path.is_relative_to(ROOT) else catalogue_path.name,
            "catalogue_file_sha256": catalogue_sha,
            "catalogue_canonical_sha256": catalogue_canonical,
            "c_report_sha256": C_REPORT_SHA256,
            "c_report_verified": bool(c_report is not None),
            "hash_convention": "file sha256 is exact bytes; canonical sha256 is UTF-8 JSON with sort_keys and compact separators",
        },
        "consumer": {
            "entry": "0x800E211C",
            "caller": "0x800E2044",
            "page_selection": "0x800E21E0..0x800E2220: (section[6] + subpiece[2]) & 0xff, then div/mod 5 and 20",
            "uv": "0x800E22D8..0x800E2310: u=(tile&15)*8, v=(tile>>4)*8",
            "clut": "0x800E2258..0x800E22A8: GetClut(0x100, 0x1e0 + ((section[7] + subpiece[6]) & 0xff))",
            "flags": "0x800E22B8..0x800E2434: bit 7 page reflection (not accepted here), bit 1 horizontal, bit 0 vertical",
            "dimensions": "subpiece width-1/height-1 are added to the UV start; the sampled extent is width/height",
            "edge": "unavailable adjacent-page samples are refused; neighboring residency is not assumed",
        },
        "coverage": coverage,
        "characters": sorted(proofs, key=lambda row: row["id"]),
        "frontier": [
            {
                "kind": "source_animation_reference",
                "characters": sorted({row["id"] for row in proofs if row["status"] == "incomplete"}),
                "detail": "an animation used by an action script references an e-table pose outside the declared count; the valid poses are exported, the used frames of that animation are not synthesized",
            },
            {
                "kind": "media_acceptance",
                "detail": "candidate atlas is unviewed; image/audio gate is not claimed",
            },
            {
                "kind": "runtime_admission",
                "detail": "C/profile and battle runtime admission are integrator-owned; this module is an export contract, not a battle renderer",
            },
        ],
        "outputs": {"manifest_sha256": manifest_sha, "atlas_sha256": atlas_sha,
                     "manifest_schema": SCHEMA},
        "caller_migration": {
            "from": "export_battle_trial.section_art(data, section, base=0)",
            "to": "export_battle_sprite_sections.section_art_compatible(data, section, base=0)",
            "intended_return_shape": "(poses [(RGBA, anchor_x, anchor_y)], animations [[(pose, ticks)]], proof)",
            "required_change": "integrator must verify source residency and resolve missing poses before connecting callers",
            "unresolved_rule": "the compatibility adapter refuses unresolved references and all unverified sections",
        },
        "media": {"status": "candidate, unviewed", "promoted": False},
    }

    if out is not None:
        _publish(Path(out), manifest_bytes, atlas_bytes, manifest, proof)
        proof["outputs"]["manifest_path"] = "battle_sprite_sections.json"
        proof["outputs"]["atlas_path"] = "battle_sprite_sections.png"
    if report is not None:
        report = Path(report)
        report.parent.mkdir(parents=True, exist_ok=True)
        tmp = report.with_name(f".{report.name}.{os.getpid()}.tmp")
        tmp.write_bytes(_canonical_json(proof))
        os.replace(tmp, report)
    return manifest


def _png_bytes(image: Image.Image) -> bytes:
    import io
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


def _publish(out: Path, manifest_bytes: bytes, atlas_bytes: bytes,
             manifest: dict[str, Any], proof: dict[str, Any]) -> None:
    out = out.resolve()
    accepted = (ROOT / "kit/work/accepted").resolve()
    if accepted in (out, *out.parents):
        raise SectionError("accepted_output", str(out))
    out.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix=".battle-sprite-stage-", dir=out))
    try:
        (stage / "battle_sprite_sections.json").write_bytes(manifest_bytes)
        (stage / "battle_sprite_sections.png").write_bytes(atlas_bytes)
        # Validate the staged manifest and atlas before replacing any live file.
        staged = json.loads((stage / "battle_sprite_sections.json").read_text())
        if staged.get("schema") != SCHEMA or not staged.get("characters"):
            raise SectionError("staged_manifest_invalid", "")
        if hashlib.sha256((stage / "battle_sprite_sections.png").read_bytes()).hexdigest() != manifest["atlas"]["sha256"]:
            raise SectionError("staged_atlas_hash_mismatch", "")
        for name in ("battle_sprite_sections.json", "battle_sprite_sections.png"):
            os.replace(stage / name, out / name)
    finally:
        shutil.rmtree(stage, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--characters", default=",".join(DEFAULT_CHARACTERS),
                        help="comma-separated stable IDs, or 'all'")
    parser.add_argument("--out", type=Path, required=True, help="candidate output directory")
    parser.add_argument("--report", type=Path, required=True, help="proof JSON path")
    parser.add_argument("--catalogue", type=Path, default=DEFAULT_CATALOGUE)
    parser.add_argument("--c-report", type=Path, default=None,
                        help="optional pinned C package report to verify by SHA-256")
    parser.add_argument("--axis-aligned-fallback", action="store_true",
                        help="retry unavailable adjacent-page samples using zero-rotation exclusive packet footprints")
    args = parser.parse_args(argv)
    result = export(args.characters, catalogue_path=args.catalogue, out=args.out,
                    report=args.report, c_report=args.c_report,
                    axis_aligned_fallback=args.axis_aligned_fallback)
    print(f"exported {len(result['characters'])} sections; "
          f"complete={len(result['coverage']['complete'])} "
          f"incomplete={len(result['coverage']['incomplete'])}; candidate atlas not viewed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
