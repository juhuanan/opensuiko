#!/usr/bin/env python3
"""compare_builds.py -- compare two isolated rebuild roots.

Usage:
    python3 kit/tools/compare_builds.py ROOT_A ROOT_B

Purpose (milestone 5 of `asset_pipeline_consolidation_plan.md`): two
builds run from the disc plus tracked inputs, in separate fresh directories,
must agree on **decoded content**. Timestamps and path-dependent provenance are
excluded from the comparison because they cannot be expected to match; generated
PNGs whose bytes differ only by encoder metadata are compared by decoded pixels.

What is compared
  * every JSON sidecar, with volatile keys stripped and any string mentioning
    either root normalised;
  * every other file by SHA-256, falling back to decoded pixel equality for
    PNGs whose bytes differ.

Exit status: 0 when the roots agree, 1 when they differ or one is missing a
file the other has.
"""
import hashlib
import json
import os
import sys

# Keys whose values legitimately differ between runs (wall clock, locations).
VOLATILE_KEYS = {
    "run_at", "generated_utc", "generated", "timestamp", "mtime",
    "output", "out", "root", "input_root", "curated_input_root", "out_root",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _normalise(obj, roots):
    """Strip volatile keys and root-dependent strings, recursively."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k in VOLATILE_KEYS:
                continue
            out[k] = _normalise(v, roots)
        return out
    if isinstance(obj, list):
        return [_normalise(v, roots) for v in obj]
    if isinstance(obj, str):
        s = obj
        for r in roots:
            if r and r in s:
                s = s.replace(r, "<ROOT>")
        return s
    return obj


def load_json_normalised(path, roots):
    with open(path) as f:
        return _normalise(json.load(f), roots)


def pixels_equal(a, b):
    try:
        from PIL import Image
        ia = Image.open(a).convert("RGBA")
        ib = Image.open(b).convert("RGBA")
        if ia.size != ib.size:
            return False
        return list(ia.getdata()) == list(ib.getdata())
    except Exception:
        return False


def walk(root):
    found = {}
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            p = os.path.join(dirpath, fn)
            found[os.path.relpath(p, root)] = p
    return found


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2
    ra, rb = (os.path.abspath(a) for a in argv)
    for r in (ra, rb):
        if not os.path.isdir(r):
            sys.stderr.write("not a directory: %s\n" % r)
            return 2
    roots = (ra, rb)
    A, B = walk(ra), walk(rb)

    only_a = sorted(set(A) - set(B))
    only_b = sorted(set(B) - set(A))
    shared = sorted(set(A) & set(B))

    diffs = []
    json_ok = file_ok = png_pixel_ok = 0
    for rel in shared:
        pa, pb = A[rel], B[rel]
        if rel.endswith(".json"):
            try:
                if load_json_normalised(pa, roots) != load_json_normalised(pb, roots):
                    diffs.append("%s: JSON content differs" % rel)
                else:
                    json_ok += 1
            except Exception as ex:
                diffs.append("%s: JSON compare failed (%s: %s)"
                             % (rel, type(ex).__name__, ex))
            continue
        ha, hb = sha256(pa), sha256(pb)
        if ha == hb:
            file_ok += 1
        elif rel.lower().endswith(".png") and pixels_equal(pa, pb):
            # Container bytes differ but the decoded image agrees.
            png_pixel_ok += 1
        else:
            diffs.append("%s: sha256 %s != %s" % (rel, ha[:16], hb[:16]))

    print("root A: %s" % ra)
    print("root B: %s" % rb)
    print("files: %d shared | %d only in A | %d only in B"
          % (len(shared), len(only_a), len(only_b)))
    print("identical: %d byte-identical, %d JSON-equal, %d pixel-equal"
          % (file_ok, json_ok, png_pixel_ok))
    for rel in only_a[:10]:
        print("  only in A: %s" % rel)
    for rel in only_b[:10]:
        print("  only in B: %s" % rel)
    for d in diffs[:20]:
        print("  DIFF %s" % d)

    if only_a or only_b or diffs:
        print("\nBUILDS DISAGREE: %d difference(s)"
              % (len(diffs) + len(only_a) + len(only_b)))
        return 1
    print("\nBUILDS AGREE: concise content identical across both roots "
          "(%d files)" % len(shared))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
