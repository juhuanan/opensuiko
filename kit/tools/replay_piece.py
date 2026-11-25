#!/usr/bin/env python3
"""replay_piece.py — round-trip check: disc bytes -> PsxVram -> dumped PNG.

For each selected 04_PLAY file / section / e-record:

  1. parse_04play.py + lzss.decode_strict -> 16,384 B atlas per c-blob.
  2. PsxVram: upload each atlas as a 64-word x 128-row rect (the LoadImage
     layout the residency oracle observes) and the section's d32 palette as
     a 32-word CLUT row. Every upload carries provenance (disc file /
     section / c-blob / kind) + sha256, and each upload is verified via the
     VRAM region hash before sampling.
  3. sample_piece() through the canonical 8-bit views at the e-record's
     (ox,oy,w,h) geometry (ox,oy from src byte11, as in dump_sprites.py),
     with palette-index-0 transparency.
  4. Compare the RGBA bytes against the PNG that dump_sprites.py wrote for
     the same piece in the dump output dir.

CAVEAT (documented, see docs/pipeline_replay2.md §6): the e-record's
on-disc texpage/clut words do NOT name the 8-bit atlas/CLUT views — they
decode to 4-bit/16-bit modes and their exact hardware meaning is still open.
The replay therefore samples through texpage/CLUT values DERIVED from the
upload positions; the e-record's raw words are logged per piece for
provenance only.

Usage:
  replay_piece.py [--out DIR] [--section S1|S2] [--e 0,1,5] FILE.BIN ...
  (default out: kit/work/dump_sprites)

Exit 0: every compared piece byte-matches its dumped PNG.
Exit 1: any mismatch, missing PNG, or error (details printed per piece).
"""

import sys, os, glob, struct, json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse_04play import parse_04play
import lzss
from psx_vram import (PsxVram, TP_8BIT, texpage_encode, clut_encode,
                      make_provenance)
from dump_sprites import decode_src_word

try:
    from PIL import Image
except ImportError:
    sys.exit("PIL required: pip install pillow")

ATLAS_W = 128
ATLAS_H = 128
ATLAS_SIZE = ATLAS_W * ATLAS_H  # 16384

# Canonical upload slots (mirror the residency oracle: CRE S1.c[1] at (320,256)).
# texpage y-base is a single bit (0/256), so the second blob slot moves in +x.
BLOB_SLOTS = [(320, 256), (448, 256)]
CLUT_SLOT = (0, 480)  # 32-word CLUT row, safely inside VRAM


