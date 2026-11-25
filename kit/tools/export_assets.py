#!/usr/bin/env python3
"""export_assets.py — regenerate the canonical Suikoden asset package.

Reads the kit's decoders + disc files and rebuilds an asset tree plus a
top-level manifest.json describing EXACTLY the files that were emitted.

Every asset entry carries provenance (decoder tool, source, disc LBA, doc
reference) plus the actual file list, byte counts and sha256 hashes.  A run
that records any error exits non-zero and writes `manifest.failed.json`
instead of `manifest.json`, so a failed run never replaces the accepted
manifest.  Classes whose inputs cannot be regenerated (geometry inputs, the
music render directory, the extras inherited from the accepted tree) are
recorded as explicit omissions rather than silently reported as a count.

Usage:
    python3 kit/tools/export_assets.py [--out DIR] [--skip CLASS,...]
                                       [--no-swatches]

Classes: dialogue, music, palettes, geometry, recipes, tables, scripts,
textures, extras

Exit status: 0 = zero recorded errors; 1 = at least one recorded error
(details in `<out>/manifest.failed.json`).  An uncaught exception also exits
non-zero and is never converted into a silent success.

Test input overrides (used by kit/tests/test_export_manifest.py; all default
to the in-tree locations):
    SUIKODEN_DIALOGUE_SRC   dialogue_found.txt        (default work/decoded_text)
    SUIKODEN_SCRIPT_CORPUS  scripts_decoded/          (default work/scripts_decoded)
    SUIKODEN_MUSIC_SRC      music/ song*_v3.wav dir   (default work/music)
    SUIKODEN_CURATED        curated metadata tree     (default work/accepted)
    SUIKODEN_BINOV          extracted/bin_overlays    (default extracted/bin_overlays)
"""

import struct, sys, os, re, json, shutil, hashlib, datetime, glob
import importlib

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

# Back-compat alias: this tool used to define this from a hardcoded path.
KIT = _KIT


def _kit(*parts):
    return os.path.join(_KIT, *parts)


def _root(*parts):
    return os.path.join(_ROOT, *parts)


def _env(name, default):
    """Input-root override for tests; default is the in-tree location."""
    v = os.environ.get(name)
    return v if v else default


OUT = os.path.join(KIT, "work", "build", "package")
DEFAULT_OUT = OUT
BINOV = _env("SUIKODEN_BINOV", os.path.join(KIT, "extracted", "bin_overlays"))
DIALOGUE_SRC = _env("SUIKODEN_DIALOGUE_SRC",
                    os.path.join(KIT, "work", "decoded_text", "dialogue_found.txt"))
SCRIPT_SRC = _env("SUIKODEN_SCRIPT_CORPUS",
                  os.path.join(KIT, "work", "scripts_decoded"))
MUSIC_SRC = _env("SUIKODEN_MUSIC_SRC", os.path.join(KIT, "work", "music"))
# Curated, git-tracked metadata that has no producer in kit/tools any more
# (areas/*.json, duel/ikki_file_table.json ...).  It is an INPUT tree; it is
# never the tree being rebuilt unless --out happens to point at it.
CURATED = _env("SUIKODEN_CURATED", os.path.join(KIT, "work", "accepted"))

sys.path.insert(0, os.path.join(KIT, "tools"))
from psx_vram import rgb555_to_rgb888 as _psx_rgb555_to_rgb888  # noqa: E402

MANIFEST_SCHEMA = "suikoden-asset-manifest/1"
DIALOGUE_SCHEMA = "suikoden-dialogue/2"
OVERLAY_BANNER = re.compile(r'^--- (\S+) \(')

WANT_SWATCHES = True

# output-relative paths this run actually wrote (used to tell stale output-root
# files apart from files this run produced)
PRODUCED = set()

MANIFEST = {
    "schema": MANIFEST_SCHEMA,
    "generated_utc": None,
    "generator": "kit/tools/export_assets.py",
    "disc": "Suikoden (v1.1) US, SLUS_002.92 — user's own dump",
    "out_root": None,
    "subset": None,
    "assets": [],
    "omissions": [],
    "errors": [],
    "validation": None,
}

# --------------------------------------------------------------- primitives
def prov(decoder, source, lba=None, doc=None, status="verified", notes=None):
    p = {"decoder": decoder, "source": source, "status": status}
    if lba is not None: p["disc_lba"] = lba
    if doc: p["doc"] = doc
    if notes: p["notes"] = notes
    return p


def err(cls, msg):
    """Record a failure. Any recorded error makes the run exit non-zero."""
    MANIFEST["errors"].append({"class": cls, "error": msg})
    print("ERROR [%s]: %s" % (cls, msg), file=sys.stderr)


def omit(cls, what, reason):
    """Record an explicit, non-fatal gap (a class/artifact not produced)."""
    MANIFEST["omissions"].append({"class": cls, "what": what, "reason": reason})
    print("OMIT  [%s] %s — %s" % (cls, what, reason))


def _rel_out(path):
    try:
        rel = os.path.relpath(path, _ROOT)
    except ValueError:
        return path
    return path if rel.startswith("..") else rel


def _load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def iter_files(base, patterns):
    """Sorted output-relative paths matched by the glob patterns, if present."""
    found = set()
    for pat in patterns:
        for m in glob.glob(os.path.join(base, pat)):
            if os.path.isfile(m):
                found.add(os.path.relpath(m, base))
    return sorted(found)


def note_written(path):
    """Record that this run wrote `path` (absolute or output-relative)."""
    if os.path.isabs(path):
        rel = os.path.relpath(path, OUT)
    else:
        rel = path
    PRODUCED.add(rel.replace(os.sep, "/"))
    return path


def add_asset(id_, cls, path, provenance, patterns, extra=None, in_place=False):
    """Register the files an asset path denotes under OUT, with hashes.

    `count` is derived from the real file list — it is never a bare claim.
    `produced_files` are those this run wrote; `stale_files` are files the
    pattern matched that this run did NOT write (superseded output from an
    earlier run, possible only when --out is not a fresh root).  `in_place`
    assets (extras) are pre-existing by design.
    """
    files = iter_files(OUT, patterns)
    if not files:
        err(cls, "asset %r matched no files under the output root (%s)"
            % (id_, ", ".join(patterns)))
        return None
    produced = [f for f in files if f in PRODUCED]
    stale = [f for f in files if f not in PRODUCED]
    e = {"id": id_, "class": cls, "path": path, "provenance": provenance,
         "count": len(files), "files": files,
         "file_hashes": {r: sha256_file(os.path.join(OUT, r)) for r in files}}
    if in_place:
        # pre-existing by design: nothing was written, nothing is "stale"
        e["registered_in_place"] = True
        e["produced_files"] = []
    else:
        e["produced_files"] = produced
        if stale:
            e["stale_files"] = stale
            omit(cls, "%s: %d superseded file(s)" % (id_, len(stale)),
                 "matched by the asset path but NOT written by this run "
                 "(first: %s); a fresh --out root avoids this" % stale[0])
    if extra: e.update(extra)
    if id_ in {a["id"] for a in MANIFEST["assets"]}:
        err(cls, "duplicate asset id %r" % id_)
    MANIFEST["assets"].append(e)
    return e


def rgb555(w):
    return list(_psx_rgb555_to_rgb888(w))


def lba_map():
    m = {}
    for lba, size, path in _load_json(os.path.join(KIT, "work/iso_files_full.json")):
        m[path] = lba
    return m
LBA = lba_map()

# --- class input inventories (used by preflight AND the exporters) ---------
IKKI = os.path.join(BINOV, "DATA/12_IKKI", "DATA")
BT2_FILES = ["BT2_1S%02d.BIN" % i for i in range(10)]
SKY_OFFSETS = {"SKY1_1": 0x21D0, "SKY1_2": 0x38E0, "SKY1_3": 0x07D0,
               "SKY2_1": "tail", "SKY2_2": "tail", "SKY2_3": 0x0088,
               "SKY3_1": "tail", "SKY3_2": 0xC438, "SKY3_3": 0xC778}
