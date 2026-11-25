#!/usr/bin/env python3
"""Check generated profile facts against B's pinned source catalogue."""
import argparse
import json
from pathlib import Path


def check(candidate, party):
    source = {row['id']: row for row in party['characters']}
    gear = candidate['equipment']
    for entry in candidate['profiles']:
        profile = entry['profile']
        character = source[profile['id']]
        seed = character['seed']
        assert profile['name'] == character['name']
        assert profile['growth'] == character['growth']
        assert profile['rune_locked'] == seed['rune_locked']
        assert profile['weapon']['names'] == seed['weapon']['names']
        assert profile['weapon']['powers'] == seed['weapon']['powers']
        assert profile['weapon']['initial_level'] == seed['weapon']['level']
        assert entry['resource_sha256'] == character['resource_sha256']
        for item in gear:
            assert (profile['id'] in item['allowed_members']) == (item['id'] in character['allowed_equipment'])
    print(f'PASS {len(candidate["profiles"])} profile fact sets and {len(candidate["profiles"]) * len(gear)} equipment eligibility comparisons')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--party', type=Path, required=True)
    args = parser.parse_args()
    check(json.loads(args.candidate.read_text()), json.loads(args.party.read_text()))
