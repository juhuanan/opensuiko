"""Legacy field fixtures used by gates still awaiting static replacements."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'kit/tools'))
import area_scene as scene
import export_first_room as ground
import maindec
from export_first_room import source
from legacy_instruction_fixture import OverlayInstructions
from test_journey_battle import until

BASE, GS, CONTEXT = 0x80010000, 0x80200000, 0x80300000


def fixture(count=3, facing=0, area='/VB6.BIN', room_number=6):
    raw, _ = source(area)
    room = scene.room_record(raw, room_number)
    section = scene.section_off(raw, room['section'])
    c = OverlayInstructions(raw)
    m = c.mem
    m.sw(0x8017DB24, GS); m.sw(0x8017C164, GS); m.sb(GS+3, count)
    m.sw(0x8017BE20, CONTEXT); m.sw(0x8017AAE4, BASE+section)
    m.sb(0x8017BD74, 27); m.sb(0x8017BD75, 25); m.sb(0x8017BD79, 2)
    m.sw(0x8017BD7C, 0x80400000); m.sb(0x80400000, facing)
    m.sb(0x80171C28, 1)
    for i, value in enumerate((8, 2, 4, 6, 35, 38)): m.sb(CONTEXT+0x89+i, value)
    table, objects = 0x80600000, 0x80700000
    records = ground.collision_sources(raw, section)
    m.sw(0x8017C038, table); m.sw(0x8017C09C, len(records))
    for i, obj in enumerate(records):
        for offset, value in enumerate((obj['x_half'],obj['y_half'],obj['order'],obj['b4'],obj['width']*8,obj['height']*8)):
            m.sb(table+12*i+offset, value)
        m.sw(table+12*i+8,objects+32*i); m.sw(objects+32*i+16,BASE+obj['sheet'])
    allocation = [0x80500000]
    def allocate(cpu):
        address = allocation[0]
        allocation[0] += (cpu.r[4]+31)//32*32
        return address
    def graphic(cpu):
        cpu.r[4] = 32
        return allocate(cpu)
    def variant(cpu):
        if cpu.r[5] != 255:
            for offset in (8,12,16): m.sb(m.rw(cpu.r[4]+offset),cpu.r[5])
        return 0
    def object_variant(cpu):
        m.sb(cpu.r[4],cpu.r[5]); return 0
    c.hooks.update({0x800C2D30:allocate,0x8013A770:graphic,0x800C2DC0:0,
                    0x800C3D8C:0,0x800C4244:0,0x800C3DAC:object_variant,0x801343B4:variant})
    external = c.external_call
    c.external_call = lambda pc: False if pc == 0x8013CCF0 else external(pc)
    return c


def snapshot(c):
    m, actors = c.mem, c.mem.rw(0x8017AF94)
    signed = lambda value: value if value < 128 else value-256
    return dict(active=m.rb(0x801716B9), followers=[dict(x=m.rb(actors+24*i)*8,
        y=m.rb(actors+24*i+1)*8, offset_x=signed(m.rb(actors+24*i+2)),
        offset_y=signed(m.rb(actors+24*i+3)), flags=m.rb(actors+24*i+4), speed=m.rb(actors+24*i+5))
        for i in range(m.rw(0x8017BF7C))])


def original_phase(c):
    samples = []
    for _ in range(80):
        c.r[31] = 0xFFFFFFFC
        c.run(0x8013E7E0)
        for i in range(c.mem.rw(0x8017BF7C)):
            c.r[4] = c.mem.rw(0x8017AF94)+24*i
            until(c, 0x8012F8AC, 0x8012F97C)
        samples.append(snapshot(c))
        if not samples[-1]['active']: return samples
    raise AssertionError('queue did not drain')


def hero_vectors(area_file='/VB6.BIN',room_number=6,entity_index=5,starts=((3,22,0),(25,25,3),(27,23,1),(27,25,2)),transition=False):
    """Actual SHU constructor, room6 alignment, interpolation and player draw clock."""
    from parse_04play import Parser
    from test_journey_battle import invoke
    raw,_=source('/04_PLAY/SHU.BIN');base=0x80A00000
    parser=Parser(raw,base);parser.parse_header();section=parser.parse_section('S2',parser.u32(40))
    area,_=source(area_file)
    stream=scene.entities(area,scene.room_record(area,room_number))[entity_index]['stream_offsets'][2]
    assert area[stream]==16
    target=tuple(area[stream+1:stream+3])
    rows=[]
    for x,y,facing in starts:
        c=fixture(1,facing,area_file,room_number);m=c.mem;read=c.read;actor=0x8017BD74
        def mapped(address,size):
            if base<=address and address+size<=base+len(raw):
                return sum(m.b.get(address+i,raw[address+i-base])<<(8*i)for i in range(size))
            return read(address,size)
        c.read=mapped
        for key in ('c','d','e','f'):
            row=section['header'][key+'_table'];m.sw(base+row['field_file_offset'],base+row['raw_file_offset'])
            for row in section[key]['entries']:m.sw(base+row['field_file_offset'],base+row['raw_file_offset'])
        m.sw(base+40,base+section['file_offset'])
        for pc in (0x801343B4,0x800C3DAC,0x800C4244):c.hooks.pop(pc,None)
        # Resource lookup is a supplied, genuine loaded Hero boundary, not a new cache claim.
        c.hooks[0x801386DC]=base
        m.sb(actor,x);m.sb(actor+1,y);m.sb(0x80171598,facing)
        invoke(c,0x801347D0);obj=m.rw(actor+8)
        def pose():
            signed=lambda value:(value+128)%256-128
            return dict(x=m.rb(actor)*8,y=m.rb(actor+1)*8,offset_x=signed(m.rb(actor+2)),offset_y=signed(m.rb(actor+3)),
                        variant=m.rb(obj),frame=m.rb(obj+2),remaining=m.rb(obj+3)or 256)
        initial=pose();assert initial['frame']==1 and initial['remaining']==12
        m.sw(0x8017AF84,BASE+stream+1);invoke(c,0x8013D0B8)
        m.sw(0x80171594,128);m.sh(0x8017C008,40);m.sh(0x8017C010,240)
        samples=[];emitted=[]
        def emit(cpu):
            if cpu.r[4]==obj:
                bits=m.rw(obj+4);px=(bits>>1)&32767;py=(bits>>18)&16383
                px=px-32768 if px&16384 else px;py=py-16384 if py&8192 else py
                current=pose()
                assert (px+m.rh(0x8017C008)+160-m.rh(0x8017B7CC),py+m.rh(0x8017C010)+120-m.rh(0x8017B7D4))==(current['x']+current['offset_x'],current['y']+current['offset_y'])
                emitted.append(current)
            return 0
        c.hooks[0x800C3EF0]=emit
        for tick in range(160):
            invoke(c,0x8013E450);emitted.clear()
            c.r[4]=actor;invoke(c,0x8012FD10)
            assert len(emitted)==1
            samples.append(dict(emitted=emitted[0],after=pose()))
            if not m.rb(0x801716B8)and not m.rb(0x8017A160):break
        else:raise AssertionError('Hero alignment did not finish')
        assert (m.rb(actor),m.rb(actor+1))==target
        assert {0x801347D0,0x80134470,0x801344C4,0x8013D0B8,0x8013E450,0x8012FD10}<=c.visited
        if (x,y)!=target:assert 0x800C4244 in c.visited
        row=dict(initial=initial,samples=samples)
        if transition:
            assert area[stream+3:stream+6]==bytes((17,128,3))
            c.r[4:6]=[128,maindec.mword(0x80171B98+12)];invoke(c,0x8013CCF0)
            selected=pose();emitted.clear()
            c.r[4]=actor;invoke(c,0x8012FD10)
            row['transition']=dict(selected=selected,emitted=emitted[0],after=pose())
        rows.append(row)
    return rows
