#!/usr/bin/env python3
"""Tests for tools/disc.py and tools/iso_extract.py.

The disc image may be a MODE2/2352 .bin or an ISO9660 .iso. disc.py is the
single source of truth for which one resolves and what its geometry is, so the
tests derive the last addressable sector from the resolved geometry instead of
assuming 2352-byte sectors (an .iso has 2048).

Deterministic behaviour (selection, geometry validation, bounds, container
honesty) is tested with synthetic tempfile fixtures so no disc is required. The
real-disc comparisons skip themselves when the disc is absent.

Run: .venv/bin/python tests/test_iso_extract.py   (exit 0 = pass)
"""
import hashlib
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(KIT, 'tools')
sys.path.insert(0, TOOLS)

import disc  # noqa: E402
from iso_extract import extract, ShortReadError  # noqa: E402

BOOTSTRAP = os.path.join(TOOLS, 'bootstrap_sources.py')
ISO_FILES = os.path.join(KIT, 'extracted', 'iso_files.json')
OVERLAY_TABLE = os.path.join(KIT, 'extracted', 'overlay_lba_table.json')
BIN_OVERLAYS = os.path.join(KIT, 'extracted', 'bin_overlays')
ENV_VARS = ('SUIKODEN_DISC', 'SUIKODEN_ISO')

MODE2_SECTOR = 2352
MODE2_HEADER = 24
MODE2_TRAILER = 280
ISO_SECTOR = 2048


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def mode2_sector(payload, sync=False):
    """One synthetic MODE2/2352 sector: header + payload + EDC/ECC filler."""
    assert len(payload) == MODE2_SECTOR - MODE2_HEADER - MODE2_TRAILER
    head = (disc.MODE2_SYNC + bytes(12)) if sync else bytes(MODE2_HEADER)
    assert len(head) == MODE2_HEADER
    return head + payload + bytes([0xEE]) * MODE2_TRAILER


def random_payloads(n, seed=20261004):
    rng = random.Random(seed)
    return [bytes(rng.randrange(256) for _ in range(MODE2_SECTOR - MODE2_HEADER
                                                     - MODE2_TRAILER))
            for _ in range(n)]


def write_mode2(path, payloads, sync=False, tail=b''):
    with open(path, 'wb') as f:
        for p in payloads:
            f.write(mode2_sector(p, sync=sync))
        f.write(tail)
    return path


def write_iso(path, payloads):
    with open(path, 'wb') as f:
        for p in payloads:
            f.write(p)
    return path


def default_env_cleared():
    """Context manager: no $SUIKODEN_DISC / $SUIKODEN_ISO override active."""
    return mock.patch.dict(os.environ, {}, clear=True)


def disc_available():
    try:
        disc.resolve()
        return True
    except disc.DiscNotFound:
        return False


class DiscTestBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix='ws_a_disc_')
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def path(self, name):
        return os.path.join(self.tmp, name)


class TestShortRead(unittest.TestCase):
    def setUp(self):
        try:
            self.iso, self.sector, _off = disc.resolve()
        except disc.DiscNotFound as ex:
            self.skipTest('no disc image available: %s' % str(ex).splitlines()[0])

    def past_end(self):
        """(lba, size) guaranteed to run off the end of the image.

        Starting at the last whole sector is always safe: whatever the image
        length modulo the sector size, the final sector is entirely inside the
        file, so reading four sectors from there cannot be satisfied.
        """
        last_lba = os.path.getsize(self.iso) // self.sector
        return last_lba, 4 * self.sector

    def test_extract_raises_on_short_read(self):
        # request more bytes than the image holds -> must raise, not truncate
        lba, size = self.past_end()
        with self.assertRaises(ShortReadError):
            extract(lba, size)

    def test_extract_ok_on_valid_range(self):
        data = extract(18698, 2048)
        self.assertEqual(len(data), 2048)

    def test_cli_fails_loudly(self):
        lba, size = self.past_end()
        out = os.path.join(tempfile.gettempdir(), 'iso_extract_shortread_test.bin')
        if os.path.exists(out):
            os.unlink(out)
        p = subprocess.run(
            [sys.executable, os.path.join(KIT, 'tools', 'iso_extract.py'),
             str(lba), str(size), '-o', out],
            capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0,
                            'CLI must exit non-zero on short read')
        self.assertIn('short read', (p.stderr + p.stdout).lower())
        self.assertFalse(os.path.exists(out),
                         'truncated output file must not be written')


