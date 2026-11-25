#!/usr/bin/env python3
"""disc.py -- single source of truth for locating and reading the Suikoden disc.

Every tool that needs disc bytes imports this module instead of hardcoding a
path. This replaces the old scattered `/home/hatch/workspace/suikoden/...` and
`~/workspace/suikoden/...` constants.

Two container layouts are supported. The geometry is chosen by file extension
and then VALIDATED against the actual file size; a size that is an exact whole
number of the other container's sectors (a 2048-B/sector ISO named `.bin`, a raw
dump named `.iso`) is refused as a container mixup instead of being read as
shifted garbage:

    .bin  MODE2/2352  raw dump -- 2352-byte sectors, 2048-byte Form 1 user
                      payload starting at byte offset 24 of each sector.
    .iso  ISO9660     plain 2048-byte sectors, payload at offset 0.
                      Produced from the .bin by tools/bin_to_iso.py.

Files with an unrecognised extension are sniffed: the 12-byte MODE2 sync
pattern (00 FF*10 00) at offset 0 plus a size divisible by 2352 identifies a raw
dump; a size divisible by 2048 identifies ISO9660. Ambiguity is resolved in
favour of MODE2 only with the sync signature, never by guessing. A size
divisible by neither sector size is accepted as a truncated dump of the named
container -- reads past the present bytes raise ShortReadError (see extract()).

Resolution order (strict -- see below):

    1. an explicit `path` argument (e.g. iso_parse.py --disc)
    2. $SUIKODEN_DISC, then $SUIKODEN_ISO
    3. <project>/disc/Suikoden (v1.1).iso
    4. <project>/disc/Suikoden (v1.1).bin
    5. legacy locations      ~/workspace/suikoden/... , /home/hatch/...
       (kept only so older notes reproduce on the machine that wrote them)

STRICT EXPLICIT SELECTION (2026-10-04): if a `path` argument or an environment
override is supplied, that exact file must exist and be readable as a disc
image. A missing override raises DiscNotFound immediately and the automatic
search is NOT attempted -- otherwise `SUIKODEN_DISC=/typo.bin` would silently
resolve a completely different image. Automatic search applies only when no
override was supplied at all.

Form 1 vs Form 2 (MIXED-MODE disc; 567 Form 1 / 29 Form 2 sectors sampled):

  * ``extract()`` returns the *logical byte stream*: 2048 user bytes per sector
    for BOTH containers. For a MODE2/2352 image that is the Form 1 user field at
    sector offset 24; the 280 EDC/ECC bytes are not part of the logical stream
    and are never returned. This makes .bin and .iso byte-identical per LBA.
  * Form 2 sectors (XA audio, STR video) carry a 2324-byte user field instead.
    Nothing in ``extract()``'s logical stream can express those bytes, so a tool
    that needs subheaders or the Form 2 field must use ``resolve_raw()`` and read
    2352-byte sectors itself (see str_decode.py). ``resolve_raw()`` never
    substitutes a different container/image for an explicit selection.

Usage:
    from disc import extract, resolve, resolve_raw, DiscNotFound, ShortReadError

    data = extract(18698, 91443)          # LBA 18698, 91443 payload bytes
    path, sector, off = resolve()         # which image, what geometry
    path, sector, off = resolve_raw()     # raw MODE2/2352 for subheader access

CLI:
    python3 disc.py                       # report which image resolves
    python3 disc.py --extract LBA SIZE -o OUT

Exit codes: 0 success, 1 disc not found / bad geometry / short read.
"""

import argparse
import os
import sys

__all__ = [
    "DiscError", "DiscNotFound", "GeometryError", "RawImageRequired",
    "ShortReadError", "NegativeLbaError",
    "resolve", "resolve_raw", "geometry", "extract", "extract_to", "info",
    "BIN_NAME", "ISO_NAME", "PAYLOAD_BYTES", "MODE2_SYNC",
]

BIN_NAME = "Suikoden (v1.1).bin"
ISO_NAME = "Suikoden (v1.1).iso"

# (sector_size, payload_offset) by extension
GEOMETRY = {".bin": (2352, 24), ".iso": (2048, 0)}

# The canonical raw geometry returned by resolve_raw().
RAW_SECTOR, RAW_OFFSET = 2352, 24

# MODE2 sync pattern at byte 0 of every 2352-byte raw sector.
MODE2_SYNC = bytes.fromhex("00ffffffffffffffffffff00")

