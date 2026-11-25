#!/usr/bin/env python3
"""Clean-checkout compatibility and preservation of local outputs."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_layout import prepare


class LayoutTest(unittest.TestCase):
    def test_real_map_restores_all_paths_without_local_outputs(self):
        data = Path(__file__).resolve().parents[1] / "data"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "archive/goals").mkdir(parents=True)
            (root / "kit").mkdir()
            (root / "kit/data").symlink_to(data, target_is_directory=True)
            prepare(root)
            for old, new in json.loads((data / "legacy_paths.json").read_text()).items():
                alias = root / old
                self.assertTrue(alias.is_symlink(), old)
                self.assertEqual(alias.resolve(), (root / new).resolve(), old)
                self.assertFalse(str(alias.readlink()).startswith("/"), old)

    def test_prepare_is_repeatable_and_preserves_local_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "archive/goals").mkdir(parents=True)
            data = root / "kit/data"
            data.mkdir(parents=True)
            (data / "labels.csv").write_text("original\n")
            (data / "legacy_paths.json").write_text(json.dumps({
                "kit/work/labels.csv": "kit/data/labels.csv",
                "kit/work/assets_zig/labels.csv": "kit/data/labels.csv",
            }))
            prepare(root)
            prepare(root)
            old = root / "kit/work/labels.csv"
            self.assertTrue(old.is_symlink())
            self.assertEqual(old.read_text(), "original\n")
            self.assertEqual((root / "kit/work/accepted/labels.csv").read_text(), "original\n")
            self.assertTrue((root / "goals").is_dir())
            old.unlink()
            old.write_text("local output\n")
            prepare(root)
            self.assertEqual(old.read_text(), "local output\n")
            self.assertEqual((data / "labels.csv").read_text(), "original\n")

    def test_conflicting_link_and_missing_input_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "archive/goals").mkdir(parents=True)
            data = root / "kit/data"
            data.mkdir(parents=True)
            (data / "legacy_paths.json").write_text(json.dumps({
                "kit/work/input.csv": "kit/data/missing.csv",
            }))
            with self.assertRaises(FileNotFoundError):
                prepare(root)
            (data / "missing.csv").write_text("input")
            (root / "kit/work/input.csv").symlink_to("../accepted")
            with self.assertRaises(FileExistsError):
                prepare(root)


if __name__ == "__main__":
    unittest.main()