BATH_BIN = os.path.join(BINOV, "DATA/03_SHIRO", "BATH.BIN")
PLAY04_DIR = os.path.join(BINOV, "DATA/04_PLAY")
STONE_BIN = os.path.join(BINOV, "DATA/03_SHIRO", "STONE.BIN")


def palette_inputs():
    return ([os.path.join(IKKI, fn) for fn in BT2_FILES]
            + [os.path.join(IKKI, n + ".BIN") for n in SKY_OFFSETS]
            + [BATH_BIN, PLAY04_DIR])


def table_sources():
    """(root, relpath, note) for every curated metadata input of `tables`."""
    return [
        (CURATED, "areas/battle_bin_tables.json", "battle/menu tables from BATTLE.BIN"),
        (CURATED, "areas/battle_transitions.json", "battle transition table"),
        (CURATED, "areas/va4b_decoded.json", "VA4B area data"),
        (CURATED, "duel/ikki_file_table.json", "duel file table (SLUS @0x8004587C)"),
        (os.path.join(KIT, "work"), "resource_table_dump.csv", "resource table dump"),
        (os.path.join(KIT, "work"), "texture_setup_sites.json", "texture setup sites"),
    ]

# ------------------------------------------------------------------ dialogue
def _parse_dialogue(src):
    """Parse the recovered-text dump.

    Overlay banners (`--- VA1.BIN (N dialogue strings) ---`) are STREAM
    STRUCTURE: they flush the current entry and switch the active overlay.
    They are never appended to a string segment (the pre-2026-10-04 parser
    let 78 banners leak into the text and merged same-(table,entry) rows from
    different overlays into one row).
    """
    hdr = re.compile(r'^\[(\d+),(\d+)\]\s+@0x([0-9a-fA-F]+):\s?(.*)$')
    entries, cur, overlay = [], None, None
    n_pre = 0
    with open(src, encoding="utf-8", errors="replace") as fh:
        src_lines = fh.readlines()
    for line in src_lines:
        s = line.rstrip("\n")
        m = OVERLAY_BANNER.match(s)
        if m:
            if cur: entries.append(cur)
            cur, overlay = None, m.group(1)
            continue
        m = hdr.match(s)
        if m:
            if cur: entries.append(cur)
            cur = None
            if overlay is None:
                n_pre += 1
                continue
            cur = {"overlay": overlay, "table": int(m.group(1)),
                   "entry": int(m.group(2)), "offset": "0x" + m.group(3),
                   "segments": [m.group(4)] if m.group(4).strip() else []}
            continue
        if cur is not None:
            if s.strip() == "[---]":
                cur["segments"].append("")
            else:
                if cur["segments"]:
                    cur["segments"][-1] += ("\n" + s if cur["segments"][-1] else s)
                else:
                    cur["segments"].append(s)
    if cur: entries.append(cur)
    return entries, n_pre


def export_dialogue():
    src = DIALOGUE_SRC
    if not os.path.exists(src):
        err("dialogue", "canonical string dump missing: %s "
                        "(no tool in kit/tools writes this file — see "
                        "kit/docs/asset_manifest_schema.md correction header)"
            % _rel_out(src))
        return
    entries, n_pre = _parse_dialogue(src)
    if n_pre:
        err("dialogue", "%d string entries appeared before any overlay banner "
                        "(no overlay identity)" % n_pre)
    if not entries:
        err("dialogue", "parsed 0 entries from %s" % _rel_out(src))
        return

    # speaker bytes + per-overlay provenance from the script corpus.
    # keyed by the FULL identity (overlay, table, entry): cross-overlay
    # merging is impossible by construction.
    spk_any = re.compile(r'speaker=(\d+)\s+\[(\d+),(\d+)\]')
    spk_addr = re.compile(r'speaker=(\d+)\s+\[(\d+),(\d+)\]\s+@0x([0-9a-fA-F]+)')
    smap = {}
    corp = SCRIPT_SRC
    stat = {"speaker_lines": 0, "resolved_lines": 0, "gap_lines": 0,
            "unresolved_lines": 0}
    ref_keys = {(en["overlay"], en["table"], en["entry"]) for en in entries}
    if os.path.isdir(corp):
        for fn in sorted(os.listdir(corp)):
            if not fn.endswith(".txt") or fn == "INDEX.md":
                continue
            ov = fn[:-4] + ".BIN"
            with open(os.path.join(corp, fn), encoding="utf-8",
                      errors="replace") as fh:
                corp_lines = fh.readlines()
            for line in corp_lines:
                if "*** DATA CONTEXT —" in line:
                    continue
                mB = spk_any.search(line)
                if not mB:
                    continue
                dsp, t, e = int(mB.group(1)), int(mB.group(2)), int(mB.group(3))
                stat["speaker_lines"] += 1
                k = (ov, t, e)
                r = smap.setdefault(k, {"speakers": set(), "overlays": set(),
                                        "addresses": set(),
                                        "phantom_suspect": False,
                                        "phantom_speakers": set()})
                if "GAP" in line:
                    # GAP lines carry no @0x address, so the pre-2026-10-04
                    # regex (which required @0x) never matched them and these
                    # fields were always empty.
                    stat["gap_lines"] += 1
                    r["phantom_suspect"] = True
                    r["phantom_speakers"].add(dsp)
                else:
                    stat["resolved_lines"] += 1
                    if k not in ref_keys:
                        stat["unresolved_lines"] += 1
                    mA = spk_addr.search(line)
                    r["speakers"].add(dsp)
                    if mA:
                        r["addresses"].add("0x" + mA.group(4))
                r["overlays"].add(ov)
        if stat["unresolved_lines"]:
            omit("dialogue", "speaker attribution",
                 "%d of %d resolved speaker lines reference a (table,entry) "
                 "that is absent from the text dump for their overlay; those "
                 "lines contribute no speaker to any row"
                 % (stat["unresolved_lines"], stat["resolved_lines"]))
    else:
        omit("dialogue", "speaker attribution",
             "script corpus %s absent: every row has empty speakers/overlays"
             % _rel_out(corp))

    out_entries = []
    banner_rows = []
    for en in entries:
        k = (en["overlay"], en["table"], en["entry"])
        s = smap.get(k, {})
        segs = en["segments"]
        for seg in segs:
            for ln in seg.split("\n"):
                if OVERLAY_BANNER.match(ln):
                    banner_rows.append("%s/%d/%d"
                                       % (en["overlay"], en["table"], en["entry"]))
        out_entries.append({
            "id": "%s/%d/%d" % (en["overlay"], en["table"], en["entry"]),
            "overlay": en["overlay"],
            "table": en["table"], "entry": en["entry"],
            "offset": en["offset"], "segments": segs,
            "speakers": sorted(s.get("speakers", [])),
            "phantom_speakers": sorted(s.get("phantom_speakers", [])),
            "overlays": sorted(s.get("overlays", [])) or [en["overlay"]],
            "script_addresses": sorted(s.get("addresses", [])),
            "phantom_suspect": bool(s.get("phantom_suspect", False)),
        })
    if banner_rows:
        err("dialogue", "%d rows contain an overlay banner inside the text "
                        "(first: %s)" % (len(banner_rows), banner_rows[0]))
    ids = [e["id"] for e in out_entries]
    if len(set(ids)) != len(ids):
        seen, dup = set(), []
        for i in ids:
            if i in seen: dup.append(i)
            seen.add(i)
        err("dialogue", "%d duplicate dialogue ids (first: %s)"
            % (len(dup), dup[0]))

    out = {
        "schema": DIALOGUE_SCHEMA,
        "id_key": "overlay/table/entry",
        "provenance": prov(
            "kit/tools/suikoden_text_decode.py (single-byte substitution codec)",
            "kit/work/decoded_text/dialogue_found.txt",
            doc="kit/docs/text_encoding.md",
            notes="Dialogue schema /2 (2026-10-04): unique id is now "
                  "overlay/table/entry because a bare table/entry is NOT "
                  "globally unique (the accepted /1 file had 993 duplicate "
                  "keys across 10,173 rows). Overlay banners are parsed as "
                  "structure, never as text. Speaker bytes from "
                  "kit/work/scripts_decoded/ (event opcode 0x1C consumer "
                  "@0x8013B8CC, kit/docs/s1_command_table_via_s2.md); "
                  "The speaker fields preserve script display-slot parameters. "
                  "This is a curated readable catalogue, not an executable "
                  "text-control stream: MAIN control02 waits for page acknowledgement, "
                  "and opcode12 selects name/image; see text_layout_rules.md. "
                  "REPRODUCIBILITY GAP: no tool in kit/tools "
                  "writes dialogue_found.txt (scratch input)."),
        "string_count": len(out_entries),
        "overlay_count": len({e["overlay"] for e in out_entries}),
        "script_attribution": {
            "source": _rel_out(corp),
            "speaker_lines": stat["speaker_lines"],
            "resolved_lines": stat["resolved_lines"],
            "gap_lines": stat["gap_lines"],
            "unresolved_lines": stat["unresolved_lines"],
            "rows_with_speakers": sum(1 for e in out_entries if e["speakers"]),
            "note": "GAP lines name a (table,entry) absent from the text dump, "
                    "so they cannot be attached to any row; per-row "
                    "phantom_suspect can therefore only fire if a GAP key also "
                    "exists as a dumped entry. A row's speakers come only from "
                    "its own overlay (cross-overlay merging rejected).",
        },
        "strings": out_entries,
    }
    dp = os.path.join(OUT, "text", "dialogue.json")
    os.makedirs(os.path.dirname(dp), exist_ok=True)
    with open(dp, "w") as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    note_written(dp)
    add_asset("dialogue", "text", "text/dialogue.json", out["provenance"],
              patterns=["text/dialogue.json"],
              extra={"dialogue_schema": DIALOGUE_SCHEMA,
                     "string_count": len(out_entries)})

