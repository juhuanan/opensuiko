"""All source appraisal identities, labels, prices and fee; static only."""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import unittest

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'kit/tools'))
from export_first_room import source
from war_text import decode
import export_shop


class AppraisalCatalogueTests(unittest.TestCase):
    def test_every_appraisal_class_record_is_exported_with_original_identity(self):
        main,_=source('MAIN.EXE');base=struct.unpack_from('<I',main,24)[0]
        word=lambda address:struct.unpack_from('<I',main,2048+address-base)[0]
        items=json.loads((ROOT/'game/assets/items.json').read_text())
        proof=json.loads((ROOT/'game/assets/items.provenance.json').read_text())
        actual={a['id']:a for a in items['appraisals']}
        witnesses={a['native_id']:a for a in proof['appraisal_items']}
        found=[]
        for native in range(1,180):
            pointer=word(0x80167658+4*native);offset=2048+pointer-base
            category=struct.unpack_from('<H',main,offset+28)[0]&0x7000
            if not category:continue
            self.assertIn(category,(0x1000,0x2000,0x4000))
            found.append(native)
            name=decode(main,offset,length=24)[0]
            stable=re.sub('[^a-z0-9]+','_',name.lower()).strip('_')
            entry=actual[stable]
            self.assertEqual((entry['name'],entry['price'],entry['fee']),
                             (name,word(pointer+24),500))
            self.assertEqual(next(g for g in items['goods'] if g['id']==stable),dict(id=stable,name=name,price=entry['price'],uses=0))
            self.assertNotIn(stable,items['stock'])
            label={0x1000:0x8016bc68,0x2000:0x8016bc70,0x4000:0x8016bc7c}[category]
            self.assertEqual(witnesses[native]['unidentified_name'],decode(main,2048+label-base)[0])
        self.assertEqual(found,list(range(114,135))+[170])
        self.assertEqual(len(actual),22)
        self.assertEqual(word(0x800dbc58),0x2442fe0c)
        self.assertEqual(hashlib.sha256(main[2048+0x800e92b0-base:2048+0x800e9350-base]).hexdigest(),
                         'a5aa5abd5d4e620828eab620c6432e06b9dcf780280c162b5cc5fc753dfac7d7')

    def test_retained_semantic_export_and_identity_ledger_agree(self):
        export_shop.write(ROOT/'game/assets',verify=True)
        packet=json.loads((ROOT/'game/assets/campaign_policies/item_shared_ledger.json').read_text())
        for item in packet['items']:
            if 114<=item['source_item_id']<=134 or item['source_item_id']==170:self.assertEqual(item['controller'],dict(kind='items_enum',tag=item['id']))
        self.assertEqual(packet['bindings']['degraded_runtime_tags'],[])
        proof=json.loads((ROOT/'game/assets/items.provenance.json').read_text())
        expected={'appraisal_items':[dict(id=r['id'],unidentified_name=r['unidentified_name']) for r in proof['appraisal_items']]}
        self.assertEqual(expected,json.loads((ROOT/'game/tests/fixtures/appraisal_names.json').read_text()))


if __name__=='__main__':unittest.main()
