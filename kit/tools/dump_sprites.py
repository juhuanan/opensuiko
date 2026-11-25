#!/usr/bin/env python3
"""04_PLAY sprite dumper — disc bytes -> PNG e-record draw pieces + JSON sidecars.

NOTE (2026-10-02): outputs are e-record draw PIECES (rectangles the game
samples), not animation frames — many are complete poses, some partial/composite.
Sidecar/identifier names still use "frames" (frames.json, key names); prose only.

Pipeline (verified end-to-end in docs/pipeline_replay2.md):
  parse_04play.py (canonical container)
    -> lzss.decode (kit/tools/lzss.py v2.0.0 ONLY; 16384 B atlas, loud
       TruncationError; the MEASURED consumed count must equal the container
       length or the blob is rejected as a partial decode)
    -> e-record src byte11 tile coords -> 8-bit index draw pieces
    -> section's own d32 32-color CLUT -> RGBA PNG (index 0 transparent)

PROVENANCE: DISC-DERIVED. Every output byte traces to the disc image via the
canonical parser + the gated decoder. No VRAM-oracle bytes are used.

Usage:
  dump_sprites.py [--out DIR] [FILE ...]
  (default: all 78 DATA/04_PLAY/*.BIN, out kit/work/dump_sprites)

Exit code: 0 if every file dumped clean; 1 if any file errored or was
quarantined (details in manifest.json — nothing fails silently).
"""

import sys, os, glob, json, struct, datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_04play import parse_04play
import lzss
from psx_vram import rgb555_to_rgb888

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("PIL required: pip install pillow")

ATLAS_W = 128
ATLAS_H = 128
ATLAS_SIZE = ATLAS_W * ATLAS_H  # 16384

DECODER_ID = "kit/tools/lzss.py v2.0.0"
PARSER_ID = "kit/tools/parse_04play.py v1.0.0"


def decode_src_word(src_u32):
    """E-record src semantics -- HYPOTHESIS, partially refuted 2026-10-03.

    See docs/sprite_placement.md §"src packing adjudication". What is
    established vs assumed:

    ESTABLISHED
      * bytes 8..10 of the word are NOT constant. All 156/156 sections carrying
        e-records vary within the section, with 125 distinct (b8,b9,b10)
        triples corpus-wide (measured 2026-10-03). This function previously
        reported them as ``const_bytes_8_10``, which asserted the opposite and
        silently discarded real bits. The value is still exposed, under an
        honest name, so downstream consumers can see what is being ignored.
      * the low-nibble-x / high-nibble-y split is a real engine idiom
        (FUN_800e1654 @0x800e18d8 ``andi 0xf`` / @0x800e190c ``sra 4``).

    REFUTED
      * ``y_tile = (b >> 4) & 0x07`` -- the engine's analogous consumer uses the
        FULL 4-bit high nibble (``sra 4``), with no 0x07 mask. The masked value
        is retained for back-compat because published pieces were cut with it,
        but it is not the verified reading.

    STILL A HYPOTHESIS
      * ``bit 7 = c-blob selector`` is statistically corroborated (440/440
        bit-7 records sit in c_count>=2 sections; 0/1693 in single-blob
        sections) but not proven from code.
      * the ``*8``/``*8`` pixel scaling matches neither engine formula (the
        sprite path uses (v&0xF)*8 / ((v>>4)*3)<<2 = 12-px rows; the glyph path
        uses *4 / *8).

    Consequently the 1,884 dumped pieces are a bounds-consistent HYPOTHESIS,
    not a verified decode. Keeping the emitted key names stable; see
    docs/sprite_placement.md for the open experiments.
    """
    b11 = (src_u32 >> 24) & 0xFF
    return {
        "byte11": b11,
        "x_tile": b11 & 0x0F,
        # back-compat: published pieces were cut with the masked value.
        "y_tile": (b11 >> 4) & 0x07,
        "y_tile_unmasked": (b11 >> 4) & 0x0F,
        "blob": (b11 >> 7) & 0x01,
        # NOT constant -- see docstring. Renamed from the false 'const_bytes_8_10'.
        "bytes_8_10": src_u32 & 0xFFFFFF,
    }


