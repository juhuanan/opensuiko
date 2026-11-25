"""Use the shared static constructor compiler for actor-owned effect workers."""
import argparse
import json
from pathlib import Path
import struct

from export_first_room import ROOT, source
from export_enemy_area_magic import BASE, span
import spell_scene_source as analysis
import spell_scene_objects as objects
import spell_scene_columns as columns

SCENE = ('argument','battle_scene')
IMPORT_TABLE = 0x8016b680
IMPORT_SIZE = 0x15c
IMPORT_SHA256 = '3e63ef284688166cafd239e99367d3a69b50e31b4368c73c56fa73528cf826bd'
INITIALIZERS = (
    ('sorcerer','E',0x900,0xad0,0,'da5e4dca335729fb2d9c80c796c706393cb8ae2f14e396b84a724233110c420a'),
    ('siren','G',0xa90,0xcdc,12,'07d6798260d3757e7109463084af094906ddbef3116f081db61b8de9dfac1025'),
    ('earth_golem','H',0x3088,0x31e8,0,'1521fe4a02eb623eccf51cb34c9c9aa9d89d49a6ff0489258ab803508b62692e'),
)


class ActorImage(analysis.Image):
    """Bind callback arguments and immutable imports, retaining other reads as symbols."""
    def __init__(self,region,actor_index=0):
        if not 0<=actor_index<12:raise ValueError('invalid actor specialization')
        raw,self.origin=source('/'+region+'_DATA.BIN')
        super().__init__(raw,BASE)
        main,self.main_origin=source('MAIN.EXE')
        self.main=analysis.Image(main[2048:],struct.unpack_from('<I',main,24)[0])
        offset=2048+IMPORT_TABLE-self.main.base
        self.import_proof=span(main,self.main_origin,offset,offset+IMPORT_SIZE,IMPORT_SHA256)
        self.imports=dict(enumerate(struct.unpack('<'+'I'*(IMPORT_SIZE//4),main[offset:offset+IMPORT_SIZE])))
        self.actor_index=actor_index

    def word(self,address):
        if self.base<=address<self.base+len(self.data):return super().word(address)
        return self.main.word(address)

    def entry_registers(self,start):
        if not self.base<=start<self.base+len(self.data):return None
        regs=list((0,)+(None,)*28+(('stack',),)+(None,)*2)
        regs[4]=SCENE;regs[5]=self.actor_index
        return tuple(regs)

    def resolve_load(self,value):
        if isinstance(value,tuple) and len(value)==3 and value[:2]==('member',analysis.member(SCENE,0x1258)):
            slot=value[2]
            if isinstance(slot,int) and 0<=slot<IMPORT_SIZE and slot%4==0:return self.imports[slot//4]
        return value

    def state_root(self,field):
        return analysis.member(analysis.member(SCENE,0xa8+140*self.actor_index),field)


def build(actor_index=0):
    effects=[]
    for identifier,region,start,end,field,digest in INITIALIZERS:
        image=ActorImage(region,actor_index)
        proof=span(image.data,image.origin,start,end,digest)
        facts=dict(initializer=BASE+start,preparation=[],state_root=image.state_root(field))
        sprites=objects.constructors(facts,image)
        column=columns.constructors(facts,image)
        gradients=objects.constructors(facts,image,constructor=image.imports[0xe0//4])
        effects.append(dict(id=identifier,sprites=sprites,columns=column,gradients=gradients,
            provenance=dict(initializer=proof,imports=image.import_proof,
                actor_index_specialization=actor_index,context_field=field)))
    result=dict(schema='suikoden-enemy-effect-constructors/1',producer='enemy_area_magic_constructors.py v1',
        admission='constructor_metadata_only',effects=effects,
        scope='Static initializer parameters only. Actor-owned context initialization, dynamic fields, worker motion/lifetimes, damage/recipient binding, art and live admission remain separate.')
    return json.loads(json.dumps(result))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'kit/work/build/enemy_area_magic/constructors.json')
    output=parser.parse_args().output
    if (ROOT/'kit/work/accepted').resolve() in (output.resolve(),*output.resolve().parents):
        raise ValueError('Constructor metadata is not an accepted asset package')
    result=build()
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(output)
