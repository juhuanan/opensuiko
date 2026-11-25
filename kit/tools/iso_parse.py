#!/usr/bin/env python3
"""Parse the ISO9660 filesystem of the Suikoden disc image into a file listing.

All reads go through tools/disc.py (LBA in, 2048-byte payload out), so this
works whether the image is a MODE2/2352 .bin or an ISO9660 .iso. Nothing is
read or written at import time; run main() (the CLI) to produce the listing.

Usage:
    python3 iso_parse.py [-o kit/extracted/iso_files.json] [--disc IMAGE]
"""

import argparse
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import disc  # noqa: E402

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUT = os.path.join(KIT, "extracted", "iso_files.json")
SECTOR = 2048

# Explicit image override (--disc); None lets disc.py resolve (.iso/.bin/$SUIKODEN_DISC).
DISC = None

# KNOWN-STALE ASCII DETECTOR (documented, not silently swallowed).
# The historical test used str.isprint(), which does not exist on str, so the
# "text" branch could never fire and every ASCII-ish file was classified
# "binary" in the tracked kit/extracted/iso_files.json. Leaving this False keeps
# the tool reproducing that tracked listing byte-for-byte; set it True to run
# the real printable-ASCII test (that WILL change the generated listing).
ASCII_TEXT_DETECTION = False


def read_sector(lba):
    return disc.extract(lba, SECTOR, DISC)


def parse_dir_record(rec):
    """rec: bytes of one directory record. Returns dict or None if padding/empty."""
    if len(rec) < 33 or rec[0] == 0:
        return None
    length = rec[0]
    flags = rec[25]
    lba = struct.unpack("<I", rec[2:6])[0]
    size = struct.unpack("<I", rec[10:14])[0]
    namelen = rec[32]
    name = rec[33:33+namelen]
    if namelen == 1 and name[0] == 0x00:
        disp = "."
    elif namelen == 1 and name[0] == 0x01:
        disp = ".."
    else:
        # keep the raw name; the version suffix is handled by the caller
        disp = name.decode("ascii", errors="replace")
    return {"len": length, "flags": flags, "lba": lba, "size": size,
            "rawname": disp}


def walk_dir(lba, size):
    entries = []
    data = b""
    nsec = (size + 2047) // 2048
    for i in range(nsec):
        data += read_sector(lba + i)
    data = data[:size]
    off = 0
    while off < len(data):
        if data[off] == 0:
            # pad to next sector boundary
            off = ((off // 2048) + 1) * 2048
            continue
        rec = parse_dir_record(data[off:off + data[off]])
        if rec is None:
            off += 1
            continue
        entries.append(rec)
        off += rec["len"]
    return entries


def strip_version(raw):
    # ISO9660 ";1" version suffix
    if ";" in raw:
        raw = raw.split(";")[0]
    return raw


def magic_of(lba, size, name=""):
    if size == 0:
        return ("empty", "")
    head = read_sector(lba)[:32]
    m = head
    if m.startswith(b"PS-X EXE"):
        return ("PS-X EXE", "PS-X EXE")
    if m[:4] == b"pQES":
        return ("SEQ music", "pQES")
    if m[:4] == b"pQBV":
        return ("SEQ music", "pQBV")
    if m[:4] == b"SEPd":
        return ("SEP music", "SEPd")
    if m[:4] == b"pBAV":
        return ("VAB header", "pBAV")
    if name.endswith(".VB") and m[:4] == b"\x00\x00\x00\x00":
        return ("VAB body", "VAG samples")
    if m[:2] == b"RI" and m[8:12] == b"CDXA":
        return ("XA audio", "RIFF/CDXA")
    if m[:4] == b"\x60\x01\x01\x80":
        return ("STR video", "chunk hdr")
    if m[:4] == bytes([0x10, 0, 0, 0]) and name.endswith(".TIM"):
        return ("TIM image", "0x10 00 00 00")
    if m.startswith(b"CD-ROM Generator"):
        return ("CCS script", "CD-ROM Gen")
    if name.endswith(".STR") or "XA1." in name or name.endswith(".XA"):
        # name-driven: these are known PS-X streaming formats
        if name.endswith(".STR"):
            return ("STR video", "by name")
        return ("XA audio", "by name")
    # raw XA sectors: subheader pattern at sector offset 18..23
    if len(m) >= 24 and m[18:20] == b"\x00\x10" and m[22] in (0x60, 0x61, 0x64):
        return ("XA audio", "raw sectors")
    # MIPS code: first word looks like a RAM pointer in 0x80000000-0x80200000
    # or a standard stack-frame prologue 27 BD xx xx
    w0 = struct.unpack("<I", m[:4])[0]
    if m[:2] == b"\x27\xbd" or (0x80000000 <= w0 < 0x80200000):
        return ("MIPS overlay", "0x%08x" % w0)
    if ASCII_TEXT_DETECTION:
        try:
            txt = m.decode("ascii")
        except UnicodeDecodeError:
            txt = None
        if txt is not None and all(c.isprintable() or c in "\t\r\n" for c in txt):
            return ("text", txt[:24].replace("\n", "\\n").replace("\r", "\\r"))
    return ("binary", m[:8].hex(" "))


def collect_files(root_lba, root_size):
    """Walk the directory tree, returning the flat ISO9660 file record list."""
    files = []

    def walk(lba, size, prefix):
        for e in walk_dir(lba, size):
            name = strip_version(e["rawname"])
            if name in (".", ".."):
                continue
            path = prefix + "/" + name if prefix else name
            isdir = bool(e["flags"] & 2)
            files.append({"path": path, "lba": e["lba"], "size": e["size"],
                          "dir": isdir})
            if isdir:
                walk(e["lba"], e["size"], path)

    walk(root_lba, root_size, "")
    return files


def build_listing():
    """Parse the ISO9660 tree and classify every file. Returns the file list."""
    pvd = read_sector(16)
    assert pvd[0] == 1 and pvd[1:6] == b"CD001", "not a PVD"
    print("Volume ID:", pvd[40:72].decode("ascii").rstrip())
    root = parse_dir_record(pvd[156:156+34])
    print("Root dir LBA:", root["lba"], "size:", root["size"])

    files = collect_files(root["lba"], root["size"])
    for f in files:
        if not f["dir"]:
            t, detail = magic_of(f["lba"], f["size"], f["path"])
            f["type"] = t
            f["magic"] = detail
        else:
            f["type"] = "dir"
            f["magic"] = ""
    return files


def main(argv=None):
    global DISC
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--disc", default=None, help="explicit .bin/.iso image path")
    ap.add_argument("-o", "--output", default=DEFAULT_OUT,
                    help="output JSON path (default: %(default)s)")
    args = ap.parse_args(argv)
    DISC = args.disc

    files = build_listing()
    with open(args.output, "w") as fh:
        json.dump(files, fh, indent=1)
    print("total records:", len(files))
    print("files:", sum(1 for f in files if not f["dir"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
