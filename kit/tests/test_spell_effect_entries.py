#!/usr/bin/env python3
"""Effect crops agree with static UV evidence and independent VRAM sampling."""
from hashlib import sha256
from pathlib import Path
import json
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
import battle_bin
import maindec
import spell_effect_entries as entries
import spell_effect_assets as strips
from psx_vram import PsxVram, clut_encode, texpage_encode


class EffectEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sections, atlases, errors, _ = battle_bin.parse()
        assert not errors, errors
        cls.blobs = {a['offset']: a['atlas'] for a in atlases}
        cls.palette = cls.blobs[cls.sections[1]['atlas_offsets'][9]]
        cls.sweep = json.loads(entries.SWEEP.read_text())
        cls.vram = PsxVram()
        for i, offset in enumerate(cls.sections[1]['atlas_offsets']):
            cls.vram.upload_rect(640 + 64*(i % 5), 256 + 128*(i // 5),
                                 64, 128, cls.blobs[offset])

    def test_primary_and_auxiliary_banks_match_independent_register_definitions(self):
        import struct,spell_effect_sweep,spell_scene_source
        raw=maindec.body();base=maindec.MBASE
        def definitions(entry):
            regs=[None]*32;regs[0]=0;regs[29]=('stack',0);stack={};bindings={};pending=None
            def transfer(word):
                op=word>>26;rs=word>>21&31;rt=word>>16&31;rd=word>>11&31;fn=word&63
                imm=word&65535;imm=imm-65536 if imm&32768 else imm
                a,b=regs[rs],regs[rt]
                if op==15:regs[rt]=(word&65535)<<16
                elif op in (8,9):
                    regs[rt]=((a+imm)&0xffffffff) if isinstance(a,int) else ('stack',a[1]+imm) if isinstance(a,tuple) and a[0]=='stack' else None
                elif op==13:regs[rt]=a|(word&65535) if isinstance(a,int) else None
                elif op==35:
                    addr=(a+imm)&0xffffffff if isinstance(a,int) else None
                    regs[rt]=('bank',(addr-0x800AA000)//4) if addr is not None and 0x800AA004<=addr<=0x800AA020 and addr%4==0 else stack.get(a[1]+imm) if isinstance(a,tuple) and a[0]=='stack' else None
                elif op==43:
                    if isinstance(a,tuple) and a[0]=='stack':stack[a[1]+imm]=b
                elif op in (32,33,36,37):regs[rt]=None
                elif op==0 and fn in (33,37):regs[rd]=a if b==0 else b if a==0 else ((a+b)&0xffffffff) if isinstance(a,int) and isinstance(b,int) else None
                elif op==0 and fn in (0,2,3):regs[rd]=None
                elif op==0 and fn not in (8,9,24,25,26,27):regs[rd]=None
                regs[0]=0
            for pc in range(entry,entry+0x4000,4):
                word=struct.unpack_from('<I',raw,pc-base)[0]
                if pending is not None:
                    transfer(word)
                    if pending[1]==0x801233B4:
                        self.assertIsNotNone(regs[4],hex(pending[0]));self.assertEqual(regs[4][0],'bank')
                        bindings[pending[0]]=regs[4][1]
                    for reg in range(1,16):regs[reg]=None
                    regs[24]=regs[25]=None;pending=None
                elif word>>26==3:pending=(pc,((pc+4)&0xf0000000)|((word&0x3ffffff)<<2))
                elif word==0x03e00008:break
                else:transfer(word)
            return bindings
        report=spell_effect_sweep.build()
        self.assertEqual(report['schema'],'suikoden-spell-effect-sweep/2')
        for effect in report['effects']:
            initializer=int(effect['initializer'],16);facts,_=spell_scene_source.analyze(initializer);expected={}
            for entry in [initializer]+facts['preparation']:expected.update(definitions(entry))
            actual={row['site']:row['section'] for row in effect['graphics_bindings']}
            self.assertEqual(actual,expected,effect['name'])
            self.assertEqual(effect['section'],next(iter(expected.values())))
        sleep=next(e for e in report['effects'] if e['name']=='Wind of Sleep')
        self.assertEqual((sleep['section'],sleep['graphics_bindings'][0]['site']),(4,0x80108C24))
        self.assertEqual(sleep['screen_wave_bindings'],[dict(site=0x80108CDC,section=3,piece=2)])
        self.assertEqual(sleep['auxiliary_sections'],[3])
        self.assertEqual(struct.unpack_from('<I',raw,0x80122B10-base)[0],0x34050002)
        judgment=next(e for e in report['effects'] if e['name']=='Judgment')
        self.assertEqual((judgment['section'],judgment['auxiliary_sections']),(7,[6]))

    def test_crops_match_static_packet_uvs_and_independent_vram_sampling(self):
        main = maindec.body()
        writer = main[0x800E21A8 - maindec.MBASE:0x800E2444 - maindec.MBASE]
        self.assertEqual(sha256(writer).hexdigest(), '8286b1d45e007ce853810736781087b17d55f539925a1874e37382755aa9ee22')
        for pc, word in {
            0x800E2224: 0x0237001A, 0x800E2250: 0x34040001, 0x800E2284: 0x24C60140,
            0x800E2290: 0x00113842, 0x800E2298: 0x00073A00, 0x800E22B0: 0x001189C0,
            # Byte 7 selects the U half. Byte 3 encodes the two tile coordinates.
            0x800E22B8: 0x92630007, 0x800E22C0: 0x2402FF80, 0x800E22C4: 0x000319C2,
            0x800E22D0: 0x00621824, 0x800E22D8: 0x92620003, 0x800E22E4: 0x30A21F00,
            0x800E22EC: 0x3082000F, 0x800E22F0: 0x000210C0, 0x800E2308: 0x00041103,
            0x800E230C: 0x000210C0, 0x800E2310: 0x02228821,
            # The horizontal branch precedes vertical. Endpoints use stored width and height.
            0x800E2334: 0x30620002, 0x800E2338: 0x10400015, 0x800E233C: 0x30620001,
            0x800E234C: 0x92630004, 0x800E235C: 0xA242000C, 0x800E236C: 0x92630005,
            0x800E2390: 0x10400015, 0x800E23C0: 0xA242000D, 0x800E23E8: 0xA245000C,
            0x800E23EC: 0xA244000D, 0x800E2400: 0xA2420014, 0x800E2410: 0xA242001D,
        }.items():
            self.assertEqual(maindec.mword(pc), word, hex(pc))
        unique = {tuple(e) for effect in self.sweep['effects']
                  for piece in effect['pieces'] for e in piece['entries']}
        self.assertEqual(len(unique), 210)
        # Also exercise all reversal combinations, which real spell entries do
        # not cover; the native writer gives horizontal reversal priority.
        unique.update((0, 0, 0, 0x80, 7, 7, 49, flag) for flag in range(4))
        for entry in sorted(unique):
            _, _, page, tile, last_x, last_y, palette, flags = entry
            half, column = divmod(page, 5)
            tpage = texpage_encode(640 + 64 * column, 256, 0)
            clut = clut_encode(928 + 16 * (palette % 2), 384 + palette // 2)
            u0 = (tile * 8 & 0x78) | (flags & 0x80)
            v0 = 128 * half + (tile & 0xF0) // 2
            us = range(u0, u0 + last_x + 1)
            vs = range(v0, v0 + last_y + 1)
            if flags & 2:
                us = us[::-1]
            elif flags & 1:
                vs = vs[::-1]
            raw = self.blobs[self.sections[1]['atlas_offsets'][page]]
            image = entries.entry_image(raw, self.palette, entry)
            self.assertEqual(image.size, (len(us), len(vs)), entry)
            for y, v in enumerate(vs):
                for x, u in enumerate(us):
                    index = self.vram.sample_texel(tpage, u, v)
                    expected = self.vram.sample_color(tpage, clut, u, v) + (255,) if index else (0, 0, 0, 0)
                    self.assertEqual(image.getpixel((x, y)), expected, (entry, x, y))

    def test_bad_page_or_crossing_crop_fails(self):
        for raw, entry in ((b'', [0]*8), (bytes(16384), [0, 0, 0, 0xF0, 0, 127, 0, 0])):
            with self.assertRaises(ValueError): entries.entry_image(raw, self.palette, entry)

    def test_review_metadata_keeps_all_animation_durations_and_refuses_runtime_claim(self):
        old = entries.OUT
        with tempfile.TemporaryDirectory(prefix='suikoden-effect-entries-') as path:
            try:
                entries.OUT = Path(path)
                entries.main()
            finally:
                entries.OUT = old
            for i, effect in enumerate(self.sweep['effects']):
                value = json.loads((Path(path) / f'{i}.json').read_text())
                self.assertEqual(value['schema'], 'suikoden-effect-entry-review/2')
                self.assertFalse(value['ready_for_runtime'])
                self.assertEqual(value['source']['lba'], 18698)
                self.assertEqual(value['source']['size'], 91451)
                self.assertTrue((Path(path) / f'{i}_atlas.png').is_file())
                self.assertTrue(value['pieces'])
                for entry in value['entries']:
                    self.assertGreater(entry['w'], 0)
                    self.assertGreater(entry['h'], 0)
                    self.assertGreaterEqual(entry['x'], 0)
                    self.assertGreaterEqual(entry['y'], 0)
                self.assertEqual(value['animations'], effect['animations'])
                self.assertNotIn('phases', value)

    def test_diagnostic_strip_caller_uses_the_shared_sampler(self):
        old = strips.OUT
        with tempfile.TemporaryDirectory(prefix='suikoden-effect-strips-') as path:
            try:
                strips.OUT = Path(path)
                strips.main()
            finally:
                strips.OUT = old
            self.assertEqual(len(json.loads((Path(path) / 'effects.json').read_text())), 33)


if __name__ == '__main__': unittest.main()
