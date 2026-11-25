#!/usr/bin/env python3
"""test_export_manifest.py — CLI-contract tests for the asset exporter.

Workstream B (2026-10-04).  These tests exercise kit/tools/export_assets.py as
a subprocess with `--out <tempdir>` and `--skip`, so they never touch the
accepted package under kit/work/assets_zig/.  A module-level guard re-hashes
two tracked approval/identity records (text/dialogue.json and
music/v3/provenance.json) before and after the whole suite and fails if any
test changed them.

What each test would catch:
  OverlayIdentityTest.test_two_overlays_same_local_key   cross-overlay id
      collapse and speaker contamination (the /1 dialogue bug).
  OverlayIdentityTest.test_banner_lines_never_enter_text  overlay banners
      leaking into dialogue strings (78 occurrences in the accepted file).
  OverlayIdentityTest.test_real_count_matches_independent_loader  parser
      drift versus an independently written loader/count of the real dump.
  ManifestContractTest.test_fresh_output_root  silent count=0 on a fresh
      --out (the export_textures self-read bug).
  ManifestContractTest.test_sparse_song_selection / ...partial...  the
      `range(n)` phantom file list and overwriting an approval record.
  ManifestContractTest.test_missing_input_records_failure / ...uncaught... /
      ...missing_dependency...  failures that used to exit 0.
  ValidationTest.*  dangling references, duplicate ids, hash/count drift and
      manifest.json being replaced by a failed run.
  ResyncBoundsTest.*  resync anchors accepted on truncated operands.

Run:  .venv/bin/python kit/tests/test_export_manifest.py
"""

import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave

_TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_TOOLS = os.path.join(_TOOLS, "tools")
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)
sys.path.insert(0, _TOOLS)

EXPORT = os.path.join(_TOOLS, "export_assets.py")
REAL_DIALOGUE = os.path.join(_KIT, "work", "decoded_text", "dialogue_found.txt")
REAL_CORPUS = os.path.join(_KIT, "work", "scripts_decoded")
REAL_CURATED = os.path.join(_KIT, "work", "assets_zig")
REAL_BINOV = os.path.join(_KIT, "extracted", "bin_overlays")
STONE_OVERLAY = os.path.join(REAL_BINOV, "DATA", "03_SHIRO", "STONE.BIN")
IKKI_DIR = os.path.join(REAL_BINOV, "DATA", "12_IKKI", "DATA")
ACCEPTED = [os.path.join(REAL_CURATED, "text", "dialogue.json"),
            os.path.join(REAL_CURATED, "music", "v3", "provenance.json")]

BANNER = re.compile(r'^--- (\S+) \(')
ENTRY = re.compile(r'^\[(\d+),(\d+)\]\s+@0x([0-9a-fA-F]+):\s?(.*)$')

_ENV_KEYS = ("SUIKODEN_DIALOGUE_SRC", "SUIKODEN_SCRIPT_CORPUS",
             "SUIKODEN_MUSIC_SRC", "SUIKODEN_CURATED", "SUIKODEN_BINOV")

# classes that need inputs absent from a bare checkout / are slow
FAST_SKIP = ("music", "palettes", "geometry", "recipes", "extras",
             "tables", "scripts", "textures")


def _load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def _sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


_ACCEPTED_BEFORE = None


def setUpModule():
    global _ACCEPTED_BEFORE
    _ACCEPTED_BEFORE = {p: _sha(p) for p in ACCEPTED if os.path.exists(p)}


def tearDownModule():
    for p, h in (_ACCEPTED_BEFORE or {}).items():
        if _sha(p) != h:
            raise AssertionError(
                "accepted record was modified by the test suite: %s" % p)


def run_export(out, skip=(), extra=(), env=None):
    args = [sys.executable, EXPORT, "--out", out]
    if skip:
        args += ["--skip", ",".join(skip)]
    args += list(extra)
    e = dict(os.environ)
    for k in _ENV_KEYS:
        e.pop(k, None)
    if env:
        e.update(env)
    return subprocess.run(args, capture_output=True, text=True, env=e,
                          cwd=_ROOT)


class OverlayIdentityTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="expman_")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.dlg = os.path.join(self.tmp, "dialogue_found.txt")
        self.corp = os.path.join(self.tmp, "corpus")
        os.makedirs(self.corp)
        self.out = os.path.join(self.tmp, "out")

    def _write_fixture(self, text):
        with open(self.dlg, "w", encoding="utf-8") as f:
            f.write(text)

    def _write_script(self, overlay, lines):
        with open(os.path.join(self.corp, overlay + ".txt"), "w",
                  encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def _env(self):
        return {"SUIKODEN_DIALOGUE_SRC": self.dlg,
                "SUIKODEN_SCRIPT_CORPUS": self.corp}

    def test_two_overlays_same_local_key(self):
        self._write_fixture(
            "preamble\n"
            "--- VA1.BIN (1 dialogue strings) ---\n"
            "[0,0] @0x100: First overlay line.\n"
            "--- VA2.BIN (1 dialogue strings) ---\n"
            "[0,0] @0x200: Second overlay line with the same local key.\n")
        self._write_script("VA1", [
            "      speaker=5 [0,0] @0x100: First",
            "      speaker=77 [0,0]: *** DATA CONTEXT — entity bytes",
            "      speaker=78 [99,99]: *** DATA CONTEXT — text bytes",
        ])
        self._write_script("VA2", ["      speaker=9 [0,0] @0x200: Second"])
        r = run_export(self.out, skip=FAST_SKIP, env=self._env())
        self.assertEqual(r.returncode, 0, r.stderr)
        d = _load(os.path.join(self.out, "text", "dialogue.json"))
        self.assertEqual(d["schema"], "suikoden-dialogue/2")
        self.assertEqual(d["id_key"], "overlay/table/entry")
        ids = [s["id"] for s in d["strings"]]
        self.assertEqual(sorted(ids), ["VA1.BIN/0/0", "VA2.BIN/0/0"])
        self.assertEqual(len(set(ids)), len(ids))
        by = {s["id"]: s for s in d["strings"]}
        self.assertEqual(by["VA1.BIN/0/0"]["speakers"], [5])
        self.assertEqual(by["VA2.BIN/0/0"]["speakers"], [9])
        # a single row may never carry two overlays
        for s in d["strings"]:
            self.assertEqual(s["overlays"], [s["overlay"]])
        m = _load(os.path.join(self.out, "manifest.json"))
        self.assertEqual(m["errors"], [])
        self.assertEqual(m["validation"]["ok"], True)

    def test_banner_lines_never_enter_text(self):
        self._write_fixture(
            "--- VA1.BIN (2 dialogue strings) ---\n"
            "[0,0] @0x100: Line one.\n"
            "second physical line\n"
            "[---]\n"
            "third segment\n"
            "--- VA2.BIN (1 dialogue strings) ---\n"
            "[7,3] @0x200: Another file entirely.\n")
        r = run_export(self.out, skip=FAST_SKIP, env=self._env())
        self.assertEqual(r.returncode, 0, r.stderr)
        d = _load(os.path.join(self.out, "text", "dialogue.json"))
        self.assertEqual([s["id"] for s in d["strings"]],
                         ["VA1.BIN/0/0", "VA2.BIN/7/3"])
        for s in d["strings"]:
            for seg in s["segments"]:
                for ln in seg.split("\n"):
                    self.assertFalse(BANNER.match(ln),
                                     "banner leaked into %s: %r" % (s["id"], ln))
        first = d["strings"][0]
        self.assertEqual(first["segments"],
                         ["Line one.\nsecond physical line", "third segment"])

    def _independent_parse(self):
        """Second, independent loader/count for the real dump."""
        rows, ov = [], None
        with open(REAL_DIALOGUE, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                mb = BANNER.match(line)
                if mb:
                    ov = mb.group(1)
                    continue
                me = ENTRY.match(line)
                if me and ov is not None:
                    rows.append(ov + "/" + me.group(1) + "/" + me.group(2))
        return rows

    def test_real_count_matches_independent_loader(self):
        if not os.path.exists(REAL_DIALOGUE):
            self.skipTest("real dialogue dump absent")
        r = run_export(self.out, skip=FAST_SKIP)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = _load(os.path.join(self.out, "text", "dialogue.json"))
        from export_assets import INDEX_TOTALS_RE
        with open(os.path.join(REAL_CORPUS, 'INDEX.md'), encoding='utf-8') as f:
            self.assertIsNotNone(INDEX_TOTALS_RE.search(f.read()),
                                 'corpus summary is not readable by its exporter')
        rows = self._independent_parse()
        self.assertGreater(len(rows), 10000)
        self.assertEqual([s["id"] for s in d["strings"]], rows)
        self.assertEqual(len(set(rows)), len(rows))
        self.assertEqual(d["string_count"], len(rows))
        self.assertGreater(d["overlay_count"], 50)
        # no banner anywhere, and per-overlay attribution only
        for s in d["strings"]:
            for seg in s["segments"]:
                for ln in seg.split("\n"):
                    self.assertFalse(BANNER.match(ln))
            self.assertEqual(s["overlays"], [s["overlay"]])
        # attribution bookkeeping must add up
        sa = d["script_attribution"]
        self.assertEqual(sa["speaker_lines"],
                         sa["resolved_lines"] + sa["gap_lines"])
        if os.path.isdir(REAL_CORPUS):
            self.assertGreater(sa["speaker_lines"], 0)


class ManifestContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="expman_")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.out = os.path.join(self.tmp, "out")

    def test_fresh_output_root_produces_content(self):
        if not os.path.exists(STONE_OVERLAY):
            self.skipTest("STONE.BIN overlay absent (nothing to regenerate)")
        r = run_export(self.out, skip=("music", "palettes", "geometry",
                                       "recipes", "extras"))
        self.assertEqual(r.returncode, 0, r.stderr)
        m = _load(os.path.join(self.out, "manifest.json"))
        self.assertEqual(m["errors"], [])
        self.assertEqual(m["validation"]["ok"], True)
        ids = {a["id"]: a for a in m["assets"]}
        self.assertIn("dialogue", ids)
        self.assertIn("stone_textures", ids)
        self.assertEqual(ids["stone_textures"]["count"], 5)
        self.assertEqual(len(ids["stone_textures"]["produced_files"]), 5)
        if os.path.isdir(REAL_CURATED):
            self.assertIn("data_tables", ids)
            self.assertGreaterEqual(ids["data_tables"]["count"], 6)
        if os.path.isdir(REAL_CORPUS):
            self.assertEqual(ids["event_scripts"]["count"], 39)
        # nothing recorded as stale on a fresh root, and every file exists
        for a in m["assets"]:
            self.assertEqual(a.get("stale_files", []), [],
                             "%s picked up stale files" % a["id"])
            self.assertTrue(a["produced_files"], a["id"])
            for rel in a["files"]:
                self.assertTrue(os.path.isfile(os.path.join(self.out, rel)))
        # a class that cannot be produced must say so instead of count=0
        for o in m["omissions"]:
            self.assertTrue(o["reason"])

    def test_sparse_song_selection(self):
        src = os.path.join(self.tmp, "music")
        os.makedirs(src)
        with wave.open(os.path.join(src, "song2_v3.wav"), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(struct.pack("<100h", *([0] * 100)))
        r = run_export(self.out, skip=("dialogue", "palettes", "geometry",
                                       "recipes", "tables", "scripts",
                                       "textures", "extras"),
                       env={"SUIKODEN_MUSIC_SRC": src})
        self.assertEqual(r.returncode, 0, r.stderr)
        m = _load(os.path.join(self.out, "manifest.json"))
        a = [x for x in m["assets"] if x["id"] == "music"][0]
        self.assertEqual(a["files"], ["music/v3/song2_v3.wav"])
        self.assertEqual(a["count"], 1)
        self.assertRegex(a["render_id"], r"^[0-9a-f]{64}$")
        p = _load(os.path.join(self.out, "music", "v3", "provenance.json"))
        self.assertEqual(p["files"], ["song2_v3.wav"])          # no song0 phantom
        self.assertEqual(list(p["file_hashes"]), ["song2_v3.wav"])
        self.assertEqual(p["approval"]["state"], "not-assessed")

    def test_partial_music_selection_keeps_existing_record(self):
        src = os.path.join(self.tmp, "music")
        os.makedirs(src)
        with wave.open(os.path.join(src, "song2_v3.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(44100)
            w.writeframes(struct.pack("<100h", *([0] * 100)))
        old_dir = os.path.join(self.out, "music", "v3")
        os.makedirs(old_dir)
        old = os.path.join(old_dir, "provenance.json")
        payload = {"schema": "suikoden-music/1",
                   "provenance": {"decoder": "old", "source": "old",
                                  "status": "best-effort"},
                   "files": ["song0_v3.wav", "song1_v3.wav", "song2_v3.wav",
                             "song3_v3.wav"]}
        with open(old, "w") as f:
            json.dump(payload, f)
        before = _sha(old)
        r = run_export(self.out, skip=("dialogue", "palettes", "geometry",
                                       "recipes", "tables", "scripts",
                                       "textures", "extras"),
                       env={"SUIKODEN_MUSIC_SRC": src})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(_sha(old), before, "approval record was overwritten")
        m = _load(os.path.join(self.out, "manifest.json"))
        self.assertTrue(any("partial selection" in o["reason"]
                            for o in m["omissions"]), m["omissions"])

    def test_missing_input_records_failure(self):
        r = run_export(self.out, skip=FAST_SKIP,
                       env={"SUIKODEN_DIALOGUE_SRC":
                            os.path.join(self.tmp, "nope.txt")})
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.exists(os.path.join(self.out, "manifest.json")),
                         "failed run replaced manifest.json")
        fp = os.path.join(self.out, "manifest.failed.json")
        self.assertTrue(os.path.exists(fp))
        m = _load(fp)
        self.assertTrue(m["errors"])

    def test_uncaught_failure_is_nonzero(self):
        # a directory where a file is expected: open() raises, and the tool
        # must NOT swallow it into a success
        r = run_export(self.out, skip=FAST_SKIP,
                       env={"SUIKODEN_DIALOGUE_SRC": self.tmp})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("Traceback", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, "manifest.json")))

    def test_missing_curated_table_input_fails_before_output(self):
        empty = os.path.join(self.tmp, "empty_curated")
        os.makedirs(empty)
        r = run_export(self.out, skip=("dialogue", "music", "palettes",
                                       "geometry", "recipes", "scripts",
                                       "textures", "extras"),
                       env={"SUIKODEN_CURATED": empty})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("tables input missing", r.stderr)
        # preflight: nothing was written, not even a tree of empty classes
        self.assertFalse(os.path.exists(os.path.join(self.out, "manifest.json")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "tables")))

    def test_missing_dependency_fails_before_output(self):
        if not os.path.isdir(IKKI_DIR):
            self.skipTest("12_IKKI palettes source absent")
        fake = os.path.join(self.tmp, "fakepil")
        os.makedirs(fake)
        with open(os.path.join(fake, "PIL.py"), "w") as f:
            f.write('raise ImportError("blocked for test")\n')
        only = ("dialogue", "music", "geometry", "recipes", "tables",
                "scripts", "textures", "extras")
        r = run_export(self.out, skip=only, env={"PYTHONPATH": fake})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("PIL", r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, "manifest.json")))
        # ... but values-only export does not need PIL
        out2 = os.path.join(self.tmp, "out2")
        r2 = run_export(out2, skip=only, extra=("--no-swatches",),
                        env={"PYTHONPATH": fake})
        self.assertEqual(r2.returncode, 0, r2.stderr)
        m = _load(os.path.join(out2, "manifest.json"))
        a = [x for x in m["assets"] if x["id"] == "palettes"][0]
        self.assertTrue(a["swatches_optional"])
        self.assertGreater(a["palette_count"], 90)
        self.assertTrue(any(o["what"] == "swatches" for o in m["omissions"]))

    def test_bad_skip_class_is_rejected(self):
        r = run_export(self.out, skip=("not_a_class",))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unknown --skip", r.stderr)