def render_frame(atlas, ox, oy, w, h, palette_rgb):
    """Slice (ox,oy,w,h) from the 128x128 8-bit atlas, apply 32-color CLUT.

    Returns RGBA Image; palette index 0 -> transparent (documented
    assumption: d32[0] is 0x0000 in every observed section).
    """
    if ox < 0 or oy < 0 or ox + w > ATLAS_W or oy + h > ATLAS_H:
        raise ValueError(
            "frame rect out of atlas bounds: origin=(%d,%d) size=%dx%d"
            % (ox, oy, w, h))
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for row in range(h):
        base = (oy + row) * ATLAS_W + ox
        for col in range(w):
            idx = atlas[base + col]
            if idx >= len(palette_rgb):
                raise ValueError(
                    "atlas index %d out of 32-color palette range" % idx)
            if idx == 0:
                px[col, row] = (0, 0, 0, 0)
            else:
                r, g, b = palette_rgb[idx]
                px[col, row] = (r, g, b, 255)
    return img


def dump_file(path, outdir):
    """Dump one 04_PLAY file. Returns (file_manifest_dict, frames_written)."""
    t0 = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with open(path, "rb") as f:
        disc = f.read()
    base = os.path.basename(path)
    r = parse_04play(path)
    fdir = os.path.join(outdir, base)
    os.makedirs(fdir, exist_ok=True)

    fm = {
        "provenance": "disc-derived",
        "source_file": base,
        "decoder": DECODER_ID,
        "parser": PARSER_ID,
        "sections": {},
    }
    n_frames = 0
    for sec_name in ("S1", "S2"):
        sec = r["sections"].get(sec_name)
        if sec is None:
            continue
        hdr = sec.get("header")
        if not isinstance(hdr, dict):
            raise ValueError("%s: section %s has no parsed header" % (base, sec_name))
        d_flags = int(hdr["d_flags"], 16)
        if (d_flags & 0xC0) != 0x80:
            raise ValueError(
                "%s: section %s d_flags=%#x not the 32-color branch"
                % (base, sec_name, d_flags))
        d_entries = sec["d"]["entries"]
        if len(d_entries) != 1:
            raise ValueError(
                "%s: section %s d_count=%d, dumper expects 1"
                % (base, sec_name, len(d_entries)))
        pal_words = [int(x, 16) for x in d_entries[0]["palette"]["rgb555"]]
        if len(pal_words) != 32:
            raise ValueError(
                "%s: section %s palette has %d words, expected 32"
                % (base, sec_name, len(pal_words)))
        palette_rgb = [rgb555_to_rgb888(w) for w in pal_words]

        # decode every c-blob: exact size and MEASURED 100% consumption, or raise.
        # (consumed is taken from the decoder, never asserted from the header)
        atlases = []
        blob_info = []
        for ce in sec["c"]["entries"]:
            b = ce["blob"]
            payload = disc[b["data_file_offset"]: b["data_file_offset"] + b["data_len"]]
            if len(payload) != b["data_len"]:
                raise ValueError("%s: short read on c-blob %d" % (base, ce["index"]))
            atlas, consumed = lzss.decode(payload)  # raises on any impurity
            if consumed != b["data_len"]:
                raise ValueError(
                    "%s: section %s c-blob %d: decoder consumed %d of %d bytes "
                    "(partial decode)" % (base, sec_name, ce["index"],
                                          consumed, b["data_len"]))
            if len(atlas) != ATLAS_SIZE:
                raise ValueError(
                    "%s: section %s c-blob %d decoded to %d bytes, expected %d"
                    % (base, sec_name, ce["index"], len(atlas), ATLAS_SIZE))
            atlases.append(atlas)
            blob_info.append({"index": ce["index"], "comp_len": b["data_len"],
                              "decomp_len": len(atlas), "consumed": consumed})

        sm = {
            "d_flags": hdr["d_flags"],
            "palette": {"words": 32,
                        "rgb555": ["0x%04x" % w for w in pal_words]},
            "blobs": blob_info,
            "frames": [],
        }
        for ee in sec["e"]["entries"]:
            rec = ee["record"]
            src_u32 = int(rec["src"], 16)
            s = decode_src_word(src_u32)
            if s["blob"] >= len(atlases):
                raise ValueError(
                    "%s: section %s e-record %d selects blob %d, only %d present"
                    % (base, sec_name, ee["index"], s["blob"], len(atlases)))
            ox, oy = s["x_tile"] * 8, s["y_tile"] * 8
            w, h = rec["w"], rec["h"]
            img = render_frame(atlases[s["blob"]], ox, oy, w, h, palette_rgb)
            png_name = "%s_e%d_c%d_(%d,%d)_%dx%d.png" % (
                sec_name, ee["index"], s["blob"], ox, oy, w, h)
            img.save(os.path.join(fdir, png_name))
            n_frames += 1
            sm["frames"].append({
                "e_index": ee["index"],
                "png": png_name,
                "u": rec["u"], "v": rec["v"], "w": w, "h": h,
                "texpage": rec["texpage"], "clut": rec["clut"],
                "src": rec["src"],
                "src_byte11": "0x%02x" % s["byte11"],
                "tile": {"x": s["x_tile"], "y": s["y_tile"]},
                "origin": [ox, oy],
                "blob": s["blob"],
                "palette": "d32",
            })
        fm["sections"][sec_name] = sm

    with open(os.path.join(fdir, "frames.json"), "w") as f:
        json.dump(fm, f, indent=2)
    fm["_frames_written"] = n_frames
    fm["_dumped_at"] = t0
    return fm, n_frames