class TestBinIsoPayloadEquivalence(unittest.TestCase):
    """A .bin and an .iso must yield identical logical payload bytes.

    Regression for the raw reader splicing each sector's 280-byte EDC/ECC
    trailer into the output: a multi-sector .bin read used to disagree with the
    .iso from output byte 2048 onward, shifting every byte after the first
    sector. Uses a synthetic image so no disc is required.
    """

    SECTORS = 3
    PAYLOAD = 2048
    TRAILER = 280
    MARKER = 0xAB

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix='iso_bin_equiv_')
        cls.bin_path = os.path.join(cls.tmp, 'fixture.bin')
        cls.iso_path = os.path.join(cls.tmp, 'fixture.iso')
        rng = random.Random(20261004)
        cls.payloads = [bytes(rng.randrange(256) for _ in range(cls.PAYLOAD))
                        for _ in range(cls.SECTORS)]
        with open(cls.bin_path, 'wb') as fb, open(cls.iso_path, 'wb') as fi:
            for payload in cls.payloads:
                fb.write(bytes(24))                       # sync + header
                fb.write(payload)                         # user data
                fb.write(bytes([cls.MARKER]) * cls.TRAILER)  # EDC/ECC
                fi.write(payload)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_multisector_bin_matches_iso(self):
        n = self.SECTORS * self.PAYLOAD
        from_bin = disc.extract(0, n, self.bin_path)
        from_iso = disc.extract(0, n, self.iso_path)
        self.assertEqual(from_bin, from_iso)
        self.assertEqual(from_bin, b''.join(self.payloads))

    def test_second_sector_is_payload_not_trailer(self):
        data = disc.extract(0, 2 * self.PAYLOAD, self.bin_path)
        self.assertEqual(data[self.PAYLOAD:], self.payloads[1])
        self.assertNotIn(bytes([self.MARKER]) * self.TRAILER, data,
                         'EDC/ECC trailer bytes leaked into the payload')

    def test_unaligned_size_matches_iso(self):
        size = self.PAYLOAD + 512
        self.assertEqual(disc.extract(0, size, self.bin_path),
                         disc.extract(0, size, self.iso_path))
        self.assertEqual(len(disc.extract(0, size, self.bin_path)), size)

    def test_multisector_read_from_nonzero_lba(self):
        # a read that starts mid-image and spans sectors 1..2 unaligned
        size = self.PAYLOAD + 500
        got = disc.extract(1, size, self.bin_path)
        self.assertEqual(got, (self.payloads[1] + self.payloads[2])[:size])
        self.assertEqual(got, disc.extract(1, size, self.iso_path))

    def test_unaligned_read_spanning_three_sectors(self):
        size = 2 * self.PAYLOAD + 300
        got = disc.extract(0, size, self.bin_path)
        self.assertEqual(got, b''.join(self.payloads)[:size])