# --------------------------------------------------------------------- music
def export_music():
    """Copy whatever v3 renders exist and describe exactly those files.

    Music DECODING/RENDERING is out of scope (user-deferred).  This function
    only packages: it must never claim 4 files when fewer exist, and it must
    never overwrite an existing provenance/approval record with an empty or
    partial file list.
    """
    md = os.path.join(OUT, "music", "v3")
    os.makedirs(md, exist_ok=True)
    src = MUSIC_SRC
    produced, records = [], []
    for i in range(4):
        name = "song%d_v3.wav" % i
        s = os.path.join(src, name)
        if os.path.exists(s):
            shutil.copy(s, os.path.join(md, name))
            note_written(os.path.join(md, name))
            produced.append(name)
            records.append({"name": name, "bytes": os.path.getsize(s),
                            "sha256": sha256_file(s)})
    if not produced:
        omit("music", "music/v3 render",
             "source %s absent (kit/work/music was deleted by "
             "CLEANUP_20261003.md); 0 of song0..song3_v3.wav copied. Any "
             "music/v3/ files already in the output root were NOT produced by "
             "this run and its provenance.json was left untouched."
             % _rel_out(src))
        return

    render_id = hashlib.sha256(
        json.dumps(sorted((r["name"], r["sha256"]) for r in records),
                   sort_keys=True).encode()).hexdigest()
    p = prov("kit/tools/pqes_render3.py",
             "disc SEQ.BIN (pQES = Sony PS1 SEQ)",
             doc="kit/docs/music_seq_hypothesis.md",
             status="best-effort",
             notes="Two parser bugs fixed (VLQ deltas after meta events, "
                   "running status on 0xFn); tone sample = u16 at tone+22, "
                   "1-based (VAG index = value-1), 512 bytes/program, sample "
                   "looping. Tempo/instrumentation are guesses. NO approval "
                   "state is inherited: any earlier approval sentence refers "
                   "to a different render id than the one recorded here.")
    new = {"schema": "suikoden-music/1", "provenance": p,
           "render_id": render_id, "files": produced,
           "file_hashes": {r["name"]: r["sha256"] for r in records},
           "file_bytes": {r["name"]: r["bytes"] for r in records},
           "approval": {"state": "not-assessed",
                        "note": "media approval is a user decision recorded "
                                "against render_id; presence of a WAV is not "
                                "approval"}}
    pp = os.path.join(md, "provenance.json")
    existing_files = []
    if os.path.exists(pp):
        try:
            existing_files = list(_load_json(pp).get("files", []))
        except Exception as ex:
            err("music", "existing provenance.json unreadable: %s" % ex)
    if existing_files and len(produced) < len(set(existing_files)):
        omit("music", "music/v3/provenance.json",
             "partial selection: copied %d of the %d files described by the "
             "existing provenance record; the write was skipped so the "
             "existing record (and any approval attached to it) is not "
             "overwritten" % (len(produced), len(set(existing_files))))
    else:
        with open(pp, "w") as fh:
            json.dump(new, fh, indent=1)
        note_written(pp)
    add_asset("music", "audio", "music/v3/", p,
              patterns=["music/v3/*.wav"],
              extra={"render_id": render_id,
                     "provenance_file": "music/v3/provenance.json",
                     "expected": 4})

# ------------------------------------------------------------------ palettes
def swatch(words, path):
    from PIL import Image
    img = Image.new("RGB", (16, 16))
    px = img.load()
    for i, w in enumerate(words[:256]):
        r, g, b = rgb555(w)
        px[i % 16, i // 16] = (r, g, b)
    img = img.resize((256, 256), Image.NEAREST)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)


