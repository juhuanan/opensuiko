#!/usr/bin/env python3
"""Recreate ignored legacy paths from the durable-data migration map.

Run after checkout (make prepare). Existing regular files are local outputs and
are preserved; conflicting symlinks fail rather than redirecting a writer.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def link(root: Path, legacy: str, target: str) -> None:
    old, new = root / legacy, root / target
    if not new.exists():
        raise FileNotFoundError(new)
    if old.is_symlink():
        if old.resolve() != new.resolve():
            raise FileExistsError(f"Conflicting legacy link: {old}")
        return
    if old.exists():
        return
    old.parent.mkdir(parents=True, exist_ok=True)
    old.symlink_to(os.path.relpath(new.resolve(), old.parent.resolve()),
                   target_is_directory=new.is_dir())


def prepare(root: Path = ROOT) -> None:
    for name in ("cache/extracted", "build", "accepted", "scratch"):
        (root / "kit/work" / name).mkdir(parents=True, exist_ok=True)
    for old, new in (
        ("goals", "archive/goals"),
        ("kit/extracted", "kit/work/cache/extracted"),
        ("kit/work/assets_zig", "kit/work/accepted"),
    ):
        link(root, old, new)
    mapping = json.loads((root / "kit/data/legacy_paths.json").read_text())
    for old, new in mapping.items():
        link(root, old, new)


if __name__ == "__main__":
    prepare()
    print("Legacy paths ready; canonical knowledge lives in kit/data")
