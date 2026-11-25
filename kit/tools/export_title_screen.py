#!/usr/bin/env python3
"""Export P01 title screen art from SLUS_002.92 and music from DATA/03_SHIRO/TITLE.8."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct
import sys

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "kit/tools"
if str(TOOLS) not in sys.path:
    sys.path.insert(0, str(TOOLS))

from disc import extract
from dot8_audio import resources as audio_resources
from export_opening_audio import export_resource
import lzss

SLUS_LBA = 18346
SLUS_SIZE = 580 * 1024
SLUS_TEXT_OFFSET = 0x800
SLUS_BASE = 0x80010000
TITLE_AUDIO_INDEX = 1


def _decode_page(body: bytes, va: int) -> bytes:
    off = va - SLUS_BASE
    comp_len = struct.unpack_from("<I", body, off)[0]
    comp = body[off : off + 4 + comp_len]
    out, used = lzss.decode_container(comp)
    if used != len(comp) or len(out) != 16384:
        raise ValueError(f"title page {va:#x} partial decode: used={used}/{len(comp)} out={len(out)}")
    return out


def _decode_palette(body: bytes, va: int, count: int, *, opaque0: bool) -> list[tuple[int, int, int, int]]:
    off = va - SLUS_BASE
    pal: list[tuple[int, int, int, int]] = []
    for i in range(count):
        c = struct.unpack_from("<H", body, off + i * 2)[0]
        r = (c & 31) << 3
        g = ((c >> 5) & 31) << 3
        b = ((c >> 10) & 31) << 3
        a = 255 if (c != 0 or opaque0) else 0
        pal.append((r, g, b, a))
    return pal


def _decode_clut(body: bytes, va: int, *, opaque0: bool) -> list[tuple[int, int, int, int]]:
    return _decode_palette(body, va, 256, opaque0=opaque0)


def _page_image(page: bytes, pal: list[tuple[int, int, int, int]]) -> Image.Image:
    im = Image.new("RGBA", (128, 128))
    im.putdata([pal[b] if b < len(pal) else (0, 0, 0, 0) for b in page])
    return im


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def export(output_dir: Path | str) -> dict:
    """Extract and validate P01 title screen candidate assets without promoting."""
    out_dir = Path(output_dir).resolve()
    accepted = (ROOT / "kit/work/accepted").resolve()
    if out_dir == accepted or accepted in out_dir.parents:
        raise ValueError("candidate output cannot be accepted staging")
    out_dir.mkdir(parents=True, exist_ok=True)

    exe = extract(SLUS_LBA, SLUS_SIZE)
    if exe[:8] != b"PS-X EXE":
        raise ValueError("unexpected SLUS_002.92 header")
    body = exe[SLUS_TEXT_OFFSET:]

    clut_logo = _decode_clut(body, 0x8005DCCC, opaque0=False)
    clut_push = _decode_clut(body, 0x8005FCCC, opaque0=False)
    clut_copy = _decode_clut(body, 0x80042528, opaque0=False)
    clut_water = _decode_clut(body, 0x800707F8, opaque0=True)

    # 320x256 water backdrop (0x140/0x180/0x1C0 x 0x100/0x180 in VRAM; rightmost 64px of 0x1C0 are zero padding).
    water = Image.new("RGBA", (320, 256))
    for bx, by, va in (
        (0, 0, 0x8006C2FC),
        (128, 0, 0x8006DBEC),
        (256, 0, 0x8006FB10),
        (0, 128, 0x800709F8),
        (128, 128, 0x80072A38),
        (256, 128, 0x800756D8),
    ):
        tile = _page_image(_decode_page(body, va), clut_water)
        if bx == 256:
            tile = tile.crop((0, 0, 64, 128))
        water.paste(tile, (bx, by))
    water = water.crop((0, 0, 320, 240))
    water_path = out_dir / "water.png"
    water.save(water_path)

    # 256x96 Suikoden title logo (0x140,0 + 0x180,0).
    logo = Image.new("RGBA", (256, 96))
    logo.paste(_page_image(_decode_page(body, 0x80054988), clut_logo).crop((0, 0, 128, 96)), (0, 0))
    logo.paste(_page_image(_decode_page(body, 0x800552F4), clut_logo).crop((0, 0, 128, 96)), (128, 0))
    logo_path = out_dir / "logo.png"
    logo.save(logo_path)

    # 16 stacked 128x32 frames of rotating "PUSH START" matching SLUS 0x80042530 table.
    push_pages = {
        448: (
            _page_image(_decode_page(body, 0x80055C00), clut_push),
            _page_image(_decode_page(body, 0x80057C94), clut_push),
        ),
        512: (
            _page_image(_decode_page(body, 0x80059F3C), clut_push),
            _page_image(_decode_page(body, 0x8005C020), clut_push),
        ),
    }
    push_start = Image.new("RGBA", (128, 32 * 16))
    anim_off = 0x80042530 - SLUS_BASE
    frame_index = 0
    while frame_index < 16:
        tp_x, v_off, _dur = struct.unpack_from("<HHH", body, anim_off + frame_index * 6)
        top_im, bot_im = push_pages[tp_x]
        src_im = top_im if v_off < 128 else bot_im
        local_y = v_off % 128
        push_start.paste(src_im.crop((0, local_y, 128, local_y + 32)), (0, frame_index * 32))
        frame_index += 1
    push_path = out_dir / "push_start.png"
    push_start.save(push_path)

    # 292x8 stitched US v1.1 Konami copyright line (0x180, 128 rows 0..23).
    p7 = _page_image(_decode_page(body, 0x80042A38), clut_copy)
    copy_img = Image.new("RGBA", (292, 8))
    copy_img.paste(p7.crop((0, 0, 128, 8)), (0, 0))
    copy_img.paste(p7.crop((0, 8, 128, 16)), (128, 0))
    copy_img.paste(p7.crop((0, 16, 36, 24)), (256, 0))
    copy_path = out_dir / "copyright.png"
    copy_img.save(copy_path)

    # 320x240 scrolling/title-menu cloud sky + bottom-right dark Suikoden logo (SLUS 0x80049598).
    clut_clouds = _decode_clut(body, 0x80052988, opaque0=True)
    cloud_sheet = Image.new("RGBA", (384, 256))
    for ci, va in enumerate((0x800495F0, 0x8004B458, 0x8004D25C, 0x8004E5D8, 0x8004FC6C, 0x80051A40)):
        cloud_sheet.paste(_page_image(_decode_page(body, va), clut_clouds), ((ci % 3) * 128, (ci // 3) * 128))
    clouds_img = cloud_sheet.crop((0, 0, 320, 240))
    clouds_path = out_dir / "clouds.png"
    clouds_img.save(clouds_path)

    # 256x64 (8x 32x64) naming-screen spinning Hero sprite (SLUS 0x800475c4, anim 0x80047594, palette 0x80047488).
    pal_hero = _decode_palette(body, 0x80047488, 32, opaque0=False)
    hero_pages = [
        _page_image(_decode_page(body, 0x800475DC), pal_hero),
        _page_image(_decode_page(body, 0x80048964), pal_hero),
    ]
    hero_spin = Image.new("RGBA", (32 * 8, 64))
    desc_ptrs_off = 0x8004756C - SLUS_BASE
    anim0_off = 0x80047594 - SLUS_BASE
    for idx in range(8):
        frame_id, _dur = struct.unpack_from("<BB", body, anim0_off + 4 + idx * 2)
        desc_va = struct.unpack_from("<I", body, desc_ptrs_off + frame_id * 4)[0]
        doff = desc_va - SLUS_BASE + 8
        _dx, _dy, page_id, uv_packed, w_m1, h_m1, _pal_hi, flags = struct.unpack_from("<BBBBBBBB", body, doff)
        ux = (uv_packed & 0x0F) * 8
        vy = ((uv_packed >> 4) & 0x0F) * 8
        crop = hero_pages[page_id].crop((ux, vy, ux + w_m1 + 1, vy + h_m1 + 1))
        if flags & 2:
            crop = crop.transpose(Image.FLIP_LEFT_RIGHT)
        hero_spin.paste(crop, (idx * 32, 0))
    hero_spin_path = out_dir / "hero_spin.png"
    hero_spin.save(hero_spin_path)

    rows = {r["index"]: r for r in audio_resources()}
    track, audio_proof = export_resource(out_dir, "title", rows[TITLE_AUDIO_INDEX])
    wav_path = out_dir / track["path"]

    manifest = {
        "schema": "suikoden-title-screen/1",
        "source": "SLUS_002.92@0x80018488; DATA/03_SHIRO/TITLE.8",
        "media_accepted": False,
        "water": {
            "path": "title/water.png",
            "width": 320,
            "height": 240,
            "sha256": _sha256(water_path),
            "wave_amplitude": 16,
            "wave_period": 128,
            "strip_width": 16,
        },
        "clouds": {
            "path": "title/clouds.png",
            "width": 320,
            "height": 240,
            "sha256": _sha256(clouds_path),
        },
        "hero_spin": {
            "path": "title/hero_spin.png",
            "frame_width": 32,
            "frame_height": 64,
            "frames": 8,
            "ticks_per_frame": 6,
            "sha256": _sha256(hero_spin_path),
        },
        "logo": {
            "path": "title/logo.png",
            "width": 256,
            "height": 96,
            "sha256": _sha256(logo_path),
        },
        "push_start": {
            "path": "title/push_start.png",
            "frame_width": 128,
            "frame_height": 32,
            "frames": 16,
            "ticks_per_frame": 4,
            "sha256": _sha256(push_path),
        },
        "copyright": {
            "path": "title/copyright.png",
            "width": 292,
            "height": 8,
            "sha256": _sha256(copy_path),
        },
        "audio": {
            "path": f"title/{track['path']}",
            "sample_rate": track["sample_rate"],
            "frames": track["frames"],
            "loop_start_frame": track["loop_start_frame"],
            "volume": track["volume"],
            "sha256": _sha256(wav_path),
            "source": audio_proof["path"],
        },
    }
    (out_dir / "title.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


if __name__ == "__main__":
    result = export(ROOT / "kit/work/build/canonical/title")
    print(f"Exported P01 title screen candidate assets to kit/work/build/canonical/title ({len(result['push_start'])} keys)")
