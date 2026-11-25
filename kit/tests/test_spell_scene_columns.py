#!/usr/bin/env python3
"""Independent column operands, loop instances and changed-source contracts."""
from pathlib import Path
import json
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
import spell_scene_source as source
import spell_scene_columns as compiler
from disc import extract


class Columns(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe=extract(17976,757760);cls.base,size=struct.unpack_from('<II',exe,24)
        cls.raw=exe[2048:2048+size];cls.report=compiler.catalogue()

    def word(self,pc):return struct.unpack_from('<I',self.raw,pc-self.base)[0]

    def constant(self,pc,register):
        if register==0:return 0
        for at in range(pc,self.base-1,-4):
            if pc-at>192:raise AssertionError('not an independent local constant')
            w=self.word(at);op=w>>26;rt=w>>16&31;rs=w>>21&31
            if op==15 and rt==register:return source.signed((w&65535)<<16)
            if op in (8,9,13) and rt==register:
                value=self.constant(at-4,rs);im=w&65535
                return source.signed(value|im if op==13 else value+(im-65536 if im&32768 else im))
            if op==0 and w&63 in (33,37) and w>>11&31==register:return source.signed(self.constant(at-4,rs)+self.constant(at-4,rt))
            if op in (32,33,35,36,37) and rt==register:raise AssertionError('dynamic constant input')
        raise AssertionError('outside image')

    def stack_constant(self,site,offset):
        for at in range(site,site-512,-4):
            w=self.word(at)
            if w>>26==43 and w>>21&31==29 and w&65535==offset:return self.constant(at-4,w>>16&31)
        raise AssertionError('missing independent stack store')

    def test_all_shared_columns_reproduce_without_scene_readiness_claims(self):
        self.assertEqual(json.loads(json.dumps(self.report)),json.loads((ROOT/'kit/data/reports/spell_column_constructors.json').read_text()))
        self.assertEqual(self.report['coverage'],dict(spells=33,column_spells=14,columns=24,blocked_sites=0))
        for spell in self.report['spells']:
            for column in spell['columns']:
                self.assertEqual(self.word(column['site']),0x0C048228)
                self.assertEqual(self.word(column['setter']),0x0C048222)
                self.assertEqual(column['segments'],self.constant(column['site']+4,4))
                self.assertEqual(column['semitransparent'],bool(self.constant(column['site']+4,5)))
                self.assertEqual(column['blend'],{1:'additive',2:'subtractive'}[self.constant(column['site']+4,6)])
                self.assertEqual(column['lower']['radius'],self.constant(column['setter']+4,5))
                self.assertEqual(column['upper']['radius'],self.constant(column['setter']+4,6))
                self.assertEqual(column['lower']['height'],self.constant(column['setter']+4,7))
                for endpoint,offsets in (('lower',(28,32,36)),('upper',(40,44,48))):
                    self.assertEqual(column[endpoint]['color'],[self.stack_constant(column['site']+4,n)&255 for n in offsets])

    def test_post_constructor_fields_and_per_iteration_bindings(self):
        spells={p['id']:p['columns'] for p in self.report['spells']}
        self.assertEqual(spells['spell_6'][0]['scale'],[1,1,4096])
        self.assertTrue(spells['spell_6'][0]['enabled'])
        self.assertFalse(spells['spell_7'][0]['enabled'])
        self.assertEqual(spells['spell_12'][0]['lower'],dict(radius=100,height=-200,color=[0,0,0]))
        self.assertEqual(spells['spell_12'][0]['upper'],dict(radius=120,height=0,color=[64,64,64]))
        self.assertEqual([p['angles'] for p in spells['spell_20']],[[0,0,0],[0,0,2048]])
        self.assertEqual([p['slot'] for p in spells['spell_28']],[144,148])
        self.assertEqual([p['slot'] for p in spells['spell_33']],[164,168,172,176,180])
        self.assertTrue(all(p['lower']['height']==p['upper']['height']==-300 for p in spells['spell_33']))

    def test_source_mutations_change_shared_parameters_and_loop_counts(self):
        facts=next(p for p in source.catalogue()['spells'] if p['id']=='spell_6')
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x801039DC-self.base,0x34050025)
        changed=compiler.constructors(facts,source.Image(raw,self.base))
        self.assertEqual(changed['columns'][0]['lower']['radius'],37)
        self.assertEqual(changed['columns'][0]['upper']['radius'],30)
        facts=next(p for p in source.catalogue()['spells'] if p['id']=='spell_33')
        self.assertEqual(self.word(0x80112290),0x2A020005)
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x80112290-self.base,0x2A020003)
        changed=compiler.constructors(facts,source.Image(raw,self.base))
        self.assertEqual([p['slot'] for p in changed['columns']],[164,168,172])

    def test_column_mutation_reaches_the_existing_portable_scene(self):
        from unittest.mock import patch
        import spell_effect_sweep,export_spell_scenes as exporter
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Ball of Lightning')
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x8010E8F0-self.base,0x34050097)
        with patch.object(source,'Image',return_value=source.Image(raw,self.base)):
            program=exporter.contracting_lightning_program(effect,list(range(len(effect['pieces']))))
        self.assertEqual([m['radius'] for m in program['meshes']],[151,151])
        self.assertEqual([m['top_radius'] for m in program['meshes']],[150,150])

    def test_nested_height_mutation_reaches_existing_scene_geometry(self):
        from unittest.mock import patch
        import spell_effect_sweep,export_spell_scenes as exporter
        effect=next(e for e in spell_effect_sweep.build()['effects'] if e['name']=='Ball of Lightning')
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x8010EC00-self.base,0x2442FFF8)
        with patch.object(source,'Image',return_value=source.Image(raw,self.base)):
            p=exporter.contracting_lightning_program(effect,list(range(len(effect['pieces']))))
        self.assertEqual(p['meshes'][0]['base_heights'][157],-13)
        self.assertEqual(p['meshes'][0]['base_heights'][158],-21)
        self.assertEqual(p['meshes'][0]['base_heights'][224],-300)
        self.assertEqual(p['meshes'][1]['base_heights'][173],-15)

    def test_missing_endpoint_setter_stays_an_explicit_blocker(self):
        facts=next(p for p in source.catalogue()['spells'] if p['id']=='spell_6')
        raw=bytearray(self.raw);struct.pack_into('<I',raw,0x801039F0-self.base,0)
        changed=compiler.constructors(facts,source.Image(raw,self.base))
        self.assertEqual(changed['columns'],[])
        self.assertEqual(changed['blocked'][0]['reason'],'unresolved_column_endpoints')


