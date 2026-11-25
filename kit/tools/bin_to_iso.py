#!/usr/bin/env python3
"""bin_to_iso.py -- convert the MODE2/2352 disc dump to a plain ISO9660 image.

The raw dump is 2352-byte sectors (2352 = 12 sync + 4 header + 2048 user data +
280 EDC/ECC). Everything the kit cares about lives in the 2048-byte user field
at offset 24. Stripping that header produces a standard ISO9660 image that
every ordinary ISO tool can read, and that halves the addressing arithmetic
downstream.

This is what `work/disc_payloads.bin` (490 MB, orphaned and undocumented until
2026-10-03) turned out to be -- a 2048-byte-sector image of the whole disc.
This tool makes that artifact reproducible instead of a mystery.

Usage:
    python3 bin_to_iso.py                          # disc/*.bin -> disc/*.iso
    python3 bin_to_iso.py --bin X.bin --iso Y.iso
    python3 bin_to_iso.py --verify                 # compare existing .iso to .bin
    python3 bin_to_iso.py --verify --iso OTHER.iso # compare some other image

Checks performed:
  * input is a whole number of 2352-byte sectors
  * sector 16 carries the ISO9660 PVD magic "CD001"
  * output is a whole number of 2048-byte sectors
  * (--verify) every sector's payload matches the source byte-for-byte

Exit codes: 0 ok, 1 failure.
"""

import argparse
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from disc import BIN_NAME, ISO_NAME, DISC_DIR  # noqa: E402

SECTOR_IN = 2352
PAYLOAD_OFF = 24
SECTOR_OUT = 2048
CHUNK_SECTORS = 4096


def _fail(msg):
    print("FAIL: %s" % msg, file=sys.stderr)
    return 1


def load_sector_headers(bin_path):
    """Return (n_sectors, payload_off) validating the sector size."""
    size = os.path.getsize(bin_path)
    if size % SECTOR_IN != 0:
        raise ValueError(
            "not a MODE2/2352 image: %d bytes is not a multiple of %d"
            % (size, SECTOR_IN))
    return size // SECTOR_IN, PAYLOAD_OFF


def check_pvd(iso_path):
    """Verify the ISO9660 primary volume descriptor at logical sector 16."""
    with open(iso_path, "rb") as f:
        f.seek(16 * SECTOR_OUT)
        vd = f.read(2048)
    if len(vd) < 2048:
        return False, "file too short to hold a volume descriptor"
    if vd[1:6] != b"CD001":
        return False, "sector 16 magic is %r, expected b'CD001'" % vd[1:6]
    vol_space = int.from_bytes(vd[80:84], "little")
    block = int.from_bytes(vd[128:130], "little")
    vol_id = vd[40:72].decode("ascii", "replace").strip()
    return True, "PVD ok: volume_id=%r logical_block=%d volume_space=%d sectors" % (
        vol_id or "", block, vol_space)


def convert(bin_path, iso_path):
    """Strip the 304-byte sector header from every sector.

    Reads whole blocks of `CHUNK_SECTORS` sectors and slices the 2048-byte
    user field out of each, which keeps the syscall count low without the
    per-sector seek arithmetic that is easy to get wrong.
    """
    n_sectors, off = load_sector_headers(bin_path)
    tmp = iso_path + ".part"
    h = hashlib.sha256()
    written = 0
    with open(bin_path, "rb") as fin, open(tmp, "wb") as fout:
        done = 0
        while done < n_sectors:
            take = min(CHUNK_SECTORS, n_sectors - done)
            raw = fin.read(take * SECTOR_IN)
            if len(raw) != take * SECTOR_IN:
                os.unlink(tmp)
                raise ValueError(
                    "truncated read at sector %d (got %d of %d bytes)"
                    % (done, len(raw), take * SECTOR_IN))
            buf = bytearray()
            for i in range(take):
                base = i * SECTOR_IN + off
                buf += raw[base:base + SECTOR_OUT]
            fout.write(buf)
            h.update(buf)
            written += len(buf)
            done += take
    if written != n_sectors * SECTOR_OUT:
        os.unlink(tmp)
        raise ValueError("wrote %d bytes, expected %d"
                         % (written, n_sectors * SECTOR_OUT))
    os.replace(tmp, iso_path)
    return n_sectors, written, h.hexdigest()


def verify(bin_path, iso_path):
    """Byte-compare every sector payload between .bin and .iso."""
    n_sectors, off = load_sector_headers(bin_path)
    if os.path.getsize(iso_path) != n_sectors * SECTOR_OUT:
        return False, ("size mismatch: %s is %d bytes, expected %d"
                       % (iso_path, os.path.getsize(iso_path),
                          n_sectors * SECTOR_OUT))
    with open(bin_path, "rb") as fb, open(iso_path, "rb") as fi:
        for lba in range(n_sectors):
            fb.seek(lba * SECTOR_IN + off)
            a = fb.read(SECTOR_OUT)
            b = fi.read(SECTOR_OUT)
            if a != b:
                return False, "first mismatch at LBA %d" % lba
    return True, "all %d sectors match byte-for-byte" % n_sectors


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Convert MODE2/2352 .bin to ISO9660 .iso")
    ap.add_argument("--bin", default=os.path.join(DISC_DIR, BIN_NAME))
    ap.add_argument("--iso", default=os.path.join(DISC_DIR, ISO_NAME))
    ap.add_argument("--verify", action="store_true",
                    help="do not convert; compare --iso against --bin")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.bin):
        return _fail("input image not found: %s" % args.bin)

    try:
        if args.verify:
            if not os.path.isfile(args.iso):
                return _fail("nothing to verify: %s missing" % args.iso)
            ok, msg = verify(args.bin, args.iso)
            print(("OK   " if ok else "FAIL ") + msg)
            if not ok:
                return 1
            ok, msg = check_pvd(args.iso)
            print(("OK   " if ok else "FAIL ") + msg)
            return 0 if ok else 1

        n_sectors, written, digest = convert(args.bin, args.iso)
        print("converted %d sectors -> %d bytes" % (n_sectors, written))
        print("wrote   %s" % args.iso)
        print("sha256  %s" % digest)
        ok, msg = check_pvd(args.iso)
        print(("OK   " if ok else "FAIL ") + msg)
        if not ok:
            return 1
        ok, msg = verify(args.bin, args.iso)
        print(("OK   " if ok else "FAIL ") + msg)
        return 0 if ok else 1
    except ValueError as ex:
        return _fail(str(ex))


if __name__ == "__main__":
    sys.exit(main())
