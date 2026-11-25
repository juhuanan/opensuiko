#!/usr/bin/env python3
"""Check the headless content diagnostic and its exit status."""
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "game/zig-out/bin/suikoden-journey"
CANONICAL = ROOT / "kit/work/build/canonical"


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(BINARY), "--check-content", str(root)], text=True, capture_output=True)


def main() -> int:
    if not BINARY.is_file() or not CANONICAL.is_dir():
        print("SKIP: build-journey and canonical-assets are required")
        return 0
    failures = 0

    def expect(name: str, root: Path, code: int, needle: str) -> None:
        nonlocal failures
        result = run(root)
        ok = result.returncode == code and needle in result.stderr
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            failures += 1
            print(f"  exit={result.returncode} stderr={result.stderr!r}")

    expect("canonical package loads", CANONICAL, 0, "is a loadable content package")

    with tempfile.TemporaryDirectory(prefix="suikoden-diag-") as temp:
        work = Path(temp) / "package"
        shutil.copytree(CANONICAL, work)
        (work / "room.json").unlink()
        expect("missing room.json", work, 1, "room.json: FileNotFound")
        shutil.copy2(CANONICAL / "room.json", work / "room.json")
        (work / "journey.json").write_text("{bad", encoding="utf-8")
        expect("corrupt journey.json", work, 1, "journey.json: SyntaxError")
        shutil.copy2(CANONICAL / "journey.json", work / "journey.json")
        (work / "party/catalogue.json").unlink()
        expect("missing party catalogue", work, 1, "party/catalogue.json: MissingPartyCatalogue")

    print(f"{4 - failures} passed, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