class ValidationTest(unittest.TestCase):
    """In-process validation checks (no output tree is written)."""

    def setUp(self):
        import export_assets
        self.ex = export_assets
        self.tmp = tempfile.mkdtemp(prefix="expman_")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self._saved = (self.ex.OUT, dict(self.ex.MANIFEST))
        self.ex.OUT = self.tmp
        self.ex.MANIFEST["assets"] = []
        self.ex.MANIFEST["errors"] = []
        self.ex.MANIFEST["omissions"] = []
        self.addCleanup(self._restore)

    def _restore(self):
        self.ex.OUT, saved = self._saved[0], self._saved[1]
        self.ex.MANIFEST.clear()
        self.ex.MANIFEST.update(saved)

    def _asset(self, **kw):
        rel = kw.pop("file", "a.txt")
        with open(os.path.join(self.tmp, rel), "w") as f:
            f.write("x")
        base = {"id": "a", "class": "text", "path": rel,
                "provenance": {"decoder": "d", "source": "s", "status": "v"},
                "count": 1, "files": [rel],
                "file_hashes": {rel: self.ex.sha256_file(
                    os.path.join(self.tmp, rel))},
                "produced_files": [rel]}
        base.update(kw)
        return base

    def test_spu_streams_cannot_be_exported_as_geometry(self):
        self.ex.preflight(set(self.ex.CLASSES) - {"geometry"})
        self.assertEqual(self.ex.MANIFEST["errors"], [])
        self.ex.export_geometry()
        self.assertEqual(self.ex.MANIFEST["assets"], [])
        self.assertEqual(os.listdir(self.tmp), [])
        omission, = self.ex.MANIFEST["omissions"]
        self.assertEqual(omission["class"], "area_geometry")
        self.assertIn("SPU ADPCM", omission["reason"])

    def test_dangling_reference_and_missing_file(self):
        good = self._asset()
        bad = self._asset(id="b", file="b.txt",
                          provenance={"decoder": "d", "source": "s",
                                      "status": "v",
                                      "doc": "kit/docs/does_not_exist_20261004.md"})
        missing = self._asset(id="c")
        missing["files"] = ["gone.txt"]
        missing["file_hashes"] = {"gone.txt": "0" * 64}
        self.ex.MANIFEST["assets"] = [good, bad, missing]
        problems = self.ex.validate_manifest()
        joined = "\n".join(problems)
        self.assertIn("does_not_exist_20261004.md", joined)
        self.assertIn("recorded file missing: gone.txt", joined)

    def test_duplicate_ids_and_hash_drift(self):
        a = self._asset()
        b = self._asset(count=99)          # count disagrees with files
        c = self._asset()
        c["file_hashes"] = {"a.txt": "0" * 64}   # wrong hash
        self.ex.MANIFEST["assets"] = [a, b, c]
        problems = self.ex.validate_manifest()
        joined = "\n".join(problems)
        self.assertIn("duplicate asset id", joined)
        self.assertIn("count 99 != 1 files", joined)
        self.assertIn("sha256 mismatch", joined)

    def test_bad_output_schema_is_detected(self):
        os.makedirs(os.path.join(self.tmp, "palettes"))
        with open(os.path.join(self.tmp, "palettes", "palettes.json"), "w") as f:
            json.dump({"schema": "wrong", "palettes": [
                {"id": "p", "rgb555": ["0000"], "rgb888": [[0, 0, 0]],
                 "swatch_status": "generated", "swatch": None}]}, f)
        problems = []
        self.ex._validate_palettes(
            os.path.join(self.tmp, "palettes", "palettes.json"), problems)
        joined = "\n".join(problems)
        self.assertIn("schema", joined)
        self.assertIn("rgb555", joined)
        self.assertIn("swatch", joined)


class ResyncBoundsTest(unittest.TestCase):
    def setUp(self):
        import build_script_corpus
        self.b = build_script_corpus

    def test_truncated_operands_are_rejected(self):
        # fixed-length branch: opcode 0x04 needs two bytes past `end`
        self.assertFalse(self.b._clean_ahead(b"\x02\x02\x04", 0, 3, set()))
        # variable-wait branch: 0x03 fmt 0xFC consumes 5 operand bytes
        self.assertFalse(self.b._clean_ahead(b"\x02\x02\x03\xfc", 0, 4, set()))
        self.assertFalse(self.b._clean_ahead(b"\x02\x02\x03\xfc\x00\x00\x00\x00", 0, 7, set()))
        # fully contained instructions still pass
        self.assertTrue(self.b._clean_ahead(b"\x02\x02\x04\x00\x00", 0, 5, set()))
        self.assertTrue(
            self.b._clean_ahead(b"\x02\x02\x03\xfc\x00\x00\x00\x00", 0, 8, set()))
        self.assertTrue(self.b._selftest_extent_bounds())


if __name__ == "__main__":
    unittest.main(verbosity=2)
