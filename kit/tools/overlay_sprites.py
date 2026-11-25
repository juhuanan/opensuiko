#!/usr/bin/env python3
"""Embedded 04_PLAY-format sprite containers, anywhere on the disc.

WHY THIS EXISTS
---------------
The 78 files in `DATA/04_PLAY/` are not the only copies of the character-sprite
container format. The **area overlays embed further containers verbatim** -- a
container is a self-contained structure whose 5-pointer header sits at
`container+0x20` and whose first header slot is always `0x34`:

    +0x20  u32 offset_table_ptr   == 0x34   <-- the signature this tool scans for
    +0x24  u32 S1
    +0x28  u32 S2
    +0x2C  u32 S3
    +0x30  u32 S4
    +0x34  u32[] offset table, zero-terminated

Every pointer *inside* a container is relative to the container start, so a
container lifted out of an overlay parses with the canonical parser unchanged.

Measured on the retail disc (2026-10-05): **113 containers** -- 78 at
`DATA/04_PLAY/*.BIN` (offset 0) and **35 embedded in 19 area overlays**. The
embedded set is sprite art that no other tool in the tree reads.

PROVENANCE
----------
DISC-DERIVED. Pixels are `lzss.decode_strict` output (canonical decoder,
`kit/tools/lzss.py` v2.0.0), never VRAM-oracle bytes. The 16,384-byte atlas and
the 8-bit index packing are the same proven path as
`docs/pipeline_replay2.md` and `docs/sprite_dumper.md`.

WHAT IS AND IS NOT CLAIMED
--------------------------
* Container discovery, section/palette/atlas extraction: **structural**, proven
  by the parser's own validation (zero errors on all 113).
* Which sprite is which character/enemy: **NOT claimed.** The sheets exist for
  the user to identify. `dump_sprites.py`'s caveats about e-record `src` packing
  (`docs/sprite_placement.md`) do not apply here -- this tool does not
  slice e-records, it renders whole 128x128 atlases.

Usage:
    overlay_sprites.py --scan                     # list every container on disc
    overlay_sprites.py --out DIR                  # render all embedded containers
    overlay_sprites.py --out DIR --play           # ... and the 78 04_PLAY files
    overlay_sprites.py --out DIR --file PATH      # one disc file

Exit: 0 all rendered, 1 any container failed to parse or decode.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import disc  # noqa: E402
import lzss  # noqa: E402
from parse_04play import parse_04play, rgb555_to_rgb888  # noqa: E402

try:
    from PIL import Image, ImageDraw
except ImportError:  # pragma: no cover
    sys.exit("PIL required: pip install pillow")

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ISO_JSON = os.path.join(_KIT, "extracted", "iso_files.json")

ATLAS_W = 128
ATLAS_H = 128
ATLAS_SIZE = ATLAS_W * ATLAS_H
HEADER_OFF = 0x20
OFFSET_TABLE_SLOT = 0x34
PARSER_ID = "kit/tools/parse_04play.py v1.0.0"
DECODER_ID = "kit/tools/lzss.py v2.0.0"


def u32(d, off):
    return struct.unpack_from("<I", d, off)[0]


# --------------------------------------------------------------------------
# container discovery
# --------------------------------------------------------------------------

def find_containers(data):
    """Every embedded container start in `data`, by the +0x20 == 0x34 signature.

    The signature is a 1-in-2^32 coincidence and every candidate is then
    structurally validated, so false positives are not a practical concern.
    Returns a list of dicts (offset, header slots, S1 preview, offset-table
    count). Containers are returned in file order.
    """
    n = len(data)
    out = []
    for cs in range(0, n - HEADER_OFF - 20, 4):
        if u32(data, cs + HEADER_OFF) != OFFSET_TABLE_SLOT:
            continue
        hdr = [u32(data, cs + HEADER_OFF + 4 * i) for i in range(5)]
        if any(h == 0 or h >= n - cs for h in hdr[1:]):
            continue
        s1 = cs + hdr[1]
        if s1 + 0x18 > n:
            continue
        a, b = struct.unpack_from("<hh", data, s1)
        cc, fl = data[s1 + 4], data[s1 + 5]
        if not (0 < a < 2000 and 0 <= b < 2000 and 0 < cc <= 64):
            continue
        t, cnt, term = cs + hdr[0], 0, False
        while t + 4 <= n and cnt < 6000:
            v = u32(data, t)
            if v == 0:
                term = True
                break
            if v >= n - cs:
                break
            t += 4
            cnt += 1
        if not term or cnt < 2:
            continue
        out.append({
            "offset": cs,
            "header": {"offset_table_ptr": hdr[0], "S1": hdr[1], "S2": hdr[2],
                       "S3": hdr[3], "S4": hdr[4]},
            "S1": {"e_count": a, "f_count": b, "c_count": cc,
                   "d_flags": "0x%02x" % fl,
                   "palette_path": ("32-color CLUT" if (fl & 0xC0) else "256-color")},
            "offset_table_count": cnt,
        })
    return out


def section_palette(section):
    """rgb888 list for a section's d-table entry 0 (32 words on this disc)."""
    entries = section["d"]["entries"]
    if not entries:
        return None
    return [tuple(c) for c in entries[0]["palette"]["rgb888"]]


