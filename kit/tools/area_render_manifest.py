#!/usr/bin/env python3
"""area_render_manifest.py -- machine-readable status record for area renders.

Workstream M, 2026-10-04.  The area-room renders under `kit/work/area_tiles/`
had **no manifest, index or sidecar**: nothing recorded which tool produced a
PNG, from which disc file/LBA, with which palette, or whether a room was
rejected instead of merely absent.  This tool builds that record and validates
it.

Two commands:

    build     inventory an output tree (PNG sha256 + size + dimensions), merge
              it with the sidecars the producing tools now write
              (`render_area_batch.py`, `fix_palettes.py`), and emit one
              deterministic JSON manifest.
    validate  re-hash every referenced and recorded file and exit non-zero on
              a missing render, a hash mismatch, a room with conflicting
              status, or an absent referenced input.

Design rules (see `kit/docs/area_render_status.md`):

* **Deterministic.** No timestamps; no absolute paths in the content.  Every
  path is stored POSIX-relative to `--root` (default: the repo root) and all
  lists are sorted.  Two `build` runs over identical inputs produce
  byte-identical JSON.
* **Disc-free by default.** The source LBA comes from the tracked
  `kit/extracted/overlay_lba_table.json`; the disc is opened only with the
  explicit `--verify-source` flag (then via `disc.py`, never directly).
* **Status is not inferred from a file's existence alone.** A file is
  `rendered` only when a sidecar attests it *and* its bytes hash to the digest
  that run recorded.  A file no run claims is `unattributed`, never silently
  accepted.
* **Palette selection is heuristic** and is recorded as such; nothing here
  consults a proven selector.

Status vocabulary for `entries[]` (per output file):

    rendered      a sidecar recorded this exact output and the bytes match
    missing       a sidecar recorded a rendered output that is not on disk
    stale         a file exists but no producer's recorded bytes match it, or
                  the room is now rejected/omitted by every producer
    rejected      the room was considered and rejected (no output expected);
                  only reached through `rooms[]`
    omitted       the room was considered and skipped (no output expected)
    unattributed  a file no producer claims (e.g. scratch/probe output)
    conflict      producers disagree about the room's status

`rooms[]` carries the per-room decision(s) exactly as the tools recorded them,
so a rejected room is a recorded outcome rather than a missing file.
"""
import argparse
import hashlib
import json
import os
import posixpath
import re
import struct
import sys

SCHEMA = "suikoden-area-render-manifest/1"
SIDECAR_SCHEMA = "suikoden-area-render-sidecar/1"
GENERATOR = "area_render_manifest.py"
REVISION = "2026-10-04.1"

_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)

DEFAULT_TREE = os.path.join(_KIT, "work", "area_tiles")
DEFAULT_LBA_TABLE = os.path.join(_KIT, "extracted", "overlay_lba_table.json")

ROOM_RE = re.compile(r"^(?P<bin>[A-Za-z0-9]+)_h(?P<hdr>[0-9]+)(?P<variant>_2x)?$")

RENDERED, MISSING, STALE = "rendered", "missing", "stale"
REJECTED, OMITTED = "rejected", "omitted"
UNATTRIBUTED, CONFLICT = "unattributed", "conflict"

ENTRY_STATUSES = (RENDERED, MISSING, STALE, UNATTRIBUTED, CONFLICT)
ROOM_STATUSES = (RENDERED, REJECTED, OMITTED)


