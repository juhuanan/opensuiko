#!/usr/bin/env python3
"""Static enemy reward, item delivery and balance contracts."""
from hashlib import sha256
import json
from pathlib import Path
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import maindec as M
import area_encounter_tables as A
ROOT = Path(__file__).resolve().parents[2]

G,R,T,E,P,C,GS,BOX=range(0x80200000,0x80280000,0x10000)


def fixture(enemies,randoms=(),runes=(0,),presence=None):
    from test_vb2_dice_states import OverlayInstructions

    c=OverlayInstructions(b'');m=c.mem;count=len(runes)
    m.sw(0x8017BE3C,G);m.sw(0x80179FD0,R);m.sw(0x8017DB24,GS)
    m.sw(G+0x1C,count);m.sw(G+0x24,count+len(enemies));m.sw(G+0x1344,T)
    m.sb(GS+3,count)
    for i,rune in enumerate(runes):
        p=P+256*i;record=C+256*i;m.sw(G+0xF84+12*(i+1),p);m.sw(p+0x1C,record)
        m.sb(record+0x4C,rune);m.sb(GS+0xE+i,i);m.sw(GS+0x1B9C+4*i,p)
    for i,raw in enumerate(enemies,1):
        m.sw(T+4*i,E+256*i)
        for j,value in enumerate(raw):m.sb(E+256*i+j,value)
        m.sb(G+0x50+140*(count+i),i)
        m.sw(0x8017AAF8+4*i,1 if presence is None else presence[i-1])
    draws=iter(randoms);c.hooks[0x80147E38]=lambda _:next(draws)
    return c


def enemy(amount=100,items=(1,2,3),rates=(50,50,50)):
    b=bytearray(64);struct.pack_into('<H',b,0x34,amount)
    for i,(item,rate) in enumerate(zip(items,rates)):b[0x36+2*i:0x38+2*i]=bytes([item,rate])
    return b


def run(c,pc):
    c.r[31]=0xFFFFFFFC
    return c.run(pc)


def reward(c):
    assert run(c,0x800E9940)==0xFFFFFFFF
    return c.mem.rw(R+0x224C),c.mem.rb(R+0x2250)


def presentation(c):
    m=c.mem;m.sw(R,1);m.sw(R+0x30,BOX);m.sh(BOX+0x20,1)
    for pc in [0x80146DFC,0x80146BB4,0x8014707C]:c.hooks[pc]=0


def check_source():
    body = M.body()
    for start, end, digest in (
        (0x800E9940, 0x800E9CEC, 'e7052aeb018715fee8d9cff1a0a2a58e89577d46c2f66ae07fdd14fd36301100'),
        (0x800E9018, 0x800E91A4, '7ba2fd64a9eaf498f9ad1f2ab7f68037a2b17aa814b61a0b2a91735d769d7d18'),
        (0x800E91A4, 0x800E9410, '86f1faff1c9ea76dcfadb98cce367f8cc3628fb7e0abed471e33c9dc71f06998'),
        (0x800CA2F0, 0x800CA38C, '7e67bbd174e461cc64d40223204820ceaa86169b9c951dcf9dcaa6bab85e9ddc'),
        (0x800CA38C, 0x800CA408, '6e130f849639cfef23dac79cfc99bcbabe54fc5f5692e61007ae4f3baa85a599'),
    ):
        assert sha256(body[start-M.MBASE:end-M.MBASE]).hexdigest() == digest, hex(start)

    for pc, expected in {
        # Initializer, enemy eligibility, signed money and the first successful drop.
        0x800E824C: 0x0C03A650, 0x800E996C: 0xAC40224C, 0x800E9970: 0xA4402250,
        0x800E99D8: 0x2421AAF8, 0x800E99E4: 0x34020001, 0x800E99E8: 0x14620061,
        0x800E99F0: 0x96030034, 0x800E99F8: 0x30620001, 0x800E99FC: 0x10400015,
        0x800E9A00: 0x3402000A, 0x800E9A08: 0x00031C03, 0x800E9A0C: 0x0062001A,
        0x800E9A74: 0x1480003E, 0x800E9A78: 0xAC43224C, 0x800E9A7C: 0x0C051F8E,
        0x800E9A84: 0x34030003, 0x800E9AB0: 0x00001810, 0x800E9AC0: 0x90700036,
        0x800E9AC4: 0x90710037, 0x800E9AC8: 0x12000029, 0x800E9AD0: 0x0C051F8E,
        0x800E9AD8: 0x34030064, 0x800E9B04: 0x00001810, 0x800E9B0C: 0x0071182A,
        0x800E9B24: 0x24217658, 0x800E9B30: 0xA4702250, 0x800E9B34: 0xA0602252,
        0x800E9B38: 0x9482001C, 0x800E9B40: 0x3042000C, 0x800E9B54: 0x9082001E,
        0x800E9B5C: 0xA0622253, 0x800E9B6C: 0xA0402253,
        # Prosperity doubles once per equipped member. Balance uses a signed cap comparison.
        0x800E9BAC: 0x34060017, 0x800E9BD0: 0x9042004C, 0x800E9BD8: 0x14460005,
        0x800E9BE8: 0x00021040, 0x800E9BEC: 0xAC82224C, 0x800E90F4: 0x3C05000F,
        0x800E90F8: 0x34A5423F, 0x800E90FC: 0x00431021, 0x800E9100: 0xAC82001C,
        0x800E9104: 0x00A2102A, 0x800E9110: 0xAC85001C,
        # The ready bit gates delivery. Full inventory retains the item in the overflow slot.
        0x800E923C: 0x96220020, 0x800E9244: 0x30420001, 0x800E9248: 0x1040005A,
        0x800E9250: 0x0C0328BC, 0x800E9254: 0x24842250, 0x800E9258: 0x1440000E,
        0x800E926C: 0xAC502254, 0x800E9270: 0x88432253, 0x800E9274: 0x98432250,
        0x800E9280: 0xA823C05F, 0x800E9288: 0xB823C05C, 0x800E92A0: 0xAC402254,
        0x800E9364: 0x24420001, 0x800E936C: 0xAC620000,
        # First free slot in persistent party order, then the four-byte append.
        0x800CA308: 0x1840001B, 0x800CA320: 0x9042000E, 0x800CA330: 0x8C441B9C,
        0x800CA338: 0x8C82001C, 0x800CA340: 0x9042001F, 0x800CA348: 0x2C420009,
        0x800CA34C: 0x10400005, 0x800CA354: 0x0C0328E3, 0x800CA370: 0x1440FFE7,
        0x800CA3B4: 0x24420001, 0x800CA3B8: 0xA062001F, 0x800CA3D4: 0x89020003,
        0x800CA3D8: 0x99020000, 0x800CA3E0: 0xA862001F, 0x800CA3E4: 0xB862001C,
    }.items():
        assert M.mword(pc) == expected, hex(pc)


