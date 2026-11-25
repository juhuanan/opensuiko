#!/usr/bin/env python3
"""bootstrap_sources.py -- rebuild the disc-derived source tree from the disc alone.

Why this exists
---------------
~20 active tools and kit/tools/rebuild_assets.sh read the raw overlay bytes in
``kit/extracted/bin_overlays/DATA/**`` (344 files, 41,450,011 bytes). Those bytes
are disc-derived and per AGENTS.md §7 must NOT be tracked, so the pipeline is not
actually reproducible from a clean checkout. The full path->LBA->size map *is*
tracked, though: ``kit/extracted/iso_files.json`` (ISO9660 listing) and
``kit/extracted/overlay_lba_table.json`` (the game's 344-entry static overlay
registry). This tool re-extracts the files straight off the disc using those
tracked tables, so ``kit/extracted/bin_overlays/`` is a derived cache rather than
a prerequisite.

Nothing here opens the disc image directly: every read goes through
``tools/disc.py`` (``disc.extract``), which validates container geometry and
honours $SUIKODEN_DISC / --disc.

Sets
----
``04_PLAY``  the 78 DATA/04_PLAY/*.BIN files (the LZSS corpus the codec gate and
             the play renderers use).
``DATA``     the 344 files in the static overlay registry (overlay_lba_table.json
             ``static_table.entries``) -- i.e. the DATA/** tree the active tools
             and rebuild_assets.sh actually read.

Sets may be repeated: ``--set 04_PLAY --set DATA``. Default is ``04_PLAY``.

Output layout and manifest
--------------------------
Files are written under ``--out`` at their ISO-relative path, e.g.
``<out>/DATA/04_PLAY/AIL.BIN``. A manifest is written to
``<out>/bootstrap_manifest.json`` recording, per file: ``path``, ``lba``,
``size``, ``sha256`` (plus the set it came from), and the metadata files used
with their own sha256. The manifest contains no timestamps or absolute paths, so
re-running the same command over the same metadata produces a byte-identical
manifest.

Idempotency (chosen: idempotent, not refused)
---------------------------------------------
Re-running into the same output directory is supported and cheap: for every
entry, if the target already exists with the expected size and its sha256
matches the manifest, extraction from the disc is skipped; otherwise the file is
re-extracted and replaced atomically (temp file + os.replace). The manifest is
rewritten identically either way. A corrupt/short output is therefore repaired
rather than trusted.

Validation
----------
Every metadata record must agree across the two tracked tables (same path ->
same LBA and same size); a disagreement, a missing cross-reference, a
``iso_size_match: false`` entry, or a duplicate path raises MetadataError. Each
extracted file's length is verified against the metadata length and a mismatch
raises BootstrapError. Output paths are validated as relative (no absolute
paths, no ``..``).

Usage
-----
    .venv/bin/python kit/tools/bootstrap_sources.py --set 04_PLAY \
        --out kit/work/candidates/20261004/ws_a/bootstrap_04play
    .venv/bin/python kit/tools/bootstrap_sources.py --set DATA --out /tmp/sources
    .venv/bin/python kit/tools/bootstrap_sources.py --set 04_PLAY --list

Exit codes: 0 success, 1 any error (metadata, geometry, short read, size).
"""

import argparse
import hashlib
import json
import os
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_DIR = os.path.dirname(TOOLS_DIR)
PROJECT_ROOT = os.path.dirname(KIT_DIR)

sys.path.insert(0, TOOLS_DIR)

import disc  # noqa: E402
from disc import DiscNotFound, ShortReadError  # noqa: E402

DEFAULT_ISO_FILES = os.path.join(KIT_DIR, "extracted", "iso_files.json")
DEFAULT_OVERLAY_TABLE = os.path.join(KIT_DIR, "extracted", "overlay_lba_table.json")
EXTRACTED_DIR = os.path.join(KIT_DIR, "extracted")

SET_04_PLAY = "04_PLAY"
SET_DATA = "DATA"
SETS = (SET_04_PLAY, SET_DATA)

MANIFEST_NAME = "bootstrap_manifest.json"
TOOL_VERSION = 1
READ_CHUNK = 1 << 20


class MetadataError(RuntimeError):
    """The tracked LBA metadata is missing, malformed or self-inconsistent."""


class BootstrapError(RuntimeError):
    """An extracted file did not match the tracked metadata."""


def _sha256_file(path, chunk=READ_CHUNK):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _load_json(path):
    if not os.path.isfile(path):
        raise MetadataError("metadata file not found: %s" % path)
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as ex:
        raise MetadataError("cannot read metadata %s: %s" % (path, ex))


def _require(cond, msg):
    if not cond:
        raise MetadataError(msg)


