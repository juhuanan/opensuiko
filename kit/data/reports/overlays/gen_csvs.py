#!/usr/bin/env python3
"""Generate per-file label CSVs from VD6 inheritance + hand-written NEW fragments.

Usage: gen_csvs.py
Reads:
  ~/workspace/suikoden/kit/work/overlays/vd6_labels.csv  (VD6 reference)
  /tmp/ovl/matches/<AREA>_<NAME>.BIN.txt                 (match lines)
  <scriptdir>/new_<name>.csv                            (hand-written NEW labels)
Writes:
  ~/workspace/suikoden/kit/work/overlays/<name>_labels.csv
"""
import csv, os, re, sys

WORK = os.path.expanduser("~/workspace/suikoden/kit/work/overlays")
MATCHDIR = "/tmp/ovl/matches"

FILES = [
    ("06_AREA.C_C_DATA.BIN", "c_data"),
    ("06_AREA.C_VC3.BIN",     "vc3"),
    ("06_AREA.C_VC6.BIN",     "vc6"),
    ("07_AREA.D_D_DATA.BIN",  "d_data"),
    ("07_AREA.D_K_DATA.BIN",  "k_data"),
    ("07_AREA.D_VD1.BIN",     "vd1"),
    ("07_AREA.D_VD2.BIN",     "vd2"),
    ("07_AREA.D_VD3.BIN",     "vd3"),
    ("07_AREA.D_VD4.BIN",     "vd4"),
    ("07_AREA.D_VD5.BIN",     "vd5"),
    ("07_AREA.D_VD7.BIN",     "vd7"),
    ("08_AREA.E_E_DATA.BIN",  "e_data"),
    ("08_AREA.E_VE1.BIN",     "ve1"),
    ("08_AREA.E_VE2.BIN",     "ve2"),
    ("08_AREA.E_VE3.BIN",     "ve3"),
    ("08_AREA.E_VE4.BIN",     "ve4"),
    ("08_AREA.E_VE5.BIN",     "ve5"),
    ("08_AREA.E_VE6.BIN",     "ve6"),
]

# VD6 reference
vd6 = {}
with open(os.path.join(WORK, "vd6_labels.csv"), newline="") as f:
    for row in csv.DictReader(f):
        vd6[row["address"].lower()] = row

def short_notes(notes, limit=220):
    notes = notes.strip()
    if len(notes) > limit:
        notes = notes[:limit].rsplit(" ", 1)[0] + "..."
    return notes

def main():
    for matchfile, short in FILES:
        rows = []
        seen = set()
        with open(os.path.join(MATCHDIR, matchfile + ".txt")) as f:
            for line in f:
                line = line.strip()
                m = re.match(r"(0x[0-9a-f]+) size=\d+ (STRICT|SHAPE) (0x[0-9a-f]+)", line)
                if not m:
                    continue
                addr, kind_m, vd6addr = m.group(1), m.group(2), m.group(3)
                ref = vd6.get(vd6addr.lower())
                if not ref:
                    print(f"WARN: no VD6 label for {vd6addr}", file=sys.stderr)
                    continue
                notes = (f"Shared engine function; {kind_m.lower()}-matches VD6 {vd6addr} "
                         f"({ref['name']}). File-specific immediates differ; behavior per VD6: "
                         f"{short_notes(ref['notes'])}")
                rows.append({"address": addr, "name": ref["name"],
                             "kind": ref["kind"], "notes": notes})
                seen.add(addr.lower())
        # NEW fragments (replace inherited rows on address conflict: file-specific analysis wins)
        frag = os.path.join(WORK, f"new_{short}.csv")
        frag_addrs = set()
        if os.path.exists(frag):
            with open(frag, newline="") as f:
                frag_rows = list(csv.DictReader(f))
            frag_addrs = {r["address"].lower() for r in frag_rows}
        rows = [r for r in rows if r["address"].lower() not in frag_addrs]
        seen -= frag_addrs
        if os.path.exists(frag):
            for row in frag_rows:
                if row["address"].lower() in seen:
                    print(f"WARN: {short} fragment dup {row['address']}", file=sys.stderr)
                rows.append(row)
                seen.add(row["address"].lower())
        rows.sort(key=lambda r: int(r["address"], 16))
        out = os.path.join(WORK, f"{short}_labels.csv")
        with open(out, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["address", "name", "kind", "notes"])
            w.writeheader()
            w.writerows(rows)
        f_cnt = sum(1 for r in rows if r["kind"] == "F")
        d_cnt = sum(1 for r in rows if r["kind"] == "D")
        print(f"{short}: {len(rows)} labels ({f_cnt} F, {d_cnt} D)")

if __name__ == "__main__":
    main()
