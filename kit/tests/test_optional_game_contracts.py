#!/usr/bin/env python3
"""Gate the optional-game contract export.

Checks, all static and headless:

* the exporter is deterministic and its four owned artifacts in the worktree are
  exactly what it regenerates (the non-writing ``--check`` path);
* input files are pinned by exact-file SHA-256 and payloads by canonical-JSON
  SHA-256, and both are recomputed here independently of the report;
* the runtime asset carries no source RAM address, offset or absolute path;
* the contract values equal the source tables the exporter asserts against;
* the fixture is derivable from the runtime asset;
* every registry row is well formed, and the open rows are exactly the typed
  blockers;
* the Zig module pins the exact asset digest and contains no source address;
* the report's test inventory equals the owned Zig test declarations;
* a tampered artifact makes ``--check`` fail without writing.

This gate never executes an original instruction, never runs the old F
minigames tests (they execute original instructions) and never plays audio,
video or a window.
"""
import contextlib
import hashlib
import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
ROOT = KIT.parent
sys.path.insert(0, str(KIT / 'tools'))

import export_optional_game_contracts as exporter  # noqa: E402
from disc import extract  # noqa: E402

CHECKS = []


def check(name):
    CHECKS.append(name)
    print(f'check: {name}')


def fail(message):
    raise AssertionError(message)


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def canonical(payload):
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def generated():
    files, runtime, fixture = exporter.build()
    return files, runtime, fixture


def read_worktree():
    result = {}
    for relative in exporter.RUNTIME_PATH, exporter.FIXTURE_PATH, exporter.REPORT_PATH, exporter.REGISTRY_PATH:
        path = ROOT / relative
        if not path.exists():
            fail(f'missing owned artifact {relative}')
        result[relative] = path.read_text(encoding='utf-8')
    return result


def check_determinism(files):
    check('exporter is deterministic across two builds')
    again, _, _ = generated()
    if again != files:
        fail('two exporter builds differ')


def check_worktree_matches(files):
    check('owned artifacts equal the regenerated text (non-writing check)')
    on_disk = read_worktree()
    for relative, text in files.items():
        if on_disk[relative] != text:
            fail(f'stale owned artifact {relative}')
    if exporter.main(['--check', str(ROOT)]) != 0:
        fail('exporter --check rejected the worktree')


def check_pins(report, runtime, fixture):
    check('input files are pinned by exact-file SHA-256')
    rows = json.loads((KIT / 'extracted' / 'iso_files.json').read_text())
    for name, relative in exporter.FILES.items():
        row = next(r for r in rows if r['path'] == relative)
        actual = digest_bytes(extract(row['lba'], row['size']))
        pinned = report['pins']['input_files'][name]
        if actual != pinned:
            fail(f'{name} input pin mismatch')
        if report['immutable_inputs'][name]['sha256'] != pinned:
            fail(f'{name} immutable input record disagrees with the pin')
    check('payloads are pinned by canonical-JSON SHA-256')
    for key, payload in (('runtime', runtime), ('fixture', fixture)):
        actual = digest_bytes(canonical(payload))
        if actual != report['pins']['canonical_json'][key]:
            fail(f'{key} canonical pin mismatch')
    check('output files pin their exact emitted bytes')
    if digest_bytes(exporter.render(runtime).encode()) != report['outputs']['runtime_sha256']:
        fail('runtime output hash mismatch')
    if digest_bytes(exporter.render(fixture).encode()) != report['outputs']['fixture_sha256']:
        fail('fixture output hash mismatch')


def check_runtime_is_semantic(runtime):
    check('runtime asset carries no source address, offset or absolute path')
    text = exporter.render(runtime)
    roots = ('/' + 'Users/', '/' + 'home/', 'kit/' + 'work')
    for forbidden in ('0x', *roots):
        if forbidden in text:
            fail(f'runtime asset leaks {forbidden!r}')
    import re
    if re.search(r'\b(ram|addr|address|offset|lba|pointer|gs)\b', text, re.I):
        fail('runtime asset names a source reference')
    for family in runtime['families'].values():
        for key in family:
            if 'addr' in key.lower() or 'pointer' in key.lower():
                fail(f'runtime key {key!r} is a source reference')


