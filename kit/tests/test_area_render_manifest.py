#!/usr/bin/env python3
"""Tests for the area-render status manifest — kit/tests/test_area_render_manifest.py

Workstream M, 2026-10-04.  Covers the gate contract of
`kit/tools/area_render_manifest.py`:

  1. a rendered room with a correct sha256 validates;
  2. a missing output file fails;
  3. a hash mismatch fails;
  4. a room appearing twice with conflicting status fails;
  5. a rejected room *with a reason* is accepted as a valid outcome;
  6. an unattributed file is surfaced, never silently accepted (strict mode
     fails on it);
  7. two builds over the same inputs produce identical manifest content, with
     no absolute paths and no disc access.

All fixtures are synthetic and written under a temporary directory, so the
suite runs without the disc and never touches `kit/work/area_tiles/`.

Run directly:
    .venv/bin/python kit/tests/test_area_render_manifest.py
or with pytest:
    .venv/bin/python -m pytest kit/tests/test_area_render_manifest.py
"""

import json
import os
import shutil
import sys
import tempfile

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import area_render_manifest as arm                       # noqa: E402
from PIL import Image                                    # noqa: E402

VERBOSE = False


# --------------------------------------------------------------------------- #
# fixtures
# --------------------------------------------------------------------------- #
def _png(path, colour=(10, 20, 30), size=(16, 16)):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Image.new("RGB", size, colour).save(path)
    return path


def _sidecar(path, records):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for rec in records:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
    return path


def _rec(area, room, status, **kw):
    rec = {
        "schema": arm.SIDECAR_SCHEMA,
        "tool": kw.pop("tool", "fix_palettes.py"),
        "tool_revision": "2026-10-04.1",
        "decoder": "lzss.py 2.0.0",
        "validation_rules": arm.REVISION,
        "area": area,
        "room": room,
        "bin": room.rsplit("_h", 1)[0],
        "header_index": int(room.rsplit("_h", 1)[1]),
        "source_path": None,
        "status": status,
        "reason": kw.pop("reason", None),
        "output": None,
        "output_2x": None,
        "sha256": None,
        "sha256_2x": None,
        "bytes": None,
        "width": None,
        "height": None,
        "palette": kw.pop("palette", None),
    }
    rec.update(kw)
    return rec


def _rendered_rec(area, room, out, out2):
    return _rec(area, room, "rendered", output=out, output_2x=out2,
                sha256=arm.sha256_file(os.path.join(_ROOT, out)),
                sha256_2x=arm.sha256_file(os.path.join(_ROOT, out2)),
                bytes=os.path.getsize(os.path.join(_ROOT, out)),
                width=16, height=16,
                palette={"method": "test", "index": 7, "file_offset": 0x100,
                         "heuristic": True})


_ROOT = None          # temp root, set by the fixture
_LBA = None           # LBA table path


def _lba_table(path):
    doc = {"static_table": {"entries": [
        {"index": 5, "addr": "0x80045034", "size": 452536, "lba": 50475,
         "path": "DATA/01_AREA.A/VA7.BIN", "iso_size_match": True},
        {"index": 8, "addr": "0x8004504c", "size": 443028, "lba": 51054,
         "path": "DATA/01_AREA.A/VA8.BIN", "iso_size_match": True},
        {"index": 20, "addr": "0x8004507c", "size": 200000, "lba": 60000,
         "path": "DATA/08_AREA.E/VE1.BIN", "iso_size_match": True},
    ]}}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, sort_keys=True)
    return path


def _setup(tmp, extra_records=(), scratch_file=True):
    """A miniature output tree + one sidecar.

    tree/08E/VE1_h0.png (+_2x)  rendered, claimed with the right hashes
    tree/01A/VA7_h32.png        a stale render of a REJECTED room
    tree/scratch/notes.png      no producer claims it -> unattributed
    """
    global _ROOT, _LBA
    _ROOT = tmp
    tree = os.path.join(tmp, "tree")
    out = _png(os.path.join(tree, "08E", "VE1_h0.png"))
    out2 = _png(os.path.join(tree, "08E", "VE1_h0_2x.png"))
    recs = [_rendered_rec("08E", "VE1_h0", "tree/08E/VE1_h0.png",
                          "tree/08E/VE1_h0_2x.png")]
    recs += [_rec("01A", "VA7_h32", "rejected",
                  reason="tile index references blob 1020 but only 37 decoded")]
    if scratch_file:
        _png(os.path.join(tree, "scratch", "notes.png"))
    recs = list(recs) + list(extra_records)
    sc = _sidecar(os.path.join(tmp, "sidecar.jsonl"), recs)
    _LBA = _lba_table(os.path.join(tmp, "overlay_lba_table.json"))
    return tree, sc


def _build(tree, sc, root=None):
    return arm.build_manifest([tree], [sc], _LBA, root or _ROOT)


