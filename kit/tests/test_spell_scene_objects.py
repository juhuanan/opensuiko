#!/usr/bin/env python3
"""Independent constructor operands, loop bounds and changed-source checks."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import spell_scene_source as source
import spell_scene_objects as compiler
from disc import extract


class ObjectCompiler(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760);cls.base,size=struct.unpack_from('<II',exe,24)
        cls.image=exe[2048:2048+size];cls.report=compiler.catalogue()

    def spell(self,identifier):return next(s for s in self.report['spells'] if s['id']==identifier)

    def test_catalogue_reproduces_and_retains_unknown_bindings(self):
        self.assertEqual(json.loads(json.dumps(self.report)),json.loads((ROOT/'kit/data/reports/spell_object_constructors.json').read_text()))
        self.assertEqual(self.report['coverage'],dict(spells=33,objects=990,blocked_sites=0,unbound_slots=72,dynamic_parameters=457))
        self.assertFalse(any(s['blocked'] for s in self.report['spells']))

    def test_source_array_bounds_and_staggered_initializers_agree_with_raw_operands(self):
        for address,expected in {0x80105A98:0x2AA20006,0x8011057C:0x2A82000A,
                                 0x8011219C:0x2A820028,0x80110E28:0x2A820010}.items():
            self.assertEqual(struct.unpack_from('<I',self.image,address-self.base)[0],expected)
        for identifier,count,animation in [('spell_9',6,3),('spell_21',10,3),('spell_23',16,6),('spell_33',40,4)]:
            objects=[o for o in self.spell(identifier)['objects'] if o['animation']==animation]
            self.assertEqual(len(objects),count)
            self.assertEqual([o['instance'] for o in objects],list(range(count)))
        copper=[o for o in self.spell('spell_23')['objects'] if o['animation']==6]
        self.assertEqual([o['delay'] for o in copper],[5*i for i in range(16)])
        self.assertTrue(all(o['initial'][8]==-56*4096 and o['size']==1 for o in copper))
        arrows=[o for o in self.spell('spell_1')['objects'] if o['animation']==8]
        self.assertEqual([o['delay'] for o in arrows],[(i+1)*64//15 for i in range(15)])
        self.assertEqual([o['initial'][0] for o in arrows],[-(i+1)*109226 for i in range(15)])
        glyphs=[o for o in self.spell('spell_17')['objects'] if o['animation']==0]
        self.assertEqual([o['delay'] for o in glyphs],[3*i for i in range(6)])
        self.assertEqual([o['initial'][70] for o in glyphs],[(6-i)*128//6 for i in range(6)])

    def test_party_dependent_loop_and_changed_bound_need_no_spell_override(self):
        facts=source.source_facts(0x801068F4)
        for party in range(1,7):
            result=compiler.constructors(facts,party_count=party)
            self.assertFalse(result['blocked'])
            self.assertEqual(sum(o['animation']==3 for o in result['objects']),4*party)
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x8011057C-self.base,0x2A820007)
        image=source.Image(raw,self.base);facts,_=source.analyze(0x80110460,image)
        changed=compiler.constructors(facts,image)
        self.assertEqual(sum(o['animation']==3 for o in changed['objects']),7)
        self.assertEqual([o['slot'] for o in changed['objects'] if o['animation']==3],[24+4*i for i in range(7)])
        with self.assertRaisesRegex(ValueError,'party size'):compiler.constructors(facts,image,0)

    def test_constant_division_is_only_folded_in_the_acyclic_compiler_pass(self):
        # Compile constant expressions; neither pass executes a CPU or an effect.
        words=[0x2404FFF9,0x34050003,0x0085001A,0x00003012,0x00003810,0x03E00008,0]
        image=source.Image(struct.pack('<7I',*words),0x1000)
        ordinary=source.Analysis(image,0x1000)
        folded=source.Analysis(image,0x1000,cut_backedges=True)
        self.assertIsNone(ordinary.before[0x1014][6])
        self.assertEqual(folded.before[0x1014][6:8],(-2,-1))

    def test_forward_constant_guards_preserve_delay_slots_and_cut_loop_exits(self):
        # bgez bypasses the negative-division adjustment; its delay slot still runs.
        words=[0x24040008,0x04810002,0x00802821,0x24850003,0x00052883,
               0x24A5FFFF,0x14A0FFFE,0,0x00A03021,0x03E00008,0]
        image=source.Image(struct.pack('<11I',*words),0x1000)
        ordinary=source.Analysis(image,0x1000)
        folded=source.Analysis(image,0x1000,cut_backedges=True)
        self.assertIsNone(ordinary.before[0x1010][5])
        self.assertNotIn(0x100c,folded.before)
        self.assertEqual(folded.before[0x1010][5],8)
        self.assertEqual(folded.before[0x1020][5],1)
        # A negative input takes the adjustment before the same arithmetic shift.
        words[0]=0x2404FFF9
        negative=source.Analysis(source.Image(struct.pack('<11I',*words),0x1000),0x1000,cut_backedges=True)
        self.assertEqual(negative.before[0x1010][5],-4)

    def test_arranged_bolt_constructor_operands_need_no_spell_override(self):
        bolts=[o for o in self.spell('spell_19')['objects'] if o['animation'] in (7,9)]
        self.assertEqual([o['delay'] for o in bolts],[0]*4+[25]*4+[50]*4+[0]*4)
        self.assertEqual([o['initial'][0] for o in bolts],[120*4096]*4+[80*4096]*4+[40*4096]*4+[20*4096]*4)
        self.assertEqual([o['initial'][68] for o in bolts],[0,1024,2048,3072]*4)
        # Change the encoded radial spacing. Every specialized constructor follows it.
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x8010D9EC-self.base,0x34020079)
        image=source.Image(raw,self.base);facts,_=source.analyze(0x8010D870,image)
        changed=[o for o in compiler.constructors(facts,image)['objects'] if o['animation']==9]
        self.assertEqual([o['initial'][0] for o in changed],[121*4096]*4+[81*4096]*4+[41*4096]*4)


    def word(self,address):return struct.unpack_from('<I',self.image,address-self.base)[0]

    def test_nested_arrays_match_independent_raw_bounds_delays_and_pointer_paths(self):
        # Each source site has an outer allocation and an inner graphics loop.
        self.assertEqual(self.word(0x80100390),0x2A42000A)
        self.assertEqual(self.word(0x801003A0),0x2A220004)
        self.assertEqual(self.word(0x80100398),0x26100006)
        self.assertEqual(self.word(0x80100388),0x00111A80)
        self.assertEqual(self.word(0x801168B8),0x2A42000A)
        self.assertEqual(self.word(0x801168C8),0x26D60004)
        self.assertEqual(self.word(0x801168CC),0x2AC20010)
        self.assertEqual(self.word(0x801168D4),0x26B50003)
        self.assertEqual(self.word(0x8011688C),0x00143040)
        for identifier,site,root_slot,delay in [('spell_3',0x80100360,40,lambda group,index:6*index),('spell_28',0x80116890,4,lambda group,index:6*group)]:
            rows=[r for r in self.spell(identifier)['objects'] if r['site']==site]
            self.assertEqual(len(rows),40)
            for i,row in enumerate(rows):
                group,index=divmod(i,10)
                self.assertEqual(row['indices'],[group,index])
                self.assertEqual([r['count'] for r in row['loops']],[4,10])
                self.assertEqual(row['slot_path'],[root_slot+4*group,4*index])
                self.assertEqual(row['instance'],i)
                self.assertEqual(row['delay'],delay(group,index))
                self.assertEqual(row['enabled'],0)
                self.assertEqual(row['looping'],int(identifier=='spell_28'))
                self.assertEqual(row['size'],8192 if identifier=='spell_28' else 4096)
                if identifier=='spell_3':self.assertEqual(row['initial'],{0:150*4096,68:group*1024})
                else:self.assertEqual(row['node_initial'],{26:512})

    def test_changed_nested_bounds_and_induction_steps_propagate_without_spell_overrides(self):
        for address,word,count,delays in [(0x80100390,0x2A420007,28,[6*i for _ in range(4) for i in range(7)]),
                                          (0x801003A0,0x2A220003,30,[6*i for _ in range(3) for i in range(10)]),
                                          (0x80100398,0x26100005,40,[5*i for _ in range(4) for i in range(10)])]:
            raw=bytearray(self.image);struct.pack_into('<I',raw,address-self.base,word)
            image=source.Image(raw,self.base);facts,_=source.analyze(0x80100168,image)
            result=compiler.constructors(facts,image);self.assertFalse(result['blocked'])
            rows=[r for r in result['objects'] if r['site']==0x80100360]
            self.assertEqual(len(rows),count);self.assertEqual([r['delay'] for r in rows],delays)
            self.assertEqual(len({tuple(r['slot_path']) for r in rows}),count)
        raw=bytearray(self.image);struct.pack_into('<I',raw,0x801168D4-self.base,0x26B50005)
        image=source.Image(raw,self.base);facts,_=source.analyze(0x80116660,image)
        rows=[r for r in compiler.constructors(facts,image)['objects'] if r['site']==0x80116890]
        self.assertEqual([r['delay'] for r in rows],[10*i for i in range(4) for _ in range(10)])

    def test_unsafe_nested_product_and_modified_outer_counter_are_explicit_blockers(self):
        for address,word,reason in [(0x80100390,0x2A420028,'unsafe_constructor_instance_count'),
                                    (0x80100398,0x26310001,'constructor_counter_modified_by_nested_loop')]:
            raw=bytearray(self.image);struct.pack_into('<I',raw,address-self.base,word)
            image=source.Image(raw,self.base);facts,_=source.analyze(0x80100168,image)
            result=compiler.constructors(facts,image)
            self.assertEqual([b for b in result['blocked'] if b['site']==0x80100360],[dict(site=0x80100360,reason=reason)])
            self.assertFalse(any(r['site']==0x80100360 for r in result['objects']))


if __name__=='__main__':unittest.main()
