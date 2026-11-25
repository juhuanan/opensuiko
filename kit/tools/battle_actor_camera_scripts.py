#!/usr/bin/env python3
"""Decode battle actor camera scripts from the 04_PLAY character files."""
import json
from pathlib import Path

import character_table
import export_first_room as field
import journey_battle

ROOT = Path(__file__).resolve().parents[2]
CAMERA = {17, 18, 19, 20}


def main():
    out = []
    seen = set()
    for record in character_table.records():
        filename = record['sprite_file']
        if filename in seen:
            continue
        seen.add(filename)
        try:
            data, source = field.source('/' + filename)
        except Exception:
            continue
        for index in range(24):
            try:
                ops = journey_battle.script(data, index)
            except Exception:
                continue
            camera = [dict(op=op, args=list(args)) for op, args in ops if op in CAMERA]
            if camera:
                out.append(dict(file=filename, character=record['name'], script=index,
                                source=source, ops=camera))
    print(json.dumps(out, indent=2))


if __name__ == '__main__':
    main()
