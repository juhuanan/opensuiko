"""Static packet RGB consumer chain and real source recipient lowering."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
import export_unite_programs as compiler
from export_physical_runes import stream, merge_libraries
from test_physical_rune_export import independent_stream


def witness():
    raw,origin=source('/B_DATA.BIN');base=0x80080000
    pointer=lambda offset:struct.unpack_from('<I',raw,offset)[0]-base
    directory=pointer(pointer(pointer(0)+12));records=pointer(directory+12)
    record=pointer(records+3*4);table=pointer(record+40);start=pointer(table+2*4)
    ops,spans=stream(raw,origin,start,table,base)
    instructions,blocked,effects=compiler.compile_operations(ops)
    if blocked or effects:raise ValueError('Unbound Commander recipient')
    member,member_origin=source('/SHU.BIN')
    resource,proof=compiler.animation_resource('hero',member,member_origin,{0,1})
    programs=[dict(id='beast_commander/recipient',instructions=instructions)]
    return dict(schema='suikoden-actor-color-witness/1',
        programs=dict(schema=compiler.program_schema(programs),programs=programs),
        animations=dict(schema='suikoden-actor-animations/1',resources=[resource]),
        source=dict(record_offset=record,table_offset=table,spans=spans,operations=ops,resource=proof),
        clocks=dict(red=3,restore=21,status=36,halt=46))


class ActorColor(unittest.TestCase):
    def test_source_frame_builder_retains_rgb_and_constructor_initializes_neutral(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        frame=main[2048+0x800e211c-base:2048+0x800e256c-base]
        self.assertEqual(hashlib.sha256(frame).hexdigest(),
            '31258efb3f524c3b4633922184aa8b82ca8c4e3fbde5102b7f91686fa700e5e3')
        for address,expected in {
            0x800e1e9c:0x34170080,0x800e1f04:0xa2170004,
            0x800e1f08:0xa2170005,0x800e1f0c:0xa2170006,
            0x800e24e4:0x8ce30004,0x800e24f4:0xacc30004,
        }.items():self.assertEqual(word(address),expected,hex(address))
        # Pose material rebuilds retain RGB; whole-packet mirroring copies the color word.
        stores=[w for (w,) in struct.iter_unpack('<I',frame) if w>>26 in (40,41)]
        self.assertFalse(any(w&65535 in (4,5,6) for w in stores))

    def test_real_commander_recipient_and_resource_agree_with_independent_raw_stream(self):
        result=witness();proof=result['source'];raw,_=source('/B_DATA.BIN')
        start=proof['spans'][0]['source_offset']
        self.assertEqual(proof['operations'],independent_stream(raw,start,proof['table_offset'],0x80080000))
        self.assertEqual([op['args'] for op in proof['operations'] if op['op']==41],[[255,64,64],[128,128,128]])
        operations=proof['operations']
        red=operations[4]['args'][0]
        restore=red+sum(op['args'][0] for op in operations[9:26] if op['op']==3)
        status=red+operations[7]['args'][1]+operations[30]['args'][0]
        halt=status+operations[33]['args'][1]
        self.assertEqual(result['clocks'],dict(red=red,restore=restore,status=status,halt=halt))
        self.assertEqual(result,json.loads((ROOT/'game/tests/fixtures/actor_color_source.json').read_text()))

    def test_color_schema_and_source_byte_narrowing_are_explicit(self):
        for incoming,expected in (([255,64,64],[255,64,64]),([-1,256,65535],[255,0,255])):
            code,blocked,effects=compiler.compile_operations([dict(op=41,args=incoming),dict(op=0,args=[])])
            self.assertEqual((blocked,effects),([],[]))
            self.assertEqual(code[0],dict(command=dict(color=expected)))
            self.assertEqual(compiler.program_schema([dict(id='color',instructions=code)]),'suikoden-actor-programs/12')
        for args in ([1,2], [True,0,0], [65536,0,0], [-32769,0,0]):
            self.assertTrue(compiler.compile_operations([dict(op=41,args=args),dict(op=0,args=[])])[1])

    def test_merge_retains_older_programs_and_chooses_color_schema(self):
        old=dict(programs=dict(schema='suikoden-actor-programs/11',programs=[dict(id='old',instructions=[dict(halt={})])]),animations=dict(resources=[]))
        extra=witness();merge_libraries(old,extra)
        self.assertEqual(old['programs']['schema'],'suikoden-actor-programs/12')
        self.assertEqual(next(p for p in old['programs']['programs'] if p['id']=='old'),dict(id='old',instructions=[dict(halt={})]))


if __name__=='__main__':
    if '--write-fixture' in sys.argv:
        (ROOT/'game/tests/fixtures/actor_color_source.json').write_text(json.dumps(witness(),separators=(',',':'))+'\n')
        sys.argv.remove('--write-fixture')
    unittest.main()
