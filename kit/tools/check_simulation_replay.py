"""Run public Journey replays or compare two captured simulation traces."""

import argparse
from collections.abc import Iterator
import json
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "game/tests/fixtures/simulation"
TRACE_SCHEMA = "suikoden-simulation-trace/1"
DIAGNOSTIC_SCHEMA = "suikoden-simulation-trace/2"


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def invalid_constant(value: str) -> None:
    raise ValueError(f"invalid JSON number {value}")


def read_trace(raw: str) -> dict:
    trace = json.loads(raw, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    if not isinstance(trace, dict) or trace.get("schema") not in (TRACE_SCHEMA, DIAGNOSTIC_SCHEMA):
        raise ValueError("expected a versioned simulation trace")
    dense = trace["schema"] == DIAGNOSTIC_SCHEMA
    keys = {"schema", "id", "checkpoints"} | ({"inputs"} if dense else set())
    if set(trace) != keys or not isinstance(trace["id"], str) or not trace["id"]:
        raise ValueError("invalid simulation trace header")
    if not isinstance(trace["checkpoints"], list) or not trace["checkpoints"]:
        raise ValueError("expected simulation checkpoints")
    if dense:
        inputs = trace["inputs"]
        if (
            not isinstance(inputs, dict)
            or set(inputs) != {"seed", "world_sha256", "replay_sha256"}
            or type(inputs["seed"]) is not int
            or not 0 <= inputs["seed"] < 2**64
            or any(
                not isinstance(inputs[key], str) or not re.fullmatch("[0-9a-f]{64}", inputs[key])
                for key in ("world_sha256", "replay_sha256")
            )
        ):
            raise ValueError("invalid simulation input identity")

    previous_tick = -1
    ids = set()
    for checkpoint in trace["checkpoints"]:
        if (
            not isinstance(checkpoint, dict)
            or not isinstance(checkpoint.get("id"), str)
            or not checkpoint["id"]
            or checkpoint["id"] in ids
            or type(checkpoint.get("tick")) is not int
            or checkpoint["tick"] <= previous_tick
        ):
            raise ValueError("checkpoints must have unique names and increasing integer ticks")
        if previous_tick == -1 and (checkpoint["id"] != "initial" or checkpoint["tick"] != 0):
            raise ValueError("initial checkpoint must be at tick 0")
        if dense and checkpoint["tick"] != previous_tick + 1:
            raise ValueError("diagnostic traces require a checkpoint every tick")
        ids.add(checkpoint["id"])
        previous_tick = checkpoint["tick"]
    return trace


def show(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True)


def differences(expected: object, actual: object, path: str = "") -> Iterator[str]:
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(expected.keys() | actual.keys()):
            child = f"{path}/{key.replace('~', '~0').replace('/', '~1')}"
            if key not in actual:
                yield f"{child} missing (expected {show(expected[key])})"
            elif key not in expected:
                yield f"{child} unexpected ({show(actual[key])})"
            else:
                yield from differences(expected[key], actual[key], child)
    elif isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            yield f"{path} length: expected {len(expected)}, got {len(actual)}"
        for index, (old, new) in enumerate(zip(expected, actual)):
            yield from differences(old, new, f"{path}/{index}")
    else:
        both_numbers = type(expected) in (int, float) and type(actual) in (int, float)
        if expected != actual or (type(expected) is not type(actual) and not both_numbers):
            yield f"{path}: expected {show(expected)}, got {show(actual)}"


def compare(expected: dict, actual: dict, label: str) -> bool:
    if expected["schema"] != actual["schema"]:
        print(f"FAIL {label}: trace schemas differ", file=sys.stderr)
        return False
    if expected["id"] != actual["id"]:
        print(f"FAIL {label}: expected replay {expected['id']!r}, got {actual['id']!r}", file=sys.stderr)
        return False
    if expected["schema"] == DIAGNOSTIC_SCHEMA:
        return compare_diagnostics(expected, actual, label)

    before = {point["id"]: point for point in expected["checkpoints"]}
    after = {point["id"]: point for point in actual["checkpoints"]}
    names = dict.fromkeys((*before, *after))
    changed = 0
    delta_count = 0
    if list(before) != list(after):
        print(f"FAIL {label}: expected checkpoint order {list(before)}, got {list(after)}", file=sys.stderr)
    for name in names:
        if name not in after:
            changes = ["checkpoint missing"]
        elif name not in before:
            changes = ["unexpected checkpoint"]
        else:
            changes = list(differences(before[name], after[name]))
        if changes:
            changed += 1
            delta_count += len(changes)
            tick = (before.get(name) or after[name])["tick"]
            print(f"FAIL {label} / {name} (tick {tick})", file=sys.stderr)
            for change in changes[:8]:
                print(f"  {change}", file=sys.stderr)
            if len(changes) > 8:
                print(f"  ... {len(changes) - 8} more changes", file=sys.stderr)
    if changed or list(before) != list(after):
        print(f"{label}: {changed} changed checkpoints, {delta_count} differences", file=sys.stderr)
        return False
    return True


def compare_diagnostics(expected: dict, actual: dict, label: str) -> bool:
    inputs = list(differences(expected["inputs"], actual["inputs"], "/inputs"))
    if inputs:
        print(f"FAIL {label}: simulation inputs differ", file=sys.stderr)
        for change in inputs:
            print(f"  {change}", file=sys.stderr)
        return False

    before, after = expected["checkpoints"], actual["checkpoints"]
    for old, new in zip(before, after):
        changes = list(differences(old, new))
        if changes:
            print(f"FAIL {label} / {old['id']} (first divergence at tick {old['tick']})", file=sys.stderr)
            for change in changes[:8]:
                print(f"  {change}", file=sys.stderr)
            if len(changes) > 8:
                print(f"  ... {len(changes) - 8} more changes", file=sys.stderr)
            return False
    if len(before) != len(after):
        tick = min(len(before), len(after))
        print(f"FAIL {label}: first divergence at tick {tick}, trace length differs", file=sys.stderr)
        return False
    return True


def run_trace(runner: Path, world: Path, replay: Path, *, every_tick: bool = False) -> dict:
    args = [runner.resolve(), world, replay]
    if every_tick:
        args.append("--every-tick")
    process = subprocess.run(
        args, capture_output=True, encoding="utf-8", timeout=60, check=False
    )
    if process.returncode:
        message = process.stderr.strip() or process.stdout.strip()
        raise ValueError(f"runner exited {process.returncode}: {message}")
    return read_trace(process.stdout)


def verify(runner: Path, world: Path, replay: Path) -> bool:
    name = replay.name.removesuffix(".replay.json")
    expected_path = replay.with_name(name + ".expected.json")
    expected = read_trace(expected_path.read_text(encoding="utf-8"))
    every_tick = expected["schema"] == DIAGNOSTIC_SCHEMA
    first = run_trace(runner, world, replay, every_tick=every_tick)
    second = run_trace(runner, world, replay, every_tick=every_tick)
    baseline_ok = compare(expected, first, name)
    repeat_ok = compare(first, second, f"{name} (repeat run)")
    if baseline_ok and repeat_ok:
        print(f"PASS {name}: {len(first['checkpoints'])} checkpoints, two runs agree")
    return baseline_ok and repeat_ok


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("verify", help="run fixtures twice and check their committed expectations")
    check.add_argument("--runner", type=Path, default=ROOT / "game/zig-out/bin/simulation-replay")
    check.add_argument("--world", type=Path, default=FIXTURES / "world.json")
    check.add_argument("replay", type=Path, nargs="*")
    traces = commands.add_parser("compare", help="compare a baseline capture and a candidate capture")
    traces.add_argument("baseline", type=Path)
    traces.add_argument("candidate", type=Path)
    runners = commands.add_parser("compare-runs", help="run two revisions with identical inputs and compare every tick")
    runners.add_argument("reference_runner", type=Path)
    runners.add_argument("candidate_runner", type=Path)
    runners.add_argument("world", type=Path)
    runners.add_argument("replay", type=Path)
    args = parser.parse_args()
    if args.command in ("compare", "compare-runs"):
        try:
            if args.command == "compare":
                baseline = read_trace(args.baseline.read_text(encoding="utf-8"))
                candidate = read_trace(args.candidate.read_text(encoding="utf-8"))
            else:
                baseline = run_trace(args.reference_runner, args.world, args.replay, every_tick=True)
                candidate = run_trace(args.candidate_runner, args.world, args.replay, every_tick=True)
            if compare(baseline, candidate, baseline["id"]):
                print(f"PASS {baseline['id']}: {len(baseline['checkpoints'])} checkpoints")
                return 0
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            print(f"FAIL trace comparison: {exc}", file=sys.stderr)
        return 1

    replays = args.replay or sorted(FIXTURES.glob("*.replay.json"))
    if not replays:
        parser.error("no replay fixtures found")
    passed = 0
    for replay in replays:
        try:
            passed += verify(args.runner, args.world, replay)
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            print(f"FAIL {replay}: {exc}", file=sys.stderr)
    print(f"{passed}/{len(replays)} simulation replays passed")
    return int(passed != len(replays))


if __name__ == "__main__":
    sys.exit(main())
