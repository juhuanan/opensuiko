#!/usr/bin/env python3
"""
iso_extract.py — extract files from the Suikoden disc image by LBA.

Thin wrapper over tools/disc.py, which is the single source of truth for
locating and reading the disc. disc.py auto-detects the container:

    .bin  MODE2/2352, 2048-byte payload starting at sector offset 24
    .iso  ISO9660,    2048-byte payload at offset 0

and honours $SUIKODEN_DISC. Both layouts present the same logical addressing:
LBA in, payload bytes out. This module no longer opens the image itself and no
longer hardcodes a path.

Usage:
  python3 iso_extract.py <lba> <num_bytes> -o <output_file>
  python3 iso_extract.py --lba 18698 --size 91443 -o work/BATTLE.BIN

Short reads FAIL LOUDLY: extract() raises ShortReadError and the CLI exits
non-zero with an error message. Truncated output is never written silently.

Guarantees inherited from disc.py (2026-10-04):

* An explicit image (this module's default resolve, disc.extract's `path`, or
  $SUIKODEN_DISC/$SUIKODEN_ISO) must exist; a missing override raises instead of
  silently resolving a different image.
* The container geometry is validated against the file size: a 2048-B/sector
  ISO named `.bin` (or vice versa) raises GeometryError rather than being read
  with a 24-byte shift.
* A read that would run past the end of the image -- including a miss inside a
  partially-present final sector -- raises ShortReadError; a negative LBA raises
  NegativeLbaError (a ShortReadError subclass). Nothing is ever spliced.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import disc  # noqa: E402
from disc import DiscNotFound, ShortReadError  # noqa: E402

# Back-compat module constants. Geometry is resolved by disc.py, never assumed;
# SECTOR/PAYLOAD_OFF describe the resolved image (None if no disc is present).
try:
    ISO, SECTOR, PAYLOAD_OFF = disc.resolve()
except DiscNotFound:
    ISO, SECTOR, PAYLOAD_OFF = None, None, None


def extract(lba: int, size: int) -> bytes:
    """Extract `size` payload bytes starting at `lba` (sector headers skipped).

    Raises ShortReadError if the image ends before `size` bytes are read —
    short reads are never silently truncated.
    """
    return disc.extract(lba, size)


def main():
    ap = argparse.ArgumentParser(description="Extract bytes from the Suikoden disc image")
    ap.add_argument("lba", type=int, nargs="?", help="Starting LBA")
    ap.add_argument("size", type=int, nargs="?", help="Number of payload bytes to extract")
    ap.add_argument("--lba", dest="lba_kw", type=int, default=None)
    ap.add_argument("--size", dest="size_kw", type=int, default=None)
    ap.add_argument("-o", "--output", required=True, help="Output file")
    args = ap.parse_args()

    lba = args.lba_kw if args.lba_kw is not None else args.lba
    size = args.size_kw if args.size_kw is not None else args.size
    if lba is None or size is None:
        ap.error("need lba and size")

    try:
        data = extract(lba, size)
    except (DiscNotFound, ShortReadError) as ex:
        print("ERROR: %s" % ex, file=sys.stderr)
        sys.exit(1)
    os.makedirs(os.path.dirname(os.path.abspath(args.output)), exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(data)
    print(f"Extracted {len(data)} bytes from LBA {lba} -> {args.output}")


if __name__ == "__main__":
    main()
