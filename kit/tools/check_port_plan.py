#!/usr/bin/env python3
"""Validate preserved plan IDs and the expanded completion-dependency graph."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
QUALIFIERS = {"core", "opening", "block1", "middle", "final", "world", "travel", "teleport", "headquarters", "recruitments", "services", "minigames", "dice", "duels", "war", "streams", "enemy-actions", "boss-actions"}
STATES = ("Implemented", "Active", "Planned", "Review needed")


def check(root=ROOT):
    documents = {name: (root / "game" / name).read_text() for name in ("ROADMAP.md", "IMPLEMENTATION.md")}
    rows = lambda text: [line.split("|") for line in text.splitlines() if re.match(r"^\|\s*\d+\s*\|", line)]
    added = rows(documents["ROADMAP.md"])
    if [int(row[1]) for row in added] != list(range(51, 101)):
        raise ValueError("roadmap must preserve IDs 51–100")
    for row in added:
        if row[2].strip() not in STATES:
            raise ValueError(f"invalid state for item{row[1].strip()}: {row[2].strip()}")
    for name, text in documents.items():
        for line in text.splitlines():
            if re.search(r"\b\d+\s+(Implemented|Active|Planned|Review needed)\b", line, re.I):
                raise ValueError(f"aggregate state count in {name}")
    graph = {item: [] for item in range(1, 101)}
    subsets = 0
    for row in added:
        item = int(row[1])
        for token in row[3].strip().split(","):
            match = re.fullmatch(r"(\d+)(?:–(\d+))?(?:\[([a-z0-9-]+)\])?", token.strip())
            if not match:
                raise ValueError(f"invalid dependency for{item}: {token}")
            start, stop, qualifier = match.groups()
            start, stop = int(start), int(stop or start)
            if not 1 <= start <= stop <= 100 or (qualifier and qualifier not in QUALIFIERS):
                raise ValueError(f"invalid range/qualifier for{item}: {token}")
            graph[item].extend(range(start, stop + 1))
            subsets += bool(qualifier)
    visiting, done = set(), set()

    def visit(item, path):
        if item in visiting:
            raise ValueError(f"dependency cycle: {path + [item]}")
        if item in done:
            return
        visiting.add(item)
        for dependency in graph[item]:
            visit(dependency, path + [item])
        visiting.remove(item)
        done.add(item)

    for item in graph:
        visit(item, [])
    return subsets


if __name__ == "__main__":
    print(f"Plan valid: preserved IDs and states; {check()} explicit subset prerequisites; no invalid dependencies or cycles.")
