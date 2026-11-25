#!/usr/bin/env python3
"""Shared canonical JSON, hashing, atomic output, and exporter CLI helpers."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_hash(path: Path) -> str:
    return sha256(path.read_bytes())


def canonical(value) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def serialize(value, *, ensure_ascii: bool = True) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=ensure_ascii) + "\n").encode()


def serialize_text(value, *, ensure_ascii: bool = True) -> str:
    return json.dumps(value, indent=2, ensure_ascii=ensure_ascii) + "\n"


def jsonl_bytes(rows) -> bytes:
    return "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows).encode()


def identified(value: dict) -> dict:
    result = dict(value)
    result["content_sha256"] = ""
    result["content_sha256"] = sha256(canonical(result))
    return result


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def sync_outputs(expected: dict[str, bytes], output_root: Path, *, check: bool) -> list[str]:
    mismatches = []
    for relative, data in expected.items():
        path = output_root / relative
        if check:
            if not path.is_file():
                mismatches.append(f"missing {relative}")
            elif path.read_bytes() != data:
                mismatches.append(f"stale {relative}")
        else:
            atomic_write(path, data)
    return mismatches


def run_exporter(
    argv: list[str] | None,
    *,
    root: Path,
    description: str | None,
    build_outputs,
    summary,
    error_types: tuple[type[BaseException], ...],
    error_prefix: str,
    input_root_help: str | None = None,
    output_root_help: str | None = None,
    check_help: str | None = None,
) -> int:
    parser = argparse.ArgumentParser(description=description)
    if input_root_help is not None:
        parser.add_argument("--input-root", type=Path, default=root, help=input_root_help)
    parser.add_argument("--output-root", type=Path, default=root, help=output_root_help)
    parser.add_argument("--check", action="store_true", help=check_help)
    args = parser.parse_args(argv)
    try:
        exported, expected = (
            build_outputs(args.input_root.resolve())
            if input_root_help is not None
            else build_outputs()
        )
        mismatches = sync_outputs(expected, args.output_root.resolve(), check=args.check)
        if mismatches:
            for row in mismatches:
                print(row, file=sys.stderr)
            return 1
        print(("checked" if args.check else "generated") + " " + summary(exported))
        return 0
    except error_types as error:
        print(f"{error_prefix}: {error}", file=sys.stderr)
        return 2