class TestStrictSelection(DiscTestBase):
    """A1: an explicit selection must resolve or raise; never a silent fallback."""

    def setUp(self):
        super().setUp()
        self.saved_env = {k: os.environ.get(k) for k in ENV_VARS}
        self.addCleanup(self._restore_env)

    def _restore_env(self):
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_missing_explicit_path_raises(self):
        missing = os.path.join(self.tmp, 'does_not_exist.bin')
        with self.assertRaises(disc.DiscNotFound) as cm:
            disc.resolve(missing)
        msg = str(cm.exception)
        self.assertIn('explicit disc image not found', msg)
        self.assertIn('Automatic search was NOT attempted', msg)
        self.assertIn(missing, msg)

    def test_missing_env_disc_override_raises(self):
        with mock.patch.dict(os.environ,
                             {'SUIKODEN_DISC': '/nonexistent/ws_a_x.bin'},
                             clear=True):
            with self.assertRaises(disc.DiscNotFound) as cm:
                disc.resolve()
        self.assertIn('$SUIKODEN_DISC', str(cm.exception))

    def test_missing_env_iso_override_raises(self):
        with mock.patch.dict(os.environ,
                             {'SUIKODEN_ISO': '/nonexistent/ws_a_x.iso'},
                             clear=True):
            with self.assertRaises(disc.DiscNotFound) as cm:
                disc.resolve()
        self.assertIn('$SUIKODEN_ISO', str(cm.exception))

    def test_missing_override_raises_for_resolve_raw(self):
        with mock.patch.dict(os.environ,
                             {'SUIKODEN_DISC': '/nonexistent/ws_a_x.bin'},
                             clear=True):
            with self.assertRaises(disc.DiscNotFound):
                disc.resolve_raw()

    def test_missing_explicit_path_raises_for_geometry(self):
        with self.assertRaises(disc.DiscNotFound):
            disc.geometry(os.path.join(self.tmp, 'nope.bin'))

    def test_env_override_is_honoured(self):
        payloads = random_payloads(2)
        iso = write_iso(self.path('chosen.iso'), payloads)
        with mock.patch.dict(os.environ, {'SUIKODEN_DISC': iso}, clear=True):
            resolved, sector, off = disc.resolve()
            self.assertEqual(resolved, iso)
            self.assertEqual((sector, off), (2048, 0))

    def test_path_argument_outranks_env(self):
        payloads = random_payloads(2)
        binp = write_mode2(self.path('chosen.bin'), payloads)
        isop = write_iso(self.path('other.iso'), payloads)
        with mock.patch.dict(os.environ, {'SUIKODEN_DISC': isop}, clear=True):
            resolved, sector, _off = disc.resolve(binp)
        self.assertEqual(resolved, binp)
        self.assertEqual(sector, 2352)

    def test_auto_search_without_override(self):
        with default_env_cleared():
            try:
                resolved, _sector, _off = disc.resolve()
            except disc.DiscNotFound as ex:
                self.skipTest('no disc in default locations: %s'
                              % str(ex).splitlines()[0])
            self.assertTrue(os.path.isfile(resolved))
            self.assertIn(os.path.abspath(resolved),
                          [os.path.abspath(c) for c in disc._default_candidates()])


class TestGeometryValidation(DiscTestBase):
    """A3: geometry comes from the extension but is validated against size."""

    def test_iso_sized_bin_is_rejected(self):
        for n in (ISO_SECTOR, 2 * ISO_SECTOR):
            with self.subTest(size=n):
                p = self.path('fake_%d.bin' % n)
                with open(p, 'wb') as f:
                    f.write(b'\x00' * n)
                with self.assertRaises(disc.GeometryError):
                    disc.resolve(p)

    def test_raw_sized_iso_is_rejected(self):
        p = self.path('raw.iso')
        with open(p, 'wb') as f:
            f.write(b'\x00' * MODE2_SECTOR)
        with self.assertRaises(disc.GeometryError):
            disc.resolve(p)

    def test_empty_image_is_rejected(self):
        for name in ('empty.bin', 'empty.iso'):
            with self.subTest(name=name):
                p = self.path(name)
                with open(p, 'wb'):
                    pass
                with self.assertRaises(disc.GeometryError):
                    disc.resolve(p)

    def test_valid_bin_geometry(self):
        payloads = random_payloads(3)
        p = write_mode2(self.path('ok.bin'), payloads)
        self.assertEqual(disc.resolve(p)[1:], (2352, 24))

    def test_valid_iso_geometry(self):
        p = write_iso(self.path('ok.iso'), random_payloads(3))
        self.assertEqual(disc.resolve(p)[1:], (2048, 0))

    def test_unknown_extension_mode2_detected_by_sync(self):
        payloads = random_payloads(3)
        p = write_mode2(self.path('noext'), payloads, sync=True)
        self.assertEqual(disc.resolve(p)[1:], (2352, 24))

    def test_unknown_extension_iso_detected_by_size(self):
        p = write_iso(self.path('noext2'), random_payloads(3))
        self.assertEqual(disc.resolve(p)[1:], (2048, 0))

    def test_unknown_extension_size_matching_neither_is_rejected(self):
        p = self.path('junk')
        with open(p, 'wb') as f:
            f.write(b'\x11' * 5000)  # not a multiple of 2048 or 2352, no sync
        with self.assertRaises(disc.DiscNotFound):
            disc.resolve(p)

    def test_truncated_raw_dump_keeps_raw_geometry(self):
        # 2 whole sectors + 24-byte header + 100 payload bytes of a partial third
        p = write_mode2(self.path('trunc.bin'), random_payloads(2),
                        sync=True, tail=bytes(MODE2_HEADER) + bytes(100))
        self.assertEqual(disc.resolve(p)[1:], (2352, 24))

    def test_truncated_iso_keeps_iso_geometry(self):
        p = self.path('trunc.iso')
        with open(p, 'wb') as f:
            f.write(b'\x22' * (ISO_SECTOR + 100))
        self.assertEqual(disc.resolve(p)[1:], (2048, 0))


