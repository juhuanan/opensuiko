#!/usr/bin/env python3
"""Independent static operands, source mutations and safe compiler joins."""
from pathlib import Path
import json
import struct
import sys
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import spell_scene_source as compiler
from disc import extract


class SpellSource(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760);cls.base,size=struct.unpack_from('<II',exe,24)
        cls.raw=exe[2048:2048+size];cls.catalogue=compiler.catalogue()

    def word(self,address):return struct.unpack_from('<I',self.raw,address-self.base)[0]

    def operand(self,site,register):
        # Independent backward constant definitions, including the jal delay slot.
        def resolve(before,reg):
            if reg==0:return 0
            for pc in range(before,self.base-1,-4):
                if before-pc>128:raise AssertionError('operand has no local constant definition')
                w=self.word(pc);op=w>>26;rt=w>>16&31;rs=w>>21&31
                if op==15 and rt==reg:return (w&65535)<<16
                if op in (8,9,13) and rt==reg:
                    raw=w&65535;value=resolve(pc-4,rs)
                    return ((value|raw) if op==13 else value+(raw-65536 if raw&32768 else raw))&0xffffffff
                if op==0 and w&63 in (33,37) and w>>11&31==reg:
                    return (resolve(pc-4,rs)+resolve(pc-4,rt))&0xffffffff
                if op in (32,33,35,36,37) and rt==reg:raise AssertionError('dynamic camera operand')
            raise AssertionError('operand outside source')
        return resolve(site+4,register)

    def test_all_33_callbacks_and_85_camera_operands_agree_with_independent_raw_definitions(self):
        c=self.catalogue
        self.assertEqual(json.loads(json.dumps(c)),json.loads((ROOT/'kit/data/reports/spell_choreography.json').read_text()))
        self.assertEqual(c['coverage']['spells'],33)
        self.assertEqual(c['coverage']['camera_operands'],85)
        self.assertEqual(c['coverage']['scheduled_cameras'],73)
        self.assertEqual(c['coverage']['scalar_timelines'],31)
        self.assertEqual([s['id'] for s in c['spells']],[f'spell_{i}' for i in range(1,34)])
        for spell in c['spells']:
            for event in spell['cameras']:
                self.assertEqual(self.word(event['site']),0x0C03D844)
                self.assertEqual(event['block'],self.operand(event['site'],4))
                self.assertEqual(event['updates'],self.operand(event['site'],5))
            if spell['table'] is not None:
                self.assertEqual(list(spell['cases'].values()),[self.word(spell['table']+4*i) for i in range(len(spell['cases']))])

    def test_preexisting_independent_scene_models_match_the_compiled_clocks(self):
        expected={'spell_1':[64,96,74,60], 'spell_9':[64,32,90,60,60],
                  'spell_10':[64,32,32,32,32,30,32,32,32]}
        for spell in self.catalogue['spells']:
            if spell['id'] in expected:self.assertEqual([p['updates'] for p in spell['phases']],expected[spell['id']])
        unresolved={s['id']:[p['index'] for p in s['phases'] if p['updates'] is None] for s in self.catalogue['spells'] if any(p['updates'] is None for p in s['phases'])}
        self.assertEqual(unresolved,{'spell_2':[4],'spell_27':[3]})
        charm=next(s for s in self.catalogue['spells'] if s['id']=='spell_8')
        self.assertEqual(charm['preparation'],[0x80105130]);self.assertEqual(charm['updater'],0x801052F8)

    def test_mutating_a_counter_limit_changes_the_compiled_phase_without_a_spell_specific_override(self):
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x800FEE90-self.base,0x2842003F)
        facts,analysis=compiler.analyze(0x800FEB14,compiler.Image(raw,self.base))
        phases=compiler.timeline(facts,analysis)
        self.assertEqual([p['updates'] for p in phases],[63,96,74,60])
        raw=bytearray(self.raw)
        struct.pack_into('<I',raw,0x800FED18-self.base,self.word(0x800FED18)&~(31<<16))
        facts,analysis=compiler.analyze(0x800FEB14,compiler.Image(raw,self.base))
        facts['phases']=compiler.timeline(facts,analysis)
        cameras=compiler.camera_schedule(facts,analysis)
        self.assertEqual([event['at'] for event in cameras],[None,161])
        self.assertIsNotNone(cameras[0]['blocker'])

    def test_equal_one_entry_flag_camera_is_derived_and_mutated_guard_is_rejected(self):
        facts=compiler.source_facts(0x80107294)
        self.assertEqual([c['at'] for c in facts['camera_schedule']],[1,65,187])
        self.assertEqual(self.word(0x80107868),0x34020001)
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x80107868-self.base,0x34020002)
        facts,analysis=compiler.analyze(0x80107294,compiler.Image(raw,self.base))
        facts['phases']=compiler.timeline(facts,analysis)
        cameras=compiler.camera_schedule(facts,analysis)
        self.assertIsNone(cameras[-1]['at'])
        self.assertIsNotNone(cameras[-1]['blocker'])

    def test_delay_slots_caller_clobbers_conflicting_paths_and_unknown_instructions(self):
        # Known callee-clobbered a0 must not survive into a later call.
        words=[0x34040007,0x0C000400,0x3405003C,0x0C000400,0,0x03E00008,0]
        image=compiler.Image(struct.pack('<7I',*words),0x1000)
        analysis=compiler.Analysis(image,0x1000)
        calls=analysis.events('call')
        self.assertEqual(calls[0][1][2][:2],(7,60));self.assertIsNone(calls[1][1][2][0])
        # The two branch arms give a0 different constants; its join is unknown.
        words=[0x10800003,0,0x34040001,0x08000406,0,0x34040002,0x0C000400,0,0x03E00008,0]
        analysis=compiler.Analysis(compiler.Image(struct.pack('<10I',*words),0x1000),0x1000)
        self.assertIsNone(analysis.events('call')[0][1][2][0])
        with self.assertRaisesRegex(ValueError,'unsupported instruction'):
            compiler.Analysis(compiler.Image(struct.pack('<3I',0xfc000000,0x03E00008,0),0x1000),0x1000)
        # SLTIU sign-extends the immediate before the unsigned comparison.
        words=[0x3C041234,0x2C85FFFF,0x0C000400,0,0x03E00008,0]
        analysis=compiler.Analysis(compiler.Image(struct.pack('<6I',*words),0x1000),0x1000)
        self.assertEqual(analysis.events('call')[0][1][2][1],1)

    def test_batch_scalar_report_is_reproducible_and_keeps_unresolved_channels_explicit(self):
        report=compiler.batch_scalar_catalogue()
        self.assertEqual(json.loads(json.dumps(report)),json.loads((ROOT/'kit/data/reports/spell_scalar_programs.json').read_text()))
        self.assertEqual(report['coverage'],dict(spells=33,channels=154,blocked_channels=23,caster_tints=23))
        for spell in report['spells']:
            self.assertFalse(set(spell['channels'])&set(spell['blocked']))
            if spell['id'] not in ('spell_2','spell_27'):
                self.assertEqual(spell['sampled_updates'],sum(p['updates'] for p in spell['phases']))
        self.assertTrue(any(reason['reason']=='conditional_memory_join' for spell in report['spells'] for reasons in spell['blocked'].values() for reason in reasons))

    def test_compiled_healing_and_earth_channels_match_independent_scalar_integrators(self):
        # These equations use independently recorded raw loads/stores, not compiler expressions.
        drops=next(s for s in self.catalogue['spells'] if s['id']=='spell_9')
        cases=[(drops['initializer'],72,76,80),(0x80110460,84,8,12),(0x80112070,208,228,228)]
        for initializer,tint,x,y in cases:
            plan,_=compiler.scalar_profile(initializer);values=compiler.sample_scalar_channels(plan)
            counts=[p['updates'] for p in plan['timeline']]
            intensity=0;scale=1
            update=0
            for phase,count in enumerate(counts):
                for age in range(count):
                    update+=1
                    if initializer==drops['initializer']:
                        intensity+=[8192,-16384,5779,0,-8669][phase]
                        if phase==1 and age==31:intensity=0
                        scale+=[0,0,186413,0,-279620][phase]
                    elif initializer==0x80110460:
                        intensity+=[8192,-16384,0,0,0][phase]
                        scale+=[0,0,209715,0,-262144][phase]
                    else:
                        intensity+=[8192,-16384,0,0,0][phase]
                        scale+=[0,0,262144,0,-262144][phase]
                        if phase==3 and age==127:scale=16777216
                    self.assertEqual((values[tint][update],values[x][update],values[y][update]),(intensity,scale,scale),(hex(initializer),update))

    def test_source_recurrence_mutation_changes_channel_samples_without_a_spell_override(self):
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x8011075C-self.base,0x24421000)
        facts,analysis=compiler.analyze(0x80110460,compiler.Image(raw,self.base))
        facts['phases']=compiler.timeline(facts,analysis)
        values=compiler.sample_scalar_channels(compiler.scalar_channels(facts,analysis))
        self.assertEqual(values[84][64],64*4096)
        original,_=compiler.scalar_profile(0x80110460)
        self.assertEqual(compiler.sample_scalar_channels(original)[84][64],64*8192)

    def test_reload_after_store_signed_guard_and_clamp_are_lowered_before_sampling(self):
        # A synthetic source CFG; sampling evaluates the compiled equations, never these words.
        words=[0x8E020000,0x2442FFFF,0xAE020000,0x8E020000,0x04410002,0,0xAE000000,0x03E00008,0]
        image=compiler.Image(struct.pack('<9I',*words),0x1000)
        root=('global',0x2000);registers=[None]*32;registers[0]=0;registers[16]=root;registers[29]=('stack',)
        analysis=compiler.Analysis(image,0x1000,initial=tuple(registers))
        facts=dict(state_global=0x2000,clock_offset=4,phase_offset=8,cases={0:0x1000},
                   phases=[dict(index=0,start=0,updates=3,clock_initial=0)],initializer=0x1000,preparation=[])
        with patch.object(compiler,'initial_values',return_value={0:1,4:0,8:0}):
            plan=compiler.scalar_channels(facts,analysis)
        self.assertEqual(compiler.sample_scalar_channels(plan)[0],[1,0,0,0])
        self.assertEqual(compiler.scalar_value(('s16',65535),{}),-1)
        self.assertEqual(compiler.scalar_value(('u8',-1),{}),255)

    def test_overlapping_word_and_halfword_channels_are_rejected(self):
        words=[0xAE000000,0xA6000002,0x03E00008,0]
        image=compiler.Image(struct.pack('<4I',*words),0x1000)
        root=('global',0x2000);registers=[None]*32;registers[0]=0;registers[16]=root;registers[29]=('stack',)
        analysis=compiler.Analysis(image,0x1000,initial=tuple(registers))
        facts=dict(state_global=0x2000,clock_offset=8,phase_offset=12,cases={0:0x1000},
                   phases=[dict(index=0,start=0,updates=1,clock_initial=0)],initializer=0x1000,preparation=[])
        with patch.object(compiler,'initial_values',return_value={0:0,2:0,8:0,12:0}):
            plan=compiler.scalar_channels(facts,analysis)
        self.assertEqual(plan['channels'],{})
        for key in (0,2):self.assertEqual(plan['blocked'][key][0]['reason'],'overlapping_scalar_storage')
    def test_vector_fill_initializer_supplies_three_source_scalar_channels(self):
        facts,analysis=compiler.analyze(0x80109DC0);facts['phases']=compiler.timeline(facts,analysis)
        plan=compiler.scalar_channels(facts,analysis)
        samples=compiler.sample_scalar_channels(plan,fields=[168,172,176])
        for field in (168,172,176):self.assertEqual(samples[field][0],0x01000000)
        for u in range(289):
            a=min(max(u-64,0),64);b=min(max(u-160,0),64)
            xy=0x01000000-209715*a+174762*b
            z=0x01000000-262144*a
            if b:z=xy=174762*b
            self.assertEqual([samples[n][u] for n in (168,172,176)],[xy,xy,z])
        # The source helper writes the unchanged input to all three consecutive words.
        for pc,offset in ((0x801207EC,8),(0x801207F0,4),(0x801207F8,0)):
            word=self.word(pc);self.assertEqual((word>>26,word>>21&31,word>>16&31,word&65535),(43,4,5,offset))
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x80109FC0-self.base,0x3C050080)
        changed=compiler.initial_values(facts,compiler.Image(raw,self.base))
        self.assertEqual([changed[n] for n in (168,172,176)],[0x00800000]*3)
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x801207F8-self.base,0)
        with self.assertRaisesRegex(ValueError,'vector fill helper source changed'):compiler.analyze(0x80109DC0,compiler.Image(raw,self.base))



if __name__=='__main__':unittest.main()
