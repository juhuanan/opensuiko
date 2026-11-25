#!/usr/bin/env python3
"""Clean-checkout compatibility and preservation of local outputs."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from prepare_layout import prepare


class LayoutTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory()
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        self.catalogs = self.root / "kit/data/catalogs/extracted"
        self.catalogs.mkdir(parents=True)
        for name in ("iso_files.json", "overlay_lba_table.json"):
            (self.catalogs / name).write_text("[]\n")

    def test_public_checkout_prepares_without_private_files(self):
        prepare(self.root)
        for name in ("iso_files.json", "overlay_lba_table.json"):
            alias = self.root / "kit/extracted" / name
            self.assertTrue(alias.is_symlink())
            self.assertFalse(alias.readlink().is_absolute())
            self.assertEqual(alias.resolve(), self.catalogs / name)
        self.assertEqual(
            (self.root / "kit/work/assets_zig").resolve(),
            self.root / "kit/work/accepted",
        )
        self.assertFalse((self.root / "goals").exists())

    def test_prepare_is_repeatable_and_preserves_local_files(self):
        archive = self.root / "archive/goals"
        archive.mkdir(parents=True)
        local_catalog = self.root / "kit/extracted/iso_files.json"
        local_catalog.parent.mkdir()
        local_catalog.write_text("local output\n")
        prepare(self.root)
        prepare(self.root)
        self.assertEqual(local_catalog.read_text(), "local output\n")
        self.assertEqual((self.catalogs / "iso_files.json").read_text(), "[]\n")
        self.assertEqual((self.root / "goals").resolve(), archive)

    def test_conflicting_link_and_missing_input_fail(self):
        catalog = self.catalogs / "iso_files.json"
        catalog.unlink()
        with self.assertRaises(FileNotFoundError):
            prepare(self.root)
        catalog.write_text("[]\n")
        (self.root / "kit/extracted/iso_files.json").symlink_to(
            self.catalogs / "overlay_lba_table.json"
        )
        with self.assertRaises(FileExistsError):
            prepare(self.root)


if __name__ == "__main__":
    unittest.main()