def load_catalog(iso_files_path=DEFAULT_ISO_FILES,
                 overlay_path=DEFAULT_OVERLAY_TABLE):
    """Return (catalog, overlay_paths).

    catalog: {path: {"lba": int, "size": int}} for every non-directory file in
    the ISO9660 listing, cross-validated against the overlay registry.
    overlay_paths: ordered list of the registry's paths (the DATA set).
    """
    iso = _load_json(iso_files_path)
    _require(isinstance(iso, list), "iso_files.json must be a list")
    catalog = {}
    for i, rec in enumerate(iso):
        _require(isinstance(rec, dict), "iso_files[%d] is not an object" % i)
        for key in ("path", "lba", "size", "dir"):
            _require(key in rec, "iso_files[%d] missing %r" % (i, key))
        if rec["dir"]:
            continue
        p = rec["path"]
        _require(isinstance(p, str) and p and not p.startswith("/"),
                 "iso_files[%d] has an unusable path %r" % (i, p))
        _require(p not in catalog, "duplicate path %r in iso_files.json" % p)
        _require(isinstance(rec["lba"], int) and rec["lba"] >= 0,
                 "%s: bad lba %r" % (p, rec["lba"]))
        _require(isinstance(rec["size"], int) and rec["size"] > 0,
                 "%s: bad size %r" % (p, rec["size"]))
        catalog[p] = {"lba": rec["lba"], "size": rec["size"]}

    overlay = _load_json(overlay_path)
    _require(isinstance(overlay, dict) and "static_table" in overlay,
             "overlay_lba_table.json has no static_table")
    table = overlay["static_table"]
    _require(isinstance(table, dict) and isinstance(table.get("entries"), list),
             "overlay_lba_table.json static_table has no entries list")
    overlay_paths = []
    for e in table["entries"]:
        _require(isinstance(e, dict), "static_table entry is not an object")
        p = e.get("path")
        _require(isinstance(p, str) and p, "static_table entry without a path")
        _require(e.get("iso_size_match") is not False,
                 "%s: overlay registry says iso_size_match=false" % p)
        _require(p in catalog,
                 "%s: overlay registry entry has no iso_files.json record" % p)
        if (e.get("lba") != catalog[p]["lba"] or e.get("size") != catalog[p]["size"]):
            raise MetadataError(
                "%s: overlay registry disagrees with iso_files.json "
                "(lba %r/%r, size %r/%r)"
                % (p, e.get("lba"), catalog[p]["lba"],
                   e.get("size"), catalog[p]["size"]))
        if p not in overlay_paths:
            overlay_paths.append(p)
    return catalog, overlay_paths


def select_entries(catalog, overlay_paths, sets):
    """Return sorted [(path, lba, size, set_name)] for the requested sets."""
    chosen = {}
    for name in sets:
        if name == SET_04_PLAY:
            pref = "DATA/04_PLAY/"
            paths = [p for p in catalog if p.startswith(pref)]
        elif name == SET_DATA:
            paths = list(overlay_paths)
        else:
            raise MetadataError("unknown set %r" % name)
        for p in paths:
            chosen.setdefault(p, name)
    return [(p, catalog[p]["lba"], catalog[p]["size"], chosen[p])
            for p in sorted(chosen)]


def _safe_target(out_dir, rel_path):
    """Join a metadata path under out_dir, refusing escapes and absolute paths."""
    if os.path.isabs(rel_path) or "\\" in rel_path or "\x00" in rel_path:
        raise MetadataError("unsafe output path %r" % rel_path)
    parts = [x for x in rel_path.split("/") if x]
    if not parts or any(x in (".", "..") for x in parts):
        raise MetadataError("unsafe output path %r" % rel_path)
    target = os.path.join(out_dir, *parts)
    root = os.path.abspath(out_dir) + os.sep
    if not os.path.abspath(target).startswith(root):
        raise MetadataError("output path escapes --out: %r" % rel_path)
    return target


def _refuse_extracted(out_dir):
    """Never write into kit/extracted (the orchestrator-owned tracked tree)."""
    ap = os.path.abspath(out_dir)
    if ap == os.path.abspath(EXTRACTED_DIR) or ap.startswith(
            os.path.abspath(EXTRACTED_DIR) + os.sep):
        raise BootstrapError(
            "--out must not be kit/extracted (or a subdirectory): that tree is "
            "tracked, and this tool exists to stop depending on it. Choose a "
            "fresh directory such as kit/work/candidates/<date>/bootstrap.")


def _disc_identity(disc_path):
    img, sector, off = disc.resolve(disc_path)
    return {
        "container": "bin-mode2-2352" if sector == 2352 else "iso9660",
        "basename": os.path.basename(img),
        "sector_size": sector,
        "payload_offset": off,
        "size": os.path.getsize(img),
    }


def _load_previous_manifest(out_dir):
    p = os.path.join(out_dir, MANIFEST_NAME)
    if not os.path.isfile(p):
        return {}
    try:
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return {}
    return {e["path"]: e for e in doc.get("files", []) if "path" in e}