def export_palettes():
    """Extract RGB555 values (required) separately from PNG swatches (optional).

    A failed swatch can therefore never present the palette VALUES as a failed
    asset, and a run without Pillow can still export values (--no-swatches).
    """
    from text_lzss import decompress as proven_decompress
    pals = []
    swdir = os.path.join(OUT, "palettes", "swatches")
    sw = {"generated": 0, "failed": 0, "skipped": not WANT_SWATCHES}

    def emit(pid, words, source, lba, doc, notes=None):
        entry = {"id": pid, "entries": len(words),
                 "rgb555": ["%04x" % w for w in words],
                 "rgb888": [rgb555(w) for w in words],
                 "swatch": None, "swatch_status": "skipped",
                 "provenance": prov("rgb555_to_rgb888 (r=(w&31)*255//31, ...)",
                                    source, lba, doc, notes=notes)}
        pals.append(entry)
        if not WANT_SWATCHES:
            return
        try:
            rel = "palettes/swatches/%s.png" % pid
            swatch(words, os.path.join(OUT, rel))
            note_written(rel)
            entry["swatch"] = rel
            entry["swatch_status"] = "generated"
            sw["generated"] += 1
        except Exception as ex:
            entry["swatch_status"] = "failed: %s" % ex
            sw["failed"] += 1
            err("palettes", "swatch %s failed (palette values unaffected): %s"
                % (pid, ex))

    ikki = IKKI
    # BT2: 10 files, trailing 512B of decompressed blob = 256-color RGB555
    for i, fn in enumerate(BT2_FILES):
        p = os.path.join(ikki, fn)
        try:
            with open(p, "rb") as fh:
                blob = fh.read()
            clen = struct.unpack("<I", blob[:4])[0]
            assert clen == len(blob) - 4
            out = proven_decompress(blob[4:4 + clen])
            words = struct.unpack("<256H", out[-512:])
            emit("bt2_%d" % i, list(words), "DATA/12_IKKI/DATA/" + fn,
                 LBA.get("/DATA/12_IKKI/DATA/" + fn),
                 "kit/docs/decode_btsky_spritestruct.md",
                 "Trailing 512B of MSB-LZSS blob (kit/tools/btsky_lzss.py, verified vs text_decode_stream @0x800C3144); smoothness 171-214/255 vs ~30 noise.")
        except Exception as ex:
            err("palettes", "BT2 %s: %s" % (fn, ex))

    # SKY: 9 files, file-specific palette offsets (corrected 2026-10-02).
    # Offsets for SKY3_2/SKY3_3 fall outside the verified 16,384 B decode:
    # those CLUTs are UNLOCATED, so they are recorded as explicit omissions
    # instead of failing the whole run on an unpack error.
    for name, off in SKY_OFFSETS.items():
        fn = name + ".BIN"; p = os.path.join(ikki, fn)
        try:
            with open(p, "rb") as fh:
                blob = fh.read()
            clen = struct.unpack("<I", blob[:4])[0]
            out = proven_decompress(blob[4:4 + clen])
            o = len(out) - 512 if off == "tail" else off
            if o < 0 or o + 512 > len(out):
                omit("palettes", "sky_%s" % name.lower(),
                     "offset 0x%x is outside the verified %d-byte decode; "
                     "CLUT unlocated (kit/docs/sky_palette.md) — "
                     "entry omitted, no 512-byte tail is invented"
                     % (o, len(out)))
                continue
            words = struct.unpack("<256H", out[o:o + 512])
            emit("sky_%s" % name.lower(), list(words), "DATA/12_IKKI/DATA/" + fn,
                 LBA.get("/DATA/12_IKKI/DATA/" + fn),
                 "kit/docs/decode_sky_palette.md",
                 "File-specific offset 0x%x (no single structural rule); "
                 "offsets beyond the decode are omitted, not substituted. "
                 "Smoothness 144-222/255." % o)
        except Exception as ex:
            err("palettes", "SKY %s: %s" % (fn, ex))

    # BATH: 4 bank CLUTs from BATH.BIN overlay @0x8008d114 + bank*0x200
    try:
        with open(BATH_BIN, "rb") as fh:
            bath = fh.read()
        base = 0x80080000
        for b in range(4):
            words = struct.unpack_from("<256H", bath, 0x8008d114 + b * 0x200 - base)
            emit("bath_bank%d" % b, list(words), "DATA/03_SHIRO/BATH.BIN",
                 LBA.get("/DATA/03_SHIRO/BATH.BIN"),
                 "kit/docs/decode_bath_filesource.md (kit/tools/bath_render.py)",
                 "Per-bank 256-color CLUT; uploader bath_sound_load case 0.")
    except Exception as ex:
        err("palettes", "BATH: %s" % ex)

    # 04_PLAY S4: 512B tail = 256xRGB555 per file (78 files)
    play = PLAY04_DIR
    n4 = 0
    for fn in sorted(os.listdir(play)):
        if not fn.endswith(".BIN"): continue
        p = os.path.join(play, fn)
        try:
            with open(p, "rb") as fh:
                d = fh.read()
            secs = struct.unpack("<5I", d[0x20:0x34])
            words = struct.unpack("<256H", d[secs[4]:secs[4] + 512])
            emit("play04_%s_s4" % fn[:-4].lower(), list(words),
                 "DATA/04_PLAY/" + fn, LBA.get("/DATA/04_PLAY/" + fn),
                 "kit/docs/decode_04play_consumer_20261002.md",
                 "S4 section (file tail, 512B).")
            n4 += 1
        except Exception as ex:
            err("palettes", "04PLAY %s: %s" % (fn, ex))

    if not pals:
        err("palettes", "no palettes extracted")
        return
    out = {"schema": "suikoden-palettes/1",
           "provenance": prov("per-entry", "multiple (see entries)",
                              notes="All palettes 15-bit RGB555; shipped as values, never rendered as art (quality rule). Offsets that fall outside a verified decode are omitted (see manifest omissions)."),
           "swatch_summary": sw,
           "palettes": pals}
    pp = os.path.join(OUT, "palettes", "palettes.json")
    os.makedirs(os.path.dirname(pp), exist_ok=True)
    with open(pp, "w") as fh:
        json.dump(out, fh, indent=1)
    note_written(pp)
    add_asset("palettes", "palette", "palettes/palettes.json",
              out["provenance"], patterns=["palettes/palettes.json"],
              extra={"palette_count": len(pals),
                     "swatches_optional": True,
                     "swatches_ok": (not WANT_SWATCHES) or sw["failed"] == 0,
                     "swatch_summary": sw})
    if not WANT_SWATCHES:
        omit("palettes", "swatches",
             "--no-swatches: palette values exported, PNG swatches are an "
             "optional artifact and were not generated")
    elif sw["generated"]:
        add_asset("palette_swatches", "palette", "palettes/swatches/*.png",
                  prov("kit/tools/export_assets.py::swatch (16x16 RGB555 -> "
                       "NEAREST 256x256)",
                       "derived from palettes/palettes.json entries",
                       status="optional",
                       notes="Optional viewer aid; failing swatches do not "
                             "affect the verified RGB555 values and are "
                             "recorded as errors, never as a verified swatch."),
                  patterns=["palettes/swatches/*.png"],
                  extra={"optional": True, "generated": sw["generated"],
                         "failed": sw["failed"]})

# ------------------------------------------------------------------ geometry
def export_geometry():
    # .8 bytes feed SPU DMA4; interpreting them as vertices fabricates geometry.
    omit("area_geometry", "geometry/*.json",
         ".8 files are stereo SPU ADPCM streams; the retired FT3/F4 "
         "interpretation is superseded by archive/docs/dot8_spu_audio.md")

