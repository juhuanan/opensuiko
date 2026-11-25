#!/usr/bin/env python3
"""Export the first shop and basic consumable rules; original pointers stay here."""
from pathlib import Path
import argparse
import hashlib
import json
import struct

import area_scene as scene
import maindec as main
from export_first_room import ROOT, source
from war_text import decode
import preparation
import item_tables


def battle_use(item_id, callback):
    """Shared item scripts; all coordinates are decoded scene units."""
    expected={25:0x800F0708,26:0x800F0850,71:0x800F0920,72:0x800F07AC,80:0x800F09F0}
    if callback!=expected[item_id]:raise ValueError('item callback changed')
    for address,word in {0x800F0788:0x24C6C2F0,0x800F082C:0x24C6C314,
                         0x800F08F4:0x24C6C390,0x800F09C4:0x24C6C3B8,
                         0x800F247C:0x3402001E,0x800F2784:0x2442FFFC,
                         0x800F278C:0x28420081,0x800F2938:0x3402001E,
                         0x800F29D0:0x2442FFFF,0x800F2CD8:0x3063FFFE,
                         0x800F2F18:0x34050005,0x800F2F44:0x14400007,
                         0x800F2F54:0x24423084}.items():
        if main.mword(address)!=word:raise ValueError(f'item lifecycle changed at {address:#x}')
    if item_id in (25,72,80):
        count={25:4,72:8,80:2}[item_id]
        offset={4:0x8016C338,8:0x8016C350,2:0x8016C380}[count]
        vectors=struct.unpack_from('<'+'h'*(count*3),main.body(),offset-main.MBASE)
        particles=[]
        for tick in range(1,30):
            row=[]
            for i in range(count):
                velocity=[int(v*4096/30) for v in vectors[3*i:3*i+3]]
                acceleration=[int(-v*30/435) for v in velocity]
                row.append([(v*tick+a*tick*(tick-1)//2)/4096 for v,a in zip(velocity,acceleration)])
            particles.append(row)
        result=dict(pending_delay=31,impact_delay=32,release_delay=65 if item_id==80 else 64,particle_tint=[64,128,0],particles=particles)
        if item_id==80:result.update(targeting="party",reset_pose=False)
        return result
    if item_id==26:
        return dict(pending_delay=31,impact_delay=31,release_delay=33,particle_tint=[32,64,96],
                    particles=[[[0,0,-512*t*(t-1)/8192]] for t in range(1,30)])
    # The balloon graphic's non-looping burst lasts ten animation updates.
    from battle_bin import parse,LOAD_BASE
    sections,_,errors,data=parse()
    if errors:raise ValueError(errors)
    table=sections[0]['tables']['f'];frame=struct.unpack_from('<I',data,table+5*4)[0]-LOAD_BASE
    if data[frame:frame+4]!=bytes((2,1,1,0)):raise ValueError('balloon burst header changed')
    duration=sum(data[frame+5+2*i] or 256 for i in range(data[frame]))
    return dict(pending_delay=duration+2,impact_delay=duration+2,release_delay=duration+4,particle_tint=[128]*3,particles=[])


def consumables():
    catalog, proof = [], []
    for item_id, stable_id, handler, heal_hp, cure in [
            (25, 'medicine', 0x800D0B74, 100, None),
            (26, 'antitoxin', 0x800D0C08, 0, 'poison'),
            (71, 'needle', 0x800D0C60, 0, 'balloon'),
            (72, 'mega_medicine', 0x800D0CD8, 500, None)]:
        pointer = main.mword(0x80167658 + item_id * 4)
        record = main.body()[pointer-main.MBASE:pointer-main.MBASE+36]
        name, _ = decode(record, 0)
        price, flags, uses, kind, battle = struct.unpack_from('<IHBBI', record, 24)
        if flags & 12 != 12 or main.mword(0x80167928 + kind * 4) != handler:
            raise ValueError(f'unsupported item descriptor: {stable_id}')
        catalog.append(dict(id=stable_id, name=name, price=price, uses=uses,
                            heal_hp=heal_hp, cure=cure,battle=battle_use(item_id,battle)))
        proof.append(dict(id=stable_id, item_id=item_id, record=hex(pointer),
                          field_effect=hex(handler), battle_callback=hex(battle)))
    return catalog, proof


def battle_reusables():
    item_id=80
    pointer=main.mword(0x80167658+item_id*4)
    record=main.body()[pointer-main.MBASE:pointer-main.MBASE+36]
    name,_=decode(record,0)
    price,flags,uses,kind,callback=struct.unpack_from('<IHBBI',record,24)
    if (name,price,flags,uses,kind,callback)!=('Dragon seal incense',0,12,0,11,0x800F09F0):
        raise ValueError('Dragon seal incense record changed')
    for pc,word in {0x800D1268:0x2463AB28,0x800F0AD4:0x24C6C3DC,
                    0x800F0AD8:0x0C038E08,0x800F21F8:0x1062000D,
                    0x800F21FC:0x2402FFCE,0x800F2230:0xAE830000,
                    0x800F2238:0x2631C380,0x800F5270:0x18400009}.items():
        if main.mword(pc)!=word:raise ValueError(f'Dragon seal lifecycle changed at {pc:#x}')
    import journey_battle
    script=journey_battle.script_at(main.body(),0x8016C3DC-main.MBASE)
    if script!=[(15,(0,1)),(30,(2,)),(35,(0,9)),(34,(1290,)),(31,(99,)),(3,(1,)),(16,(0,1)),(0,())]:
        raise ValueError('Dragon seal recipient descriptor changed')
    label,_=decode(main.body()[0x8016AB28-main.MBASE:0x8016AB80-main.MBASE],0)
    if 'only during battles' not in label:raise ValueError('Dragon seal field-use help changed')
    return [dict(id='dragon_seal_incense',name=name,price=price,uses=uses,heal_hp=50,cure=None,
                 field_usable=False,battle=battle_use(item_id,callback))],dict(item_id=item_id,record=hex(pointer),
                 field_effect='0x800D1244',battle_callback=hex(callback),recipient='0x8016C3DC',
                 help='0x8016AB28',particle_vectors='0x8016C380',shared_helper='0x800F215C',
                 consumption='zero-use count skips decrement/removal at0x800F5270')


def automatic_revival():
    """Buddha's automatic KO branch, measured from script installation (age0)."""
    item_id = 83
    pointer = main.mword(0x80167658 + item_id * 4)
    record = main.body()[pointer-main.MBASE:pointer-main.MBASE+36]
    name, _ = decode(record, 0)
    if (name, *struct.unpack_from('<IHBBI', record, 24)) != ('Sacrificial Buddha', 5000, 0, 1, 0, 0):
        raise ValueError('Sacrificial Buddha record changed')
    words = {
        0x800E0A7C:0x0C038D63, 0x800E0A9C:0x1C600009,
        0x800E0AAC:0x14400029, 0x800E0AB4:0x0C038B24,
        0x800E2CB4:0x34020004, 0x800E2CF0:0x34060053,
        0x800E2D08:0x0C032902, 0x800E2D18:0x24C6C400,
        0x800E2D24:0x08038B65, 0x800E2D48:0x0C0381DE,
        0x800E2D54:0x2A020009, 0x800E2D7C:0xA0430045,
        0x8016BB88:0x800F3170, 0x8016BB8C:0x800F32D4,
        0x800F31FC:0x90450000, 0x800F3214:0x34050080,
        0x800E1F50:0x0C038811, 0x800E2050:0xA0850000,
        0x800E206C:0xA0800002,
        0x800F3218:0x34630004, 0x800F3224:0x00003021,
        0x800F3228:0x00003821, 0x800F3234:0x2A220004,
        0x800F3270:0x3C020003, 0x800F3274:0x34422000,
        0x800F3280:0x3402003C, 0x800F32A0:0x24421DA4,
        0x800F1E18:0x2442FFFF, 0x800F1E1C:0x1C400011,
        0x800F1E24:0x340200FF, 0x800F1E4C:0x24421FCC,
        0x800F19DC:0x0043001A, 0x800F19C8:0xAE200154,
        0x800F1A18:0x001310C0, 0x800F1A54:0x0C05423B,
        0x800F1A64:0x00031B03, 0x800F1A98:0x0C054204,
        0x800F1AA8:0x00031B03, 0x800F1AC0:0xAE400008,
        0x800F20BC:0x2442FFFC, 0x800F20C4:0x28420081,
        0x800F20E0:0x34020063, 0x800F20F8:0x0C038ACF,
        0x800F3344:0x000517C2, 0x800F3348:0x00A22821,
        0x800F334C:0x00052843, 0x800F3350:0x0C038595,
        0x800E16E8:0x30428000, 0x800E177C:0xA462004E,
    }
    for pc, word in words.items():
        if main.mword(pc) != word:
            raise ValueError(f'Sacrificial Buddha lifecycle changed at {pc:#x}')
    import journey_battle
    script = journey_battle.script_at(main.body(), 0x8016C400-main.MBASE)
    expected = [(15,(0,1)),(4,(3,)),(3,(15,)),(30,(0,)),(35,(0,6)),
                (34,(2068,)),(31,(99,)),(3,(1,)),(30,(0,)),(35,(0,7)),
                (31,(99,)),(4,(2,)),(3,(10,)),(4,(0,)),(16,(0,1)),(0,())]
    if script != expected:
        raise ValueError('Sacrificial Buddha recipient descriptor changed')
    # Shared callbacks run after the script; KO installs this script after its
    # actor's current update, so its initial wait first resumes on the next tick.
    birth = script[2][1][0] + 1
    move_start = birth + 2
    timer = main.mword(0x800F3280) & 0xffff
    fade_start = birth + timer + 2
    white_end = fade_start + (255-128+3)//4 - 1
    pending = white_end + 3
    result = dict(id='sacrificial_buddha', name=name, price=5000,
                  hp_divisor=2, clone_birth=birth, clone_motion_start=move_start,
                  clone_motion_stop=fade_start-1, clone_release=white_end+1,
                  white_start=fade_start, white_end=white_end,
                  pending_delay=pending, impact_delay=pending+1,
                  recovery_start=pending+1, release_delay=pending+1+script[12][1][0],
                  particle_tint=[128,0,0], particle_plane_z=0, particles=[])
    from export_spell_scenes import effect_sine
    radius = 0x32000
    for age in range(1, timer):
        remaining = timer-age
        radius -= radius // remaining
        units = radius >> 12
        result['particles'].append([
            [units*effect_sine(((age+8*i)%32)*128+1024)/4096,
             units*effect_sine(((age+8*i)%32)*128)/4096]
            for i in range(4)])
    proof = dict(item_id=item_id, record=hex(pointer), descriptor_quantity=1,
                 consumption='first matching inventory slot is removed whole; not manual use',
                 knockout='0x800E2C90; battle mode4, HP0 and actor lock clear',
                 driver='0x800E09BC; actor script/callback precedes KO installation',
                 recipient='0x8016C400', helpers=['0x800F3170','0x800F1DA4','0x800F1FCC','0x800F32D4'],
                 trajectory='0x800F198C; Q12 radius,32 angular steps,4 clones,absolute Z0',
                 clone_pose='0x800E1E3C/0x800E2044; first pose of selected down animation3, held without animation updates',
                 sine_table='0x801765BC; consumers0x80150810/0x801508EC',
                 status='Buddha branch skips ordinary class0..8 clearing and inactive flags',
                 hp='0x800E1654; pending half-maxHP recovery respects protection',
                 sound=2068, words={hex(pc):hex(word) for pc,word in words.items()})
    return result, proof


def appraisals():
    fee_word = main.mword(0x800DBC58)
    assert fee_word == 0x2442FE0C
    fee = 0x10000 - (fee_word & 0xFFFF)
    result, proof = [], []
    for item in item_tables.items():
        item_id=item["id"]
        pointer = item["addr"]
        record = main.body()[pointer-main.MBASE:pointer-main.MBASE+36]
        name, _ = decode(record, 0)
        price, flags = struct.unpack_from('<IH', record, 24)
        if not flags&0x7000:continue
        assert flags&0x7000 in (0x1000,0x2000,0x4000)
        stable_id=preparation.stable_id(name)
        result.append(dict(id=stable_id, name=name, price=price, fee=fee))
        label={0x1000:0x8016bc68,0x2000:0x8016bc70,0x4000:0x8016bc7c}[flags&0x7000]
        proof.append(dict(id=stable_id, native_id=item_id, descriptor=hex(pointer),
                          unidentified_name=decode(main.body(),label-main.MBASE)[0]))
    return result, proof


def export():
    data, provenance = source('/VB6.BIN')
    entry = scene.entities(data, scene.room_record(data, 9))[2]
    script = entry['stream_offsets'][2]
    if data[script:script + 4] != bytes.fromhex('43 02 00 fd'):
        raise ValueError('shop service changed')
    arguments = scene.ptr_at(data, scene.root(data) + 16)
    context = scene.ptr_at(data, arguments + 12)
    stock = scene.ptr_at(data, context)
    ids = list(data[stock:data.index(0, stock)])
    if ids != [25, 72, 71, 143]:
        raise ValueError('shop stock changed')
    item = main.mword(0x80167658 + ids[0] * 4)
    record = main.body()[item - main.MBASE:item - main.MBASE + 36]
    name, _ = decode(record, 0)
    price, flags, uses, kind = struct.unpack_from('<IHBB', record, 24)
    handler = main.mword(0x80167928 + kind * 4)
    if flags & 12 != 12 or handler != 0x800D0B74 or main.mword(handler + 0x3C) != 0x24420064:
        raise ValueError('unsupported field item effect')
    greeting_offset = scene.ptr_at(data, context + 4)
    greeting, _ = decode(data, greeting_offset)
    catalog, item_proof = consumables()
    reusables,reusable_proof=battle_reusables()
    revival,revival_proof=automatic_revival()
    from battle_bin import battle_bin_lba
    battle_lba,battle_size=battle_bin_lba()
    supported = {row['item_id']: row['id'] for row in item_proof}
    supported.update({row['crystal']:row['id'] for row in preparation.rune_bindings()})
    appraisal_catalog, appraisal_proof = appraisals()
    decorations=[dict(id=row['id'],name=row['name'],price=row['price'],uses=0) for row in appraisal_catalog]
    rules = {'schema': 'suikoden-items/7', 'appraisals': appraisal_catalog, 'room': 'vb6_shop', 'npc': 'shopkeeper',
             'greeting': greeting, 'medicine': {'name': name, 'price': price, 'uses': uses, 'heal_hp': 100},
             'consumables': catalog, 'battle_reusables':reusables, 'automatic_revival':revival, 'goods':preparation.crystal_goods()+decorations, 'equipment_goods': preparation.equipment_goods(), 'stock': [supported[i] for i in ids if i in supported]}
    proof = {'schema': 'suikoden-items-provenance/1', 'sources': [provenance,
             {'file': 'MAIN.EXE', 'lba': main.EXE_LBA, 'size': main.EXE_SIZE,
              'image_sha256': hashlib.sha256(main.body()).hexdigest(),
              'parser': 'PS-X EXE header stripped; maindec.py'},
             {'file':'DATA/00_INIT/BATTLE.BIN','lba':battle_lba,'size':battle_size,
              'parser':'battle_bin.py section0 f-record5; ten-update non-looping balloon burst'}],
             'exporter': 'export_shop.py v11 + preparation.py v1', 'text_decoder': 'war_text.py',
             'shop_script_offset': script, 'context_offset': context, 'stock_offset': stock,
             'stock_item_ids': ids, 'medicine_id': ids[0], 'medicine_record': hex(item),
             'field_effect': hex(handler), 'greeting_offset': greeting_offset,
             'consumables': item_proof, 'battle_reusables':reusable_proof, 'rune_crystals': preparation.rune_bindings(),
             'automatic_revival': {'profile':revival,'proof':revival_proof,'runtime':'per-member KO lifecycle and source-world clone composition'},
             'battle_effects': {'particles':'MAIN:0x8016C338/0x8016C350; integrator0x800F1AF8; healer0x800F215C; cure0x800F2838',
                               'clocks':'MAIN:0x800F24E0/0x800F26CC/0x800F297C/0x800F2C54/0x800F2EB8/0x800F3084',
                               'visual_limits':['Detached poison and Needle burst use shared status art in spell schema43; native GPU/material and human media review remain open.'],
                               'remaining_items':['Sacrificial Buddha: additional actor/formation qualification, material/GPU review, SFX and media acceptance remain.']},
             'appraisal_items': appraisal_proof, 'appraisal_fee': '0x800DBBF4; 0x800DBC58:500',
             'rune_mapping_table': '0x8016B080; 29 rows after sentinel', 'omitted_stock_item_ids': [i for i in ids if i not in supported],
             'consumers': ['0x801397D0', '0x800D1BE4', '0x800D32B0', '0x800CA38C',
                           '0x800CBBE8', '0x800D0B74', '0x800D0C08', '0x800D0C60',
                           '0x800D0CD8', '0x800CC164', '0x800D5548', '0x800D3BC4', '0x800D4014'],
             'port_limits': ['gear/urn/rune-piece sales await their transaction rules',
                             'field use requires a living target and refuses no effect; battle use spends at dispatch',
                             'balloon acquisition and original item effect graphics remain outside this batch',
                             'one bundle per purchase; choose a party member with a free slot',
                             'nine inventory slots per member; no starting items']}
    return {'items.json': rules, 'items.provenance.json': proof}


def write(output, verify=False):
    target = Path(output).resolve()
    if not verify and ROOT / 'kit/work/accepted' in (target, *target.parents):
        raise ValueError('semantic export must not write the accepted tree')
    for name, value in export().items():
        path = target / name
        encoded = json.dumps(value, indent=2) + '\n'
        if verify:
            if not path.is_file() or path.read_text() != encoded:
                raise ValueError(f'stale shop export: {path}')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(encoded)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'game/assets')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    write(args.out, args.verify)
    print('Shop metadata verified' if args.verify else 'Shop semantic metadata exported')