def replay_file(path, outdir, sections=("S1", "S2"), e_filter=None):
    """Replay one 04_PLAY file. Returns (n_ok, n_fail, [detail strings])."""
    base = os.path.basename(path)
    with open(path, "rb") as f:
        disc = f.read()
    r = parse_04play(path)
    fdir = os.path.join(outdir, base)
    frames_path = os.path.join(fdir, "frames.json")
    if not os.path.exists(frames_path):
        return 0, 1, ["%s: no frames.json in %s (run dump_sprites.py first)"
                      % (base, fdir)]
    with open(frames_path) as fh:
        frames = json.load(fh)
    if frames.get("provenance") != "disc-derived":
        return 0, 1, ["%s: frames.json is not disc-derived, refusing" % base]

    n_ok, n_fail, details = 0, 0, []
    for sec_name in sections:
        sec = r["sections"].get(sec_name)
        sm = frames["sections"].get(sec_name)
        if sec is None or sm is None:
            continue
        hdr = sec.get("header")
        if not isinstance(hdr, dict):
            return n_ok, n_fail + 1, details + [
                "%s: section %s has no parsed header" % (base, sec_name)]
        d_flags = int(hdr["d_flags"], 16)
        if (d_flags & 0xC0) != 0x80:
            return n_ok, n_fail + 1, details + [
                "%s: section %s d_flags=%#x not the 32-color branch"
                % (base, sec_name, d_flags)]
        d_entries = sec["d"]["entries"]
        pal_words = [int(x, 16) for x in d_entries[0]["palette"]["rgb555"]]
        if len(pal_words) != 32:
            return n_ok, n_fail + 1, details + [
                "%s: section %s palette has %d words, expected 32"
                % (base, sec_name, len(pal_words))]

        vram = PsxVram()
        # upload atlases
        atlases = []
        for ce in sec["c"]["entries"]:
            b = ce["blob"]
            payload = disc[b["data_file_offset"]:
                           b["data_file_offset"] + b["data_len"]]
            atlas = lzss.decode_strict(payload)
            if len(atlas) != ATLAS_SIZE:
                return n_ok, n_fail + 1, details + [
                    "%s: section %s c-blob %d decoded to %d bytes"
                    % (base, sec_name, ce["index"], len(atlas))]
            bi = ce["index"]
            if bi >= len(BLOB_SLOTS):
                return n_ok, n_fail + 1, details + [
                    "%s: section %s c-blob %d has no canonical slot"
                    % (base, sec_name, bi)]
            sx, sy = BLOB_SLOTS[bi]
            rec = vram.upload_rect(
                sx, sy, 64, 128, atlas,
                provenance=make_provenance(base, section=sec_name,
                                           blob_index=bi, kind="atlas",
                                           slot=(sx, sy)))
            if not vram.verify_upload(rec):
                return n_ok, n_fail + 1, details + [
                    "%s: section %s atlas upload failed verification"
                    % (base, sec_name)]
            atlases.append((bi, sx, sy))
        # upload d32 CLUT
        cx, cy = CLUT_SLOT
        clut_bytes = b"".join(struct.pack("<H", w) for w in pal_words)
        crec = vram.upload_rect(
            cx, cy, 32, 1, clut_bytes,
            provenance=make_provenance(base, section=sec_name, kind="clut",
                                       slot=(cx, cy)))
        if not vram.verify_upload(crec):
            return n_ok, n_fail + 1, details + [
                "%s: section %s CLUT upload failed verification" % (base, sec_name)]
        clut_val = clut_encode(cx, cy)
        slot_tp = {bi: texpage_encode(sx, sy, TP_8BIT)
                   for bi, sx, sy in atlases}

        for fr in sm["frames"]:
            if e_filter is not None and fr["e_index"] not in e_filter:
                continue
            png_path = os.path.join(fdir, fr["png"])
            label = "%s %s e%d" % (base, sec_name, fr["e_index"])
            if not os.path.exists(png_path):
                n_fail += 1
                details.append("%s: MISSING png %s" % (label, fr["png"]))
                continue
            try:
                s = decode_src_word(int(fr["src"], 16))
                bi = s["blob"]
                if bi not in slot_tp:
                    raise ValueError("blob %d not uploaded" % bi)
                ox, oy = s["x_tile"] * 8, s["y_tile"] * 8
                w, h = fr["w"], fr["h"]
                if ox < 0 or oy < 0 or ox + w > ATLAS_W or oy + h > ATLAS_H:
                    raise ValueError(
                        "frame rect out of atlas bounds: origin=(%d,%d) "
                        "size=%dx%d" % (ox, oy, w, h))
                rows = vram.sample_piece(slot_tp[bi], clut_val, ox, oy, w, h,
                                         transparent_index=0)
                got = b"".join(bytes(px) for row in rows for px in row)
                want = Image.open(png_path).convert("RGBA").tobytes()
                if got == want:
                    n_ok += 1
                else:
                    n_fail += 1
                    details.append(
                        "%s: PIXEL MISMATCH vs %s "
                        "(e-record texpage=%s clut=%s logged for provenance)" %
                        (label, fr["png"], fr["texpage"], fr["clut"]))
            except Exception as ex:  # noqa: BLE001 - per-piece loud failure
                n_fail += 1
                details.append("%s: %s: %s" % (label, type(ex).__name__, ex))
    return n_ok, n_fail, details


def main(argv):
    kitdir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    outdir = os.path.join(kitdir, "work", "dump_sprites")
    sections = ("S1", "S2")
    e_filter = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--out":
            outdir = argv[i + 1]; i += 2
        elif argv[i] == "--section":
            sections = (argv[i + 1],); i += 2
        elif argv[i] == "--e":
            e_filter = {int(x) for x in argv[i + 1].split(",")}; i += 2
        else:
            files.append(argv[i]); i += 1
    if not files:
        files = sorted(glob.glob(os.path.join(
            kitdir, "extracted", "bin_overlays", "DATA", "04_PLAY", "*.BIN")))

    total_ok = total_fail = 0
    for path in files:
        n_ok, n_fail, details = replay_file(path, outdir, sections, e_filter)
        total_ok += n_ok
        total_fail += n_fail
        print("%-12s %d ok, %d fail" % (os.path.basename(path), n_ok, n_fail))
        for d in details:
            print("   ", d)
    print("----\n%d pieces ok, %d failed" % (total_ok, total_fail))
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
