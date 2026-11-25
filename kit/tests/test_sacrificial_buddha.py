#!/usr/bin/env python3
"""Independent static Buddha descriptor, callback-clock and trajectory checks."""
import json
import hashlib
from pathlib import Path
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'kit/tools'))
from disc import extract
from war_text import decode
import export_shop


class Buddha(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exe = extract(17976, 757760)
        cls.base, size = struct.unpack_from('<II', exe, 24)
        cls.image = exe[2048:2048+size]
        if hashlib.sha256(cls.image).hexdigest() != 'e123263c3046a7283d8ca26598185672ed3f8de72d97f5efb0ee8e88ccaa55fa':
            raise ValueError('expected US v1.1 MAIN.EXE image')
        cls.profile, cls.proof = export_shop.automatic_revival()

    def word(self, pc):
        return struct.unpack_from('<I', self.image, pc-self.base)[0]

    def test_automatic_inventory_branch_preserves_statuses_and_removes_first_slot(self):
        pointer = self.word(0x80167658+83*4)
        raw = self.image[pointer-self.base:pointer-self.base+36]
        self.assertEqual(decode(raw, 0)[0], 'Sacrificial Buddha')
        self.assertEqual(struct.unpack_from('<IHBBI', raw, 24), (5000,0,1,0,0))
        # Actor update occurs before the HP/lock predicate and KO helper.
        for pc, word in {
            0x800E0A7C:0x0C038D63, 0x800E0A94:0x86630012,
            0x800E0A9C:0x1C600009, 0x800E0AA4:0x92020005,
            0x800E0AAC:0x14400029, 0x800E0AB4:0x0C038B24,
            0x800E2CB8:0x14620021, 0x800E2CF0:0x34060053,
            0x800E2CF8:0x94620020, 0x800E2D00:0x1446000A,
            0x800E2D08:0x0C032902, 0x800E2D0C:0x02002821,
            0x800E2D18:0x24C6C400, 0x800E2D24:0x08038B65,
            0x800E2D30:0x26100001, 0x800E2D3C:0x24630004,
            0x800E2D48:0x0C0381DE, 0x800E2D54:0x2A020009,
            0x800E2D7C:0xA0430045, 0x800E2D80:0xA0430046,
        }.items():
            self.assertEqual(self.word(pc), word, hex(pc))
        # The successful branch jumps past all ordinary KO status/inactive writes.
        self.assertEqual((self.word(0x800E2D24)&0x3ffffff)<<2 | 0x80000000, 0x800E2D94)
        cursor = 0x8016C400-self.base
        widths = {0:1,3:2,4:2,15:3,16:3,30:2,31:2,34:2,35:3}
        script = []
        while True:
            op = struct.unpack_from('<H', self.image, cursor)[0]
            n = widths[op]
            args = struct.unpack_from('<'+'h'*(n-1), self.image, cursor+2)
            script.append((op,args)); cursor += 2*n
            if op == 0: break
        self.assertEqual(script, [(15,(0,1)),(4,(3,)),(3,(15,)),(30,(0,)),
                         (35,(0,6)),(34,(2068,)),(31,(99,)),(3,(1,)),(30,(0,)),
                         (35,(0,7)),(31,(99,)),(4,(2,)),(3,(10,)),(4,(0,)),(16,(0,1)),(0,())])
        self.assertEqual([self.word(0x8016BB70+i*4) for i in (6,7)], [0x800F3170,0x800F32D4])
        # Constructor selects the down animation and resets its frame cursor.
        for pc,word in {0x800F31FC:0x90450000,0x800F3200:0x0C03878F,
                        0x800E1F50:0x0C038811,0x800E2050:0xA0850000,
                        0x800E206C:0xA0800002}.items():
            self.assertEqual(self.word(pc),word,hex(pc))
        # Half-HP queues through the protection-aware shared HP consumer.
        for pc, word in {0x800F333C:0x84450010,0x800F3344:0x000517C2,
                         0x800F3348:0x00A22821,0x800F334C:0x00052843,
                         0x800F3350:0x0C038595,0x800F3354:0x00052823,
                         0x800E16E8:0x30428000,0x800E16F4:0x00008021,
                         0x800E177C:0xA462004E}.items():
            self.assertEqual(self.word(pc),word,hex(pc))

    def test_script_then_callback_clock_has_two_distinct_helper_handoffs(self):
        # A descriptor/callback reference model, not execution of original code.
        # The KO driver installed the first delay after this actor's age0 update.
        stage='down_wait'; delay=15; callback=None; selector=0
        timer=self.word(0x800F3280)&65535
        white=255; events={}; motion=[]
        for age in range(1,150):
            # Scripts observe the selector from the preceding callback update.
            if stage in ('down_wait','one_wait','recover_wait'):
                delay-=1
                if delay==0:
                    if stage=='down_wait':stage='first_mailbox';selector=0
                    elif stage=='one_wait':stage='second_mailbox';selector=0
                    else:events['release_delay']=age;break
            elif stage=='first_mailbox':
                callback='allocate';stage='wait_clones'
            elif stage=='wait_clones' and selector==99:
                stage='one_wait';delay=1
            elif stage=='second_mailbox':
                callback='heal';stage='wait_heal'
            elif stage=='wait_heal' and selector==99:
                events['recovery_start']=age;stage='recover_wait';delay=10
            # Callback replacement takes effect next update, not recursively.
            if callback=='allocate':
                events['clone_birth']=age;callback='install_orbit';selector=1
            elif callback=='install_orbit':callback='orbit'
            elif callback=='orbit':
                timer-=1
                if timer:
                    motion.append(age)
                else:callback='white'
            elif callback=='white':
                events.setdefault('white_start',age)
                white-=4
                if white<=128:
                    events['white_end']=age;selector=99;callback='cleanup'
            elif callback=='cleanup':events['clone_release']=age;callback=None
            elif callback=='heal':
                events['pending_delay']=age;events['impact_delay']=age+1
                selector=99;callback=None
        events['clone_motion_start']=motion[0]
        events['clone_motion_stop']=motion[-1]+1
        self.assertEqual(events, {k:self.profile[k] for k in events})
        self.assertEqual((events['pending_delay'],events['impact_delay'],events['release_delay']), (112,113,123))
        self.assertEqual((len(motion),motion[0],motion[-1]),(59,18,76))

    def test_ring_positions_match_integer_step_recurrence_and_quarter_table(self):
        quarter = struct.unpack_from('<1025h', self.image, 0x801765BC-self.base)
        def sine(angle):
            q,r=divmod(angle%4096,1024)
            return (quarter[r],quarter[1024-r],-quarter[r],-quarter[1024-r])[q]
        # Subtract before plotting, truncate radius before multiplying by trig.
        radius=0x32000;counter=60;angle=0
        self.assertEqual(len(self.profile['particles']),59)
        for row in self.profile['particles']:
            counter-=1;angle=(angle+1)%32
            change=-(radius//counter)
            radius+=change
            expected=[]
            for i in range(4):
                a=((angle+8*i)%32)*128
                expected.append([(radius>>12)*sine(a+1024)/4096,(radius>>12)*sine(a)/4096])
            self.assertEqual(row,expected)
            self.assertEqual(row[0],[-v for v in row[2]])
        self.assertEqual(radius,0)
        self.assertEqual(self.profile['particles'][-1],[[0,0]]*4)
        self.assertEqual(self.profile['particle_tint'],[128,0,0])
        self.assertEqual(self.profile['particle_plane_z'],0)

    def test_research_is_reproducible_and_does_not_enable_manual_use(self):
        packet=export_shop.export()
        retained=json.loads((ROOT/'game/assets/items.provenance.json').read_text())
        self.assertEqual(packet['items.provenance.json'],retained)
        research=retained['automatic_revival']
        self.assertEqual(research['profile'],self.profile)
        self.assertEqual(packet['items.json']['automatic_revival'],self.profile)
        ledger=json.loads((ROOT/'game/assets/campaign_policies/item_shared_ledger.json').read_text())
        item=next(i for i in ledger['items'] if i['source_item_id']==83)
        self.assertEqual(item['controller'],dict(kind='items_enum',tag=self.profile['id']))
        self.assertEqual((item['max_uses'],item['usable'],item['battle_usable']),(0,False,False))
        menu=json.loads((ROOT/'game/assets/combat_systems/menu_lists.json').read_text())
        bound={i for row in menu['items'] for i in row['source_records']}
        remaining=next(row for row in menu['blocked'] if row['id']=='source_item_records_without_port_identity')
        self.assertIn(83,bound)
        self.assertEqual(remaining['count'],menu['capacities']['source_item_records']-len(bound))
        self.assertNotIn('sacrificial_buddha',[i['id'] for i in packet['items.json']['consumables']])
        real=export_shop.main.mword
        with patch.object(export_shop.main,'mword',side_effect=lambda pc:0 if pc==0x800F3350 else real(pc)):
            with self.assertRaisesRegex(ValueError,'lifecycle changed'):
                export_shop.automatic_revival()


if __name__=='__main__': unittest.main()
