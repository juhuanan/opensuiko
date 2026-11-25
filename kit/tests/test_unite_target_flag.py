#!/usr/bin/env python3
"""Independent unite records, UI target selection and execution-time repair."""
from pathlib import Path
import struct
import sys
KIT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(KIT/'tools'))
from disc import extract
import q_residue as Q


def check():
    main=extract(17976,757760)[2048:]
    anchors={
        0x800ED9F0:0x2421D18C,0x800ED9F8:0x8C220000,
        0x800EDA00:0x94420016,0x800EDA08:0x30420002,
        0x800EDA0C:0x10400034,0x800EDA54:0x8C450038,
        0x800EDA5C:0xAC650034,0x800EDAD4:0x2442DB18,
        0x800EDAEC:0x2442DE58,0x800EDAFC:0xAC220000,
        0x800EDBF8:0x8CA30008,0x800EDC14:0x90630038,
        0x800EDC20:0xA0430049,
        0x800EDB3C:0x3C028018,0x800EDB40:0x8C42BE3C,
        0x800EDB5C:0x24510B40,0x800EDBF4:0x8CA40018,
        0x800EDBFC:0x00041080,0x800EDC00:0x00441021,
        0x800EDC04:0x00021080,0x800EDC08:0x00441021,
        0x800EDC18:0x00021080,0x800EDC1C:0x00511021,
        0x800EB834:0x90630038,0x800EB840:0xA0430049,
        0x800EC2A4:0x90630038,0x800EC2B0:0xA0430049,
        0x800ECF24:0x90630038,0x800ECF30:0xA0430049,
        0x800FEDAC:0x8C63BE3C,0x800FEDC0:0x80540B89,
        0x801166C8:0x805E0B89,0x801166D0:0x24630050,
        0x801166E8:0x001E18C0,0x801166EC:0x007E1821,
        0x801166F0:0x00031880,0x801166F4:0x007E1823,
        0x801166F8:0x00031880,0x801166FC:0x00691821,
        0x80116700:0x8C640068,0x80116704:0x8C65006C,
        0x80116708:0x8C660070,0x80116710:0x0C0481CD,
        0x800F588C:0x94420016,0x800F5890:0x82040049,
        0x800F5894:0x30430003,0x800F589C:0x10620005,
        0x800F58A4:0x1062000C,0x800F58C0:0x8C42002C,
        0x800F58C8:0x1C40000D,0x800F58D8:0x0C03E1A0,
        0x800F58E0:0x10400007,0x800F58E8:0x0C03D8D1,
        0x800F58F4:0x1080FFF6,0x800F58FC:0xA2040049,
        0x800F5914:0x90420019,0x800F593C:0xAC830018,
        0x800F868C:0x8C430024,0x800F8690:0x18800014,
        0x800F8698:0x0064102A,0x800F86BC:0x90620045,
        0x800F86C4:0x14400008,0x800F86CC:0x84620012,
        0x800F86D0:0x8463004E,0x800F86DC:0x04410002,
        0x800F86E0:0x00001021,0x800F86E4:0x2402FFFF,
        0x800F6358:0x8C43001C,0x800F635C:0x8C420024,
        0x800F6360:0x24700001,0x800F6370:0x0C03E181,
        0x800F6380:0x0C03E1A0,0x800F6388:0x10400009,
        0x800F638C:0x02001021,0x800F63A0:0x26100001,
        0x800F63AC:0x00001021,0x800F8628:0x90430055,
        0x800F8630:0x14600011,0x800F8650:0x90830045,
        0x800F8660:0x84820012,0x800F8664:0x8483004E,
        0x800F8670:0x0002102A,
    }
    for va,word in anchors.items():
        assert struct.unpack_from('<I',main,va-0x800C0800)[0]==word,hex(va)
    # The UI's rebased store and execution's unre-based load name one byte.
    assert 0xB40+0x49==0xB89
    # Read the pointer table independently of Q's fixed-stride extraction.
    pointers=struct.unpack_from('<32I',main,0x8016D190-0x800C0800)
    rows=Q.unites()
    groups=[]
    for i,(ptr,row) in enumerate(zip(pointers,rows)):
        offset=ptr-0x800C0800
        flags=struct.unpack_from('<H',main,offset+22)[0]
        assert flags in (1,3)
        assert flags==row['flags'] and int(row['addr'],16)==ptr
        # Bit-test UI chooses one of two handler installations. Independently
        # compare this choice against the exported target-selection meaning.
        ui_handler=0x800EDB18 if flags&2 else 0x800EDE58
        assert row['target_selection']==('individual' if ui_handler==0x800EDB18 else 'no_individual_picker')
        if ui_handler==0x800EDE58:groups.append(i)
    assert groups==[2,9,14,19,20,25,29,31]
    assert len(rows)==32
    print(f'PASS: {len(anchors)} raw UI/target/retarget anchors, 32 independent pointer-table records; '
          '24 individual-target and 8 no-picker unites')

if __name__=='__main__':
    check()
