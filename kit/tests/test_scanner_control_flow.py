#!/usr/bin/env python3
"""GS control-flow paths preserve pointer ownership, branch states and instruction delays."""
from pathlib import Path
import json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import gs_scan as G
import audit_gs_records as A
from test_scanner_clobbers import GsWindow,I,R,lui,lw,addiu,jal,jr,NOP,S0,V0,V1,GP,RA,H2DA_OFF


def check():
    cases=0
    # Signed reads count as accesses, including when they replace their own base.
    for opcode, name, width in [(0x20, 'lb', 1), (0x21, 'lh', 2)]:
        for signed_base in [False, True]:
            reg = S0 if signed_base else V0
            w = GsWindow([lw(S0,GP,H2DA_OFF),NOP,I(opcode,S0,reg,0x1D5C),
                          NOP,lw(V0,S0,4),jr(RA),NOP])
            rows = w.run()
            assert any(r[3:] == (name,width,'R','gs+0x1D5C') for r in rows)
            assert ('gs+0x4' in [r[-1] for r in rows]) == (not signed_base)
            cases += 1
    transfers=[(2<<26)|((G.MBASE+0x1000)>>2&0x3FFFFFF),jr(RA),
               I(4,0,0,8),I(1,0,1,8),I(6,0,0,8),R(0,V1,0,0,9)]
    seeds=[[lw(S0,GP,H2DA_OFF)],
           [lui(V1,0x8018),lw(S0,V1,H2DA_OFF)],
           [lui(S0,0x801C),addiu(S0,S0,-0x8000)],
           [lui(S0,0x801B),I(0x0D,S0,S0,0x8000)]]
    for seed in seeds:
        for transfer in transfers:
            w=GsWindow(seed+[NOP,transfer,lw(V0,S0,0x10),lw(V0,S0,0x20),jr(RA),NOP])
            rows=w.run();descs=[r[-1] for r in rows]
            assert 'gs+0x10' in descs and 'gs+0x20' not in descs,(seed,hex(transfer),descs)
            cases+=1
    # A literal root can change register; a load or volatile call cannot be crossed.
    for intervening, valid in [([], True), ([lw(V1,V1,0),NOP], False),
                               ([jal(G.MBASE+0x1000),NOP], False)]:
        w=GsWindow([lui(V1,0x801B),*intervening,I(0x0D,V1,S0,0x8000),
                    lw(V0,S0,0x40),jr(RA),NOP])
        assert ('gs+0x40' in w.descs()) == valid
        cases+=1
    for reg, valid in [(V1,False),(S0,True)]:
        w=GsWindow([lui(reg,0x801B),jal(G.MBASE+0x1000),I(0x0D,reg,reg,0x8000),
                    lw(V0,reg,0x40),jr(RA),NOP])
        assert ('gs+0x40' in w.descs()) == valid
        cases+=1
    for transfer, reg, valid in [(transfers[0],S0,False),(jr(RA),S0,False),
                                 (jal(G.MBASE+0x1000),V1,False),
                                 (jal(G.MBASE+0x1000),S0,True)]:
        w=GsWindow([transfer,lui(reg,0x801B),I(0x0D,reg,reg,0x8000),
                    lw(V0,reg,0x40),jr(RA),NOP])
        assert ('gs+0x40' in w.descs()) == valid
        cases+=1
    # A seed materialized in a terminal delay slot cannot seed the next lexical block.
    for code in [[transfers[0],lw(S0,GP,H2DA_OFF),lw(V0,S0,0x20)],
                 [lui(V1,0x8018),transfers[0],lw(S0,V1,H2DA_OFF),lw(V0,S0,0x20)],
                 [transfers[0],lui(S0,0x801B),lw(V0,S0,-0x8000)]]:
        assert not GsWindow(code).run();cases+=1
    # Calls return to their continuation; conditional fallthrough remains a bounded path.
    for transfer in [jal(G.MBASE+0x1000),I(5,V0,0,8)]:
        descs=GsWindow([lw(S0,GP,H2DA_OFF),NOP,transfer,NOP,lw(V0,S0,0x20),jr(RA),NOP]).descs()
        assert 'gs+0x20' in descs;cases+=1
    # Independent audit accepts the transfer's delay access, rejects its lexical successor.
    for transfer in transfers:
        w=GsWindow([lw(S0,GP,H2DA_OFF),NOP,transfer,lw(V0,S0,0x10),lw(V0,S0,0x20)])
        class Body:
            word=staticmethod(w.reader)
        start=G.MBASE+4*w.at
        assert A.base_writer(Body(),start+12)[0]=='SEED load'
        assert A.base_writer(Body(),start+16)[0]=='no control-flow path from base writer'
        cases+=1
    # Branches keep separate pointer states; a skipped clobber is not applied to its sibling.
    def jump(index):return (2<<26)|((G.MBASE+4*(10+index))>>2&0x3FFFFFF)
    w=GsWindow([lw(S0,GP,H2DA_OFF),NOP,I(5,V1,0,4),NOP,
                lui(S0,0x8009),jump(10),NOP,lw(V0,S0,0x20),jr(RA),NOP,
                lw(V0,S0,0x30),jr(RA),NOP])
    assert 'gs+0x20' in w.descs() and 'gs+0x30' not in w.descs();cases+=1
    # A load in a jump delay slot becomes visible after the first target instruction.
    w=GsWindow([lw(S0,GP,H2DA_OFF),NOP,jump(6),lw(S0,S0,0),NOP,NOP,
                lw(V0,S0,4),lw(V0,S0,8),jr(RA),NOP])
    assert 'gs+0x4' in w.descs() and 'gs+0x8' not in w.descs()
    class Body:
        word=staticmethod(w.reader)
    start=G.MBASE+4*w.at
    assert A.base_writer(Body(),start+24)[0]=='SEED load'
    assert A.base_writer(Body(),start+28)[0]=='CLOBBERING load';cases+=1
    # Loop-varying offsets widen to explicitly unknown indexed accesses, not invented fields.
    w=GsWindow([lw(S0,GP,H2DA_OFF),NOP,lw(V0,S0,4),addiu(S0,S0,4),
                I(5,V1,0,-3),NOP,jr(RA),NOP])
    ds=w.descs();assert 'gs+0x4' in ds and 'gs+?+idx' in ds
    assert not [d for d in ds if d.startswith('gs+0x') and d!='gs+0x4'];cases+=1
    # A lexical zero assignment skipped by a branch cannot prove the taken-path index zero.
    from test_scanner_clobbers import T0,S1,addu,A0
    w=GsWindow([lw(S0,GP,H2DA_OFF),NOP,I(5,V1,0,2),addiu(T0,0,1),
                addiu(T0,0,0),addu(S1,S0,T0),lw(V0,S1,4),jr(RA),NOP])
    assert 'gs+0x4' in w.descs() and 'gs+?+idx' in w.descs();cases+=1
    w=GsWindow([lw(A0,GP,H2DA_OFF),NOP,jal(G.MBASE+0x1000),
                lw(V0,A0,4),lw(V0,A0,8),jr(RA),NOP])
    assert 'gs+0x4' in w.descs() and 'gs+0x8' not in w.descs();cases+=1
    # A call's delay instruction can use a zero argument; its return cannot.
    for use_delay in [False,True]:
        use=addu(S1,S0,A0)
        code=[lw(S0,GP,H2DA_OFF),NOP,addiu(A0,0,0),jal(G.MBASE+0x1000)]
        code+=([use,NOP] if use_delay else [NOP,use])
        code+=[lw(V0,S1,4),jr(RA),NOP]
        ds=GsWindow(code).descs()
        assert ('gs+0x4' in ds) if use_delay else ('gs+?+idx' in ds)
        cases+=1
    # The exact disc counterexample: the GS seed at90E0 jumps to the epilogue at912C;
    # result-object state2 reaches9164 from a different path with a0=*(80179FD0).
    body=A.Body(A.BODIES['gs'])
    assert body.word(0x800E912C)==0x0803A464
    assert A.base_writer(body,0x800E9164)[0]=='no control-flow path from base writer'
    records=G.scan()
    tracked=json.loads((Path(__file__).resolve().parents[1]/"work/gs_recs.json").read_text())
    assert {tuple(r) for r in tracked}==set(records)
    assert not [r for r in records if r[0]=='indirect' and r[1]==0x800E9164]
    assert {0x801284C0,0x801284C4,0x801284D0,0x801284DC} <= {r[1] for r in records}
    cases+=1
    # Publish subsystem 801BA000 at 8017C20C, clear a descending block
    # within that subsystem, and store the final call result at subsystem+30.
    chunks = {
        0x800C2B54: (0x3C02801B, 0x3442A000, 0x3C018018, 0xAC22C20C, 0x3C018018, 0xA020B7B0,
                     0x340300FF, 0x3C02801B, 0x3442A3FC, 0xAC40003C, 0x2463FFFF, 0x0461FFFD,
                     0x2442FFFC, 0x0C05524A, 0x2404FFFF, 0x3C038018, 0x8C63C20C, 0x8FBF0010,
                     0xAC620030, 0x03E00008, 0x27BD0018),
        # Allocate the result object, then publish the returned pointer at 80179FD0.
        0x800E81A8: (0x34042258, 0x0C030B4C, 0x24500B40, 0x3C018018, 0xAC229FD0),
        # State 2 branches with A0 still holding the result pointer.
        0x800E9018: (0x3C048018, 0x8C849FD0, 0x27BDFFE8, 0xAFBF0014, 0xAFB00010, 0x8C900030,
                     0x8C830000, 0x34020001, 0x10620010, 0x28620002, 0x10400005, 0, 0x10600008,
                     0x02002021, 0x0803A465, 0x2402FFFF, 0x34020002, 0x10620035, 0x2402FFFF),
        # Confirm or alternate input gates the selected-item read. Its two branches
        # write result+0/+4 with callbacks 800E91A4 and 800E93CC, respectively.
        0x800E9134: (0x3C028018, 0x8C42BE4C, 0, 0x30420040, 0x14400007, 0, 0x3C028018,
                     0x8C42AF7C, 0, 0x30420100, 0x1040000D, 0x2402FFFF, 0x94822250, 0, 0x10400005,
                     0xAC800000, 0x3C02800F, 0x244291A4, 0x0803A464, 0xAC820004, 0x3C02800F,
                     0x244293CC, 0xAC820004, 0x2402FFFF),
    }
    for address, expected in chunks.items():
        assert tuple(body.word(address + 4 * i) for i in range(len(expected))) == expected, hex(address)
    cases += 2
    print(f'PASS: {cases} static GS flow cases; six transfers, four seed styles, literal-root clobbers/delays, call/branch fallthrough and result ownership')


if __name__=='__main__':check()
