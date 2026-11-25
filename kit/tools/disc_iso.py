#!/usr/bin/env python3
"""Shared ISO listing, MAIN.EXE loading, and strict 16 KB LZSS decode helpers.

Wraps ``disc`` and ``lzss`` without modifying those hash-tracked modules.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from lzss import LZSSError, decode as lzss_decode

MAIN_HEADER = 2048
_KIT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_ISO_FILES = _KIT_DIR / "extracted" / "iso_files.json"

__all__ = [
    "MAIN_HEADER",
    "DEFAULT_ISO_FILES",
    "iso_records",
    "iso_record",
    "extract_path",
    "main_image",
    "lzss_decode_16k",
]


def iso_records(iso_path: str | os.PathLike[str] | None = None, *, include_dirs: bool = False) -> list[dict]:
    """Return entries from iso_files.json (files only unless include_dirs=True)."""
    path = DEFAULT_ISO_FILES if iso_path is None else Path(iso_path)
    with path.open(encoding="utf-8") as handle:
        records = json.load(handle)
    if include_dirs:
        return records
    return [record for record in records if not record.get("dir")]


def iso_record(rel_path: str, iso_path: str | os.PathLike[str] | None = None) -> dict:
    """Find a file record in iso_files.json by exact path."""
    for record in iso_records(iso_path, include_dirs=False):
        if record.get("path") == rel_path:
            return record
    raise KeyError(f"{rel_path} not in ISO listing")


def extract_path(
    rel_path: str,
    iso_path: str | os.PathLike[str] | None = None,
    disc_path: str | None = None,
) -> bytes:
    """Extract a disc file by ISO path."""
    from disc import extract

    record = iso_record(rel_path, iso_path=iso_path)
    return extract(record["lba"], record["size"], path=disc_path)


def main_image(
    iso_path: str | os.PathLike[str] | None = None,
    disc_path: str | None = None,
) -> bytes:
    """MAIN.EXE body with the 2048-byte PS-X EXE header stripped."""
    return extract_path("MAIN.EXE", iso_path=iso_path, disc_path=disc_path)[MAIN_HEADER:]


def lzss_decode_16k(payload: bytes) -> bytes | None:
    """Strict 16 KB stream decode returning None on stream/length mismatch."""
    try:
        out, consumed = lzss_decode(bytes(payload))
    except LZSSError:
        return None
    if consumed != len(payload) or len(out) != 16384:
        return None
    return out
