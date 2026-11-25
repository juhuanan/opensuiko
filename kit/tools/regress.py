#!/usr/bin/env python3
"""regress.py -- the single regression gate for the Suikoden asset pipeline.

Runs:
  1. All lzss golden fixtures (kit/tests/fixtures/lzss/manifest.json).
  2. Full-corpus gate: every c-blob of all 78 DATA/04_PLAY files must
     decode_strict() to exactly 16384 bytes with 100% input consumption.
  3. Duel-asset gate: every BT*/SKY* container in DATA/12_IKKI/DATA must
     decode_container() to exactly 16384 bytes.

The corpus it reads is `kit/extracted/bin_overlays/DATA` by default, but that is
NOT a prerequisite any more: pass `--corpus DIR` (or set $SUIKODEN_CORPUS) to
point at a freshly bootstrapped tree instead, which is what rebuild_assets.sh
does. 2026-10-04: the path was hardcoded, so the gate could not run from the disc
alone.

Exit 0 = all green. Exit 1 = any failure (prints diagnostics).
This gates future asset publication: do not ship assets from a tree where
regress.py fails.
"""
import sys
import os
import json
import glob
import hashlib

KIT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(KIT, 'tools'))

from lzss import (  # noqa: E402
    decode_strict, decode_container, LZSSError, TruncationError,
    __version__ as LZSS_VERSION,
)
from parse_04play import parse_04play  # noqa: E402

failures = []

# DATA root holding 04_PLAY/ and 12_IKKI/. Overridable so the gate does not
# depend on the extracted cache existing.
CORPUS = os.environ.get('SUIKODEN_CORPUS') or os.path.join(
    KIT, 'extracted', 'bin_overlays', 'DATA')


def check(name, fn):
    try:
        fn()
    except Exception as ex:  # noqa: BLE001 - report, don't crash
        failures.append((name, '%s: %s' % (type(ex).__name__, ex)))
        print('FAIL %-28s %s: %s' % (name, type(ex).__name__, ex))
    else:
        print('ok   %s' % name)


def run_fixtures():
    fixdir = os.path.join(KIT, 'tests', 'fixtures', 'lzss')
    with open(os.path.join(fixdir, 'manifest.json')) as f:
        manifest = json.load(f)
    for m in manifest:
        with open(os.path.join(fixdir, m['payload']), 'rb') as f:
            payload = f.read()

        def one(m=m, payload=payload):
            if m['mode'] == 'must_raise_TruncationError':
                try:
                    decode_strict(payload)
                except TruncationError:
                    return
                raise AssertionError('did not raise TruncationError')
            if m['mode'] == 'decode_container':
                out, used = decode_container(payload)
                assert used == len(payload), 'container used %d/%d' % (used, len(payload))
            else:
                out = decode_strict(payload)
            with open(os.path.join(fixdir, m['expected']), 'rb') as f:
                expected = f.read()
            assert out == expected, 'output differs (%d vs %d bytes)' % (len(out), len(expected))
            assert hashlib.sha256(out).hexdigest() == m['expected_sha256'], 'sha256 mismatch'

        check('fixture/' + m['name'], one)


def run_04play_corpus():
    d = os.path.join(CORPUS, '04_PLAY')
    paths = sorted(glob.glob(os.path.join(d, '*.BIN')))
    assert len(paths) == 78, 'expected 78 04_PLAY files, found %d' % len(paths)
    n = 0

    def one():
        nonlocal n
        for path in paths:
            with open(path, 'rb') as f:
                raw = f.read()
            st = parse_04play(path)
            for sec in ('S1', 'S2'):
                for e in st['sections'][sec]['c']['entries']:
                    b = e['blob']
                    payload = raw[b['data_file_offset']:b['data_file_offset'] + b['data_len']]
                    assert len(payload) == b['data_len']
                    out = decode_strict(payload)
                    assert len(out) == 16384, \
                        '%s %s.c[%d]: %d bytes, want 16384' % (
                            os.path.basename(path), sec, e['index'], len(out))
                    n += 1

    check('corpus/04_PLAY (%d files)' % len(paths), one)
    if not any(f[0].startswith('corpus/04_PLAY') for f in failures):
        print('     %d c-blobs, all 16384 bytes, 100%% input consumption' % n)


def run_duel_corpus():
    d = os.path.join(CORPUS, '12_IKKI', 'DATA')
    paths = sorted(glob.glob(os.path.join(d, 'BT*.BIN')) +
                   glob.glob(os.path.join(d, 'SKY*.BIN')))
    assert paths, 'no BT/SKY files found'

    def one():
        for path in paths:
            with open(path, 'rb') as f:
                blob = f.read()
            out, used = decode_container(blob)
            assert used == len(blob), '%s: container used %d/%d' % (
                os.path.basename(path), used, len(blob))
            assert len(out) == 16384, '%s: %d bytes' % (
                os.path.basename(path), len(out))

    check('corpus/duel-assets (%d files)' % len(paths), one)


def main(argv=None):
    global CORPUS
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv:
        if len(argv) == 2 and argv[0] == '--corpus':
            CORPUS = argv[1]
        else:
            sys.stderr.write('usage: regress.py [--corpus DIR]\n')
            return 2
    print('lzss v%s' % LZSS_VERSION)
    print('corpus: %s' % CORPUS)
    run_fixtures()
    run_04play_corpus()
    run_duel_corpus()
    print('---')
    if failures:
        print('%d FAILURES' % len(failures))
        return 1
    print('ALL GREEN')
    return 0


if __name__ == '__main__':
    sys.exit(main())