# Logical payload bytes per sector, by extension. A MODE2/2352 Form 1 sector
# carries 2048 user bytes at offset 24; the remaining 280 bytes are EDC/ECC and
# are NOT part of the logical byte stream. Reading `sector - off` (2328) spliced
# that trailer into the output and shifted every byte after the first sector, so
# .bin and .iso disagreed from output byte 2048 onward. Form 2 sectors (XA audio,
# STR video) have a 2324-byte user field; a tool that needs those bytes must go
# through resolve_raw(), which hands back the full 2352-byte sectors.
PAYLOAD_BYTES = {".bin": 2048, ".iso": 2048}

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
KIT_DIR = os.path.dirname(TOOLS_DIR)
PROJECT_ROOT = os.path.dirname(KIT_DIR)
DISC_DIR = os.path.join(PROJECT_ROOT, "disc")


class DiscError(IOError):
    """Base class for every disc-layer failure."""


class DiscNotFound(DiscError):
    """No usable disc image could be located. Message lists everywhere we looked."""


class GeometryError(DiscNotFound):
    """An image exists but its size contradicts its container geometry.

    Subclasses DiscNotFound so existing `except DiscNotFound` callers (and the
    CLIs) keep failing loudly instead of tracebacking.
    """


class RawImageRequired(DiscNotFound):
    """A MODE2/2352 .bin was required, but the resolved image is ISO9660.

    Subclasses DiscNotFound for the same reason as GeometryError. Raised instead
    of silently reading a different file's sectors.
    """


class ShortReadError(DiscError):
    """The image ended before the requested payload was fully read."""


class NegativeLbaError(ShortReadError):
    """A negative LBA was requested. Documented subclass of ShortReadError."""


def _default_candidates():
    """Automatic-search locations, in order. Environment overrides are NOT here."""
    return [
        os.path.join(DISC_DIR, ISO_NAME),
        os.path.join(DISC_DIR, BIN_NAME),
        # legacy/foreign locations -- last resort only
        os.path.expanduser("~/workspace/suikoden/" + BIN_NAME),
        os.path.expanduser("~/workspace/suikoden/" + ISO_NAME),
        "/home/hatch/workspace/suikoden/" + BIN_NAME,
        "/home/hatch/workspace/suikoden/" + ISO_NAME,
    ]


def _env_override():
    """(value, source_name) for $SUIKODEN_DISC / $SUIKODEN_ISO, or None."""
    for var in ("SUIKODEN_DISC", "SUIKODEN_ISO"):
        val = os.environ.get(var)
        if val:
            return val, "$" + var
    return None


def _override(path):
    """The single explicit selection, or None for automatic search.

    An explicit `path` argument outranks the environment. Exactly one override
    is honoured: an override that does not exist is an error, never a licence to
    try a different override or fall back to the automatic search.
    """
    if path:
        return path, "path argument"
    return _env_override()


def _candidates():
    """Legacy combined list (env first, then defaults). Used for search-list
    messages; resolve()/resolve_raw() do NOT scan it blindly any more."""
    out = []
    env = _env_override()
    if env:
        out.append(env[0])
    return out + _default_candidates()


def _detect_geometry(path):
    """Return (sector_size, payload_offset) for `path`, validated against size.

    Extension first, then a size validation that separates two very different
    cases (2026-10-04):

      * a size that is an exact whole number of the OTHER container's sectors is
        the container-mixup trap (a 2048-B/sector ISO named `.bin`, a raw dump
        named `.iso`) -- GeometryError, because reading it as the named
        geometry would yield shifted garbage;
      * a size divisible by neither sector size is treated as a truncated dump
        of the named container: the geometry is still the extension's (never
        silently switched) and every read is bounds-checked in extract(), which
        raises ShortReadError rather than splicing a partial final sector.

    An unknown extension is sniffed: the 12-byte MODE2 sync signature at byte 0
    positively identifies a raw dump; otherwise size divisibility decides, with
    ISO9660 preferred only when 2352 cannot apply.

    Raises GeometryError if the file cannot possibly be the named container and
    DiscNotFound if an extensionless file matches no known layout.
    """
    size = os.path.getsize(path)
    if size <= 0:
        raise GeometryError(
            "disc image %r is empty (size 0); refusing to use it" % path)
    ext = os.path.splitext(path)[1].lower()

    if ext in GEOMETRY:
        sector, off = GEOMETRY[ext]
        other = 2048 if sector == 2352 else 2352
        if size % sector == 0:
            return sector, off
        if size % other == 0:
            raise GeometryError(
                "disc image %r is named %s (%d B/sector) but its size %d is an "
                "exact whole number of %d-byte sectors -- probable container "
                "mixup (an ISO named .bin or a raw dump named .iso); refusing "
                "to read shifted garbage" % (path, ext, sector, size, other))
        # Divisible by neither: assume a truncated dump of the named container.
        # extract() bounds-checks every read and raises ShortReadError.
        return sector, off

    # Unknown extension: sniff the layout from the bytes and the size.
    with open(path, "rb") as f:
        head = f.read(len(MODE2_SYNC))
    if head == MODE2_SYNC and size >= RAW_SECTOR:
        # Positive MODE2 signature: trust the bytes over the size, so that a
        # truncated raw dump is still addressable sector by sector.
        return 2352, 24
    if size % 2352 == 0 and size % 2048 != 0:
        return 2352, 24
    if size % 2048 == 0:
        return 2048, 0
    if size % 2352 == 0:
        return 2352, 24
    raise DiscNotFound(
        "found %r but cannot determine its sector geometry (size %d is not a "
        "multiple of 2048 or 2352 and there is no MODE2 sync signature)"
        % (path, size))


