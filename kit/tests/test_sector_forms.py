#!/usr/bin/env python3
"""Pin the disc's sector forms, because this fact was once recorded backwards.

On 2026-10-05 the corpus concluded that `.8` files were CD-XA audio and that the
entire "scene geometry" strand was a Form-1 misread. That was inverted. The sectors
say otherwise, and the sector subheader says it unambiguously: submode bit 5 (0x20)
means Form 2, bit 2 (0x04) means audio, and every `.8` file is `0x08` -- Data, Form 1.

The consequence of the wrong version was not a bad render; it was that 38 correct open
questions were closed as refuted and the geometry work was suppressed. A claim that can
invalidate a whole strand from one premise has to be checked by a machine, not by a
reader who might repeat the same inference.

    python kit/tests/test_sector_forms.py
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "tools"))
import disc  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FORM2 = 0x20          # subheader byte 2, bit 5
AUDIO = 0x04          # subheader byte 2, bit 2
SUBMODE_OFF = 18      # byte 2 of the 8-byte subheader, at sector offset 16


def inventory():
    with open(os.path.join(ROOT, "kit", "extracted", "iso_files.json")) as fh:
        return [r for r in json.load(fh) if not r.get("dir")]


def main() -> int:
    path, sector, _ = disc.resolve_raw()
    recs = inventory()
    fails: list[str] = []
    with open(path, "rb") as fh:
        def submodes(rec, n=6):
            out = set()
            for i in range(min(n, max(1, rec["size"] // 2048))):
                fh.seek((rec["lba"] + i) * sector)
                out.add(fh.read(24)[SUBMODE_OFF])
            return out

        eights = [r for r in recs if r["path"].endswith(".8")]
        if len(eights) != 67:
            fails.append(f"expected 67 `.8` files, found {len(eights)}")
        bad = [(r["path"], submodes(r)) for r in eights
               if any(s & FORM2 for s in submodes(r))]
        if bad:
            fails.append(f"`.8` files reading as Form 2: {bad[:4]}")
        notdata = [(r["path"], submodes(r)) for r in eights
                   if not all(s & 0x08 for s in submodes(r))]
        if notdata:
            fails.append(f"`.8` files whose submode is not Data: {notdata[:4]}")

        form2 = sorted(r["path"] for r in recs
                       if r["size"] >= 4096 and (submodes(r, 1) and
                                                 next(iter(submodes(r, 1))) & FORM2))
        if form2 != ["DATA/01_AREA.A/XA1.", "DATA/16_WAR/XA2."]:
            fails.append(f"the Form 2 set is {form2}, expected exactly XA1. and XA2.")
        audio = [r["path"] for r in recs if r["size"] >= 4096
                 and any(s & AUDIO for s in submodes(r, 1))
                 and any(s & FORM2 for s in submodes(r, 1))]
        if sorted(audio) != ["DATA/01_AREA.A/XA1.", "DATA/16_WAR/XA2."]:
            fails.append(f"the audio set is {sorted(audio)}")

    if fails:
        print("FAIL: sector-form invariant broken:")
        for f in fails:
            print(f"  - {f}")
        return 1
    print("PASS: 67 `.8` files are Form 1 Data (submode 0x08); the only Form 2 files "
          "on the disc are DATA/01_AREA.A/XA1. and DATA/16_WAR/XA2. (submode 0x64)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
