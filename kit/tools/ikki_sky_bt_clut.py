#!/usr/bin/env python3
"""Duel embedded uploads, sampler coordinates and per-overlay palette sources.

The portraits use traced palettes at(640,448/449). The embedded128x128 page
supplies128x32 bands sampled with CLUT(0,497). The separate512-byte source
uploaded at800818C8 lands at(0,496): the preceding vtable+E0 call resets the
row counter to16. Its assignment to row497 was wrong. A later setter17/upload supplies the band palette. Its rendered colours
await user acceptance; external BT/SKY palette pairing remains separate. See duel_embedded_residency.md.

--render-embedded writes portraits and bands with their traced palette sources.
Legacy --render reproduces an unverified external-page/palette experiment.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

import ikki_palettes as source
import maindec
import lzss

B = source.OVERLAY_BASE  # 0x80080000

#: the duel code is identical in all three overlays at these VAs; only the data
#: they address shifts.  The shift is *recovered* by `trace()` and cross-checked.
OVERLAYS = ("PAN_TEO.BIN", "SHU_KWA.BIN", "SHU_TEO.BIN")

GETCLUT = 0x8014ABD4
GETTPAGE = 0x8014AB0C
VTABLE = 0x80165608

#: the two backdrop quad builders and their four argument-load sites.
BUILDERS = (
    {"function": 0x80088538, "quads": "embedded64x64 quads",
     "clut_site": 0x800886C4, "tpage_site": 0x80088704},
    {"function": 0x80088994, "quads": "embedded128x32 bands",
     "clut_site": 0x80088C34, "tpage_site": 0x80088C7C},
)

#: what each `gpu_loadimage_wrap` site uploads.  The destination is *decoded*
#: from the instruction words by `upload_destinations()`; this map only names it.
UPLOAD_NAMES = {
    0x8008133C: "icon damage/fade ramp, static 32x1",
    0x8008159C: "icon cell page, per-frame 64x128 (x = s1*0x40 + 0x280)",
    0x80081830: "icon cell page, per-frame 64x128 (x = 0x280)",
    0x80081950: "IC cell page, static 32x64",
    0x800819A0: "embedded palettes, 256x1 at rows448/449",
    0x80081A34: "embedded128x128 page at (0x340,0x100)",
}


def vtable_neighbourhood() -> list[dict]:
    """Identify every vtable slot in `+0x60..+0xA0`.

    The parent task asked whether `gpu_loadimage_wrap` (`+0x70`) is the only
    image-transfer slot.  It is: the transfer family is `+0x64` and `+0x70`
    (both Route through `0x801483D4` -> `[0x8017FE58].8`), and every other slot
    in the window is read from its first instruction.  In particular neither
    `+0x60` (=`0x80148368`, a `[0x8017FE5C].0x3C` dispatcher) nor `+0x74`
    (=`0x8014AE88`, a 4-byte POLY filler) is a LoadImage.
    """
    def head(t, n=3):
        return [maindec.mword(t + 4 * i) for i in range(n)]

    names = {
        0x60: "dispatcher: calls [0x8017FE5C]+0x3C with one arg (not a RECT mover)",
        0x64: "transfer wrapper A: 0x801483D4 -> [0x8017FE58].8 (takes a RECT-like struct)",
        0x68: "4-byte POLY packer (sets code 9 / 0x2C at +3/+7)",
        0x6C: "GetTpage 0x8014AB0C (this finding)",
        0x70: "gpu_loadimage_wrap 0x80148590 (the six sites; also transfer wrapper B)",
        0x74: "4-byte POLY packer (code 5 / 0x28)",
        0x78: "video/is-busy style predicate",
        0x7C: "sprite/OT helper",
        0x80: "sprite/text helper",
        0x84: "text_decode_stream 0x800C3144 (LZSS)",
        0x88: "texture/material helper",
        0x8C: "GetClut 0x8014ABD4 (this finding)",
        0x90: "OT/primitive helper",
        0x94: "engine helper",
        0x98: "texture page table filler (writes 0x10 per texel)",
        0x9C: "node/pool release",
        0xA0: "teardown chain",
    }
    out = []
    for off in sorted(names):
        target = maindec.mword(VTABLE + off)
        out.append({"slot": off, "target": target,
                    "head": head(target) if target else None, "role": names[off]})
    return out


#: the per-overlay pointer-table entry the duel code loads as the palette source
#: (`lui $a0,0x8009 ; lw $a0,-0x64c8($a0)` at 0x800818B8/0x800818BC), and the
#: 256-entry palette uploader it is handed to (vtable +0x18C).
PALETTE_POINTER = {"PAN_TEO.BIN": 0x80089B54, "SHU_KWA.BIN": 0x80089B38,
                   "SHU_TEO.BIN": 0x80089B38}
PALETTE_UPLOADER = 0x800C3C5C          # RECT(x=0, y=0x1E0+counter, w=0x100, h=1)
PALETTE_ROW_COUNTER = 0x80179038
PALETTE_SLOT = 0x800818BC              # the `lw $a0,-0x64c8($a0)` in the overlay


def sky_palette(name: str = "PAN_TEO.BIN") -> dict:
    """The per-overlay row496 palette source (legacy function name).

    Resolved from the instruction at `PALETTE_SLOT`: `lui $a0,0x8009` then
    `lw $a0,imm($a0)`.  The loaded word is the palette VA; its 512 bytes are read
    out of the same overlay file.
    """
    data = source.overlay(name)
    site = PALETTE_SLOT
    lo = _w(data, site) & 0xFFFF
    if lo & 0x8000:
        lo -= 0x10000
    table = ((0x8009 << 16) + lo) & 0xFFFFFFFF
    assert table == PALETTE_POINTER[name], (name, hex(table))
    va = _w(data, table)
    off = va - B
    blk = data[off:off + 512]
    assert _w(data, 0x80081898) == 0x8C4200E0
    assert _w(data, 0x800818A0) == 0x0040F809
    assert _w(data, 0x800818A4) >> 16 == 0x3404
    assert maindec.mword(VTABLE + 0xE0) == 0x800C39E4
    assert maindec.mword(0x800C39E8) == 0xA0249038
    counter = _w(data, 0x800818A4) & 0xFFFF
    words = struct.unpack("<256H", blk)
    return {"overlay": name, "pointer_table": table, "pointer": va,
            "file_offset": off, "bytes": 512, "words": words,
            "mean_rgb555": (sum(w & 31 for w in words) / 256,
                            sum((w >> 5) & 31 for w in words) / 256,
                            sum((w >> 10) & 31 for w in words) / 256),
            "uploader": PALETTE_UPLOADER, "uploader_slot": 0x18C,
            "row": 0x1E0 + counter, "rect": (0, 0x1E0 + counter, 256, 1),
            "counter_before_upload": counter, "sampled_band_row": 497,
            "band_palette_mapping": "separate row497 source reported by embedded_uploads"}


def sky_palettes() -> dict:
    """`{overlay: sky_palette}` for all three duel overlays."""
    return {n: sky_palette(n) for n in OVERLAYS}


def getclut(x: int, y: int) -> int:
    """MAIN.EXE 0x8014ABD4, verbatim: `(y << 6) | ((x >> 4) & 0x3F)`."""
    return ((y << 6) | ((x >> 4) & 0x3F)) & 0xFFFF


def getclut_back(word: int) -> tuple[int, int]:
    """The VRAM (x, y) a CLUT halfword names (the inverse of `getclut`)."""
    return ((word & 0x3F) << 4, (word >> 6) & 0x3FF)


def _w(data: bytes, va: int) -> int:
    return struct.unpack_from("<I", data, va - B)[0]


def _s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# --------------------------------------------------------------------------
# instruction-level recovery
# --------------------------------------------------------------------------

def arg_table(data: bytes, call_va: int, reg: int) -> int:
    """The overlay VA a call-site argument register was loaded from.

    Walks back from the call site for the `lw $reg,0x0($at)` that defines `reg`,
    then for the `addiu $at,$at,lo` + `lui $at,hi` pair that built `$at`.  This is
    why the table addresses in this finding are *recovered*, not typed in.
    """
    lw_va = None
    for k in range(1, 20):
        ins = _w(data, call_va - 4 * k)
        if (ins >> 26) == 0x23 and ((ins >> 16) & 31) == reg and (ins & 0xFFFF) == 0:
            lw_va = call_va - 4 * k
            break
    if lw_va is None:
        raise ValueError("no `lw $%d,0x0($at)` before %#x" % (reg, call_va))
    lo = hi = None
    for k in range(1, 8):
        ins = _w(data, lw_va - 4 * k)
        op, rs, rt = ins >> 26, (ins >> 21) & 31, (ins >> 16) & 31
        if op == 0x09 and rs == 1 and rt == 1 and lo is None:
            lo = lw_va - 4 * k
        elif op == 0x0F and rt == 1 and hi is None:
            hi = lw_va - 4 * k
            break
    if lo is None or hi is None:
        raise ValueError("no lui/addiu pair for %#x" % lw_va)
    return (((_w(data, hi) & 0xFFFF) << 16) + _s16(_w(data, lo))) & 0xFFFFFFFF


def upload_sites(name: str = "PAN_TEO.BIN") -> list[dict]:
    """Every `gpu_loadimage_wrap` (vtable +0x70) call site in one overlay."""
    data = source.overlay(name)
    rows = []
    for va in range(B, B + len(data) - 4, 4):
        x = _w(data, va)
        if (x >> 26) == 0x23 and ((x >> 16) & 31) == 2 and (x & 0xFFFF) == 0x70:
            for k in (1, 2, 3):
                if _w(data, va + 4 * k) == 0x0040F809:
                    rows.append({"site": va + 4 * k, "name": UPLOAD_NAMES.get(va + 4 * k)})
                    break
    return rows


def _const_before(data: bytes, store_va: int) -> int | None:
    """The constant stored by the `sh $rt,imm($sp)` at `store_va`, or None.

    The RECT fields are built three ways in this code: `ori $rt,$zero,imm`,
    `addiu $rt,$zero,imm` (negative immediates such as `-0xa0`), and
    `addiu $rt,$rt2,imm` where `$rt2` is the rect base.  A `None` return means the
    source register was set by a loop counter (see `RECT_COUNTERS`).
    """
    ins = _w(data, store_va - 4)
    op, imm = ins >> 26, ins & 0xFFFF
    if op == 0x0D:                       # ori $rt,$zero,imm
        return imm
    if op == 0x09:                       # addiu $rt,{zero|base},imm
        return _s16(imm)
    return None


#: the `gpu_loadimage_wrap` sites with the `sh` that stores each RECT field.
RECT_FIELDS = (
    # site, x store, y store, w store, h store
    (0x8008133C, 0x80081318, 0x80081320, 0x80081328, 0x80081330),
    (0x80081950, 0x8008192C, 0x80081934, 0x8008193C, 0x80081944),
    (0x800819A0, 0x80081970, 0x80081978, 0x80081980, 0x80081988),
    (0x80081A34, 0x80081A18, 0x80081A1C, 0x80081A20, 0x80081A28),
)

# Register values belong to the upload routine, not the separate quad builder.
RECT_COUNTERS = {0x8008192C: "0x280 + 0x40*i, i=0,1",
                 0x80081978: "0x1C0 + i, i=0,1",
                 0x80081A1C: 0x100, 0x80081A20: 0x40}


def upload_destinations() -> list[dict]:
    """Every destination the four constant-RECT uploads write, decoded."""
    data = source.overlay("PAN_TEO.BIN")
    rows = []
    for site, xs, ys, ws, hs in RECT_FIELDS:
        row = {"site": site, "name": UPLOAD_NAMES[site]}
        for key, store in (("x", xs), ("y", ys), ("w", ws), ("h", hs)):
            val = _const_before(data, store)
            row[key] = RECT_COUNTERS.get(store, val)
        rows.append(row)
    return rows


def embedded_uploads(name):
    """Disc-backed embedded page/palette sources and their actual upload rectangles."""
    data = source.overlay(name)
    palettes = 0x80090000 + _s16(_w(data, 0x80081994))
    pages = 0x80090000 + _s16(_w(data, 0x800818F4))
    third = 0x80090000 + _s16(_w(data, 0x800819EC))
    out = {"pages": [], "palettes": []}
    for i in range(2):
        ptr = _w(data, palettes + i*4)
        block = data[ptr-B:ptr-B+512]
        if len(block) != 512:
            raise ValueError('embedded palette exceeds overlay')
        out["palettes"].append({"offset": ptr-B, "rect": [0x280,0x1C0+i,256,1],
                                "sha256": hashlib.sha256(block).hexdigest()})
    for ptr,rect in [(_w(data,pages),[0x280,0x180,32,64]),
                     (_w(data,pages+4),[0x2C0,0x180,32,64]),
                     (third,[0x340,0x100,64,128])]:
        size = _w(data,ptr)
        blob = data[ptr-B:ptr-B+4+size]
        output,used = lzss.decode_container(blob)
        if used != len(blob) or len(output) != rect[2]*rect[3]*2:
            raise ValueError('embedded page size/consumption disagrees with upload')
        out["pages"].append({"offset": ptr-B, "rect": rect, "used": used,
                            "sha256": hashlib.sha256(output).hexdigest()})
    assert _w(data, 0x80081A5C) == 0x8C4200E0
    assert _w(data, 0x80081A68) == 0x34040011
    assert _w(data, 0x80081A80) == 0x8C42018C
    assert _w(data, 0x80081A84) == 0x3C048009
    ptr = 0x80090000 + _s16(_w(data, 0x80081A88))
    block = data[ptr-B:ptr-B+512]
    if len(block) != 512:
        raise ValueError('embedded band palette exceeds overlay')
    out['band_palette'] = {'offset': ptr-B, 'rect': [0, 497, 256, 1],
                           'sha256': hashlib.sha256(block).hexdigest()}
    return out


# --------------------------------------------------------------------------
# the chain
# --------------------------------------------------------------------------

def trace() -> dict:
    """The backdrop draw chain: the builders, their coordinate tables, the uploads."""
    out = {
        "getclut_formula": {"address": GETCLUT, "expr": "(y << 6) | ((x >> 4) & 0x3F)",
                            "words": [maindec.mword(GETCLUT + 4 * i) for i in range(4)]},
        "vtable": VTABLE,
        "vtable_slots": {"+0x6C (GetTpage)": maindec.mword(VTABLE + 0x6C),
                         "+0x8C (GetClut)": maindec.mword(VTABLE + 0x8C)},
        "overlays": {}, "builders": [],
    }
    for name in OVERLAYS:
        rec = source._rec(source.OVERLAY_DIR + name)
        out["overlays"][name] = {"lba": rec["lba"], "size": rec["size"],
                                 "uploads": upload_sites(name)}
    for b in BUILDERS:
        row = dict(b, clut=[], tpage=[])
        for name in OVERLAYS:
            data = source.overlay(name)
            ctab = arg_table(data, b["clut_site"], 4)
            c2 = arg_table(data, b["clut_site"], 5)
            ttab = arg_table(data, b["tpage_site"], 6)
            t2 = arg_table(data, b["tpage_site"], 7)
            row.setdefault("tables", {})[name] = {"clut": ctab, "clut_y": c2,
                                                  "tpage": ttab, "tpage_y": t2}
            # the builders' outer counter is s4 in {0,1} with s1 = s4*8
            for s1 in (0, 8):
                a0 = _w(data, ctab + s1) & 0xFFFF
                a1 = _w(data, c2 + s1) & 0xFFFF
                row["clut"].append({"overlay": name, "s1": s1, "a0": a0, "a1": a1,
                                    "vram": getclut_back(getclut(a0, a1))})
                a2 = _w(data, ttab + s1) & 0xFFFF
                a3 = _w(data, t2 + s1) & 0xFFFF
                row["tpage"].append({"overlay": name, "s1": s1, "a2": a2, "a3": a3})
        out["builders"].append(row)
    out["upload_destinations"] = upload_destinations()
    out["embedded_uploads"] = {n: embedded_uploads(n) for n in OVERLAYS}
    out["sky_palettes"] = {n: {k: v for k, v in sky_palette(n).items() if k != "words"}
                           for n in OVERLAYS}
    return out


def backdrop_clut_coords() -> list[tuple[int, int]]:
    """The distinct VRAM CLUT coordinates the backdrop draws sample."""
    seen, out = set(), []
    for b in trace()["builders"]:
        for c in b["clut"]:
            t = tuple(c["vram"])
            if t not in seen:
                seen.add(t)
                out.append(t)
    return out


def render(outdir: Path) -> dict:
    """Historical unverified external-page/palette experiment.

    The gate is the user's; this writes the three variants plus a provenance
    sidecar.  Each overlay's palette is the one its own code loads.
    """
    from PIL import Image, ImageDraw

    outdir.mkdir(parents=True, exist_ok=True)
    report = trace()
    pages = source.pages("SKY") + source.pages("BT")
    for name in OVERLAYS:
        pal = sky_palette(name)
        lut = [(((w & 31) * 255) // 31, (((w >> 5) & 31) * 255) // 31,
                (((w >> 10) & 31) * 255) // 31) for w in pal["words"]]
        cols = 4
        rows = (len(pages) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * 132, rows * 132), (30, 30, 30))
        lab = ImageDraw.Draw(sheet)
        for i, p in enumerate(pages):
            tile = Image.new("RGB", (128, 128))
            px = tile.load()
            for y in range(128):
                for x in range(128):
                    px[x, y] = lut[p["page"][y * 128 + x]]
            sheet.paste(tile, ((i % cols) * 132, (i // cols) * 132))
            lab.text(((i % cols) * 132 + 2, (i // cols) * 132 + 2),
                     p["name"].replace(".BIN", ""), fill=(255, 255, 0))
        stem = name.replace(".BIN", "")
        sheet.save(outdir / ("sky_bt_under_%s_palette.png" % stem))
        (outdir / ("palette_%s.bin" % stem)).write_bytes(bytes(
            b for w in pal["words"] for b in struct.pack("<H", w)))
    report["pages"] = [{k: v for k, v in p.items() if k != "page"} for p in pages]
    report["image_gate"] = ("unverified experiment: this source uploads496; "
                            "the embedded band sampler reads497. External-page "
                            "palette pairing and rendered colours are not established")
    (outdir / "provenance.json").write_text(json.dumps(report, indent=2, default=str) + "\n")
    return report


def embedded_images(name):
    """Return the existing embedded page decodes with their upload provenance."""
    from PIL import Image

    data = source.overlay(name)
    uploads = embedded_uploads(name)
    rec = source._rec('DATA/12_IKKI/' + name)
    images = []
    palettes = [*uploads['palettes'], uploads['band_palette']]
    for page, palette in zip(uploads['pages'], palettes, strict=True):
        offset = page['offset']
        plane, used = lzss.decode_container(data[offset:offset + page['used']])
        if used != page['used']:
            raise ValueError('embedded page consumption changed')
        words = struct.unpack_from('<256H', data, palette['offset'])
        lut = [((w & 31) * 255 // 31, ((w >> 5) & 31) * 255 // 31,
                ((w >> 10) & 31) * 255 // 31, 255 if w else 0) for w in words]
        width, height = page['rect'][2] * 2, page['rect'][3]
        image = Image.new('RGBA', (width, height))
        image.putdata([lut[i] for i in plane])
        images.append((image, {'file': rec['path'], 'lba': rec['lba'], 'size': rec['size'],
                               **page, 'palette': palette}))
    return images


def gauge_band_rows(name):
    data = source.overlay(name)
    # The band builder indexes this UV table once for each duel side.
    table = 0x10000 + _s16(_w(data, 0x80088B40))
    coordinates = struct.unpack_from('<16I', data, table)
    rows = []
    for start in (0, 8):
        uv = coordinates[start:start + 8]
        top = uv[1]
        if top not in (0, 32, 64, 96) or uv != (0, top, 128, top, 0, top + 32, 128, top + 32):
            raise ValueError(f'unexpected gauge UVs for {name}')
        rows.append(top)
    return rows


def render_embedded(outdir: Path):
    """Review embedded portraits and bands with their traced palette uploads."""
    from PIL import Image, ImageDraw
    outdir.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGB", (960,750), (35,35,40))
    label = ImageDraw.Draw(sheet)
    report = {"decoder": "kit/tools/lzss.py v2.0.0", "image_gate": "pending user review",
              "gauge_colours": "row497 source traced; pending user image review", "sources": []}
    for y,name in enumerate(OVERLAYS):
        for x,(tile, provenance) in enumerate(embedded_images(name)):
            sheet.paste(tile.convert('RGB').resize((192,192),Image.Resampling.NEAREST),(x*320+10,y*250+30))
            label.text((x*320+10,y*250+8),name + (' portrait '+str(x) if x<2 else ' bands / row497'),fill='white')
            report["sources"].append(provenance)
    sheet.save(outdir/'contact.png')
    (outdir/'provenance.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    outputs = ap.add_mutually_exclusive_group()
    outputs.add_argument("--render", type=Path)
    outputs.add_argument("--render-embedded", type=Path)
    a = ap.parse_args()
    if a.render_embedded:
        render_embedded(a.render_embedded)
        print("wrote %s (candidate, user-gated)" % a.render_embedded)
    elif a.render:
        render(a.render)
        print("wrote %s (candidate, user-gated)" % a.render)
    else:
        print(json.dumps(trace(), indent=2))