# --------------------------------------------------------------------------- #
# 1. a rendered room with a correct hash validates
# --------------------------------------------------------------------------- #
def test_rendered_room_with_correct_hash_validates():
    tmp = tempfile.mkdtemp(prefix="arm1_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE1_h0.png")
        assert entry is not None, "rendered output missing from the manifest"
        assert entry["status"] == "rendered", entry["status"]
        assert entry["sha256"] == entry["expected_sha256"]
        assert entry["source"]["disc_path"] == "DATA/08_AREA.E/VE1.BIN"
        assert entry["source"]["lba"] == 60000, entry["source"]
        assert entry["producers"][0]["palette"]["heuristic"] is True
        errors, _ = arm.validate_manifest(man, tmp)
        assert errors == [], errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 2. a missing output file fails
# --------------------------------------------------------------------------- #
def test_missing_output_file_fails():
    tmp = tempfile.mkdtemp(prefix="arm2_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        assert arm.validate_manifest(man, tmp)[0] == []
        os.remove(os.path.join(tmp, "tree/08E/VE1_h0.png"))
        errors, _ = arm.validate_manifest(man, tmp)
        assert any("VE1_h0.png" in e for e in errors), errors
        assert any("absent" in e or "missing" in e for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_render_never_written_is_recorded_as_missing():
    """A sidecar that says 'rendered' but whose file the tree lacks must fail,
    not be silently dropped."""
    tmp = tempfile.mkdtemp(prefix="arm2b_")
    try:
        tree, sc = _setup(tmp)
        rec = _rec("08E", "VE2_h0", "rendered",
                   output="tree/08E/VE2_h0.png",
                   output_2x="tree/08E/VE2_h0_2x.png",
                   sha256="0" * 64, sha256_2x="1" * 64, bytes=99,
                   width=16, height=16)
        with open(sc) as fh:
            _sidecar(sc, [json.loads(l) for l in fh] + [rec])
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE2_h0.png")
        assert entry is not None and entry["status"] == "missing", entry
        errors, _ = arm.validate_manifest(man, tmp)
        assert any("missing rendered output" in e for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 3. a hash mismatch fails
# --------------------------------------------------------------------------- #
def test_hash_mismatch_fails():
    tmp = tempfile.mkdtemp(prefix="arm3_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        p = os.path.join(tmp, "tree/08E/VE1_h0.png")
        _png(p, colour=(200, 0, 0))          # same path, different bytes
        errors, _ = arm.validate_manifest(man, tmp)
        assert any("sha256 mismatch" in e and "VE1_h0.png" in e
                   for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_changed_producer_bytes_are_stale_not_rendered():
    """The manifest distinguishes "a run recorded these bytes" from "this file
    merely exists at the right path"."""
    tmp = tempfile.mkdtemp(prefix="arm3b_")
    try:
        tree, sc = _setup(tmp)
        _png(os.path.join(tmp, "tree/08E/VE1_h0.png"), colour=(9, 9, 9))
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE1_h0.png")
        assert entry["status"] == "stale", entry["status"]
        assert entry["reason"]
        assert arm.validate_manifest(man, tmp)[0] == []     # integrity is fine
        errors, _ = arm.validate_manifest(man, tmp, strict=True)
        assert any("stale" in e for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 4. a room appearing twice with conflicting status fails
# --------------------------------------------------------------------------- #
def test_duplicate_room_with_conflicting_status_fails():
    tmp = tempfile.mkdtemp(prefix="arm4_")
    try:
        tree, sc = _setup(tmp)
        rec_rendered = _rendered_rec("08E", "VE1_h0", "tree/08E/VE1_h0.png",
                                     "tree/08E/VE1_h0_2x.png")
        rec_rendered["tool"] = "render_area_batch.py"
        rec_rejected = _rec("08E", "VE1_h0", "rejected",
                            tool="fix_palettes.py", reason="bogus pointer")
        with open(sc) as fh:
            _sidecar(sc, [json.loads(l) for l in fh]
                     + [rec_rendered, rec_rejected])
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE1_h0.png")
        assert entry["status"] == "conflict", entry["status"]
        room = _room(man, "08E/VE1_h0")
        assert room["conflict"] is True
        errors, _ = arm.validate_manifest(man, tmp)
        assert any("conflicting status" in e or "producers disagree" in e
                   for e in errors), errors
        assert arm.validate_exit_code(man, tmp) == 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_same_status_from_two_producers_is_not_a_conflict():
    tmp = tempfile.mkdtemp(prefix="arm4b_")
    try:
        tree, sc = _setup(tmp)
        dup = _rendered_rec("08E", "VE1_h0", "tree/08E/VE1_h0.png",
                            "tree/08E/VE1_h0_2x.png")
        dup["tool"] = "render_area_batch.py"
        with open(sc) as fh:
            _sidecar(sc, [json.loads(l) for l in fh] + [dup])
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE1_h0.png")
        assert entry["status"] == "rendered", entry["status"]
        assert len(entry["producers"]) == 2
        assert "render_area_batch.py" in entry["attribution"]
        assert arm.validate_manifest(man, tmp)[0] == []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 5. a rejected room with a reason is a valid outcome
# --------------------------------------------------------------------------- #
def test_rejected_room_with_reason_is_a_valid_outcome():
    tmp = tempfile.mkdtemp(prefix="arm5_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        room = _room(man, "01A/VA7_h32")
        assert room is not None, "the rejected room was not recorded"
        assert room["room_status"] == "rejected"
        assert "1020" in room["reason"]
        assert man["summary"]["rooms_by_status"]["rejected"] == 1
        # the stale PNG left behind by the pre-fix tool is flagged as stale,
        # not counted as a rendered output
        stale = _entry(man, "tree/01A/VA7_h32.png")
        assert stale is None or stale["status"] == "stale"
        errors, _ = arm.validate_manifest(man, tmp)
        assert errors == [], errors
        assert arm.validate_exit_code(man, tmp) == 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 6. an unattributed file is surfaced, never silently accepted
# --------------------------------------------------------------------------- #
def test_unattributed_file_is_surfaced_not_accepted():
    tmp = tempfile.mkdtemp(prefix="arm6_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        entry = _entry(man, "tree/scratch/notes.png")
        assert entry is not None, "the unattributed file vanished"
        assert entry["status"] == "unattributed"
        assert entry["sha256"]                      # bytes still recorded
        assert entry["producers"] == []
        assert man["summary"]["unattributed_outputs"] == ["tree/scratch/notes.png"]
        # the two files the 08E room legitimately produced are rendered
        assert man["summary"]["entries_by_status"].get("rendered") == 2
        # not silently accepted: strict mode calls it out
        assert arm.validate_manifest(man, tmp)[0] == []
        errors, _ = arm.validate_manifest(man, tmp, strict=True)
        assert any("unattributed" in e and "notes.png" in e
                   for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_scratch_named_like_a_room_is_still_unattributed():
    """A file whose name looks like a room but which no sidecar claims is
    unattributed, not rendered."""
    tmp = tempfile.mkdtemp(prefix="arm6b_")
    try:
        tree, sc = _setup(tmp)
        _png(os.path.join(tmp, "tree/08E", "VE9_h3.png"))
        man = _build(tree, sc)
        entry = _entry(man, "tree/08E/VE9_h3.png")
        assert entry["status"] == "unattributed", entry["status"]
        assert entry["attribution"] == "none"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 7. determinism
# --------------------------------------------------------------------------- #
def test_two_builds_are_identical_and_disc_free():
    tmp = tempfile.mkdtemp(prefix="arm7_")
    try:
        tree, sc = _setup(tmp)
        assert "disc" not in sys.modules, "importing the manifest tool pulled in disc"
        a = json.dumps(_build(tree, sc), sort_keys=True)
        b = json.dumps(_build(tree, sc), sort_keys=True)
        assert a == b, "two builds over the same inputs differ"
        assert tmp not in a, "an absolute path leaked into the manifest"
        assert "timestamp" not in a.lower() and "generated_at" not in a.lower()
        assert "disc" not in sys.modules, "build opened the disc"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_absent_referenced_input_fails():
    tmp = tempfile.mkdtemp(prefix="arm8_")
    try:
        tree, sc = _setup(tmp)
        man = _build(tree, sc)
        assert arm.validate_manifest(man, tmp)[0] == []
        os.remove(sc)
        errors, _ = arm.validate_manifest(man, tmp)
        assert any("absent referenced input" in e for e in errors), errors
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_unknown_sidecar_schema_is_a_hard_error():
    tmp = tempfile.mkdtemp(prefix="arm9_")
    try:
        tree, sc = _setup(tmp)
        with open(sc, "w", encoding="utf-8") as f:
            f.write(json.dumps({"schema": "something/else"}) + "\n")
        try:
            _build(tree, sc)
        except SystemExit as ex:
            assert "schema" in str(ex)
            return
        raise AssertionError("an unknown sidecar schema was accepted")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def test_real_tree_if_present_builds_self_consistently():
    """Smoke test over the real 1,728-PNG tree when it is present. It asserts
    only self-consistency (every recorded hash matches its file) so other
    workstreams adding scratch files cannot break the suite."""
    real = os.path.join(KIT, "work", "area_tiles")
    if not os.path.isdir(real):
        print("skip: %s absent" % real)
        return
    man = arm.build_manifest([real], [], os.path.join(
        KIT, "extracted", "overlay_lba_table.json"), KIT)
    assert man["summary"]["entries"] == len(man["entries"])
    errors, _ = arm.validate_manifest(man, KIT)
    assert errors == [], errors[:5]
    assert man["summary"]["entries_by_status"].get("unattributed", 0) == \
        man["summary"]["entries"]


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _entry(man, output):
    for e in man["entries"]:
        if e["output"] == output:
            return e
    return None


def _room(man, room):
    for r in man["rooms"]:
        if r["room"] == room:
            return r
    return None


if __name__ == "__main__":
    tests = [(n, f) for n, f in sorted(globals().items())
             if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as ex:                          # noqa: BLE001
            failed += 1
            print("FAIL %s: %s: %s" % (name, type(ex).__name__, ex))
        else:
            print("ok   %s" % name)
    print("\n%d passed, %d failed" % (len(tests) - failed, failed))
    sys.exit(1 if failed else 0)