def resolve(path=None):
    """Return (path, sector_size, payload_offset) for the disc image.

    An explicit `path` argument or an environment override must exist; a missing
    override raises DiscNotFound listing exactly what was asked for, and no
    automatic search is performed. Without an override the default locations are
    searched (the .iso is preferred for ``extract()`` because both containers
    give identical logical bytes; use resolve_raw() when raw sectors are needed).

    Raises DiscNotFound with the full search list if nothing usable exists, and
    GeometryError (a DiscNotFound subclass) if a file's size contradicts its
    geometry.
    """
    over = _override(path)
    if over is not None:
        cand, source = over
        if not os.path.isfile(cand):
            raise DiscNotFound(
                "explicit disc image not found: %r (from %s). Automatic search "
                "was NOT attempted because an explicit selection was supplied; "
                "fix or unset the override.\nSearched:\n  %s"
                % (cand, source, cand))
        sector, off = _detect_geometry(cand)
        return cand, sector, off

    tried = []
    for cand in _default_candidates():
        tried.append(cand)
        if os.path.isfile(cand):
            sector, off = _detect_geometry(cand)
            return cand, sector, off
    raise DiscNotFound(
        "no Suikoden disc image found. Set $SUIKODEN_DISC to the .bin or .iso, "
        "or place it at %s\nSearched:\n  %s"
        % (os.path.join(DISC_DIR, ISO_NAME), "\n  ".join(tried)))


def resolve_raw(path=None):
    """Return (path, 2352, 24) -- the RAW MODE2/2352 image, for tools that need
    subheader bytes (STR sector headers, XA, CD-XA stream parsing, the 2324-byte
    Form 2 user field that extract() cannot express).

    Container honesty (2026-10-04): the returned path is never a different image
    than the one that was selected.

      * With an explicit `path` / $SUIKODEN_DISC / $SUIKODEN_ISO, that exact
        file must resolve AND must be raw MODE2/2352; otherwise this raises
        (RawImageRequired for an .iso, GeometryError for a bad size). It will
        not walk off to some other .bin.
      * With no override, the automatic search deliberately prefers a raw .bin
        among the default locations, because an .iso cannot carry subheaders.
        If only an .iso is present that is a hard error -- subheaders are never
        synthesised. (This is the one documented case where resolve_raw() may
        return a different file than resolve() would: resolve() prefers the
        .iso, resolve_raw() must have the .bin.)

    The old dead `prefer_bin` argument is removed; callers that need to force a
    specific container should pass it explicitly (or set $SUIKODEN_DISC).
    """
    over = _override(path)
    if over is not None:
        img, sector, off = resolve(path)  # strict: honoured or raises
        if (sector, off) == (RAW_SECTOR, RAW_OFFSET):
            return img, RAW_SECTOR, RAW_OFFSET
        raise RawImageRequired(
            "resolve_raw() needs the raw MODE2/2352 image, but the explicitly "
            "selected image is %s (%d B/sector, payload offset %d). Subheader "
            "and Form 2 bytes do not exist in an ISO9660 .iso; pass the .bin via "
            "$SUIKODEN_DISC or the path argument. Refusing to substitute a "
            "different file." % (img, sector, off))

    seen = []
    for cand in _default_candidates():
        if not os.path.isfile(cand):
            continue
        try:
            sector, off = _detect_geometry(cand)
        except DiscNotFound as ex:
            seen.append("%s (%s)" % (cand, str(ex).splitlines()[0]))
            continue
        if (sector, off) == (RAW_SECTOR, RAW_OFFSET):
            return cand, RAW_SECTOR, RAW_OFFSET
        seen.append("%s (%d B/sector, payload offset %d -- not raw MODE2/2352)"
                    % (cand, sector, off))
    raise DiscNotFound(
        "a raw MODE2/2352 .bin is required (subheader bytes and the Form 2 user "
        "field are not present in an .iso). Set $SUIKODEN_DISC to the .bin, or "
        "regenerate it with tools/bin_to_iso.py's inverse.\nSearched:\n  %s"
        % ("\n  ".join(seen) if seen else "\n  ".join(_default_candidates())))