def bootstrap(out_dir, sets, disc_path=None, iso_files_path=DEFAULT_ISO_FILES,
              overlay_path=DEFAULT_OVERLAY_TABLE, log=print):
    """Extract the selected metadata entries into out_dir. Returns the manifest."""
    _refuse_extracted(out_dir)
    catalog, overlay_paths = load_catalog(iso_files_path, overlay_path)
    entries = select_entries(catalog, overlay_paths, sets)
    if not entries:
        raise BootstrapError("no files selected for sets %r" % (sets,))

    identity = _disc_identity(disc_path)
    os.makedirs(out_dir, exist_ok=True)
    previous = _load_previous_manifest(out_dir)

    files = []
    extracted = skipped = 0
    for n, (rel_path, lba, size, set_name) in enumerate(entries, 1):
        target = _safe_target(out_dir, rel_path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        want = previous.get(rel_path)

        if os.path.isfile(target) and os.path.getsize(target) == size:
            if want and want.get("size") == size and want.get("lba") == lba:
                if _sha256_file(target) == want.get("sha256"):
                    files.append({"path": rel_path, "lba": lba, "size": size,
                                  "sha256": want["sha256"], "set": set_name})
                    skipped += 1
                    continue

        try:
            data = disc.extract(lba, size, disc_path)
        except (DiscNotFound, ShortReadError) as ex:
            raise BootstrapError("%s (LBA %d, %d bytes): %s"
                                 % (rel_path, lba, size, ex))
        if len(data) != size:
            raise BootstrapError(
                "%s: extracted %d bytes but metadata says %d"
                % (rel_path, len(data), size))

        tmp = target + ".bootstrap_tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, target)

        files.append({"path": rel_path, "lba": lba, "size": size,
                      "sha256": hashlib.sha256(data).hexdigest(),
                      "set": set_name})
        extracted += 1
        if n % 50 == 0 or n == len(entries):
            log("  %d/%d %s" % (n, len(entries), rel_path))

    manifest = {
        "tool": os.path.basename(__file__),
        "tool_version": TOOL_VERSION,
        "sets": list(sets),
        "disc": identity,
        "metadata": [
            {"path": _repo_rel(iso_files_path),
             "sha256": _sha256_file(iso_files_path)},
            {"path": _repo_rel(overlay_path),
             "sha256": _sha256_file(overlay_path)},
        ],
        "file_count": len(files),
        "total_bytes": sum(f["size"] for f in files),
        "files": files,
    }
    with open(os.path.join(out_dir, MANIFEST_NAME), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, sort_keys=True)
        f.write("\n")
    manifest["_extracted"] = extracted
    manifest["_skipped"] = skipped
    return manifest


def _repo_rel(path):
    ap = os.path.abspath(path)
    return os.path.relpath(ap, PROJECT_ROOT)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Re-extract the tracked-metadata disc sources from the disc")
    ap.add_argument("--out", default=None,
                    help="output directory (required unless --list); must not be "
                         "kit/extracted")
    ap.add_argument("--set", dest="sets", action="append", choices=SETS,
                    help="source set to extract (repeatable; default 04_PLAY)")
    ap.add_argument("--disc", default=None, help="explicit .bin/.iso image path")
    ap.add_argument("--iso-files", default=DEFAULT_ISO_FILES,
                    help="ISO9660 listing JSON (default: %(default)s)")
    ap.add_argument("--overlay-table", default=DEFAULT_OVERLAY_TABLE,
                    help="overlay LBA registry JSON (default: %(default)s)")
    ap.add_argument("--list", action="store_true",
                    help="list the selection and exit without writing anything")
    args = ap.parse_args(argv)

    sets = args.sets or [SET_04_PLAY]
    try:
        catalog, overlay_paths = load_catalog(args.iso_files, args.overlay_table)
        entries = select_entries(catalog, overlay_paths, sets)
    except MetadataError as ex:
        print("METADATA ERROR: %s" % ex, file=sys.stderr)
        return 1

    if args.list:
        per_set = {}
        for _p, _lba, size, name in entries:
            c, b = per_set.get(name, (0, 0))
            per_set[name] = (c + 1, b + size)
        for name in sets:
            c, b = per_set.get(name, (0, 0))
            print("set %-8s %3d files, %d bytes" % (name, c, b))
        print("total    %3d files, %d bytes" % (
            len(entries), sum(e[2] for e in entries)))
        return 0

    if not args.out:
        ap.error("--out is required (it is never defaulted, and never "
                 "kit/extracted)")

    try:
        manifest = bootstrap(args.out, sets, args.disc, args.iso_files,
                             args.overlay_table)
    except (BootstrapError, MetadataError, DiscNotFound, ShortReadError) as ex:
        print("ERROR: %s" % ex, file=sys.stderr)
        return 1
    print("bootstrap: %d files (%d bytes) -> %s"
          % (manifest["file_count"], manifest["total_bytes"], args.out))
    print("  extracted %d, reused %d, manifest %s"
          % (manifest["_extracted"], manifest["_skipped"],
             os.path.join(args.out, MANIFEST_NAME)))
    for name in manifest["sets"]:
        c = sum(1 for f in manifest["files"] if f["set"] == name)
        print("  set %-8s %d files" % (name, c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