class TestBoundsAndLba(DiscTestBase):
    """A4: no partial-sector splicing, no negative LBAs."""

    def setUp(self):
        super().setUp()
        self.payloads = random_payloads(2)
        # two whole sectors plus a partial third sector holding 100 payload bytes
        self.trunc = write_mode2(self.path('trunc.bin'), self.payloads,
                                 sync=True,
                                 tail=bytes(MODE2_HEADER) + bytes([0x33]) * 100)
        self.whole = write_mode2(self.path('whole.bin'), self.payloads, sync=True)

    def test_partial_final_sector_overrun_raises(self):
        with self.assertRaises(disc.ShortReadError) as cm:
            disc.extract(0, 2 * ISO_SECTOR + 101, self.trunc)
        self.assertIn('partial', str(cm.exception).lower())

    def test_bytes_present_in_partial_sector_are_returned_intact(self):
        size = 2 * ISO_SECTOR + 100
        got = disc.extract(0, size, self.trunc)
        self.assertEqual(got, b''.join(self.payloads) + bytes([0x33]) * 100)

    def test_read_past_whole_sector_end_raises(self):
        with self.assertRaises(disc.ShortReadError):
            disc.extract(2, 2 * ISO_SECTOR, self.whole)

    def test_negative_lba_raises_short_read_subclass(self):
        with self.assertRaises(disc.NegativeLbaError) as cm:
            disc.extract(-1, 2048, self.whole)
        self.assertIsInstance(cm.exception, disc.ShortReadError)

    def test_negative_size_raises(self):
        with self.assertRaises(disc.ShortReadError):
            disc.extract(0, -1, self.whole)

    def test_zero_size_returns_empty(self):
        self.assertEqual(disc.extract(0, 0, self.whole), b'')

    def test_multisector_unaligned_read(self):
        n = ISO_SECTOR + 700
        self.assertEqual(disc.extract(0, n, self.whole),
                         b''.join(self.payloads)[:n])


class TestResolveRawIdentity(DiscTestBase):
    """A2: resolve_raw must never silently hand back a different image."""

    def test_explicit_iso_raises_raw_required(self):
        iso = write_iso(self.path('only.iso'), random_payloads(2))
        with self.assertRaises(disc.RawImageRequired) as cm:
            disc.resolve_raw(iso)
        self.assertIsInstance(cm.exception, disc.DiscNotFound)
        self.assertIn('Refusing to substitute', str(cm.exception))

    def test_explicit_bin_is_honoured_exactly(self):
        binp = write_mode2(self.path('only.bin'), random_payloads(2))
        resolved, sector, off = disc.resolve_raw(binp)
        self.assertEqual(resolved, binp)
        self.assertEqual((sector, off), (2352, 24))

    def test_iso_sized_bin_is_rejected_not_switched(self):
        p = self.path('fake.bin')
        with open(p, 'wb') as f:
            f.write(b'\x00' * ISO_SECTOR)
        with self.assertRaises(disc.GeometryError):
            disc.resolve_raw(p)

    def test_auto_search_prefers_bin_and_never_returns_iso(self):
        """With no override, resolve_raw scans the default locations only."""
        with default_env_cleared():
            try:
                resolved, sector, off = disc.resolve_raw()
            except disc.DiscNotFound:
                # no raw dump in the default locations: must be a hard error,
                # never a silent .iso read
                self.skipTest('no raw .bin in default locations')
            self.assertEqual((sector, off), (2352, 24))
            self.assertTrue(resolved.lower().endswith('.bin'))
            self.assertIn(os.path.abspath(resolved),
                          [os.path.abspath(c) for c in disc._default_candidates()])

    def test_real_disc_resolves_iso_for_extract_and_bin_for_raw(self):
        bin_path = os.path.join(disc.DISC_DIR, disc.BIN_NAME)
        iso_path = os.path.join(disc.DISC_DIR, disc.ISO_NAME)
        if not (os.path.isfile(bin_path) and os.path.isfile(iso_path)):
            self.skipTest('both .bin and .iso needed for this comparison')
        with default_env_cleared():
            self.assertEqual(disc.resolve()[0], iso_path)
            self.assertEqual(disc.resolve_raw()[0], bin_path)
            # same logical span from each container, driven by tracked metadata
            with open(ISO_FILES) as f:
                rec = next(r for r in json.load(f)
                           if r['path'] == 'DATA/04_PLAY/AIL.BIN')
            from_bin = disc.extract(rec['lba'], rec['size'], bin_path)
            from_iso = disc.extract(rec['lba'], rec['size'], iso_path)
        self.assertEqual(len(from_bin), rec['size'])
        self.assertEqual(from_bin, from_iso)