def render_atlas(atlas, palette):
    """16384 index bytes -> 128x128 RGBA, index 0 transparent (as dump_sprites)."""
    img = Image.new("RGBA", (ATLAS_W, ATLAS_H))
    px = img.load()
    for i, idx in enumerate(atlas):
        if idx == 0:
            continue
        if idx >= len(palette):
            raise ValueError("atlas index %d beyond %d-entry palette"
                             % (idx, len(palette)))
        px[i % ATLAS_W, i // ATLAS_W] = palette[idx] + (255,)
    return img


def atlas_has_content(atlas):
    """Non-background pixel count, so blank sheets can be reported as blank."""
    return sum(1 for v in atlas if v)


def decode_container(data, cs, workdir):
    """Parse one embedded container. Returns (parsed, atlases, notes).

    `atlases` is a list of {section, blob_index, atlas(bytes), palette, png}.
    """
    tail = data[cs:]
    fd, tmp = tempfile.mkstemp(suffix=".bin", dir=workdir)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(tail)
        parsed = parse_04play(tmp)
    finally:
        os.unlink(tmp)

    errs = parsed["validation"]["errors"]
    if errs:
        raise ValueError("parser reported %d validation error(s): %s"
                         % (len(errs), errs[:3]))

    atlases, notes = [], []
    for name in ("S1", "S2"):
        sec = parsed["sections"].get(name)
        if sec is None:
            notes.append("%s absent" % name)
            continue
        pal = section_palette(sec)
        if pal is None:
            notes.append("%s has no d-table palette" % name)
            continue
        for ent in sec["c"]["entries"]:
            blob = ent.get("blob")
            if blob is None:
                notes.append("%s.c[%d] has no blob" % (name, ent["index"]))
                continue
            start = blob["data_file_offset"]
            raw = lzss.decode_strict(tail[start:start + blob["data_len"]])
            if len(raw) != ATLAS_SIZE:
                raise ValueError("%s.c[%d] decoded to %d bytes, expected %d"
                                 % (name, ent["index"], len(raw), ATLAS_SIZE))
            atlases.append({"section": name, "blob": ent["index"],
                            "atlas": raw, "palette": pal,
                            "png": render_atlas(raw, pal),
                            "content_px": atlas_has_content(raw)})
    return parsed, atlases, notes


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def contact_sheet(atlases, scale, label, cols=None):
    """Grid of atlases at `scale`, with a caption per cell."""
    if not atlases:
        return None
    n = len(atlases)
    cols = cols or (2 if n <= 4 else 4)
    rows = (n + cols - 1) // cols
    cw, ch = ATLAS_W * scale, ATLAS_H * scale
    cap = 12
    W, H = cols * cw, rows * (ch + cap)
    sheet = Image.new("RGB", (W, H), (24, 24, 28))
    dr = ImageDraw.Draw(sheet)
    for i, a in enumerate(atlases):
        cx, cy = (i % cols) * cw, (i // cols) * (ch + cap)
        img = a["png"] if scale == 1 else a["png"].resize((cw, ch), Image.NEAREST)
        sheet.paste(img, (cx, cy), img)
        dr.text((cx + 3, cy + ch + 1),
                "%s.c%d %dpx" % (a["section"], a["blob"], a["content_px"]),
                fill=(190, 190, 200))
    dr.text((4, 2), label, fill=(255, 220, 120))
    return sheet


def render_file(data, path, outdir, workdir, manifest, uniq=None, seen=None):
    """Render every container in one disc file. Returns (rendered, failed).

    `uniq`/`seen` accumulate the deduplicated atlas set for the global index.
    """
    containers = find_containers(data)
    if not containers:
        return 0, 0
    stem = path.replace("/", "_").replace(".", "_")
    rendered = failed = 0
    for c in containers:
        cs = c["offset"]
        label = "%s+0x%x" % (path, cs)
        try:
            parsed, atlases, notes = decode_container(data, cs, workdir)
        except Exception as exc:  # noqa: BLE001 -- reported, never swallowed
            manifest["failures"].append({"container": label, "error": str(exc)})
            failed += 1
            print("  FAIL %s: %s" % (label, exc))
            continue
        fdir = os.path.join(outdir, "%s_%06x" % (stem, cs))
        os.makedirs(fdir, exist_ok=True)
        for a in atlases:
            a["png"].save(os.path.join(fdir, "%s_c%d.png"
                                       % (a["section"], a["blob"])))
        sheet = contact_sheet(atlases, 2, label)
        if sheet is not None:
            sheet.save(os.path.join(fdir, "sheet.png"))
        for a in atlases:
            manifest["atlases"].append({
                "container": label,
                "section": a["section"],
                "blob": a["blob"],
                "content_px": a["content_px"],
                "sha1_atlas": hashlib.sha1(a["atlas"]).hexdigest(),
                "sha1_palette": hashlib.sha1(
                    repr(a["palette"]).encode()).hexdigest()[:12],
            })
            if uniq is not None:
                h = hashlib.sha1(a["atlas"] + repr(a["palette"]).encode()).hexdigest()
                if h not in seen:
                    seen.add(h)
                    a = dict(a, label="%s %s.c%d" % (label, a["section"], a["blob"]))
                    uniq.append(a)
        manifest["containers"].append({
            "file": path, "offset": cs, "label": label,
            "S1": c["S1"], "header": c["header"],
            "atlases": len(atlases), "notes": notes,
        })
        rendered += 1
        print("  ok   %-46s atlases=%d notes=%s"
              % (label, len(atlases), ",".join(notes) if notes else "-"))
    return rendered, failed


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def iso_files(only=None):
    with open(_ISO_JSON) as f:
        files = [r for r in json.load(f) if not r.get("dir")]
    if only:
        files = [r for r in files if r["path"] in only]
    return files


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(_KIT, "work", "overlay_sprites"))
    ap.add_argument("--scan", action="store_true",
                    help="list every container on disc and exit")
    ap.add_argument("--play", action="store_true",
                    help="also render the 78 DATA/04_PLAY containers")
    ap.add_argument("--file", action="append", default=None,
                    help="restrict to this disc path (repeatable)")
    args = ap.parse_args(argv)

    files = iso_files(args.file)
    if args.scan:
        total = 0
        for r in files:
            data = disc.extract(r["lba"], r["size"])
            cs = find_containers(data)
            if not cs:
                continue
            total += len(cs)
            for c in cs:
                print("%-42s +0x%06x  S1=(%d,%d) c=%d %s tbl=%d"
                      % (r["path"], c["offset"], c["S1"]["e_count"],
                         c["S1"]["f_count"], c["S1"]["c_count"],
                         c["S1"]["palette_path"], c["offset_table_count"]))
        print("containers: %d in %d files scanned" % (total, len(files)))
        return 0

    # Default target set: the EMBEDDED containers (04_PLAY itself is optional).
    if not args.file and not args.play:
        files = [r for r in files if not r["path"].startswith("DATA/04_PLAY/")]

    os.makedirs(args.out, exist_ok=True)
    workdir = tempfile.mkdtemp(prefix="overlay_sprites_")
    manifest = {
        "provenance": "disc-derived",
        "tool": "kit/tools/overlay_sprites.py",
        "parser": PARSER_ID,
        "decoder": DECODER_ID,
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "containers": [], "atlases": [], "failures": [],
    }
    sheetdir = os.path.join(args.out, "sheets")
    os.makedirs(sheetdir, exist_ok=True)

    rendered = failed = 0
    uniq, seen = [], set()
    for r in files:
        data = disc.extract(r["lba"], r["size"])
        if not find_containers(data):
            continue
        print("%s (%d bytes)" % (r["path"], len(data)))
        got, bad = render_file(data, r["path"], args.out, workdir, manifest,
                               uniq=uniq, seen=seen)
        rendered += got
        failed += bad

    # Global index: one deduped atlas grid so the whole set is eyeballable.
    if uniq:
        rows = (len(uniq) + 7) // 8
        W, H = 8 * ATLAS_W, rows * (ATLAS_H + 12)
        idx = Image.new("RGB", (W, H), (24, 24, 28))
        dr = ImageDraw.Draw(idx)
        for i, a in enumerate(uniq):
            cx, cy = (i % 8) * ATLAS_W, (i // 8) * (ATLAS_H + 12)
            idx.paste(a["png"], (cx, cy), a["png"])
            dr.text((cx + 2, cy + ATLAS_H + 1), a["label"][-60:],
                    fill=(190, 190, 200))
        idx.save(os.path.join(sheetdir, "ALL_unique_atlases.png"))
        manifest["unique_atlases"] = len(uniq)
        print("unique atlases: %d -> %s"
              % (len(uniq), os.path.join(sheetdir, "ALL_unique_atlases.png")))

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    print("containers rendered: %d, failed: %d, atlases: %d"
          % (rendered, failed, len(manifest["atlases"])))
    print("manifest: %s" % os.path.join(args.out, "manifest.json"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