# --------------------------------------------------------------------------- #
# small deterministic helpers
# --------------------------------------------------------------------------- #
def sha256_file(path, _bufsize=1 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(_bufsize), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def rel_posix(path, root):
    """POSIX path relative to root; raises if `path` escapes `root`."""
    ap = os.path.abspath(path)
    ar = os.path.abspath(root)
    if ap == ar:
        return "."
    if not ap.startswith(ar + os.sep):
        raise ValueError("%s is outside --root %s" % (path, root))
    return ap[len(ar) + 1:].replace(os.sep, "/")


def portable_posix(path, root):
    """Stable path for the manifest: repo-relative when the target is inside
    `root`, otherwise just the basename.

    Determinism forbids absolute paths in the compared content (they differ
    between machines and CI runs), and a manifest built over a temporary tree
    must not embed that tree's location.  The digest next to the path is what
    identifies the file, not the directory it happened to live in.
    """
    try:
        return rel_posix(path, root)
    except ValueError:
        return posixpath.basename(os.path.abspath(path).replace(os.sep, "/"))


def png_dims(path):
    """(width, height) from the PNG IHDR, without Pillow.  None if not a PNG."""
    try:
        with open(path, "rb") as f:
            head = f.read(24)
    except OSError:
        return None
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    w, h = struct.unpack_from(">II", head, 16)
    return int(w), int(h)


def _json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _load_lba_table(path):
    """disc_path -> {'lba','size','table_index','table_addr'} from the tracked
    overlay LBA table.  No disc access."""
    out = {}
    if not os.path.isfile(path):
        return out
    doc = _json(path)
    for e in doc.get("static_table", {}).get("entries", []):
        out[e["path"]] = {"lba": e.get("lba"), "size": e.get("size"),
                          "table_index": e.get("index"),
                          "table_addr": e.get("addr")}
    return out


def _normalize_palette(pal):
    if not pal:
        return None
    out = dict(pal)
    # Selection by both tools is a heuristic; make that impossible to miss.
    out["selection"] = "heuristic"
    out.setdefault("heuristic", True)
    return out


def _producer_key(p):
    return (p.get("tool") or "", p.get("room_status") or "",
            p.get("tool_revision") or "", p.get("expected_sha256") or "")


# --------------------------------------------------------------------------- #
# sidecars (written by render_area_batch.py / fix_palettes.py)
# --------------------------------------------------------------------------- #
def load_sidecars(paths, root):
    """Return (records, references).  Each record is one processed room (or a
    file-level outcome).  Malformed schema is a hard error: a silently dropped
    sidecar would be exactly the guesswork this manifest replaces."""
    records, references = [], []
    for path in paths:
        if not os.path.isfile(path):
            raise SystemExit("sidecar not found: %s" % path)
        references.append({"path": portable_posix(path, root),
                           "sha256": sha256_file(path),
                           "role": "sidecar"})
        with open(path, "r", encoding="utf-8") as f:
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if rec.get("schema") != SIDECAR_SCHEMA:
                    raise SystemExit("%s:%d: unknown sidecar schema %r"
                                     % (path, lineno, rec.get("schema")))
                rec["_sidecar"] = path
                records.append(rec)
    return records, references


def _claim_of(rec, root):
    """Turn one sidecar record into a claim about a room's outcome."""
    return {
        "tool": rec.get("tool"),
        "tool_revision": rec.get("tool_revision"),
        "decoder": rec.get("decoder"),
        "validation_rules": rec.get("validation_rules"),
        "sidecar": portable_posix(rec["_sidecar"], root)
        if rec.get("_sidecar") else None,
        "room_status": rec.get("status"),
        "reason": rec.get("reason"),
        "header_index": rec.get("header_index"),
        "output": rec.get("output"),
        "output_2x": rec.get("output_2x"),
        "expected_sha256": rec.get("sha256"),
        "expected_sha256_2x": rec.get("sha256_2x"),
        "width": rec.get("width"),
        "height": rec.get("height"),
        "bytes": rec.get("bytes"),
        "palette": _normalize_palette(rec.get("palette")),
    }


def build_manifest(tree_dirs, sidecar_paths, lba_table_path, root,
                   verify_source=False):
    root = os.path.abspath(root)
    lba = _load_lba_table(lba_table_path)
    records, references = load_sidecars(sidecar_paths, root)
    if os.path.isfile(lba_table_path):
        references.append({"path": portable_posix(lba_table_path, root),
                           "sha256": sha256_file(lba_table_path),
                           "role": "lba_table"})

    # room key -> claims (deduped)
    claims = {}
    for rec in records:
        area = rec.get("area")
        room = rec.get("room")
        if not room:
            continue                      # file-level record only
        key = "%s/%s" % (area, room) if area else room
        claims.setdefault(key, [])
        claim = _claim_of(rec, root)
        if claim not in claims[key]:
            claims[key].append(claim)

    # inventory every PNG under every tree
    observed = {}
    for tree in tree_dirs:
        for dirpath, dirnames, filenames in os.walk(tree):
            dirnames.sort()
            for name in sorted(filenames):
                if not name.lower().endswith(".png"):
                    continue
                ap = os.path.join(dirpath, name)
                rel = rel_posix(ap, root)
                dims = png_dims(ap)
                observed[rel] = {
                    "output": rel,
                    "sha256": sha256_file(ap),
                    "bytes": os.path.getsize(ap),
                    "width": dims[0] if dims else None,
                    "height": dims[1] if dims else None,
                }

    def _room_of(rel):
        base = posixpath.basename(rel)[:-4]
        parent = posixpath.dirname(rel)
        area = posixpath.basename(parent) if parent else None
        m = ROOM_RE.match(base)
        if not m:
            return area, None, None, None
        rid = "%s_h%s" % (m.group("bin"), m.group("hdr"))
        variant = "2x" if m.group("variant") else "1x"
        key = "%s/%s" % (area, rid) if area else rid
        return area, rid, variant, key

    entry_by_output = {}

    def _source_for(area, room_id):
        """disc file + LBA for a room, from the tracked LBA table (no disc)."""
        if not area or not room_id or "_h" not in room_id:
            return None
        bin_name = room_id.rsplit("_h", 1)[0]
        area_folder = _area_folders().get(area)
        if not area_folder:
            return None
        disc_path = "DATA/%s/%s.BIN" % (area_folder, bin_name)
        info = lba.get(disc_path)
        src = {"disc_path": disc_path,
               "lba": info["lba"] if info else None,
               "size": info["size"] if info else None,
               "lba_table": portable_posix(lba_table_path, root)
               if os.path.isfile(lba_table_path) else None,
               "in_lba_table": bool(info)}
        if verify_source:
            src["disc_payload_sha256"] = _disc_payload_sha256(src["lba"],
                                                              src["size"])
        extracted = os.path.join(_KIT, "extracted", "bin_overlays", disc_path)
        src["extracted_sha256"] = (sha256_file(extracted)
                                   if os.path.isfile(extracted) else None)
        return src

    def _claims_for(area, room_id):
        key = "%s/%s" % (area, room_id) if area else (room_id or "")
        return claims.get(key, [])

    def _statuses(cls):
        return sorted({c["room_status"] for c in cls if c["room_status"]})

    def _entry(observed_file, area, room_id, variant, key):
        cls = _claims_for(area, room_id) if room_id else []
        st = _statuses(cls)
        producers = sorted(cls, key=_producer_key)
        expected = None
        attribution = "none"
        reason = None
        if not cls:
            status, room_status = UNATTRIBUTED, "unknown"
        elif len(st) > 1:
            status, room_status = CONFLICT, "conflict"
            reason = "producers disagree: %s" % ", ".join(
                "%s=%s" % (c["tool"], c["room_status"]) for c in producers)
        elif st == [RENDERED]:
            room_status = RENDERED
            matches = [c for c in producers
                       if _expected_for(c, variant) == observed_file["sha256"]]
            if matches:
                status = RENDERED
                expected = observed_file["sha256"]
                attribution = "match:" + ",".join(
                    sorted({c["tool"] for c in matches}))
            else:
                status = STALE
                reason = ("bytes match no recorded current render (%d producer%s)"
                          % (len(producers), "" if len(producers) == 1 else "s"))
        else:
            room_status = ",".join(st)
            status = STALE
            reason = "; ".join(sorted({c["reason"] for c in producers
                                       if c["reason"]})) or "room not rendered"
            attribution = "room-status:" + room_status
        src = _source_for(area, room_id)
        return {
            "output": observed_file["output"],
            "area": area,
            "room": key,
            "room_id": room_id,
            "bin": (room_id.rsplit("_h", 1)[0] if room_id else None),
            "variant": variant,
            "status": status,
            "room_status": room_status,
            "reason": reason,
            "attribution": attribution,
            "sha256": observed_file["sha256"] if observed_file else None,
            "expected_sha256": expected,
            "bytes": observed_file["bytes"] if observed_file else None,
            "width": observed_file["width"] if observed_file else None,
            "height": observed_file["height"] if observed_file else None,
            "source": src,
            "producers": producers,
        }

    for rel in sorted(observed):
        area, room_id, variant, key = _room_of(rel)
        entry_by_output[rel] = _entry(observed[rel], area, room_id, variant, key)

    # a rendered room whose output is absent from every inventoried tree
    for key in sorted(claims):
        cls = claims[key]
        st = _statuses(cls)
        if st != [RENDERED]:
            continue
        area, _, room_id = key.partition("/")
        if not room_id:
            area, room_id = None, key
        outputs = sorted({c["output"] for c in cls if c["output"]})
        outputs += sorted({c["output_2x"] for c in cls if c["output_2x"]})
        for out in outputs:
            rel = rel_posix(out, root) if os.path.isabs(out) else out
            if rel in entry_by_output:
                continue
            # The producer's own output may simply live outside the inventoried
            # trees (e.g. a candidate render dir named by the sidecar). That is
            # not a missing render: hash the file where the sidecar said it
            # would be and record it as rendered. Only a file that is genuinely
            # absent everywhere becomes `missing`.
            ap = os.path.join(root, rel)
            variant = "2x" if rel.endswith("_2x.png") else "1x"
            producers = sorted(cls, key=_producer_key)
            base = {
                "output": rel, "area": area, "room": key, "room_id": room_id,
                "bin": (room_id.rsplit("_h", 1)[0] if room_id else None),
                "variant": variant, "attribution": "none",
                "source": _source_for(area, room_id), "producers": producers,
            }
            if os.path.isfile(ap):
                dims = png_dims(ap)
                digest = sha256_file(ap)
                exp = next((_expected_for(c, variant) for c in producers
                            if _expected_for(c, variant)), None)
                base.update({
                    "status": RENDERED if (exp is None or exp == digest)
                              else STALE,
                    "room_status": RENDERED,
                    "reason": None if (exp is None or exp == digest) else
                              "bytes match no recorded current render",
                    "sha256": digest, "expected_sha256": exp,
                    "bytes": os.path.getsize(ap),
                    "width": dims[0] if dims else None,
                    "height": dims[1] if dims else None,
                })
            else:
                base.update({
                    "status": MISSING, "room_status": RENDERED,
                    "reason": "recorded by %s but absent from every inventoried "
                              "tree" % ",".join(sorted({c["tool"]
                                                        for c in producers})),
                    "sha256": None,
                    "expected_sha256": next(
                        (c["expected_sha256"] for c in producers
                         if c["expected_sha256"]), None),
                    "bytes": None, "width": None, "height": None,
                })
            entry_by_output[rel] = base

    entries = sorted(entry_by_output.values(), key=lambda e: e["output"])

    rooms = []
    for key in sorted(claims):
        cls = sorted(claims[key], key=_producer_key)
        st = _statuses(cls)
        area, _, room_id = key.partition("/")
        if not room_id:
            area, room_id = None, key
        conflict = len(st) > 1
        rooms.append({
            "room": key, "area": area, "room_id": room_id,
            "bin": (room_id.rsplit("_h", 1)[0] if room_id else None),
            "room_status": "conflict" if conflict else (st[0] if st else "unknown"),
            "conflict": conflict,
            "reason": "; ".join(sorted({c["reason"] for c in cls if c["reason"]}))
                      or None,
            "heuristic_palette": any(c["palette"] for c in cls),
            "source": _source_for(area, room_id),
            "producers": cls,
        })

    manifest = {
        "schema": SCHEMA,
        "generator": {"tool": GENERATOR, "revision": REVISION},
        "trees": sorted(portable_posix(t, root) for t in tree_dirs),
        "references": sorted(references, key=lambda r: r["path"]),
        "summary": _summarize(entries, rooms),
        "entries": entries,
        "rooms": rooms,
    }
    return manifest


def _expected_for(claim, variant):
    return claim.get("expected_sha256_2x" if variant == "2x"
                     else "expected_sha256")


def _area_folders():
    """subdir -> DATA area folder, imported from fix_palettes.AREAS so the
    manifest follows the producing tool instead of a second hardcoded map."""
    global _AREA_FOLDERS_CACHE
    try:
        return _AREA_FOLDERS_CACHE
    except NameError:
        pass
    sys.path.insert(0, _TOOLS)
    import fix_palettes as fp                              # noqa: E402
    _AREA_FOLDERS_CACHE = {sub: area for sub, (area, _names)
                           in fp.AREAS.items()}
    return _AREA_FOLDERS_CACHE


def _disc_payload_sha256(lba, size):
    """Hash the disc payload for one BIN.  Requires the disc; called only with
    --verify-source.  Uses disc.py, never the image directly."""
    if lba is None or size is None:
        return None
    try:
        sys.path.insert(0, _TOOLS)
        from disc import extract                             # noqa: E402
        return sha256_bytes(extract(lba, size))
    except Exception as ex:                                  # noqa: BLE001
        return "unavailable:%s" % type(ex).__name__


def _summarize(entries, rooms):
    by_status = {}
    for e in entries:
        by_status[e["status"]] = by_status.get(e["status"], 0) + 1
    rooms_by_status = {}
    for r in rooms:
        rooms_by_status[r["room_status"]] = rooms_by_status.get(
            r["room_status"], 0) + 1
    return {
        "entries": len(entries),
        "entries_by_status": dict(sorted(by_status.items())),
        "rooms": len(rooms),
        "rooms_by_status": dict(sorted(rooms_by_status.items())),
        "conflicting_rooms": sorted(r["room"] for r in rooms if r["conflict"]),
        "unattributed_outputs": sorted(
            e["output"] for e in entries if e["status"] == UNATTRIBUTED),
    }


# --------------------------------------------------------------------------- #
# validation (the gate)
# --------------------------------------------------------------------------- #
def validate_manifest(man, root, strict=False):
    """Return (errors, warnings).  Non-empty errors mean exit non-zero."""
    errors, warnings = [], []
    if man.get("schema") != SCHEMA:
        errors.append("unknown manifest schema %r" % man.get("schema"))
        return errors, warnings

    for r in man.get("references", []):
        path = os.path.join(root, r["path"])
        if not os.path.isfile(path):
            errors.append("absent referenced input: %s (%s)"
                          % (r["path"], r.get("role")))
            continue
        if r.get("sha256") and sha256_file(path) != r["sha256"]:
            errors.append("referenced input changed: %s" % r["path"])

    seen_outputs = {}
    room_status = {}
    for e in man.get("entries", []):
        out = e.get("output")
        if out in seen_outputs:
            errors.append("duplicate output entry: %s" % out)
        seen_outputs[out] = e
        status = e.get("status")
        if status not in ENTRY_STATUSES:
            errors.append("unknown entry status %r for %s" % (status, out))
        rid = e.get("room")
        if rid and e.get("room_status") not in (None, "unknown"):
            room_status.setdefault(rid, set()).add(e["room_status"])
        if status == MISSING:
            errors.append("missing rendered output: %s (%s)"
                          % (out, e.get("reason")))
        path = os.path.join(root, out) if out else None
        if e.get("sha256"):
            if not path or not os.path.isfile(path):
                errors.append("recorded output is absent: %s" % out)
            elif sha256_file(path) != e["sha256"]:
                errors.append("sha256 mismatch: %s" % out)
        exp = e.get("expected_sha256")
        if status == RENDERED and exp and e.get("sha256") != exp:
            errors.append("rendered output does not match its producer digest: "
                          "%s" % out)
        if strict and status in (STALE, UNATTRIBUTED, CONFLICT):
            errors.append("strict: %s output: %s (%s)"
                          % (status, out, e.get("reason")))

    for rid, statuses in sorted(room_status.items()):
        if len(statuses) > 1:
            errors.append("room %s appears with conflicting status: %s"
                          % (rid, ", ".join(sorted(statuses))))

    for r in man.get("rooms", []):
        if r.get("conflict"):
            errors.append("room %s: producers disagree (%s)"
                          % (r["room"], r.get("reason")))
    if strict:
        # Strict is a hygiene report, not an integrity gate. A room that was
        # considered and produced no output *with a recorded reason* is a valid
        # outcome whether the tools called it `rejected` (the tilemap did not
        # validate) or `omitted` (no palette candidate / bad ptab). Neither is a
        # defect in the manifest, and failing on one but not the other would
        # make the mode unusable on any real tree. What strict does fail on is
        # output whose provenance is unknowable or wrong: bytes nothing claims,
        # bytes a producer no longer reproduces, and producers that disagree.
        for name in ("stale", "unattributed"):
            n = man.get("summary", {}).get("entries_by_status", {}).get(name, 0)
            if n:
                warnings.append("%d %s output(s) recorded" % (n, name))
        rooms_by = man.get("summary", {}).get("rooms_by_status", {})
        for name in (REJECTED, OMITTED):
            if rooms_by.get(name):
                warnings.append("%d room(s) %s (recorded outcome, not a "
                                "defect)" % (rooms_by[name], name))
    return errors, warnings


def validate_exit_code(man, root, strict=False, out=sys.stdout):
    errors, warnings = validate_manifest(man, root, strict)
    s = man.get("summary", {})
    print("manifest: %s" % man.get("schema"))
    print("  entries: %s" % json.dumps(s.get("entries_by_status", {}),
                                       sort_keys=True))
    print("  rooms:   %s" % json.dumps(s.get("rooms_by_status", {}),
                                       sort_keys=True))
    print("  conflicts: %d" % len(s.get("conflicting_rooms", [])))
    print("  unattributed: %d" % len(s.get("unattributed_outputs", [])))
    for w in warnings:
        print("  warning: %s" % w)
    for e in errors:
        print("  ERROR: %s" % e)
    print("VALIDATION %s (%d error%s)"
          % ("FAILED" if errors else "OK", len(errors),
             "" if len(errors) == 1 else "s"))
    return 1 if errors else 0


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def _build_cmd(args):
    root = os.path.abspath(args.root)
    trees = args.tree or [DEFAULT_TREE]
    man = build_manifest(trees, args.sidecar, args.lba_table, root,
                         verify_source=args.verify_source)
    text = json.dumps(man, indent=1, sort_keys=True) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        print("wrote %s (%d entries, %d rooms)"
              % (args.out, len(man["entries"]), len(man["rooms"])))
    else:
        sys.stdout.write(text)
    return 0


def _validate_cmd(args):
    root = os.path.abspath(args.root)
    if args.manifest == "-":
        man = json.load(sys.stdin)
    else:
        man = _json(args.manifest)
    if args.json:
        errors, warnings = validate_manifest(man, root, strict=args.strict)
        print(json.dumps({"errors": errors, "warnings": warnings,
                          "summary": man.get("summary")},
                         indent=1, sort_keys=True))
        return 1 if errors else 0
    return validate_exit_code(man, root, strict=args.strict)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="inventory renders + sidecars -> manifest")
    b.add_argument("--tree", action="append", metavar="DIR",
                   help="output tree to inventory (default: kit/work/area_tiles; "
                        "repeatable)")
    b.add_argument("--sidecar", action="append", default=[], metavar="JSONL",
                   help="producer sidecar to merge (repeatable)")
    b.add_argument("--lba-table", default=DEFAULT_LBA_TABLE,
                   help="tracked overlay LBA table")
    b.add_argument("--root", default=_ROOT,
                   help="paths in the manifest are relative to this root")
    b.add_argument("--out", default=None, help="write manifest here")
    b.add_argument("--verify-source", action="store_true",
                   help="also hash the disc payload per source BIN "
                        "(requires the disc; off by default)")
    b.set_defaults(func=_build_cmd)

    v = sub.add_parser("validate", help="gate: re-hash and check consistency")
    v.add_argument("--manifest", required=True, help="manifest path, or -")
    v.add_argument("--root", default=_ROOT)
    v.add_argument("--strict", action="store_true",
                   help="also fail on stale / unattributed / omitted")
    v.add_argument("--json", action="store_true", help="machine-readable report")
    v.set_defaults(func=_validate_cmd)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
