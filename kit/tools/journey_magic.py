"""Named spell effects recovered from the original callback operands."""
import spell_rules
import item_tables
import maindec as main

# Native spell IDs and damage callback arguments (element, base power).
DAMAGE = {1:('fire',100),2:('fire',150),3:('fire',400),4:('fire',700),
          14:('wind',400),16:('wind',500),17:('lightning',150),18:('lightning',100),
          19:('lightning',600),20:('lightning',1000),22:('earth',300),24:('earth',700)}
ELEMENTS = ('fire','water','earth','lightning','wind')


def bind_story_rune(systems):
    record = main.mword(item_tables.RUNE_NAME_PTR)
    name = item_tables.name_at(record, item_tables.RUNE_NAME_LIMIT)
    native_ids = [item_tables.byte(record + item_tables.RUNE_SPELL_OFF + tier)
                  for tier in range(item_tables.RUNE_SPELL_BYTES)]
    if name != 'Soul Eater' or native_ids != [25, 26, 27, 28]:
        raise ValueError('Soul Eater record differs from the qualified story rune')
    spells = {spell['id']: (index, spell['name']) for index, spell in enumerate(systems['spells'])}
    spell_ids = [f'spell_{native}' for native in native_ids]
    if any(spell_id not in spells for spell_id in spell_ids):
        raise ValueError('Soul Eater requires all four spell descriptors')
    definition = dict(id='soul_eater', name=name, spells=[spells[key][0] for key in spell_ids],
                      spell_names=[spells[key][1] for key in spell_ids], allowed_members=['hero'])
    existing = next((rune for rune in systems['runes'] if rune['id'] == definition['id']), None)
    if existing is None:
        systems['runes'].append(definition)
    elif existing != definition:
        raise ValueError('conflicting Soul Eater definition in the input package')
    return dict(id=definition['id'], source='MAIN.EXE', lba=main.EXE_LBA,
                offset=main.EXE_HEADER + record - main.MBASE, spell_ids=spell_ids,
                decoder='journey_magic.bind_story_rune', recipient_writer='MAIN.EXE:0x80141AC0')


def export(systems):
    names=item_tables.spell_names()
    existing={int(row['id'].removeprefix('spell_')):row for row in systems['spells']}
    for native,(element,power) in DAMAGE.items():
        pointer=main.mword(0x8016D33C+4*native)
        flags=main.body()[pointer-main.MBASE+22]
        existing[native]=dict(id=f'spell_{native}',name=names[native-1],kind='damage',
            allies=False,group=not bool(flags&2),power=power,element=element,field_use=False)
    existing[12]=dict(id='spell_12',name=names[11],kind='heal',allies=True,group=True,
                      power=300,clear_status=True,field_use=True)
    for native,kind,allies,group,power in [(10,'skill_bonus_scale',False,True,80),(21,'defense_bonus_scale',True,False,150),(23,'protection',True,False,3)]:
        existing[native]=dict(id=f'spell_{native}',name=names[native-1],kind=kind,allies=allies,group=group,power=power,field_use=False)
    # Preserve existing indices used by saves; append source-rule descriptors.
    _, reviewed = spell_rules.build()
    for rule in reviewed['spells']:
        native = rule['native_id']
        if native not in existing and rule['status'] == 'supported':
            existing[native] = dict(id=rule['id'], name=rule['name'], kind='source_rule',
                allies=rule['target_side'] == 'ally', group=rule['selection'] != 'single',
                power=1, field_use=False)
    systems['spells']=list(existing.values())
    indices={native:index for index,native in enumerate(existing)}
    for rune,source in zip(systems['runes'],item_tables.runes(),strict=True):
        rune['spells']=[indices.get(native) for native in source['spell_ids']]
    proof=[]
    for native,spell in existing.items():
        pointer=main.mword(0x8016D33C+4*native)
        flags=main.body()[pointer-main.MBASE+22]
        spell['field_use']=bool(flags&8)
        proof.append(dict(id=spell['id'],descriptor=hex(pointer),flags=flags,
                          callback=hex(main.mword(pointer+28))))
    return proof
