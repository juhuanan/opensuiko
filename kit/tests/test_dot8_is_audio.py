#!/usr/bin/env python3
"""Guard .8 sector framing: Form1 data containing SPU ADPCM, never XA.

The earlier Form2 interpretation sliced EDC/ECC into the stream. A wrong
sector slice destroying valid ADPCM flags is a negative control, not evidence
that the longer slice is correct. See dot8_spu_audio.md for the SPU consumer.
"""
import json
import os
import sys

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, "tools"))

import disc  # noqa: E402

FAILED = []
CHECKS = [0]


def check(name, cond, detail=""):
    CHECKS[0] += 1
    if cond:
        print("ok   %s" % name)
    else:
        print("FAIL %s %s" % (name, detail))
        FAILED.append(name)


def _files():
    with open(os.path.join(KIT, "extracted", "iso_files.json")) as f:
        return {x["path"]: x for x in json.load(f) if not x.get("dir")}


def _raw(name, files, max_sectors=None):
    r = files[name]
    lba, size = r["lba"], r["size"]
    sectors = size // 2048
    if max_sectors:
        sectors = min(sectors, max_sectors)
    path, RS, _RO = disc.resolve_raw()
    with open(path, "rb") as f:
        f.seek(lba * RS)
        return f.read(sectors * RS), RS, sectors


def test_form1_payload_and_submode():
    files = _files()
    raw, RS, sectors = _raw("DATA/05_BATLE/BATTLE1.8", files, max_sectors=64)
    check("raw read is whole sectors", len(raw) == sectors * RS)
    # MODE2 sync
    check("MODE2 sync pattern", raw[:12] == b"\x00" + b"\xff" * 10 + b"\x00",
          raw[:12].hex())
    # subheader: file, channel, submode, coding -- repeated
    subs = set()
    for i in range(len(raw) // RS):
        s = raw[i * RS + 16:i * RS + 24]
        check_ok = len(s) == 8 and s[:4] == s[4:]
        if not check_ok:
            check("subheader repeats", False, s.hex())
            return
        subs.add(s[2])
    check("every sampled sector submode is 0x08 (Form1 data)", subs == {0x08}, sorted(subs))
    check("every sampled data-sector coding byte is zero (not an audio channel count)",
          all(raw[i * RS + 19] == 0 for i in range(len(raw) // RS)))


def test_wrong_form2_slice_breaks_valid_adpcm_framing():
    """Deliberately including EDC/ECC destroys the correct16-byte framing."""
    files = _files()
    name = "DATA/05_BATLE/BATTLE1.8"
    r = files[name]
    lba, size = r["lba"], r["size"]
    sectors = size // 2048
    f1 = disc.extract(lba, size)
    n1 = sum(1 for i in range(1, len(f1), 16) if f1[i] == 2)
    check("Form 1: byte 1 of every 16 is 0x02 almost always",
          n1 > 0.999 * (len(f1) // 16), "%d of %d" % (n1, len(f1) // 16))

    raw, RS, _s = _raw(name, files)
    f2 = b"".join(raw[i * RS + 24:i * RS + 2348] for i in range(sectors))
    check("wrong slice length is sectors x 2324", len(f2) == sectors * 2324,
          len(f2))
    n2 = sum(1 for i in range(1, len(f2), 16) if f2[i] == 2)
    frac = n2 / (len(f2) // 16)
    check("wrong Form2 slice destroys valid flags", frac < 0.5,
          "%.3f (%d of %d)" % (frac, n2, len(f2) // 16))

    # the desync arithmetic that explains the period
    check("2324-2048 = 276 and 276 % 16 = 4", 2324 - 2048 == 276 and 276 % 16 == 4)
    check("4 sectors x 276 B re-aligns exactly on a 16-byte boundary",
          (4 * 276) % 16 == 0)


def test_all_dot8_files_are_audio():
    files = _files()
    names = sorted(n for n in files if n.endswith(".8"))
    check("there are 67 .8 files", len(names) == 67, len(names))
    bad = []
    for n in names:
        raw, RS, sectors = _raw(n, files, max_sectors=8)
        for i in range(len(raw) // RS):
            if raw[i * RS + 18] != 0x08:
                bad.append((n, hex(raw[i * RS + 18])))
                break
    check("every .8 file's sampled sectors are submode 0x08", not bad, bad[:5])


if __name__ == "__main__":
    test_form1_payload_and_submode()
    test_wrong_form2_slice_breaks_valid_adpcm_framing()
    test_all_dot8_files_are_audio()
    print()
    print("%d passed, %d failed" % (CHECKS[0] - len(FAILED), len(FAILED)))
    sys.exit(1 if FAILED else 0)