class TestBootstrapSources(DiscTestBase):
    """A5: disc-only source bootstrap driven by tracked LBA metadata."""

    def run_bootstrap(self, *extra):
        cmd = [sys.executable, BOOTSTRAP] + list(extra)
        return subprocess.run(cmd, capture_output=True, text=True,
                              cwd=KIT)

    def test_list_counts_match_tracked_metadata(self):
        p = self.run_bootstrap('--list')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn('set 04_PLAY   78 files, 1317788 bytes', p.stdout)
        p2 = self.run_bootstrap('--list', '--set', 'DATA')
        self.assertEqual(p2.returncode, 0, p2.stderr)
        self.assertIn('set DATA     344 files, 41450011 bytes', p2.stdout)

    def test_refuses_to_write_into_kit_extracted(self):
        p = self.run_bootstrap('--set', '04_PLAY', '--out',
                               os.path.join(KIT, 'extracted', 'bin_overlays'))
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('must not be kit/extracted', p.stderr)

    def test_metadata_disagreement_raises(self):
        iso_files = self.path('iso.json')
        with open(iso_files, 'w') as f:
            json.dump([{'path': 'DATA/04_PLAY/X.BIN', 'lba': 100, 'size': 10,
                        'dir': False}], f)
        overlay = self.path('overlay.json')
        with open(overlay, 'w') as f:
            json.dump({'static_table': {'entries': [
                {'path': 'DATA/04_PLAY/X.BIN', 'lba': 101, 'size': 10,
                 'iso_size_match': True}]}}, f)
        p = self.run_bootstrap('--set', 'DATA', '--out', self.path('out'),
                               '--iso-files', iso_files,
                               '--overlay-table', overlay)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('METADATA ERROR', p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.path('out'),
                                                     'bootstrap_manifest.json')))

    def test_04play_extraction_matches_tracked_overlays(self):
        tracked = os.path.join(BIN_OVERLAYS, 'DATA', '04_PLAY')
        if not os.path.isdir(tracked):
            self.skipTest('tracked bin_overlays/DATA/04_PLAY not present')
        if not disc_available():
            self.skipTest('no disc image available')
        out = self.path('boot04')
        p = self.run_bootstrap('--set', '04_PLAY', '--out', out)
        if p.returncode != 0 and 'no Suikoden disc' in (p.stderr + p.stdout):
            self.skipTest('no disc image available')
        self.assertEqual(p.returncode, 0, p.stderr)
        names = sorted(os.listdir(tracked))
        self.assertEqual(len(names), 78)
        for name in names:
            self.assertEqual(
                sha256_file(os.path.join(out, 'DATA', '04_PLAY', name)),
                sha256_file(os.path.join(tracked, name)),
                'byte mismatch for %s' % name)
        with open(os.path.join(out, 'bootstrap_manifest.json')) as f:
            manifest = json.load(f)
        self.assertEqual(manifest['file_count'], 78)
        self.assertEqual(manifest['total_bytes'], 1317788)
        for entry in manifest['files']:
            self.assertFalse(entry['path'].startswith('/'))
            self.assertNotIn('..', entry['path'].split('/'))
            self.assertNotIn('\\', entry['path'])
            self.assertIn('sha256', entry)
            self.assertGreaterEqual(entry['lba'], 0)

    def test_rerun_into_same_dir_is_idempotent(self):
        if not disc_available():
            self.skipTest('no disc image available')
        out = self.path('boot_idem')
        first = self.run_bootstrap('--set', '04_PLAY', '--out', out)
        if first.returncode != 0 and 'no Suikoden disc' in (first.stderr
                                                            + first.stdout):
            self.skipTest('no disc image available')
        self.assertEqual(first.returncode, 0, first.stderr)
        manifest_path = os.path.join(out, 'bootstrap_manifest.json')
        with open(manifest_path, 'rb') as f:
            before = f.read()
        second = self.run_bootstrap('--set', '04_PLAY', '--out', out)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn('reused 78', second.stdout)
        with open(manifest_path, 'rb') as f:
            self.assertEqual(f.read(), before,
                             'manifest must be deterministic across re-runs')


if __name__ == '__main__':
    unittest.main(verbosity=2)