# ------------------------------------------------------------------- recipes
def parse_play04(path):
    """Parse a 04_PLAY file into the sprite-RECIPE structure.

    Built on the canonical container parser (kit/tools/parse_04play.py),
    the single source of truth for the 04_PLAY container. Schema
    suikoden-sprite-recipe/2 changes from /1:

    - "frames" (17 x u16 at 0x34) is GONE: it was garbage from a 16-bit
      misread of the 32-bit offset table (alternating offsets and zeros).
      Replaced by "offset_table" with the real 32-bit entries.
    - "sections.S0" (mislabeled offset-table pointer) is gone; replaced by
      "sections.offset_table".
    - "graphics_blobs" added: the c-table LZSS-compressed graphics blocks
      ([u32 len][LZSS]), which the game decodes and LoadImages to VRAM.
      The container is NOT descriptor-only.
    - "anims" retains its spacing-model keys and carries exact counted
      sequence headers/pairs for S1 and S2; stream bounds follow the counts.

    Everything here is verified container/descriptor data (provenance in
    docs). Base TEXTURES are gated on later phases and NOT included.
    """
    from parse_04play import parse_04play, PARSER_VERSION
    cp = parse_04play(path)
    verrs = cp["validation"]["errors"]
    if verrs:
        raise ValueError("canonical parse failed: %s" % (verrs,))
    name = os.path.basename(path)
    secs = cp["sections"]

    def section(name):
        s = secs[name]
        h = s["header"]
        blobs = [{
            "index": e["index"],
            "file_offset": "0x%x" % e["target_file_offset"],
            "resolved": e["relocated"],
            "len_field": e["blob"]["len_field"],
            "data_len": e["blob"]["data_len"],
        } for e in s["c"]["entries"]]
        palettes = [{
            "index": e["index"],
            "file_offset": "0x%x" % e["target_file_offset"],
            "resolved": e["relocated"],
            "words": e["palette"]["words"],
            "rgb555": e["palette"]["rgb555"],
            "rgb888": e["palette"]["rgb888"],
        } for e in s["d"]["entries"]]
        pieces = [e["record"] for e in s["e"]["entries"]]
        # anims: model-aware (canonical f-table)
        f = s["f"]
        anims = {"model": f["model"]}
        if f["model"] == "fixed_records":
            recs = []
            for e in f["entries"]:
                raw = bytes.fromhex(e["raw_hex"])
                recs.append({
                    "index": e["index"],
                    "file_offset": "0x%x" % e["target_file_offset"],
                    "header": raw[:4].hex(),
                    "pairs": [[raw[4 + 2 * k], raw[5 + 2 * k]]
                              for k in range((len(raw) - 4) // 2)],
                    "raw_hex": e["raw_hex"],
                    "frame_count": e["sequence"]["frame_count"],
                    "flags": e["sequence"]["flags"],
                    "draw_capacity": e["sequence"]["draw_capacity"],
                    "parse_confidence": "counted-header/pairs",
                })
            anims["records"] = recs
        else:
            # Preserve the stream view; every entry also has exact counted pairs.
            with open(path, "rb") as fh:
                d = fh.read()
            start = f["stream_start_file_offset"]
            approx_end = f["stream_end_file_offset"]
            anims["entries"] = [{
                "index": e["index"],
                "stream_offset": "0x%x" % e["target_file_offset"],
                "resolved": e["relocated"],
                "raw_hex": e["raw_hex"],
                "sequence": e["sequence"],
            } for e in f["entries"]]
            anims["stream"] = {
                "start_file_offset": "0x%x" % start,
                "approx_end_file_offset": "0x%x" % approx_end,
                "end_note": "exact maximum counted-sequence end; entries can alias",
                "bytes_hex": d[start:approx_end].hex(),
            }
            anims["parse_confidence"] = \
                "counted-header/pairs; live S1 consumer traced"
        return {
            "file_offset": "0x%x" % s["file_offset"],
            "header": {
                "a_e_count": h["a_e_count"], "b_f_count": h["b_f_count"],
                "c_count": h["c_count"], "d_flags": h["d_flags"],
                "d_count": h["d_count"],
                "palette_path": h["palette_path"],
                "return_value_u8": h["return_value_u8"],
            },
            "graphics_blobs": blobs,
            "palettes": palettes,
            "pieces": pieces,
            "anims": anims,
        }

    s4 = secs["S4"]
    s4words = [int(w, 16) for w in s4["rgb555"]]
    return {
        "schema": "suikoden-sprite-recipe/2",
        "id": name[:-4],
        "source_file": "DATA/04_PLAY/" + name,
        "disc_lba": LBA.get("/DATA/04_PLAY/" + name),
        "size": cp["provenance"]["source_size"],
        "source_sha256": cp["provenance"]["source_sha256"],
        "provenance": {
            "container_parser": "kit/tools/parse_04play.py v%s" % PARSER_VERSION,
            "parser_warnings": cp["validation"]["warnings"],
            "piece_records": "8-byte header + count*8-byte sub-pieces; legacy raw-prefix "
                             "keys retained (archive/docs/play_s1_consumers.md)",
            "true_consumer": "S1:800E1E3C ->800E2044 ->800E211C; live timer800E2A9C",
            "anim_sequences": "4-byte header + frame_count*(draw index,duration) pairs; "
                              "zero counts and out-of-range references are preserved, "
                              "not asserted reachable",
            "base_textures": "Not included in this recipe; decoded index planes are "
                             "separate assets with their own palette/image gates",
            "pixel_codec": "kit/tools/lzss.py v2.0.0;128x128 indexed planes, strict consumption",
        },
        "sections": {
            "offset_table": "0x%x" % cp["offset_table"]["table_file_offset"],
            "S1": "0x%x" % secs["S1"]["file_offset"],
            "S2": "0x%x" % secs["S2"]["file_offset"],
            "S3": "0x%x" % secs["S3"]["file_offset"],
            "S4": "0x%x" % secs["S4"]["file_offset"],
        },
        "offset_table": {
            "count": cp["offset_table"]["count"],
            "entries": [{
                "index": e["index"],
                "file_offset": "0x%x" % e["target_file_offset"],
                "resolved": e["relocated"],
                "approx_region": e["approx_region"],
            } for e in cp["offset_table"]["entries"]],
        },
        "S1": section("S1"),
        "S2": section("S2"),
        "S3": {"size_field": secs["S3"]["size_field"],
               "data_len": secs["S3"]["data_len"]},
        "palette_256": {"entries": 256,
                        "rgb555": ["%04x" % w for w in s4words],
                        "rgb888": [rgb555(w) for w in s4words]},
    }


def export_recipes():
    rd = os.path.join(OUT, "sprites", "recipes")
    os.makedirs(rd, exist_ok=True)
    play = PLAY04_DIR
    if not os.path.isdir(play):
        err("recipes", "04_PLAY source missing: %s" % _rel_out(play))
        return
    n = 0
    for fn in sorted(os.listdir(play)):
        if not fn.endswith(".BIN"): continue
        try:
            rec = parse_play04(os.path.join(play, fn))
            with open(os.path.join(rd, fn[:-4] + ".json"), "w") as fh:
                json.dump(rec, fh)
            note_written(os.path.join(rd, fn[:-4] + ".json"))
            n += 1
        except Exception as ex:
            err("recipes", "%s: %s" % (fn, ex))
    add_asset("sprite_recipes", "sprite-recipe", "sprites/recipes/*.json",
              prov("kit/tools/export_assets.py::parse_play04",
                   "DATA/04_PLAY/*.BIN (78 files)",
                   doc="kit/docs/decode_04play_overlay_consumer.md",
                   status="verified-descriptors",
                   notes="Descriptors + palettes + animation WITHOUT base textures (gated). The Zig renderer consumes this as quad-descriptor + palette-animation data."),
              patterns=["sprites/recipes/*.json"])

# -------------------------------------------------------------------- tables
def export_tables():
    td = os.path.join(OUT, "tables")
    os.makedirs(td, exist_ok=True)
    copied, provenance_rows = [], []
    for root, rel, note in table_sources():
        s = os.path.join(root, rel)
        if not os.path.exists(s):
            err("data_tables", "curated input missing: %s — cannot copy to "
                               "tables/%s" % (_rel_out(s), os.path.basename(rel)))
            continue
        dst = os.path.join(td, os.path.basename(rel))
        shutil.copy(s, dst)
        note_written(dst)
        copied.append(os.path.basename(rel))
        provenance_rows.append({"file": os.path.basename(rel), "note": note,
                                "source": _rel_out(s),
                                "source_sha256": sha256_file(s)})
    p = prov("curated tracked metadata (no producer in kit/tools); see "
             "per-file `sources`",
             "multiple disc BINs", doc="kit/docs/asset_map.md",
             status="curated-copy",
             notes="Consolidated copies of tracked metadata read from the "
                   "curated input tree %s (NOT from the output tree being "
                   "rebuilt). Originals remain in place. Source hashes are "
                   "recorded so drift is detectable." % _rel_out(CURATED))
    with open(os.path.join(td, "provenance.json"), "w") as fh:
        json.dump({"schema": "suikoden-tables/1", "provenance": p,
                   "files": copied, "sources": provenance_rows}, fh, indent=1)
    note_written(os.path.join(td, "provenance.json"))
    if copied:
        add_asset("data_tables", "table", "tables/*", p,
                  patterns=["tables/*"],
                  extra={"curated_input_root": _rel_out(CURATED),
                         "sources": provenance_rows})

# ------------------------------------------------------------------- scripts
STATS_RE = re.compile(
    r'# stats: (\d+) insns, (\d+) dialogue lines, (\d+) gaps')
INDEX_TOTALS_RE = re.compile(
    r'Totals: (\d+) overlays, (\d+) instructions, (\d+) dialogue lines, '
    r'(\d+) string-table gaps')


def export_scripts():
    sd = os.path.join(OUT, "scripts")
    os.makedirs(sd, exist_ok=True)
    src = SCRIPT_SRC
    if not os.path.isdir(src):
        err("scripts", "script corpus missing: %s" % _rel_out(src))
        return
    n = 0
    for fn in sorted(os.listdir(src)):
        if fn.endswith(".txt"):
            shutil.copy(os.path.join(src, fn), os.path.join(sd, fn))
            note_written(os.path.join(sd, fn))
            n += 1
    if os.path.exists(os.path.join(src, "INDEX.md")):
        shutil.copy(os.path.join(src, "INDEX.md"), os.path.join(sd, "INDEX.md"))
        note_written(os.path.join(sd, "INDEX.md"))
    # derive the totals from the files actually copied; never hardcode a
    # superseded number (the pre-2026-10-04 note claimed 62,717/1,402 while
    # the corpus actually contains 62,739/2,283).
    ti = td = tg = 0
    for fn in sorted(os.listdir(sd)):
        if not fn.endswith(".txt"):
            continue
        with open(os.path.join(sd, fn), encoding="utf-8", errors="replace") as f:
            m = STATS_RE.search(f.read(8192))
        if m:
            ti += int(m.group(1)); td += int(m.group(2)); tg += int(m.group(3))
        else:
            err("scripts", "%s has no '# stats:' header" % fn)
    totals = {"overlays": n, "insns": ti, "dialogue": td, "gaps": tg}
    idx = os.path.join(sd, "INDEX.md")
    if os.path.exists(idx):
        with open(idx, encoding="utf-8", errors="replace") as fh:
            m = INDEX_TOTALS_RE.search(fh.read())
        if m:
            claimed = (int(m.group(1)), int(m.group(2)), int(m.group(3)),
                       int(m.group(4)))
            actual = (n, ti, td, tg)
            if claimed != actual:
                err("scripts", "INDEX.md totals %s disagree with the copied "
                               "per-file stats %s" % (claimed, actual))
        else:
            omit("scripts", "INDEX.md totals",
                 "no parseable 'Totals:' line; per-file stats used")
    p = prov("kit/tools/event_script_decode.py (82-entry table) + "
             "kit/tools/build_script_corpus.py",
             "kit/work/scripts_decoded/ (copied from %s)" % _rel_out(src),
             doc="kit/docs/s1_command_table_via_s2.md",
             notes="Counts are recomputed from the copied files' '# stats:' "
                   "headers: %d instructions, %d dialogue lines with "
                   "speakers, %d string-table gaps. Dialogue resolved against "
                   "the canonical dialogue_found.txt (never re-decoded here)."
                   % (ti, td, tg))
    if n:
        add_asset("event_scripts", "script", "scripts/*.txt", p,
                  patterns=["scripts/*.txt"],
                  extra={"totals": totals,
                         "index": "scripts/INDEX.md" if os.path.exists(
                             os.path.join(sd, "INDEX.md")) else None})

# ------------------------------------------------------------------ textures
def export_textures():
    """Regenerate the Stone Tablet pages from disc-derived overlay bytes.

    The pre-2026-10-04 version READ `<OUT>/data/shiro/png/stone_*.png` — the
    output tree it was rebuilding — so a fresh --out silently produced 0
    files.  It now decodes the STONE.BIN overlay directly (same codec as
    kit/tools/stone_render.py) and reproduces the 4x NEAREST upscales too.
    """
    import numpy as np
    from PIL import Image
    import stone_render as sr
    overlay = STONE_BIN if os.path.exists(STONE_BIN) else str(sr.OVERLAY)
    if not os.path.exists(overlay):
        err("textures", "stone overlay missing: %s" % _rel_out(overlay))
        return
    with open(overlay, "rb") as fh:
        raw = fh.read()
    pal = sr.load_clut(raw)
    td = os.path.join(OUT, "textures", "stone")
    os.makedirs(td, exist_ok=True)
    for stem, addr in (("stone_font_a", sr.FONT_A), ("stone_font_b", sr.FONT_B)):
        idx = sr.decode_4bit(raw[addr - sr.BASE:addr - sr.BASE + sr.FONT_SIZE])
        img = Image.fromarray(pal[idx])
        img.save(os.path.join(td, stem + ".png"))
        note_written(os.path.join(td, stem + ".png"))
        img.resize((img.width * 4, img.height * 4), Image.NEAREST).save(
            os.path.join(td, stem + "_4x.png"))
        note_written(os.path.join(td, stem + "_4x.png"))
    sw = np.zeros((16, 16, 3), dtype=np.uint8)
    for i, c in enumerate(pal):
        sw[i, :] = c
    Image.fromarray(sw).resize((256, 256), Image.NEAREST).save(
        os.path.join(td, "stone_clut16.png"))
    note_written(os.path.join(td, "stone_clut16.png"))
    p = prov("kit/tools/stone_render.py (decode logic; import, not subprocess)",
             "DATA/03_SHIRO/STONE.BIN",
             doc="kit/docs/decode_stone_pixels.md",
             notes="Disc-derived overlay bytes decoded to two 4bpp 128x128 "
                   "kanji pages + 16-color CLUT; recognizable Japanese text "
                   "(verified). The *_4x files are NEAREST upscales of the "
                   "128x128 pages (viewer aid, no new pixels). Regenerated "
                   "from the overlay instead of copying the output tree; "
                   "pixel-identical to the 2026-10-01 pages. Overlay "
                   "sha256=%s." % sha256_file(overlay))
    add_asset("stone_textures", "texture", "textures/stone/*.png", p,
              patterns=["textures/stone/*.png"],
              extra={"source_overlay": "DATA/03_SHIRO/STONE.BIN",
                     "source_sha256": sha256_file(overlay)})

# -------------------------------------------------------------------- extras
def _count_credit_lines(path):
    n = 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s and not s.startswith("#"):
                n += 1
    return n


def export_extras():
    """Register pre-existing assets that live under the selected OUT root.

    Reality check (2026-10-04): these are NOT regenerated by any tool here, so
    each is verified to exist and registered only with its real file list and
    count.  A documented-but-absent extra is an explicit omission.
    """
    base = OUT
    # credits -----------------------------------------------------------------
    cpath = os.path.join(base, "text", "credits_vz8.txt")
    if os.path.exists(cpath):
        n = _count_credit_lines(cpath)
        add_asset("credits", "text", "text/credits_vz8.txt",
                  prov("kit/tools/text_decode_demo.py",
                       "DATA/15_AREA.Z/VZ8.BIN @ 0x1c14",
                       doc="kit/work/decoded_text/README.md",
                       status="registered-in-place",
                       notes="%d non-comment staff-credit lines (GENSO "
                             "SUIKODEN STAFF, ...). Registered in place; not "
                             "copied or regenerated by this run." % n),
                  patterns=["text/credits_vz8.txt"], in_place=True,
                  extra={"credit_lines": n})
    else:
        omit("credits", "text/credits_vz8.txt",
             "not present under the selected output root; registered-in-place "
             "class, so a fresh root has no credits to describe")

    # xa audio ----------------------------------------------------------------
    xad = os.path.join(base, "audio", "xa")
    if os.path.isdir(xad):
        wavs = sorted(f for f in os.listdir(xad) if f.endswith(".wav"))
        if wavs:
            add_asset("xa_audio", "audio", "audio/xa/",
                      prov("kit/tools/xa_decode.py (historical; FFmpeg is the "
                           "accepted producer)",
                           "disc XA sectors",
                           doc="kit/work/assets_zig/audio/xa/",
                           status="registered-in-place",
                           notes="Registered in place; media approval is a "
                                 "user decision and is NOT inferred from file "
                                 "presence. Any historical approval sentence "
                                 "refers to different bytes than these."),
                      patterns=["audio/xa/*.wav"], in_place=True,
                      extra={"expected": 6, "readme": "audio/xa/README.md"
                             if os.path.exists(os.path.join(xad, "README.md"))
                             else None})
            if len(wavs) != 6:
                omit("xa_audio", "clip count",
                     "%d WAV clips present vs 6 documented" % len(wavs))
        else:
            omit("xa_audio", "audio/xa/*.wav", "directory present but empty")
    else:
        omit("xa_audio", "audio/xa/",
             "not present under the selected output root (registered-in-place "
             "class)")

    # vab banks ---------------------------------------------------------------
    banksd = os.path.join(base, "audio", "banks")
    vb = os.path.join(base, "audio", "vab_decoded.wav")
    bankwavs = sorted(f for f in os.listdir(banksd)
                      if f.endswith(".wav")) if os.path.isdir(banksd) else []
    if bankwavs:
        add_asset("vab_banks", "audio", "audio/banks/ + audio/vab_decoded.wav",
                  prov("kit/tools/vab_to_wav.py", "ORCH.VB + VAB banks",
                       doc=None,
                       status="registered-in-place",
                       notes="%d bank WAVs present under the selected output "
                             "root (the accepted count was 48). No kit/docs "
                             "writeup exists for this bank set; the historical "
                             "provenance pointed at a docs file that was never "
                             "written. No approval state is inferred. "
                             "vab_decoded.wav present=%s."
                             % (len(bankwavs), os.path.exists(vb))),
                  patterns=["audio/banks/*.wav"] +
                           (["audio/vab_decoded.wav"] if os.path.exists(vb) else []),
                  in_place=True,
                  extra={"expected_banks": 48, "actual_banks": len(bankwavs),
                         "vab_decoded_wav": os.path.exists(vb)})
        if len(bankwavs) != 48:
            omit("vab_banks", "bank count",
                 "%d bank WAVs present under audio/banks/; the accepted "
                 "manifest declared files count=48 (= %d bank WAVs + "
                 "vab_decoded.wav), while asset_manifest_schema.md prose said "
                 "'ORCH.VB + 47 banks'. Count is now derived from the actual "
                 "file list; whether a 48th bank was ever expected is NOT "
                 "established statically." % (len(bankwavs), len(bankwavs)))
        if not os.path.exists(vb):
            omit("vab_banks", "audio/vab_decoded.wav",
                 "composite output named in this asset's path is missing")
    else:
        omit("vab_banks", "audio/banks/",
             "no bank WAVs under the selected output root "
             "(registered-in-place class)")

    # str video ---------------------------------------------------------------
    vd = os.path.join(base, "video")
    mp4s = sorted(f for f in os.listdir(vd)
                  if f.endswith(".mp4")) if os.path.isdir(vd) else []
    if mp4s:
        add_asset("str_video", "video", "video/*.mp4",
                  prov("kit/tools/str_decode.py", "disc STR files",
                       doc="kit/docs/str_video.md",
                       status="registered-in-place",
                       notes="Registered in place; not re-decoded by this run. "
                             "Media approval is a user decision, not a "
                             "property of the file list."),
                  patterns=["video/*.mp4"], in_place=True,
                  extra={"expected": 3})
        if len(mp4s) != 3:
            omit("str_video", "clip count",
                 "%d MP4s present vs 3 documented" % len(mp4s))
    else:
        omit("str_video", "video/*.mp4",
             "not present under the selected output root "
             "(registered-in-place class)")

# ---------------------------------------------------------------- validation
DOC_REF = re.compile(r'kit/(?:docs|work)/[A-Za-z0-9_./-]+')


#: The research corpus is RETIRED from the active tree: it lives under
#: `archive/docs/`, while the registry and the tools still cite it by its former
#: `kit/docs/` prefix.  Provenance therefore resolves against either location, so
#: retiring the corpus does not silently turn every citation into a dangling one.
_RETIRED_PREFIX = "kit/docs/"


def _provenance_resolves(tok):
    """True if a provenance token names a file, in the live tree or the archive."""
    if os.path.exists(os.path.join(_ROOT, tok)):
        return True
    if tok.startswith(_RETIRED_PREFIX):
        return os.path.exists(os.path.join(
            _ROOT, "archive", "docs", tok[len(_RETIRED_PREFIX):]))
    return False


def _doc_refs(blob):
    return sorted(set(DOC_REF.findall(blob)))


def _validate_dialogue(path, problems):
    d = _load_json(path)
    if d.get("schema") != DIALOGUE_SCHEMA:
        problems.append("dialogue.json schema is %r, expected %r"
                        % (d.get("schema"), DIALOGUE_SCHEMA))
    strings = d.get("strings") or []
    if d.get("string_count") != len(strings):
        problems.append("dialogue.json string_count %r != %d strings"
                        % (d.get("string_count"), len(strings)))
    seen = set()
    for r in strings:
        rid = r.get("id")
        want = "%s/%d/%d" % (r.get("overlay"), r.get("table", -1),
                             r.get("entry", -1))
        if rid != want:
            problems.append("dialogue id %r does not match overlay/table/entry %r"
                            % (rid, want))
        if rid in seen:
            problems.append("duplicate dialogue id %s" % rid)
        seen.add(rid)
        ov = r.get("overlays")
        if not isinstance(ov, list) or ov != [r.get("overlay")]:
            problems.append("dialogue %s: overlays %r must be exactly "
                            "[%r] (cross-overlay merging rejected)"
                            % (rid, ov, r.get("overlay")))
        for seg in r.get("segments") or []:
            for ln in seg.split("\n"):
                if OVERLAY_BANNER.match(ln):
                    problems.append("dialogue %s: overlay banner inside text"
                                    % rid)
    return len(strings)


def _validate_palettes(path, problems):
    d = _load_json(path)
    if d.get("schema") != "suikoden-palettes/1":
        problems.append("palettes.json schema is %r" % d.get("schema"))
    seen = set()
    for e in d.get("palettes") or []:
        pid = e.get("id")
        if pid in seen:
            problems.append("duplicate palette id %s" % pid)
        seen.add(pid)
        if len(e.get("rgb555") or []) != 256:
            problems.append("palette %s: %d rgb555 words != 256"
                            % (pid, len(e.get("rgb555") or [])))
        for c in e.get("rgb888") or []:
            if not (isinstance(c, list) and len(c) == 3
                    and all(isinstance(v, int) and 0 <= v <= 255 for v in c)):
                problems.append("palette %s: bad rgb888 triple %r" % (pid, c))
                break
        if len(e.get("rgb888") or []) != 256:
            problems.append("palette %s: %d rgb888 triples != 256"
                            % (pid, len(e.get("rgb888") or [])))
        if e.get("swatch_status") == "generated":
            if not os.path.isfile(os.path.join(OUT, e.get("swatch") or "")):
                problems.append("palette %s: swatch %r recorded but missing"
                                % (pid, e.get("swatch")))
        elif e.get("swatch_status") == "failed":
            problems.append("palette %s: optional swatch failed (%s)"
                            % (pid, e.get("swatch")))
    return len(seen)


def _validate_tables(path, problems):
    d = _load_json(path)
    if d.get("schema") != "suikoden-tables/1":
        problems.append("tables/provenance.json schema is %r" % d.get("schema"))
    for fn in d.get("files") or []:
        if not os.path.isfile(os.path.join(OUT, "tables", fn)):
            problems.append("tables/provenance.json: recorded file missing: %s"
                            % fn)
    for src in d.get("sources") or []:
        if not os.path.isfile(os.path.join(_ROOT, src.get("source", ""))):
            problems.append("tables provenance: source no longer exists: %s"
                            % src.get("source"))
    return len(d.get("files") or [])


def validate_manifest():
    problems = []
    for e in MANIFEST["assets"]:
        aid = e.get("id")
        if not aid:
            problems.append("asset without id")
        if e.get("class") not in ASSET_CLASSES:
            problems.append("%s: unknown asset class %r" % (aid, e.get("class")))
        p = e.get("provenance") or {}
        for key in ("decoder", "source", "status"):
            if not p.get(key):
                problems.append("%s: provenance missing %r" % (aid, key))
        files = e.get("files") or []
        if not files:
            problems.append("%s: no files recorded" % aid)
        if e.get("count") != len(files):
            problems.append("%s: count %r != %d files"
                            % (aid, e.get("count"), len(files)))
        pf = e.get("produced_files")
        if not isinstance(pf, list):
            problems.append("%s: produced_files missing" % aid)
        else:
            outside = [f for f in pf if f not in files]
            if outside:
                problems.append("%s: produced_files not covered by files: %s"
                                % (aid, outside[:3]))
        for rel in files:
            fp = os.path.join(OUT, rel)
            if not os.path.isfile(fp):
                problems.append("%s: recorded file missing: %s" % (aid, rel))
                continue
            want = (e.get("file_hashes") or {}).get(rel)
            if want != sha256_file(fp):
                problems.append("%s: sha256 mismatch for %s" % (aid, rel))
        for tok in _doc_refs(json.dumps(p)):
            if not _provenance_resolves(tok):
                problems.append("%s: dangling provenance reference %s"
                                % (aid, tok))
    if any(a["id"] == "dialogue" for a in MANIFEST["assets"]):
        _validate_dialogue(os.path.join(OUT, "text", "dialogue.json"), problems)
    if any(a["id"] == "palettes" for a in MANIFEST["assets"]):
        _validate_palettes(os.path.join(OUT, "palettes", "palettes.json"),
                           problems)
    if any(a["id"] == "data_tables" for a in MANIFEST["assets"]):
        _validate_tables(os.path.join(OUT, "tables", "provenance.json"),
                         problems)
    ids = [a["id"] for a in MANIFEST["assets"]]
    if len(set(ids)) != len(ids):
        problems.append("duplicate asset ids in manifest")
    MANIFEST["validation"] = {"ok": not problems, "problems": problems,
                             "assets_checked": len(MANIFEST["assets"])}
    for pr in problems:
        err("validation", pr)
    return problems

# ---------------------------------------------------------------------- main
# --skip class names (also the manifest top-level "subset" vocabulary)
CLASSES = ["dialogue", "music", "palettes", "geometry", "recipes",
           "tables", "scripts", "textures", "extras"]

# per-asset `class` values recorded inside manifest["assets"] (a different
# namespace from the --skip list above)
ASSET_CLASSES = {"text", "audio", "video", "palette", "geometry",
                 "sprite-recipe", "table", "script", "texture"}

# module requirements per class; checked BEFORE any output is written
CLASS_DEPS = {
    "palettes": ["text_lzss"],   # PIL is only needed for optional swatches
    "recipes": ["parse_04play"],
    "textures": ["PIL", "numpy", "stone_render"],
}

USAGE = """export_assets.py -- regenerate the canonical asset package manifest.

Usage:
    python3 export_assets.py [--out DIR] [--skip CLASS,...] [--no-swatches]

Options:
    --out DIR        write the tree + manifest to DIR (default: kit/work/build/package)
    --skip A,B       skip asset classes: %s
    --no-swatches    export palette VALUES only (PNG swatches are optional)
    -h, --help       show this help and exit

Both "--out DIR" and "--out=DIR" forms are accepted. An unrecognised
argument is a hard error: this tool writes a whole staging tree, so it must
never silently fall back to the default location.

Zero recorded errors -> exit 0 and <out>/manifest.json.
Any recorded error   -> exit 1 and <out>/manifest.failed.json (the accepted
manifest.json is left untouched).
""" % ", ".join(CLASSES)


def parse_args(argv):
    """Parse argv. Returns (out_dir_or_None, skip_set) or raises SystemExit."""
    global WANT_SWATCHES
    if "-h" in argv or "--help" in argv:
        print(USAGE)
        raise SystemExit(0)
    skip = set()
    out = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--skip="):
            skip.update(x for x in a.split("=", 1)[1].split(",") if x)
        elif a == "--skip":
            i += 1
            if i >= len(argv):
                raise SystemExit("ERROR: --skip needs a value")
            skip.update(x for x in argv[i].split(",") if x)
        elif a.startswith("--out="):
            out = a.split("=", 1)[1]
        elif a == "--out":
            i += 1
            if i >= len(argv):
                raise SystemExit("ERROR: --out needs a value")
            out = argv[i]
        elif a == "--no-swatches":
            WANT_SWATCHES = False
        else:
            raise SystemExit("ERROR: unrecognised argument %r\n\n%s" % (a, USAGE))
        i += 1
    unknown = skip - set(CLASSES)
    if unknown:
        raise SystemExit("ERROR: unknown --skip class(es): %s\nknown: %s"
                         % (", ".join(sorted(unknown)), ", ".join(CLASSES)))
    return out, skip


def preflight(skip):
    """Dependencies and required inputs, checked before any output is written."""
    for cls in CLASSES:
        if cls in skip:
            continue
        for mod in CLASS_DEPS.get(cls, []):
            try:
                importlib.import_module(mod)
            except Exception as ex:
                err("preflight", "%s requires module %r: %s" % (cls, mod, ex))
    if WANT_SWATCHES and "palettes" not in skip:
        try:
            importlib.import_module("PIL")
        except Exception as ex:
            err("preflight", "palettes swatches require module 'PIL': %s "
                             "(use --no-swatches for values-only export)" % ex)
    if "dialogue" not in skip and not os.path.exists(DIALOGUE_SRC):
        err("preflight", "dialogue input missing: %s" % _rel_out(DIALOGUE_SRC))
    if "scripts" not in skip and not os.path.isdir(SCRIPT_SRC):
        err("preflight", "script corpus missing: %s" % _rel_out(SCRIPT_SRC))
    if "tables" not in skip:
        for root, rel, _note in table_sources():
            if not os.path.exists(os.path.join(root, rel)):
                err("preflight", "tables input missing: %s"
                    % _rel_out(os.path.join(root, rel)))
    if "palettes" not in skip:
        for p in palette_inputs():
            if not os.path.exists(p):
                err("preflight", "palettes input missing: %s" % _rel_out(p))
    if "recipes" not in skip and not os.path.isdir(PLAY04_DIR):
        err("preflight", "recipes input missing: %s" % _rel_out(PLAY04_DIR))
    if "textures" not in skip and not os.path.exists(STONE_BIN):
        err("preflight", "textures input missing: %s" % _rel_out(STONE_BIN))


def main(argv=None):
    global OUT, WANT_SWATCHES
    WANT_SWATCHES = True
    out, skip = parse_args(sys.argv[1:] if argv is None else argv)
    if out:
        OUT = os.path.abspath(out)
    os.makedirs(OUT, exist_ok=True)
    # Reset per run: MANIFEST/PRODUCED are module-global and add_asset()
    # appends to them, so a second main() would otherwise double-count and
    # mis-report.
    PRODUCED.clear()
    MANIFEST["assets"] = []
    MANIFEST["errors"] = []
    MANIFEST["omissions"] = []
    MANIFEST["validation"] = None
    MANIFEST["out_root"] = _rel_out(OUT)
    MANIFEST["subset"] = {"built": [c for c in CLASSES if c not in skip],
                          "skipped": sorted(skip),
                          "swatches": WANT_SWATCHES}

    preflight(skip)
    if not MANIFEST["errors"]:
        if "dialogue" not in skip: export_dialogue()
        if "music" not in skip: export_music()
        if "palettes" not in skip: export_palettes()
        if "geometry" not in skip: export_geometry()
        if "recipes" not in skip: export_recipes()
        if "tables" not in skip: export_tables()
        if "scripts" not in skip: export_scripts()
        if "textures" not in skip: export_textures()
        if "extras" not in skip: export_extras()

    MANIFEST["generated_utc"] = datetime.datetime.now(
        datetime.timezone.utc).isoformat()
    if not MANIFEST["errors"]:
        validate_manifest()

    failed = bool(MANIFEST["errors"])
    name = "manifest.failed.json" if failed else "manifest.json"
    mpath = os.path.join(OUT, name)
    with open(mpath, "w") as f:
        json.dump(MANIFEST, f, indent=1)

    print("assets: %d  errors: %d  omissions: %d"
          % (len(MANIFEST["assets"]), len(MANIFEST["errors"]),
             len(MANIFEST["omissions"])))
    for a in MANIFEST["assets"]:
        print("  %-16s %-12s %s (n=%s)" % (a["id"], a["class"], a["path"],
                                           a.get("count")))
    for o in MANIFEST["omissions"]:
        print("  OMIT  [%s] %s" % (o["class"], o["what"]))
    for e in MANIFEST["errors"]:
        print("  ERROR [%s] %s" % (e["class"], e["error"]))
    if failed:
        print("FAILED: %d recorded error(s); wrote %s (manifest.json not "
              "replaced)" % (len(MANIFEST["errors"]), name), file=sys.stderr)
        return 1
    print("OK: wrote %s" % name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
