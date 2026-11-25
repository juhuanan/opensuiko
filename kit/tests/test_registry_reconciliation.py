#!/usr/bin/env python3
"""Check the first-pass mapping preserves all 92 questions and the partial row."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def check():
    ledger = json.loads((ROOT / 'goals/open_questions_first_pass.json').read_text())
    questions = [json.loads(line) for line in
                 (ROOT / ledger['question_file']).read_text().splitlines()]
    ids = {q['id'] for q in questions}
    assert len(ids) == len(questions), 'duplicate question ids'
    seen, carried = set(), set()
    partial = 0
    for entry in ledger['dispositions']:
        key = (entry['file'], entry['line'])
        assert key not in seen, key
        seen.add(key)
        lines = (ROOT / 'kit/work' / entry['file']).read_text().splitlines()
        row = json.loads(lines[entry['line'] - 1])
        original = entry['original']
        # Only verdict, replacement and annotation may change on historical rows.
        for field in set(original) | set(row):
            if field not in {'evidence', 'superseded_by', 'note'}:
                assert row.get(field) == original.get(field), (key, field)
        assert entry['targets'], ('missing disposition', key)
        if entry['action'] == 'retained_partial':
            assert row == original and row['evidence'] == 'partial'
            partial += 1
        else:
            assert original['evidence'] == 'open' and row['evidence'] == 'superseded'
            for target in entry['targets']:
                if target.startswith('R'):
                    assert target in ids, ('lost live question', key, target)
                    assert target in row['superseded_by']
                    q = next(q for q in questions if q['id'] == target)
                    assert f"kit/work/{entry['file']}:{entry['line']}" in q['source']
                    carried.add(target)
                else:
                    for source in target.split('; '):
                        assert (ROOT / source.split(':')[0]).is_file(), source
                        assert source in row['superseded_by']
    assert len(seen) == 93 and partial == 1
    assert carried == ids, 'orphaned canonical question'
    for name, count in ledger['original_line_counts'].items():
        assert len((ROOT / 'kit/work' / name).read_text().splitlines()) == count, name
    print(f'PASS: 92 source questions + 1 partial preserved; {len(ids)} canonical questions linked')


if __name__ == '__main__':
    check()