class Motion(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.facts={p['id']:p for p in source.catalogue()['spells']}

    def test_report_reproduces_and_retains_unresolved_writers(self):
        report=compiler.motion_catalogue()
        self.assertEqual(json.loads(json.dumps(report)),json.loads((ROOT/'kit/data/reports/spell_column_motion.json').read_text()))
        self.assertEqual(report['coverage'],dict(spells=33,column_spells=14,columns=24,parameter_channels=160,blocked_parameters=104,complete_parameter_columns=7))
        healing=next(p for p in report['spells'] if p['id']=='spell_15')
        self.assertTrue(any(b['reason']=='unbound_column_writer' for values in healing['plan']['blocked'].values() for b in values))

    def test_yell_and_scream_complete_parameter_lifetimes_match_source_equations(self):
        for identifier,radius,stop,end in [('spell_6',30,304,368),('spell_7',120,300,364)]:
            result=compiler.motion(self.facts[identifier]);binding=result['columns'][0];plan=result['plan']
            values=source.sample_scalar_channels(plan,fields=list(binding['fields'].values()))
            for u in range(end+1):
                for name,key in binding['fields'].items():
                    expected=0
                    if name=='enabled':expected=int(u<stop and (identifier=='spell_6' or u>=65))
                    elif name in ('lower_radius','upper_radius'):expected=radius
                    elif name=='lower_height':expected=-5-3*min(max(u-96,0),80)
                    elif name in ('scale_x','scale_y'):expected=1+128*min(max(u-64,0),32)
                    elif name=='scale_z':expected=4096
                    self.assertEqual(values[key][u],expected,(identifier,name,u))

    def test_vector_helper_shifts_and_source_order_update_both_shining_columns(self):
        result=compiler.motion(self.facts['spell_31']);plan=result['plan'];values=source.sample_scalar_channels(plan)
        image=source.Image()
        for pc,w in {0x8010B3A4:0xAE500190,0x8010B3A8:0xAE500194,0x8010B5C4:0x3C030004,
                     0x8010B840:0x3C03FFFC,0x8010B858:0x28840040,0x8010B85C:0x1480003E,0x8010B878:0xAC400000,0x8010BC20:0x0C0481ED,0x8010BC44:0x0C0481ED,
                     0x801207C0:0x00042303,0x801207D0:0x00021303,0x801207E0:0x00021303}.items():self.assertEqual(image.word(pc),w)
        for binding in result['columns']:
            for u in range(385):
                scale=4096 if u==0 else 64*min(max(u-96,0),64)-64*min(max(u-320,0),63)
                for name in ('scale_x','scale_y'):self.assertEqual(values[binding['fields'][name]][u],scale,(name,u))
                self.assertEqual(values[binding['fields']['scale_z']][u],4096)
                self.assertEqual(values[binding['fields']['enabled']][u],int(97<=u<384))

    def test_changed_nested_recurrence_changes_only_the_recovered_axis(self):
        image=source.Image();raw=bytearray(image.data);struct.pack_into('<I',raw,0x80103D1C-image.base,0x24420040)
        r=compiler.motion(self.facts['spell_6'],source.Image(raw,image.base));v=source.sample_scalar_channels(r['plan']);f=r['columns'][0]['fields']
        self.assertEqual(v[f['scale_x']][96],2049)
        self.assertEqual(v[f['scale_y']][96],4097)

    def test_unknown_loop_writer_and_helper_are_rejected_instead_of_frozen(self):
        image=source.Image();raw=bytearray(image.data);struct.pack_into('<I',raw,0x80104340-image.base,0xAE020048)
        r=compiler.motion(self.facts['spell_6'],source.Image(raw,image.base));key=r['columns'][0]['fields']['scale_x']
        self.assertNotIn(key,r['plan']['channels'])
        self.assertTrue(any(b['reason']=='unbound_column_writer' for b in r['plan']['blocked'][key]))
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x801042B8-image.base,0x0C048222)
        r=compiler.motion(self.facts['spell_6'],source.Image(raw,image.base))
        self.assertTrue(all(k not in r['plan']['channels'] for k in r['columns'][0]['fields'].values()))
        raw=bytearray(image.data);struct.pack_into('<I',raw,0x801207C8-image.base,0x8FA2000C)
        with self.assertRaisesRegex(ValueError,'vector helper source changed'):compiler.motion(self.facts['spell_31'],source.Image(raw,image.base))


if __name__=='__main__':unittest.main()