def geometry(path=None):
    """Return (sector_size, payload_offset), validated against the real file.

    With no argument this is resolve()'s geometry for the auto-selected image.
    An explicit path must exist (an explicit selection is never silently
    ignored); geometry is then derived from the file's extension and size.
    """
    if path:
        if not os.path.isfile(path):
            raise DiscNotFound(
                "explicit disc image not found: %r; geometry cannot be "
                "validated without the file" % path)
        return _detect_geometry(path)
    _img, sector, off = resolve()
    return sector, off


def _payload_bytes(ext, sector, off):
    """Logical bytes per sector for the resolved geometry.

    Both supported containers carry 2048 logical bytes per sector (MODE2 Form 1
    user data / ISO9660 block). The default is 2048 rather than `sector - off`,
    because `sector - off` (2328 for a raw sector) would splice EDC/ECC into the
    stream.
    """
    return PAYLOAD_BYTES.get(ext, 2048)


def extract(lba, size, path=None):
    """Read `size` payload bytes starting at `lba` (logical byte stream).

    Payload bytes only -- mode/sector headers are skipped according to the
    validated geometry, so .bin and .iso return identical bytes for the same LBA
    (Form 1 user data; see the module docstring for Form 2).

    Bounds (2026-10-04): a read that would run past the end of the image raises
    ShortReadError, including a miss inside a partially-present final sector.
    No trailer bytes and no partial chunks are ever appended. A negative LBA
    raises NegativeLbaError (a ShortReadError subclass).
    """
    if lba < 0:
        raise NegativeLbaError(
            "negative LBA %d requested (LBAs are zero-based sector numbers)" % lba)
    if size < 0:
        raise ShortReadError("negative size %d requested" % size)

    img, sector, off = resolve(path)
    ext = os.path.splitext(img)[1].lower()
    payload = _payload_bytes(ext, sector, off)
    img_size = os.path.getsize(img)

    out = bytearray()
    cur = lba
    with open(img, "rb") as f:
        while len(out) < size:
            pos = cur * sector + off
            need = min(payload, size - len(out))
            if pos + need > img_size:
                where = ("inside a partially-present final sector"
                         if pos < img_size else "past the end of the image")
                raise ShortReadError(
                    "short read: requested %d bytes from LBA %d, got %d; need "
                    "bytes [%d, %d) from image %s (%d bytes) -- %s"
                    % (size, lba, len(out), pos, pos + need, img, img_size,
                       where))
            f.seek(pos)
            chunk = f.read(need)
            if len(chunk) != need:
                raise ShortReadError(
                    "short read: requested %d bytes from LBA %d, got %d; "
                    "image %s returned %d of %d bytes at offset %d"
                    % (size, lba, len(out), img, len(chunk), need, pos))
            out.extend(chunk)
            cur += 1
    return bytes(out)


def extract_to(lba, size, out_path, path=None):
    """extract() straight to a file, creating parent dirs. Returns byte count."""
    data = extract(lba, size, path)
    parent = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(parent, exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(data)
    return len(data)


def info(path=None):
    """Human-readable one-line summary of the resolved image."""
    try:
        img, sector, off = resolve(path)
    except DiscNotFound as ex:
        return "DISC NOT FOUND: %s" % str(ex).splitlines()[0]
    size = os.path.getsize(img)
    return "disc: %s  (%s, %d B/sector, payload off %d, %d sectors, %d bytes)" % (
        img, ".bin MODE2/2352" if sector == 2352 else ".iso ISO9660",
        sector, off, size // sector, size)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Locate and read the Suikoden disc image")
    ap.add_argument("--disc", default=None, help="explicit .bin/.iso path")
    ap.add_argument("--extract", nargs=2, type=int, metavar=("LBA", "SIZE"),
                    help="extract payload bytes")
    ap.add_argument("-o", "--output", help="output file for --extract")
    args = ap.parse_args(argv)

    print(info(args.disc))
    if args.extract:
        if not args.output:
            ap.error("--extract requires -o/--output")
        lba, size = args.extract
        try:
            n = extract_to(lba, size, args.output, args.disc)
        except (DiscNotFound, ShortReadError) as ex:
            print("ERROR: %s" % ex, file=sys.stderr)
            return 1
        print("Extracted %d bytes from LBA %d -> %s" % (n, lba, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