def main(argv):
    kitdir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    outdir = os.path.join(kitdir, "work", "dump_sprites")
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--out":
            if i + 1 >= len(argv):
                sys.stderr.write(
                    "ERROR: --out requires a directory argument\n")
                return 2
            outdir = argv[i + 1]; i += 2
        elif argv[i].startswith("--out="):
            outdir = argv[i].split("=", 1)[1]
            if not outdir:
                sys.stderr.write(
                    "ERROR: --out requires a directory argument\n")
                return 2
            i += 1
        elif argv[i].startswith("--"):
            sys.stderr.write("ERROR: unrecognised option %s\n" % argv[i])
            return 2
        else:
            files.append(argv[i]); i += 1
    if not files:
        files = sorted(glob.glob(os.path.join(
            kitdir, "extracted", "bin_overlays", "DATA", "04_PLAY", "*.BIN")))
    os.makedirs(outdir, exist_ok=True)

    manifest = {
        "provenance": "disc-derived",
        "tool": "kit/tools/dump_sprites.py",
        "decoder": DECODER_ID,
        "parser": PARSER_ID,
        "run_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "output": outdir,
        "files": {},
    }
    errors = []
    total_frames = 0
    for path in files:
        base = os.path.basename(path)
        try:
            fm, n = dump_file(path, outdir)
            manifest["files"][base] = {"status": "ok", "frames": n,
                                       "sections": sorted(fm["sections"].keys())}
            total_frames += n
            print("ok   %-12s %d frames" % (base, n))
        except Exception as ex:
            manifest["files"][base] = {"status": "error",
                                       "error": "%s: %s" % (type(ex).__name__, ex)}
            errors.append(base)
            print("ERROR %-12s %s: %s" % (base, type(ex).__name__, ex))
    manifest["summary"] = {"files": len(files), "ok": len(files) - len(errors),
                           "errors": len(errors), "frames": total_frames}
    with open(os.path.join(outdir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("----\n%d/%d files ok, %d frames" % (len(files) - len(errors), len(files), total_frames))
    if errors:
        print("errored:", ", ".join(errors))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