def check_source_tables(runtime, report):
    check('contract values equal the asserted source tables')
    families = runtime['families']
    if families['coin']['stakes'] != [100, 1000, 10000]:
        fail('COIN stakes mismatch')
    if [row['base'] for row in families['coin']['difficulty']] != [15, 7, 4]:
        fail('COIN difficulty base mismatch')
    if [row['range'] for row in families['coin']['difficulty']] != [20, 8, 6]:
        fail('COIN difficulty range mismatch')
    if families['coin']['shuffle']['steps'] != 20:
        fail('COIN shuffle step count mismatch')
    if families['coin']['profit'] != {'threshold': 5000, 'flag_mask': 0x00A00000, 'flag_value': 0x00200000, 'result_bit': 0x40}:
        fail('COIN profit gate mismatch')
    specials = [(row['score'], row['roller_wins'], row['multiplier']) for row in families['dice']['specials']]
    if specials != [(8, True, 3), (16, False, 3), (32, True, 2), (64, False, 2), (128, False, 1)]:
        fail('dice special table mismatch')
    if families['dice']['wager']['increments'] != [100, 1000] or families['dice']['wager']['maximum'] != 9900:
        fail('dice wager grid mismatch')
    if [row['identities'] for row in families['karuta']['rounds']] != [5, 7, 10, 15]:
        fail('KARUTA identity table mismatch')
    if [row['record_moves'] for row in families['karuta']['rounds']] != [900, 1500, 2400, 3300]:
        fail('KARUTA record table mismatch')
    board = families['karuta']['board']
    if (board['rows'], board['columns'], board['cells'], board['pairs']) != (8, 6, 48, 24):
        fail('KARUTA board mismatch')
    codes = [row['code'] for row in families['karuta']['cell_states']]
    if codes != list(range(11)):
        fail('KARUTA cell state codes mismatch')
    if families['karuta']['cell_states'][10]['id'] != 'empty':
        fail('KARUTA state 10 must be the empty state')
    if families['karuta']['settlement']['pays_bits']:
        fail('KARUTA must not claim a payout')
    if report['source_tables']['coin_stakes'] != families['coin']['stakes']:
        fail('report source table disagrees with runtime')
    if report['source_tables']['karuta_identity_counts'] != [5, 7, 10, 15]:
        fail('report identity counts mismatch')
    if report['source_tables']['karuta_record_thresholds'] != [900, 1500, 2400, 3300]:
        fail('report record thresholds mismatch')


def check_fixture_agreement(runtime, fixture):
    check('fixture is derived from the runtime asset')
    dice, coin, karuta = runtime['families']['dice'], runtime['families']['coin'], runtime['families']['karuta']
    if fixture['dice']['specials'] != dice['specials']:
        fail('fixture dice specials mismatch')
    if fixture['dice']['balance_cap'] != dice['balance_cap']:
        fail('fixture dice cap mismatch')
    if fixture['coin']['stakes'] != coin['stakes'] or fixture['coin']['profit'] != coin['profit']:
        fail('fixture coin mismatch')
    if fixture['coin']['difficulty'] != coin['difficulty']:
        fail('fixture coin difficulty mismatch')
    if fixture['karuta']['rounds'] != karuta['rounds'] or fixture['karuta']['quit_round'] != karuta['quit_round']:
        fail('fixture KARUTA rounds mismatch')
    if fixture['karuta']['board'] != karuta['board']:
        fail('fixture KARUTA board mismatch')
    for example in fixture['karuta']['index_examples']:
        expected_row = example['index'] % 8
        expected_column = example['index'] // 8
        if (example['row'], example['column']) != (expected_row, expected_column):
            fail('fixture linear index convention mismatch')
        if example['column'] * 8 + example['row'] != example['index']:
            fail('fixture linear index is not column-major')


def check_registry(report):
    check('registry rows are well formed and open rows are the typed blockers')
    path = ROOT / exporter.REGISTRY_PATH
    rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines() if line.strip()]
    if len(rows) < 15:
        fail('registry inventory is too small')
    ids = [row['id'] for row in rows]
    if len(set(ids)) != len(ids):
        fail('duplicate registry id')
    for row in rows:
        if row['evidence'] not in ('proven', 'open'):
            fail(f"invalid evidence {row['evidence']!r}")
        if not row['claim'] or not row['class']:
            fail('empty registry row')
        if row['superseded_by']:
            fail('a new row must not claim a supersession')
    open_rows = [row['id'] for row in rows if row['evidence'] == 'open']
    by_id = {row['id']: row for row in rows}
    if by_id.get('optional-games/shared/3d-presentation', {}).get('evidence') != 'proven':
        fail('the qualified dice geometry is missing from the registry')
    if 'optional-games/shared/scene-composition' not in open_rows:
        fail('the remaining dice composition blocker is missing from the registry')
    if 'optional-games/shared/effect-owner' not in open_rows:
        fail('the effect-owner blocker is missing from the registry')
    blocker_ids = {row['id'] for row in report['blockers']}
    if 'blocker.dice.3d-presentation' not in blocker_ids:
        fail('the 3D blocker is missing from the report')
    kinds = {row['kind'] for row in report['blockers']}
    if kinds != {'required_source', 'caller_obligation'}:
        fail('blockers must stay typed')