def check_disc_records(records, items):
    counts = {}
    for source in A.area_data_files():
        data = A.load(source)
        try:
            _, _, directory, _ = A.chain(data)
        except ValueError:
            continue
        letter = Path(source['path']).name[0].lower()
        word = lambda address: struct.unpack_from('<I', data, address - 0x80080000)[0]
        # Read directory+12's counted pointers independently of the policy asset.
        table = word(directory + 12)
        count = word(table)
        assert 1 <= count <= 32
        for index in range(1, count + 1):
            address = word(table + 4 * index)
            offset = address - 0x80080000
            assert 0 <= offset <= len(data) - 64
            money = struct.unpack_from('<h', data, offset + 0x34)[0]
            pairs = [dict(item=item, rate=rate) for item, rate in
                     struct.iter_unpack('<BB', data[offset + 0x36:offset + 0x3C])]
            assert all(pair['item'] <= 179 for pair in pairs)
            record = records.get(f'area_{letter}.enemy.{index:02}')
            if letter != 'z':
                assert record is not None
                assert (money, pairs) == (record['money_encoded'], record['drops']), record['id']
            else:
                assert record is None
        counts[letter] = count
    assert set(counts) == set('abcdefghz') and sum(counts.values()) == 32
    assert sum(counts.values()) - counts['z'] == len(records) == 29
    for item, uses in items.items():
        address = M.mword(0x80167658 + 4 * item)
        flags, default = struct.unpack_from('<HB', M.body(), address - M.MBASE + 0x1C)
        assert uses == (default if flags & 0x0C else 0), item


def settlement(row, records, items):
    present = [records[name] for name, eligible in zip(row['records'], row['eligible'], strict=True) if eligible]
    delta = sum(int(value / 10) * 100 if value % 2 else value
                for value in (entry['money_encoded'] for entry in present))
    mask = 0xFFFFFFFF
    delta = (delta << sum(row['money_runes'])) & mask
    total = (row['balance'] + delta) & mask
    signed = total if total < 0x80000000 else total - (1 << 32)
    after = 999999 if signed > 999999 else total
    selected = None
    draws = iter(row['draws'])
    for entry in present:
        pair = entry['drops'][next(draws) % 3]
        if pair['item'] and next(draws) % 100 < pair['rate']:
            selected = {'item': pair['item'], 'uses': items[pair['item']]}
            break
    return {
        'money_delta': delta, 'balance_after': after, 'credited': (after - row['balance']) & mask,
        'overflow': (total - after) & mask, 'item': selected, 'eligible_count': len(present),
        'draws_used': len(row['draws']) - sum(1 for _ in draws),
    }


def check():
    check_source()
    directory = ROOT / 'game/assets/campaign_policies'
    policy = json.loads((directory / 'enemy_policy.json').read_text())
    records = {entry['id']: entry for area in policy['areas'] for entry in area['records']}
    items = {entry['id']: entry['default_uses'] for entry in policy['drop_items']}
    assert len(items) == 37
    check_disc_records(records, items)

    rows = json.loads((directory / 'enemy_policy_vectors.json').read_text())['settlements']
    assert len(rows) == len({row['name'] for row in rows}) == 239
    exhausted = 0
    for row in rows:
        try:
            actual = settlement(row, records, items)
        except StopIteration:
            assert row.get('error') == 'RandomInputExhausted', row['name']
            exhausted += 1
        else:
            assert actual == row.get('expect'), (row['name'], actual, row.get('expect'))
    assert exhausted == 1
    print('PASS: static reward chooser, signed balance cap, readiness, party insertion and overflow')
    print('PASS: 32 disc records, 37 item descriptors and 239 retained settlement vectors')


if __name__ == '__main__':
    check()