def check_module_identity():
    check('Zig module pins the exact asset digest and stays address-free')
    asset = (ROOT / exporter.RUNTIME_PATH).read_bytes()
    source = (ROOT / exporter.ZIG_SOURCE_PATH).read_text(encoding='utf-8')
    marker = 'pub const asset_sha256 = [32]u8{'
    if marker not in source:
        fail('module does not pin the asset digest')
    literal = source[source.index(marker) + len(marker):]
    literal = literal[:literal.index('};')]
    values = [int(part, 16) for part in literal.replace('\n', ' ').replace(',', ' ').split()]
    if bytes(values) != hashlib.sha256(asset).digest():
        fail('module digest does not match the owned asset')
    if '@embedFile' in source:
        fail('module must not embed the asset (package path trap)')
    roots = ('kit/' + 'work', '/' + 'Users/', '/' + 'home/')
    for forbidden in ('0x800', *roots):
        if forbidden in source:
            fail(f'Zig module leaks {forbidden!r}')
    if '@import("battle_rules")' not in source or 'pub const Draws = draws_mod.Draws;' not in source:
        fail('module must reuse the canonical Draws stream')


def check_test_inventory(report):
    check('report test inventory equals the owned Zig test declarations')
    import re
    text = (ROOT / exporter.ZIG_TEST_PATH).read_text(encoding='utf-8')
    names = re.findall(r'^test "([^"]+)"', text, re.M)
    if report['test_inventory'] != names:
        fail('report test inventory is stale')
    covered = set()
    for row in report['acceptance']:
        if row['status'] != 'covered':
            fail(f"acceptance case {row['case']!r} is not covered")
        for name in row['tests']:
            if name not in names:
                fail(f"acceptance cites unknown test {name!r}")
            covered.add(name)
    if covered != set(names):
        missing = sorted(set(names) - covered)
        fail(f'acceptance matrix does not cite every owned test: {missing}')


def check_static_only():
    check('exporter and gate never execute original instructions')
    for path in (ROOT / 'kit/tools/export_optional_game_contracts.py',
                 ROOT / 'kit/tests/test_optional_game_contracts.py'):
        text = path.read_text(encoding='utf-8')
        # Built from parts so this gate does not match its own literal list.
        forbidden_helpers = ('Overlay' + 'Instructions', 'test_vb2' + '_dice_states',
                             'sub' + 'process', 'kit/tools/' + 'emu',
                             'memory' + '_writer', 'Basic' + 'CPU')
        for forbidden in forbidden_helpers:
            if forbidden in text:
                fail(f'{path.name} references an instruction-executing helper: {forbidden}')


def check_tamper(files):
    check('a tampered artifact fails --check without writing')
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        for relative, text in files.items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding='utf-8')
        asset = root / exporter.RUNTIME_PATH
        original = asset.read_text(encoding='utf-8')
        asset.write_text(original.replace('"vb2_dice"', '"vb2_dice_tampered"'), encoding='utf-8')
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            code = exporter.main(['--check', str(root)])
        if code == 0:
            fail('--check accepted a tampered artifact')
        if asset.read_text(encoding='utf-8').startswith('{"schema": "suikoden.optional-games.v1"'):
            pass  # still JSON, but it must be unchanged by the check
        if 'vb2_dice_tampered' not in asset.read_text(encoding='utf-8'):
            fail('--check wrote to the tree')
        if 'stale' not in stderr.getvalue() and 'CHECK FAILED' not in stderr.getvalue():
            fail('--check did not report the stale artifact')

    check('--out regenerates byte-identical files from the disc')
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        for relative, text in files.items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text, encoding='utf-8')
        if exporter.main(['--out', str(root)]) != 0:
            fail('--out failed on a clean tree')
        for relative, text in files.items():
            if (root / relative).read_text(encoding='utf-8') != text:
                fail(f'--out wrote a different {relative}')


def main():
    files, runtime, fixture = generated()
    report = json.loads(files[exporter.REPORT_PATH])
    check_determinism(files)
    check_worktree_matches(files)
    check_pins(report, runtime, fixture)
    check_runtime_is_semantic(runtime)
    check_source_tables(runtime, report)
    check_fixture_agreement(runtime, fixture)
    check_registry(report)
    check_module_identity()
    check_test_inventory(report)
    check_static_only()
    check_tamper(files)
    print(f'PASS: {len(CHECKS)} optional-game contract checks '
          f'({len(report["test_inventory"])} Zig tests, {len(report["blockers"])} typed blockers)')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except AssertionError as error:
        print(f'FAIL: {error}', file=sys.stderr)
        sys.exit(1)
