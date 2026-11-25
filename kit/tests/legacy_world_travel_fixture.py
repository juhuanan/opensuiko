"""Historical world travel trace producer. Test entry points use static source and retained traces."""
from pathlib import Path
import itertools
import json
import struct
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import export_world_travel as export
from export_first_room import source
from legacy_instruction_fixture import ModuleInstructions, call
from test_vb2_dice_states import OverlayInstructions
from test_worldmap_points import GS,ST,OBJ,SUB,fixture,run
import maindec as M
ROOT=Path(__file__).resolve().parents[2]


def resolvers():
    result=[]
    for mask,heading,requested in itertools.product(range(16),range(4),range(4)):
        c=OverlayInstructions(b'');m=c.mem;m.sw(0x8017A0B8,ST);m.sb(ST+0x23,heading*2);m.sb(0x8016F2A7,255)
        c.hooks[0x80127114]=lambda cpu:bool(mask&(1<<(3 if cpu.r[4]==4 else cpu.r[4])))
        call(c,0x80127224,requested)
        result.append(dict(mask=mask,heading=heading,requested=requested,accepted=bool(c.r[2]&128),facing=(c.r[2]&15)%4))
    return result


def encounter_machine(chance=0,pick=0,counter=5,party=30,rune=False,enabled=True,scripted=False,boat=False,ready=True,pending=True,table=True):
    inputs=locals().copy()
    data,_=source('/B_DATA.BIN');c=ModuleInstructions(data,0x80080000);m=c.mem
    c.hooks[0x80147E38]=lambda cpu:draw(cpu)
    draws=[]
    def draw(cpu):
        value=(chance,pick)[len(draws)];draws.append(value);return value
    D=int.from_bytes(data[:4],'little')
    m.sw(0x8017A0B8,ST);m.sw(0x8017DB24,GS);m.sw(ST+0x2C,D)
    m.sw(0x8016F2A0,int(enabled));m.sb(0x8016F2A7,0 if scripted else 255);m.sb(0x8016F2A6,int(boat))
    m.sb(ST+0x22,int(ready));m.sb(ST+0x24,int(pending));m.sh(0x8017A0A8,counter)
    m.sb(GS+3,1);m.sb(GS+14,0);m.sw(GS+0x1B9C,OBJ);m.sw(OBJ+0x1C,SUB)
    m.sb(SUB+13,party);m.sb(SUB+0x4C,24 if rune else 0);m.sw(GS+0x1BC0,77)
    if not table:m.sw(D+12,0)
    return c,draws,inputs


def encounter_case(**kwargs):
    c,draws,inputs=encounter_machine(**kwargs)
    call(c,0x801260B8)
    selected=c.mem.rw(GS+0x1BC0)
    return dict(**inputs,accepted=bool(c.r[2]),draws=len(draws),next_pending=bool(c.mem.rb(ST+0x24)),selected=None if selected==77 else selected)


def encounter_cases():
    result=[]
    for chance,pick in itertools.product((0,7,8,255,256,32767),(0,4094,4095,28664,28665,32759,32760,32767)):
        result.append(encounter_case(chance=chance,pick=pick))
    content,_=export.export()
    for i,entry in enumerate(content['encounters']):
        raw=i*(32767//len(content['encounters']))
        threshold=entry['enemy_level_sum']*15//10
        for party,rune in itertools.product((threshold-1,threshold,threshold+1),(False,True)):
            result.append(encounter_case(pick=raw,party=party,rune=rune))
    for key in ('enabled','scripted','boat','ready','pending','table'):
        result.append(encounter_case(**{key:key in ('scripted','boat')}))
    for counter in (0,4,5,65535):result.append(encounter_case(counter=counter))
    return result


def menu_cases():
    rows=[]
    for pressed,scripted,encounter,entrance in itertools.product((False,True),repeat=4):
        c=fixture(1,86,84 if entrance else 90);m=c.mem
        for pc in (0x80127650,0x80127784,0x8012731C,0x800CA220):c.hooks[pc]=0
        c.hooks[0x801260B8]=int(encounter)
        m.sb(0x8016F2A7,0 if scripted else 255);m.sw(0x8017BE4C,128 if pressed else 0)
        m.sw(0x8017DA90,0xF00D);m.sh(ST+0x20,7);m.sw(ST+0x1C,123);m.sh(0x8017A0A8,9)
        run(c,0x801280C4)
        callback=m.rw(0x8017DA90)
        assert callback==(0x80128528 if entrance else 0x80128A48 if pressed and not scripted else 0x801285A4 if encounter else 0xF00D)
        assert m.rb(GS+0x1D5E)==int(callback==0x80128A48)
        if callback==0x80128A48:assert m.rb(GS+0x1D5F)==128
        rows.append(dict(pressed=pressed,scripted=scripted,encounter=encounter,entrance=entrance,menu=callback==0x80128A48))
    # The actual outer menu-driver chain preserves interpolation/counters; GPU/resource services are explicit hooks.
    c=fixture(1,86,90);m=c.mem;driver=0x80F00000
    m.sh(ST+0x20,7);m.sw(ST+0x1C,123);m.sh(0x8017A0A8,9);m.sh(0x8016F304,20)
    m.sb(GS+0x1D5E,1)
    for pc in (0x800C2DC0,0x800C39F4,0x800C3A04,0x800C36A4,0x800C3500,0x800C36D4,0x800C33A0,0x800C34CC,driver):c.hooks[pc]=0
    c.hooks[0x800CA66C]=driver;c.hooks[0x800C2D30]=0x80700000
    for pc in (0x80128A48,0x80128A6C,0x80128A90,0x80128B14,0x80128B8C,0x80128C60,0x80128CC8):
        run(c,pc)
        assert (m.rh(ST+0x20),m.rw(ST+0x1C),m.rh(0x8017A0A8),m.rh(0x8016F304))==(7,123,9,20)
    assert m.rw(0x8017DA90)==0x801280C4 and m.rb(GS+0x1D5E)==0
    return rows


def rabbit_fixture(raw,defending=False,dead_mask=0,actor=7,commander=False,record=None):
    from legacy_instruction_fixture import ModuleInstructions,call
    from test_battle_picker import SCENE
    c=ModuleInstructions(raw,0x80080000);m=c.mem;heap=[0x80500000]
    m.sw(0x8017BE3C,SCENE);m.sw(SCENE+0x1258,0x8016B680)
    m.sw(SCENE+8,actor);m.sw(SCENE+0x1C,6);m.sw(SCENE+0x24,actor)
    def alloc(cpu):
        value=heap[0];heap[0]+=(cpu.r[4]+15)&~15
        assert heap[0]<0x80800000
        return value
    c.hooks[0x800C2D30]=alloc;c.hooks[0x800C2DC0]=0;c.hooks[0x800C3104]=0;c.hooks[0x800E1654]=0
    external=c.external_call
    def boundary(pc):
        if pc==0x800E3820 and c.r[6]==0x8009EFBC:
            c.effects.append((pc,tuple(c.r[4:8])));c.r[2]=0;return True
        return external(pc)
    c.external_call=boundary
    for i in range(1,actor+1):
        a=SCENE+0x50+140*i;b=SCENE+0xB40+84*i
        dead=i<=6 and bool(dead_mask&(1<<(i-1)))
        m.sb(a+3,int(i==actor));m.sb(b+0x44,(i-1)%6+1);m.sb(b+0x45,int(dead))
        m.sh(b+0x10,100);m.sh(b+0x12,0 if dead else 100)
        m.sh(b+0x30,90);m.sh(b+0x32,40);m.sb(b+0x47,int(defending))
        for j,value in enumerate((i*1000,0,0)):m.sw(a+0x5C+4*j,value);m.sw(a+0x68+4*j,value)
    for i,native in enumerate((8,2,6,35,38,32),1):
        handle=0x80410000+128*i;persistent=0x80420000+128*i
        m.sb(SCENE+0x50+140*i,native)
        m.sw(SCENE+0xF84+12*i,handle);m.sw(handle+0x1C,persistent);m.sw(handle+4,0x80430000+128*i);m.sb(handle,native)
    parent=SCENE+0x50+140*actor;aux=SCENE+0x50+140*19
    scripts=struct.unpack_from('<I',raw,record+40)[0] if record is not None else 0x800A2248 if commander else 0x8009F788
    section=struct.unpack_from('<I',raw,record+44)[0] if record is not None else 0x800A25E0 if commander else 0x8009FB70
    m.sw(parent+8,scripts)
    call(c,0x800E1E3C,section,0);m.sw(parent+0x84,c.r[2])
    call(c,0x800E7468,c.r[2]);m.sw(parent+0x88,c.r[2])
    return c,parent,aux


def rabbit_driver(c,parent):
    from test_battle_picker import SCENE
    c.mem.sb(parent,1);c.mem.sw(SCENE+0x1344,0x80400000);c.mem.sw(0x80400004,0x8009F748)
    c.mem.sw(0x8017DA94,0x800F72F0);c.mem.sw(0x8017DA98,0x800F40FC);c.mem.sw(SCENE+0x134C,1)
    for pc in (0x800E0EA0,0x800E7DC0,0x800E0824,0x800E256C,0x800E6D38,0x800E0080,0x800E02CC,0x800E1BF8):c.hooks[pc]=0


def hold_rabbit_scheduler(c):
    c.mem.sw(0x8017DA98,0x80F00000);c.hooks[0x80F00000]=0xFFFFFFFF


def rabbit_cases():
    # Shared HP/reaction presentation are boundaries; next-actor scheduling is held after launch.
    from legacy_instruction_fixture import call
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    inputs=list(itertools.product((0,16711,16712,32767),(0,32767),(0,1,16),(False,True)))
    inputs += [(0,16711,0,False),(0,16712,0,False)]
    for trigger,target_draw,dead_mask,defending in inputs:
        c,parent,aux=rabbit_fixture(raw,defending,dead_mask);m=c.mem
        rolls=iter((trigger,target_draw,100));draw_count=[0];used=[]
        def draw(_):
            draw_count[0]+=1;value=next(rolls,32767);used.append(value);return value
        c.hooks[0x80147E38]=draw
        expected=trigger*100//32767>=51 and not dead_mask&(1<<((target_draw*100//32767)%6))
        if expected:
            # Real launch dispatch and first actor update share one outer frame.
            rabbit_driver(c,parent)
            call(c,0x800DE0B0,0)
            assert m.rw(0x8017DA98)==0x800F3E98 and m.rb(SCENE+0xB40+84*7+0x46)==1
        else:call(c,0x80080664,SCENE)
        selected=m.rb(SCENE+0xB40+84*7+0x49)
        special=m.rw(SCENE+0xB40+84*7+0x50)==0x80080B44
        assert special==expected
        row=dict(trigger=trigger,target_draw=target_draw,dead_mask=dead_mask,defending=defending,projectile=special,target=selected-1 if special else None,impact_tick=None,release_tick=None,duration=None,damage=0)
        row.update(decision_draws=used[:],result='projectile' if special else 'ordinary' if c.r[2]==0xFFFFFFFF else 'skipped' if m.rb(SCENE+0xB40+84*7+0x46) else 'waiting',normal_target=selected-1 if not special and c.r[2]==0xFFFFFFFF else None)
        if special:
            assert draw_count[0]==2 and m.rb(aux+3)==1
            assert selected==(target_draw*100//32767)%6+1
            hold_rabbit_scheduler(c)
            for tick in range(2,151):
                call(c,0x800DE0B0,0)
                applied=[args[:2] for pc,args in c.effects if pc==0x800E1654]
                if applied and row['impact_tick'] is None:
                    row['impact_tick']=tick;row['damage']=applied[0][1]
                    assert applied==[(selected,27 if defending else 55)] and draw_count[0]==3
                    assert m.rw(SCENE+0xB40+84*7+0x50)==0
                if not m.rb(aux+3) and row['release_tick'] is None:
                    row['release_tick']=tick
                    assert all(m.rw(aux+off)==0 for off in (0x54,0x84,0x88))
                if m.rw(SCENE+0x30):row['duration']=tick;break
            else:raise AssertionError('Rabbit projectile did not complete')
            assert (row['impact_tick'],row['release_tick'],row['duration'])==(64,94,117)
            assert draw_count[0]==3
            assert 0x800F7E90 in c.visited and 0x800F7D5C not in c.visited
            assert len([pc for pc,_ in c.effects if pc==0x800C2DC0])==6
            assert [args[:3] for pc,args in c.effects if pc==0x800E3820]==[(selected,7,0x8009EFBC)]
            assert export.rabbit_timings(raw)['projectile']=={key:row[key] for key in ('impact_tick','release_tick','duration')}
        rows.append(row)
    return rows


def rabbit_ordinary_cases():
    from legacy_instruction_fixture import call
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    layouts=((1,2,3,4,5,6),(4,2,3,1,5,6))
    specs=[(layout,mask,defending,retry,accuracy,False,False) for layout,mask,defending,retry,accuracy in itertools.product(layouts,(0,1,7),(False,True),(False,True),(0,99))]
    specs += [(layouts[0],1,defending,False,99,True,False) for defending in (False,True)]
    specs += [(layouts[0],0,True,True,0,False,True)]
    for layout,mask,defending,retry,accuracy,fallback,projectile_retry in specs:
        actor=7 if accuracy==0 else 12
        c,parent,aux=rabbit_fixture(raw,defending,mask,actor);m=c.mem;rabbit_driver(c,parent)
        front=[i for i,row in enumerate(layout) if row<4 and not mask&(1<<i)]
        for i,row in enumerate(layout,1):m.sb(SCENE+0xB40+84*i+0x44,row)
        waiting=[0]+[0]*len(front) if retry and front else []
        if not front:launch=[0]
        elif projectile_retry:launch=[32767,32767]
        elif fallback:launch=[32767,0,32767,accuracy]
        else:launch=[0,32767,accuracy]
        values=waiting+launch+([100] if front else [])
        stream=iter(values);count=[0]
        def draw(_):count[0]+=1;return next(stream,32767)
        c.hooks[0x80147E38]=draw
        call(c,0x800DE0B0,0)
        if waiting:
            assert count[0]==len(waiting) and m.rb(SCENE+0xB40+84*actor+0x46)==0
            assert m.rw(0x8017DA98)==0x800F40FC and m.rw(SCENE+0xB40+84*actor+0x50)==0
            call(c,0x800DE0B0,0)
        kind='projectile' if projectile_retry else 'ordinary' if front else 'skipped'
        selected=m.rb(SCENE+0xB40+84*actor+0x49)
        row=dict(formation=list(layout),dead_mask=mask,defending=defending,actor=actor-1,draws=values,wait_draws=len(waiting),kind=kind,target=selected-1 if front else None,impact_tick=None,return_tick=None,duration=None,damage=0)
        if not front:
            assert count[0]==1 and m.rb(SCENE+0xB40+84*actor+0x46)==1 and m.rw(SCENE+0x30)==1
        else:
            assert selected==(5 if projectile_retry else front[0]+1)
            assert count[0]==len(values)-1 and m.rb(SCENE+0xB40+84*actor+0x46)==1
            assert m.rw(SCENE+0xB40+84*actor+0x50)==(0x80080B44 if projectile_retry else 0x800F5960)
            hold_rabbit_scheduler(c)
            for tick in range(2,201):
                call(c,0x800DE0B0,0)
                applied=[args[:2] for pc,args in c.effects if pc==0x800E1654]
                if applied and row['impact_tick'] is None:
                    row['impact_tick']=tick;row['damage']=applied[0][1]
                    assert applied==[(selected,27 if defending else 55)]
                if m.rw(SCENE+0x30) and row['return_tick'] is None:row['return_tick']=tick
                if m.rw(SCENE+0x30) and m.rb(parent+5)==0:
                    row['duration']=tick;break
            else:raise AssertionError('Rabbit ordinary action failed to finish')
            assert count[0]==len(values)
            if kind=='ordinary':
                assert (row['impact_tick'],row['return_tick'],row['duration'])==(79,99,134)
                assert m.rw(parent+0x54)==m.rw(parent+0x58)==0
                assert 0x800F7D5C in c.visited and 0x800F7E90 in c.visited
                assert export.rabbit_timings(raw)['ordinary']=={key:row[key] for key in ('impact_tick','return_tick','duration')}
            else:
                assert (row['impact_tick'],row['duration'])==(64,117)
                row['return_tick']=None
        rows.append(row)
    # The low-HP guard check is outside the ordinary runtime subset, including Phero.
    for hp in (24,25):
        c,_,_=rabbit_fixture(raw);c.mem.sh(SCENE+0xB40+84+0x12,hp)
        call(c,0x800F79E0,7,1)
        assert c.r[2]==(2 if hp==24 else 0)
    return rows


def commander_fixture(raw,dead_mask=0):
    from test_battle_picker import SCENE
    c,parent,aux=rabbit_fixture(raw,dead_mask=dead_mask,actor=10,commander=True);m=c.mem
    c.hooks[0x80147D78]=0
    rabbit_driver(c,parent);m.sb(parent,3);m.sw(0x8040000C,0x800A2208);m.sw(SCENE+0x20,4)
    for i in range(7,11):m.sb(SCENE+0xB40+84*i+0x44,i-6);m.sb(SCENE+0xB40+84*i+0x46,int(i!=10))
    return c,parent,aux


def commander_choices():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    for front,ally,dead,roll in itertools.product((False,True),('unacted','acted','ko'),(0,1,16),(0,50,51,99,100,32767)):
        c,parent,_=commander_fixture(raw,dead);m=c.mem
        m.sb(SCENE+0xB40+84*10+0x44,1 if front else 4)
        m.sb(SCENE+0xB40+84*7+0x46,int(ally!='unacted'));m.sb(SCENE+0xB40+84*7+0x45,int(ally=='ko'));m.sh(SCENE+0xB40+84*7+0x12,0 if ally=='ko' else 100)
        c.hooks[0x80147E38]=roll;c.hooks[0x800E3820]=0
        call(c,0x80080F00,SCENE)
        scripts=[args for pc,args in c.effects if pc==0x800E3820]
        order=not front and ally=='unacted'
        count=sum(pc==0x80147E38 for pc,args in c.effects)
        result='order' if order else 'status' if scripts else 'waiting'
        assert c.r[2]==int(order)
        if order:assert m.rw(SCENE+12)==0x800811B0 and scripts[0][:3]==(10,10,0x800A2268) and count==0
        else:assert (not scripts or scripts[0][2]==0x800A2374) and m.rb(SCENE+0xB40+84*10+0x46)==int(bool(scripts))
        rows.append(dict(front=front,ally=ally,dead_mask=dead,roll=roll,result=result,target=scripts[0][1]-1 if scripts and not order else None,draws=count))
    # Original grouping excludes a locked front ally; no concurrent lock state is implemented by the runtime subset.
    c,_,_=commander_fixture(raw);c.mem.sb(SCENE+0xB40+84*7+0x46,0);c.mem.sb(SCENE+0x50+140*7+5,1)
    c.hooks[0x800E3820]=0;c.hooks[0x80147E38]=51;call(c,0x80080F00,SCENE);assert c.r[2]==0
    return rows


def coordinator_end_cases():
    from test_battle_picker import SCENE
    rows=[];raw=source('/B_DATA.BIN')[0]
    for mask in range(16):
        c,_,_=commander_fixture(raw);m=c.mem;c.hooks[0x800F6110]=0;c.hooks[0x800F777C]=0
        m.sw(SCENE+0x2C,777);m.sw(0x8017DA94,0x800F74A8)
        for i in range(4):m.sb(SCENE+0xB40+84*(i+7)+0x45,bool(mask&(1<<i)))
        call(c,0x800F74A8,1);left=m.rw(SCENE+0x2C);won=left==0
        assert left==4-mask.bit_count() and m.rw(0x8017DA94)==(0x800F78B0 if won else 0x800F64F0)
        waits=[]
        if won:
            assert m.rw(SCENE+0x1264)==30
            for tick in range(1,32):
                call(c,0x800F78B0,1);waits.append(dict(remaining=30-tick,ready=c.r[2]==1))
            assert all(not row['ready'] for row in waits[:30]) and waits[30]['ready']
        rows.append(dict(inactive=mask,remaining_enemies=left,victory=won,waits=waits))
    return rows


def coordinator_picker_cases():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    for speeds,rolls,acted,locks in itertools.product(((1,2,3),(3,3,3),(9,0,4)),((0,0,0),(9,1,5),(32767,10,9)),range(8),range(8)):
        c=ModuleInstructions(raw,0x80080000);m=c.mem;m.sw(0x8017BE3C,SCENE);m.sw(SCENE+0x24,3);m.sw(SCENE+0x1C,3)
        for i,speed in enumerate(speeds,1):
            m.sh(SCENE+0xB40+84*i+0x2A,speed);m.sh(SCENE+0xB40+84*i+0x12,100)
            m.sb(SCENE+0xB40+84*i+0x46,int(bool(acted&(1<<(i-1)))));m.sb(SCENE+0x50+140*i+5,int(bool(locks&(1<<(i-1)))))
        tape=iter(rolls);c.hooks[0x80147E38]=lambda _:next(tape);call(c,0x800F4698)
        value=c.r[2];choice={'no_ready':{}} if value==0xFFFFFFFF else {'round_end':{}} if value==0 else dict(actor=value-1)
        rows.append(dict(speeds=list(speeds),rolls=list(rolls),acted=acted,locks=locks,choice=choice,draws=sum(pc==0x80147E38 for pc,args in c.effects)))
    return rows


def coordinator_snapshot(c,selected=True):
    from test_battle_picker import SCENE
    m=c.mem;native=m.rw(SCENE+0x3420)
    cached=None if not selected else {'no_ready':{}} if native==0xFFFFFFFF else {'round_end':{}} if native==0 else dict(actor=native-1)
    stage={0x800F45C8:'await_order',0x800F3E98:'select',0x800F3FEC:'check',0x800F40FC:'dispatch',0x800F43E0:'round_boundary',0x800F445C:'item_wait'}[m.rw(0x8017DA98)]
    if m.rw(0x8017DA94)==0x800F74A8:stage='round_ready'
    left=m.rw(SCENE+0x1264);left=left-0x100000000 if left&0x80000000 else left
    return dict(stage=stage,remaining=left,current_actor=m.rw(SCENE+8)-1,cached=cached,completed=bool(m.rw(SCENE+0x30)),cross_side_pending=bool(m.rw(SCENE+0x44)))


def commander_scheduler_cases():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];checks=0;rows=[]
    for delay,candidate,locked,completed,marker in itertools.product((0,1,2),(1,7),(0,8),(0,1),(0,1)):
        c,_,_=commander_fixture(raw);m=c.mem
        m.sw(0x8017DA98,0x800F3E98);m.sw(SCENE+0x1264,delay);m.sw(SCENE+0x44,marker);m.sb(SCENE+0xB40+84*candidate+0x46,0)
        c.hooks[0x800F4698]=candidate;c.hooks[0x800F6110]=0
        call(c,0x800F3E98,2)
        assert m.rw(SCENE+0x1264)==(delay-1)&0xFFFFFFFF
        after_select=coordinator_snapshot(c,delay!=2);after_check=None;after_dispatch=None
        picks=[pc for pc,args in c.effects if pc==0x800F4698]
        if delay==2:assert not picks and m.rw(0x8017DA98)==0x800F3E98
        else:
            assert picks==[0x800F4698] and m.rw(SCENE+0x3420)==candidate and m.rw(0x8017DA98)==0x800F3FEC
            assert m.rw(SCENE+0x44)==int(marker or candidate==1)
            # Model a candidate becoming locked between selection and dispatch.
            m.sb(SCENE+0x50+140*candidate+5,locked);m.sw(SCENE+0x30,completed)
            call(c,0x800F3FEC,2)
            dispatch=not locked and (completed or not (marker or candidate==1))
            assert m.rw(0x8017DA98)==(0x800F40FC if dispatch else 0x800F3E98 if locked else 0x800F3FEC),(delay,candidate,locked,completed,hex(m.rw(0x8017DA98)),m.rw(SCENE+8),m.rw(SCENE+0x30),m.rw(SCENE+0x44))
            assert m.rw(SCENE+8)==(candidate if dispatch else 10)
            if dispatch:assert m.rw(SCENE+0x30)==m.rw(SCENE+0x44)==0
            after_check=coordinator_snapshot(c)
            if dispatch and candidate==7:
                m.sh(SCENE+0xB40+84*candidate+0x4A,32);call(c,0x800F40FC,2)
                after_dispatch=coordinator_snapshot(c)
                assert m.rb(SCENE+0xB40+84*candidate+0x46)==1 and m.rw(SCENE+0x30)==1
        rows.append(dict(delay=delay,candidate=candidate-1,locked=bool(locked),completed=bool(completed),marker=bool(marker),after_select=after_select,after_check=after_check,after_dispatch=after_dispatch))
        checks+=1
    for candidate,stage in ((0,0x800F43E0),(0xFFFFFFFF,0x800F3E98)):
        c,_,_=commander_fixture(raw);m=c.mem;m.sw(0x8017DA98,0x800F3E98);m.sw(SCENE+0x1264,1)
        c.hooks[0x800F4698]=candidate;call(c,0x800F3E98,2)
        assert m.rw(SCENE+0x3420)==candidate and m.rw(0x8017DA98)==stage and m.rw(SCENE+8)==10
        assert m.rw(SCENE+0x1264)==(30 if candidate==0 else 0)
        rows.append(dict(delay=1,candidate=-1 if candidate==0xFFFFFFFF else -2,locked=False,completed=False,marker=False,after_select=coordinator_snapshot(c),after_check=None,after_dispatch=None))
        checks+=1
    assert len(rows)==checks==50
    return rows


def commander_dispatch_cases(party_attack=False,knockout=False,critical_cases=False):
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    inputs=(('normal',32767),('minimum',10),('near_knockout',32767),('locked_target',32767),('routed',32767)) if party_attack else itertools.product(('normal','turtle','sleep'),(0,32767))
    if knockout:inputs=(('normal',32767),('minimum',10),('near_knockout',32767),('locked_target',32767),('routed',32767),('flagged',32767))
    if critical_cases:inputs=(('normal',32767),('minimum',10),('threshold',32767),('near_knockout',32767),('locked_target',32767),('routed',32767),('killer',32767),('killer_boundary',32767),('flagged',32767))
    for mode,value in inputs:
        c,parent,_=commander_fixture(raw);m=c.mem;images=[];read=c.read
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read;arm_character(c,3,'PAN',images)
        ally=SCENE+0x50+140*9;target=SCENE+0x50+140*3;slot=SCENE+0xB40+84*3
        m.sb(ally,2);m.sb(ally+3,1);m.sw(ally+8,0x800A0FD8)
        call(c,0x800E1E3C,0x800A1348,0);m.sw(ally+0x84,c.r[2]);call(c,0x800E7468,c.r[2]);m.sw(ally+0x88,c.r[2])
        m.sw(0x80400008,0x800A0F98);m.sb(SCENE+0xB40+84*9+0x46,0);m.sh(SCENE+0xB40+84*9+0x30,99)
        for i in range(1,7):
            m.sb(SCENE+0xB40+84*i+0x46,int(i<=2));m.sb(SCENE+0xB40+84*i+0x47,1);m.sh(SCENE+0xB40+84*i+0x2A,0)
        m.sb(0x80420000+128*3+0x4C,25 if mode=='turtle' else 6)
        if mode=='sleep':m.sh(slot+0x4A,32);m.sw(SCENE+0x30A0+128*3+16*5,1)
        if party_attack:
            arm_character(c,1,'SHU',images,scripts=True)
            hero=SCENE+0xB40+84;m.sb(hero+0x46,0);m.sb(hero+0x47,0);m.sb(hero+0x49,9 if mode=='locked_target' else 7);m.sh(hero+0x30,50);m.sh(hero+0x2A,2)
            victim_index=9 if mode in ('locked_target','routed') else 7
            victim=SCENE+0x50+140*victim_index;m.sb(victim,2);m.sb(victim+3,1);m.sw(victim+8,0x800A0FD8)
            call(c,0x800E1E3C,0x800A1348,0);m.sw(victim+0x84,c.r[2]);call(c,0x800E7468,c.r[2]);m.sw(victim+0x88,c.r[2])
            m.sh(SCENE+0xB40+84*victim_index+0x12,12 if mode=='near_knockout' else 100)
        if party_attack and mode=='routed':
            m.sw(SCENE+0x2C,2);m.sh(hero+0x26,9999);m.sh(SCENE+0xB40+84*9+0x10,90);m.sh(SCENE+0xB40+84*9+0x12,90);m.sh(SCENE+0xB40+84*9+0x32,25);m.sh(SCENE+0xB40+84*9+0x26,40)
            for dead in (7,8):m.sh(SCENE+0xB40+84*dead+0x12,0);m.sb(SCENE+0xB40+84*dead+0x45,1)
        if knockout:
            if mode=='flagged':m.sh(SCENE+0xB40+84*victim_index+0x4A,0x90)
            if mode=='routed':m.sh(hero+0x30,150)
            else:m.sh(SCENE+0xB40+84*victim_index+0x12,11 if mode=='near_knockout' else 10 if mode=='minimum' else 5)
        if critical_cases:
            if mode=='near_knockout':m.sh(SCENE+0xB40+84*victim_index+0x12,30)
            if mode=='flagged':m.sh(SCENE+0xB40+84*victim_index+0x4A,0x90)
            if mode in ('killer','killer_boundary'):m.sb(0x80420000+128+0x4C,15)
        del c.hooks[0x800E1654]
        def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
        def icon(cpu):cpu.r[31]=0x800E0750;return 0
        c.hooks[0x800E1780]=numbers;c.hooks[0x800E0748]=icon;c.hooks[0x800F6110]=0
        # All original coordinator/picker/dispatch code runs; camera and the following round are boundaries.
        c.hooks[0x800F74A8]=0xFFFFFFFF
        frame=[0];draws=[];dispatches=[];attempts=[];basic=c.basic
        def trace(pc):
            if pc==0x800F40FC and frame[0]>1:attempts.append((frame[0],m.rw(SCENE+8)-1))
            return basic(pc)
        c.basic=trace
        def draw(cpu):
            selected=value
            if critical_cases and frame[0]==(200 if mode in ('locked_target','routed') else 144) and sum(row['tick']==frame[0] for row in draws)==1:
                selected={'threshold':3,'routed':24,'killer':5,'killer_boundary':6}.get(mode,2)
            draws.append(dict(tick=frame[0],value=selected));return selected
        c.hooks[0x80147E38]=draw;samples=[]
        for tick in range(1,450 if knockout or critical_cases else 350 if party_attack else 205):
            frame[0]=tick;call(c,0x800DE0B0,0)
            if attempts and attempts[-1][0]==tick and m.rb(SCENE+0xB40+84*(attempts[-1][1]+1)+0x46):dispatches.append(attempts[-1])
            samples.append(dict(coordinator=coordinator_snapshot(c,tick>=72),dispatch_count=len(dispatches),last_dispatched=dispatches[-1][1] if dispatches else None,party_acted=[bool(m.rb(SCENE+0xB40+84*i+0x46)) for i in range(1,7)],hp=m.rh(slot+0x12),flags=m.rh(slot+0x4A),draws=len(draws)))
            if party_attack:
                samples[-1].update(hero_locked=bool(m.rb(SCENE+0x50+140+5)),victim_locked=bool(m.rb(victim+5)),victim_hp=m.rh(SCENE+0xB40+84*victim_index+0x12),victim_down=bool(m.rb(SCENE+0xB40+84*victim_index+0x45)),owner_locked=bool(m.rb(parent+5)),ally_locked=bool(m.rb(ally+5)))
            if knockout or critical_cases:samples[-1]['victim_flags']=m.rh(SCENE+0xB40+84*victim_index+0x4A)
            if m.rw(0x8017DA94)==0x800F74A8:break
        if critical_cases:
            selected=0x800F5ABC in c.visited
            assert {0x800F835C,0x800F4834}<=c.visited
            assert (0x800F5ABC if selected else 0x800F5960) in c.visited
            assert selected==(mode not in ('threshold','killer_boundary'))
            end=346 if mode=='near_knockout' else 338 if selected and mode in ('locked_target','routed') else 282 if selected else 273
            assert tick==end,(mode,tick,dispatches)
            launch=200 if mode in ('locked_target','routed') else 144
            assert samples[launch-1]['coordinator']['cross_side_pending']==selected
            if selected and mode!='near_knockout':assert samples[launch+94]['coordinator']['current_actor']==0
            assert all(sample['victim_flags']==(0x90 if mode=='flagged' else 0) for sample in samples)
            rows.append(dict(mode=mode,critical=selected,draws=draws,samples=samples));continue
        if knockout:
            launch=200 if mode in ('locked_target','routed') else 144;impact=launch+72;hurt_end=impact+36
            lethal=mode!='near_knockout';end=launch+202 if lethal else launch+129
            assert tick==end,(mode,tick,end)
            assert all(sample['victim_hp']>0 for sample in samples[:impact-1])
            if lethal:
                assert samples[impact-1]['victim_hp']==0 and samples[hurt_end-1]['victim_down']
                assert all(sample['victim_locked'] for sample in samples[launch-1:hurt_end+92])
                assert not samples[hurt_end+92]['victim_locked'] and not samples[end-1]['victim_locked']
            else:assert samples[-1]['victim_hp']==1 and not samples[-1]['victim_down']
            assert all(sample['victim_flags']==(0x90 if mode=='flagged' else 0) for sample in samples)
            rows.append(dict(mode=mode,draws=draws,samples=samples));continue
        if party_attack:
            assert tick==(329 if mode in ('locked_target','routed') else 273) and dispatches==([(200,0),(203,2),(206,3),(209,4),(212,5)] if mode in ('locked_target','routed') else [(144,0),(147,3),(150,4),(153,5),(156,2)]),(mode,tick,dispatches)
            assert samples[142]['coordinator']['cached']==dict(actor=0)
            assert samples[143]['hero_locked']==(mode not in ('locked_target','routed')) and samples[143]['ally_locked']
            impact=272 if mode in ('locked_target','routed') else 216
            assert samples[impact-2]['victim_hp']==(12 if mode=='near_knockout' else 90 if mode=='routed' else 100) and samples[impact-1]['victim_hp']<(12 if mode=='near_knockout' else 90 if mode=='routed' else 100)
            release=328 if mode in ('locked_target','routed') else 272
            assert samples[release-1]['hero_locked']==False and samples[release-2]['hero_locked']
            assert len(draws)==(19 if mode in ('locked_target','routed') else 16),(mode,len(draws))
            rows.append(dict(mode=mode,draws=draws,samples=samples));continue
        assert tick==200 and dispatches==[(144,3),(147,4),(150,5),(156,2)],(mode,dispatches,tick)
        assert samples[71]['coordinator']['cached']==dict(actor=3) and samples[142]['coordinator']['stage']=='dispatch'
        assert len(draws)==(8 if mode=='turtle' else 9)
        rows.append(dict(mode=mode,draws=draws,samples=samples))
    return rows


def commander_order_cases():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    inputs=list(itertools.product(((0,False),(1,False),(2,False),(0,True)),('normal','defend','turtle','copper','existing','lethal'),((100,0),(32767,32767))))
    inputs += [((i,swap),'normal',(100,roll)) for i,swap in ((0,False),(2,False),(0,True)) for roll in (6553,6554)]
    for (index,swap),mode,(damage_roll,status_roll) in inputs:
        c,parent,_=commander_fixture(raw);m=c.mem;images=[];read=c.read
        formation=list(range(6))
        if swap:formation[0],formation[5]=formation[5],formation[0]
        target=formation[index]
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read
        arm_character(c,target+1,('SHU','GRE','PAN','VIC','YAM','TAI')[target],images)
        for i in range(6):m.sb(SCENE+0xB40+84*(i+1)+0x44,formation.index(i)+1)
        ally=SCENE+0x50+140*(index+7);m.sb(ally,2);m.sb(ally+3,1);m.sw(ally+8,0x800A0FD8)
        call(c,0x800E1E3C,0x800A1348,0);m.sw(ally+0x84,c.r[2]);call(c,0x800E7468,c.r[2]);m.sw(ally+0x88,c.r[2])
        m.sw(0x80400008,0x800A0F98);m.sb(SCENE+0xB40+84*(index+7)+0x46,0);m.sh(SCENE+0xB40+84*(index+7)+0x30,99)
        slot=SCENE+0xB40+84*(target+1);ward=SCENE+0x50+140*(target+1);initial_hp=24 if mode=='lethal' else 100
        m.sh(slot+0x12,initial_hp);m.sb(slot+0x47,int(mode=='defend'))
        m.sb(0x80420000+128*(target+1)+0x4C,25 if mode=='turtle' else 0)
        flags=0xE7 if mode=='lethal' else 48 if mode=='existing' else 0x8000 if mode=='copper' else 0
        m.sh(slot+0x4A,flags)
        for status in range(9):
            if flags & (1,2,4,8,16,32,128,64,32768)[status]:m.sw(SCENE+0x30A0+128*(target+1)+16*status,1)
        del c.hooks[0x800E1654]
        def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
        def icon(cpu):cpu.r[31]=0x800E0750;return 0
        c.hooks[0x800E1780]=numbers;c.hooks[0x800E0748]=icon
        # The real order stage runs; only later unrelated actor selection is held.
        c.hooks[0x800F3E98]=0xFFFFFFFF
        draws=[damage_roll]+([] if mode=='turtle' else [status_roll]);tape=iter(draws)
        c.hooks[0x80147E38]=lambda _:next(tape);samples=[]
        for tick in range(1,240):
            call(c,0x800DE0B0,0)
            samples.append(dict(owner_locked=bool(m.rb(parent+5)),ally_locked=bool(m.rb(ally+5)),target_locked=bool(m.rb(ward+5)),ally_acted=bool(m.rb(SCENE+0xB40+84*(index+7)+0x46)),hp=m.rh(slot+0x12),flags=m.rh(slot+0x4A),down=bool(m.rb(slot+0x45)),draws=sum(pc==0x80147E38 for pc,args in c.effects)))
            if tick>1 and samples[-1]['ally_acted'] and not any(samples[-1][key] for key in ('owner_locked','ally_locked','target_locked')):break
        else:raise AssertionError('single Squirrel order did not complete')
        assert tick==199 and samples[11]['ally_acted'] and not samples[10]['ally_acted']
        assert all(row['owner_locked']==(i<142) and row['ally_locked']==(12<=i<199) and row['target_locked']==(12<=i<153) for i,row in enumerate(samples,1))
        assert samples[115]['hp']==initial_hp and samples[116]['hp']==(0 if mode=='lethal' else initial_hp if mode=='copper' else samples[-1]['hp'])
        assert samples[-1]['draws']==len(draws) and 0x800F79E0 not in c.visited and 0x800F7D5C not in c.visited
        assert {0x800811B0,0x80081374,0x8008145C}<=c.visited
        owner,attack=export.commander_order_timings(raw)
        assert owner==dict(launch_tick=12,owner_release_tick=142) and attack==dict(impact_tick=106,return_tick=107,status_tick=108,target_release_tick=142,duration=188,status_percent=20)
        rows.append(dict(ally=index,target=target,formation=formation,mode=mode,initial_hp=initial_hp,draws=draws,samples=samples))
    return rows


def commander_cases():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    for target,mode,roll in itertools.product((0,4,5),('normal','turtle','sleep','turtle_sleep'),(0,9830,9831,32767)):
        c,parent,aux=commander_fixture(raw);m=c.mem;images=[];read=c.read
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read
        arm_character(c,target+1,('SHU','GRE','PAN','VIC','YAM','TAI')[target],images)
        turtle='turtle' in mode;sleep='sleep' in mode
        m.sb(0x80420000+128*(target+1)+0x4C,25 if turtle else 0)
        if sleep:m.sh(SCENE+0xB40+84*(target+1)+0x4A,32);m.sw(SCENE+0x30A0+128*(target+1)+16*5,1)
        # The native setter retains flags/acted/active records; its separate icon allocation is a presentation boundary.
        def icon(cpu):cpu.r[31]=0x800E0750;return 0
        c.hooks[0x800E0748]=icon
        draws=[0]*target+[51]+([] if turtle else [roll]);tape=iter(draws)
        c.hooks[0x80147E38]=lambda _:next(tape)
        samples=[]
        for tick in range(1,160):
            call(c,0x800DE0B0,0)
            if tick==1:hold_rabbit_scheduler(c)
            ward=SCENE+0x50+140*(target+1);slot=SCENE+0xB40+84*(target+1)
            samples.append(dict(owner_locked=bool(m.rb(parent+5)),target_locked=bool(m.rb(ward+5)),auxiliary_alive=bool(m.rb(aux+3)),sleep=bool(m.rh(slot+0x4A)&32),acted=bool(m.rb(slot+0x46)),draws=sum(pc==0x80147E38 for pc,args in c.effects)))
            assert all(m.rh(SCENE+0xB40+84*i+0x12)==100 for i in range(1,7))
            if tick>1 and not samples[-1]['owner_locked'] and not samples[-1]['target_locked'] and not samples[-1]['auxiliary_alive']:break
        else:raise AssertionError('Commander action did not release all actors')
        assert tick==130 and not any(pc==0x800E1654 for pc,args in c.effects)
        assert {0x80080F00,0x800814F4,0x800E4C4C,0x800E5E60,0x800E6AD4}<=c.visited
        assert samples[23]['auxiliary_alive'] and not samples[84]['auxiliary_alive']
        assert samples[99]['owner_locked'] and not samples[100]['owner_locked']
        expected=sleep or (not turtle and roll*100//32767%100<30)
        assert samples[-1]['sleep']==expected and samples[-1]['draws']==len(draws)
        rows.append(dict(target=target,mode=mode,draws=draws,samples=samples))
    return rows


def arm_character(c,index,code,images,scripts=False):
    import struct
    from test_battle_picker import SCENE
    data=source('/'+code+'.BIN')[0];base=0x81000000+index*0x100000
    images.append((base,data));m=c.mem
    section=int.from_bytes(data[36:40],'little')
    ne,nf,nc,flags=struct.unpack_from('<HHBB',data,section)
    for field,count in ((8,nc),(12,flags&63),(16,ne),(20,nf)):
        table=int.from_bytes(data[section+field:section+field+4],'little')
        m.sw(base+section+field,base+table)
        for j in range(count):m.sw(base+table+4*j,base+int.from_bytes(data[table+4*j:table+4*j+4],'little'))
    actor=SCENE+0x50+140*index;m.sb(actor+3,1)
    if scripts:
        table=int.from_bytes(data[32:36],'little');m.sw(actor+8,base+table)
        for i in range(10):m.sw(base+table+4*i,base+int.from_bytes(data[table+4*i:table+4*i+4],'little'))
    call(c,0x800E1E3C,base+section,0);m.sw(actor+0x84,c.r[2])
    call(c,0x800E7468,c.r[2]);m.sw(actor+0x88,c.r[2])


def cover_cases(knockout=False):
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    inputs=itertools.product(((0,1,0),(0,2,2),(4,5,0),(5,4,0)),(False,True),(False,) if knockout else (False,True),(0,100),(1,27,55,56) if knockout else (100,))
    for (target,guard,dead_mask),defending,protected,roll,initial_hp in inputs:
        c,parent,_=rabbit_fixture(raw,dead_mask=dead_mask);m=c.mem;images=[];read=c.read
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read
        codes=('SHU','GRE','PAN','VIC','YAM','TAI')
        arm_character(c,target+1,codes[target],images);arm_character(c,guard+1,codes[guard],images)
        # Run common hurt/HP consumers. Skip only number-packet construction after the pending-HP store.
        c.external_call=lambda pc:super(type(c),c).external_call(pc)
        del c.hooks[0x800E1654]
        def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
        c.hooks[0x800E1780]=numbers
        ward_b=SCENE+0xB40+84*(target+1);guard_b=SCENE+0xB40+84*(guard+1)
        m.sh(ward_b+0x12,24);m.sh(guard_b+0x12,initial_hp);m.sb(guard_b+0x47,int(defending));m.sh(guard_b+0x4A,0xF7 if knockout else 0x8000 if protected else 0)
        if knockout:
            persistent=0x80420000+128*(guard+1);m.sb(persistent+0x1F,2);m.sh(persistent+0x20,25);m.sh(persistent+0x24,26)
            for status in (0,1,2,4,5,6,7):m.sw(SCENE+0x30A0+128*(guard+1)+16*status,1)
        formation=list(range(1,7))
        if target>=3:formation[0],formation[target]=formation[target],formation[0]
        for i,row in enumerate(formation,1):m.sb(SCENE+0xB40+84*i+0x44,row)
        draws=[0]+[0]*sum(not dead_mask&(1<<i) and formation[i]<4 for i in range(target))+[32767,99,roll];tape=iter(draws)
        c.hooks[0x80147E38]=lambda _:next(tape)
        rabbit_driver(c,parent);samples=[]
        for tick in range(1,160):
            call(c,0x800DE0B0,0)
            if tick==1:hold_rabbit_scheduler(c)
            ward_a=SCENE+0x50+140*(target+1);guard_a=SCENE+0x50+140*(guard+1)
            samples.append(dict(hp=m.rh(guard_b+0x12),ward_hp=m.rh(ward_b+0x12),guard_locked=bool(m.rb(guard_a+5)),ward_locked=bool(m.rb(ward_a+5)),actor_locked=bool(m.rb(parent+5)),guard_down=bool(m.rb(guard_b+0x45)),guard_flags=m.rh(guard_b+0x4A),ward_returning=0x8016C2CA<=m.rw(ward_a+12)<=0x8016C2D2))
            assert m.rh(ward_b+0x12)==24
            if tick>1 and not any(samples[-1][key] for key in ('guard_locked','ward_locked','actor_locked')):break
        else:raise AssertionError('interception did not release all actors')
        guard_release=next(i+1 for i,row in enumerate(samples) if not row['guard_locked'])
        ward_release=next(i+1 for i,row in enumerate(samples) if not row['ward_locked'])
        ward_return=next(i+1 for i,row in enumerate(samples) if row['ward_returning'])
        assert ward_return==guard_release+int(guard>target)
        impact=next((i+1 for i,row in enumerate(samples) if row['hp']!=initial_hp),79)
        calls=[args for pc,args in c.effects if pc==0x800E1780]
        assert len(calls)==int(not protected),(target,guard,defending,protected,roll,len(calls),samples[-1])
        assert (guard_release,ward_release,tick)==(124,134+int(guard>target),134+int(guard>target))
        assert impact==79 and len([pc for pc,args in c.effects if pc==0x80147E38])==len(draws)
        falls=samples[-1]['hp']==0
        if falls:
            assert 0x800E2C90 in c.visited
            assert all(row['guard_down']==(i>=124) and row['guard_flags']==(0 if i>=124 else 0xF7) for i,row in enumerate(samples,1))
            assert m.rw(guard_a+12)==0x8016C078
            for status in (0,1,2,4,5,6,7):assert m.rw(SCENE+0x30A8+128*(guard+1)+16*status)==1
        elif knockout:assert all(not row['guard_down'] and row['guard_flags']==0xF7 for row in samples)
        assert {0x800F5E90,0x800F7E90,0x800E1654,0x800E3FDC}<=c.visited
        if not protected:assert 0x800F7468 in c.visited
        assert not m.rw(parent+0x54) and not m.rw(parent+0x58)
        rows.append(dict(target=target,guard=guard,dead_mask=dead_mask,formation=formation,defending=defending,protected=protected,draws=draws,initial_hp=initial_hp,statuses=knockout,damage=initial_hp-samples[-1]['hp'],impact_tick=impact,guard_release_tick=guard_release,ward_return_tick=ward_return,ward_release_tick=ward_release,duration=tick,samples=samples))
    if knockout:
        for items,used in (((25,26),None),((25,83),1),((83,83),0)):
            c,_,_=rabbit_fixture(raw);m=c.mem;record=0x80420000+128*2
            m.sw(SCENE+0x3428,4);m.sh(SCENE+0xB40+84*2+0x12,0);m.sb(record+0x1F,len(items))
            for i,item in enumerate(items):m.sh(record+0x20+4*i,item)
            c.hooks[0x800E3820]=0;c.hooks[0x800CA408]=0
            call(c,0x800E2C90,2)
            removed=[args[1] for pc,args in c.effects if pc==0x800CA408]
            scripts=[args[2] for pc,args in c.effects if pc==0x800E3820]
            assert removed==([] if used is None else [used])
            assert scripts==[0x8016C068 if used is None else 0x8016C400]
            assert m.rb(SCENE+0xB40+84*2+0x45)==int(used is None)
    return rows


def protection_cases():
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    # Native selector supplies expected results; names/types are independently checked below.
    for target,hp,dead_mask,phero,mixed in itertools.product(range(6),(24,25),(0,6,63),(False,True),(False,True)):
        c,_,_=rabbit_fixture(raw,dead_mask=dead_mask);m=c.mem
        ids=[8,2,6,35,38,32];names=['hero','gremio','pahn','viktor','yam_koo','tai_ho'];types=[0]*6
        if mixed:ids[2]=1;names[2]='cleo';types[2]=1
        for i,(native,kind) in enumerate(zip(ids,types),1):
            m.sb(SCENE+0x50+140*i,native);m.sb(0x80410000+128*i,native);m.sb(0x80410000+128*i+10,kind)
        m.sh(SCENE+0xB40+84*(target+1)+0x12,hp)
        m.sb(0x80420000+128*(target+1)+0x4C,26 if phero else 0)
        call(c,0x800F79E0,7,target+1)
        assert not any(pc==0x80147E38 for pc,_ in c.effects)
        rows.append(dict(target=target,hp=hp,dead_mask=dead_mask,phero=phero,ids=names,protector=c.r[2]-1 if c.r[2] else None))
    metadata=export.protection_export()[0]
    import character_table,preparation
    names={r['id']:preparation.stable_id(r['name']) for r in character_table.records()}
    pairs=[];address=0x8016C814
    while M.body()[address-M.MBASE]!=255:
        ward=M.body()[address-M.MBASE];protector=M.body()[address-M.MBASE+1];address+=2
        pairs.append(dict(ward=names[ward],protector=names[protector]))
    assert metadata['pairs']==pairs and len(pairs)==15
    for record in character_table.records():
        header=source('/'+record['sprite_file'])[0]
        assert next(r['character_type'] for r in metadata['characters'] if r['id']==names[record['id']])==header[10]
    # Native action locks and pending lethal HP reject a relationship candidate.
    for lock,inactive,pending,expected in ((0,0,0,2),(1,0,0,3),(0,1,0,3),(0,0,100,3),(0,0,99,2)):
        c,_,_=rabbit_fixture(raw);m=c.mem;m.sh(SCENE+0xB40+84+0x12,24)
        m.sb(SCENE+0x50+140*2+5,lock);m.sb(SCENE+0xB40+84*2+0x45,inactive);m.sh(SCENE+0xB40+84*2+0x4E,pending)
        call(c,0x800F79E0,7,1);assert c.r[2]==expected
    return rows


def roc_loop_case(presentation=False, ko_hp=None, alone=False, flagged=False, defending=False, cover=None, round_context=None, medicine=False, medicine_pair=None, gremio_attack=False, paired_attack=False, party_commands=None, party_attack_power=80):
    """Complete single-Roc attack, Hero reaction/retaliation and original round gate."""
    from test_battle_picker import SCENE
    gremio_attack=gremio_attack or paired_attack
    raw=source('/B_DATA.BIN')[0];c,parent,_=rabbit_fixture(raw,actor=7);m=c.mem;read=c.read;images=[]
    def character_read(address,size):
        for base,data in images:
            if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
        return read(address,size)
    c.read=character_read;arm_character(c,1,'SHU',images,scripts=True)
    if cover is not None or round_context is not None or medicine or gremio_attack:
        if cover is not None:assert cover['guard']==1
        arm_character(c,2,'GRE',images,scripts=True)
    if party_commands is not None:
        assert round_context is not None and presentation and len(party_commands)==6
        for actor,code in enumerate(('PAN','VIC','YAM','TAI'),3):arm_character(c,actor,code,images,scripts=True)
    call(c,0x800E1E3C,0x800A39BC,0);m.sw(parent+0x84,c.r[2]);call(c,0x800E7468,c.r[2]);m.sw(parent+0x88,c.r[2])
    rabbit_driver(c,parent);m.sb(parent,4);m.sw(parent+8,0x800A36C8);m.sw(0x80400010,0x800A3688)
    m.sw(SCENE+0x20,1);m.sw(SCENE+0x2C,1)
    for i in range(1,8):
        b=SCENE+0xB40+84*i;m.sb(b+0x46,0);m.sb(b+0x47,int(i!=1));m.sh(b+0x2A,60 if i==7 else 24 if i==1 else 0)
    hero=SCENE+0xB40+84;enemy=SCENE+0xB40+84*7
    m.sb(hero+0x49,7);m.sh(hero+0x30,180);m.sh(hero+0x26,9999)
    for off,value in ((0x10,110),(0x12,110),(0x30,125),(0x32,55),(0x26,55)):m.sh(enemy+off,value)
    if ko_hp is not None:
        m.sh(hero+0x12,ko_hp);m.sb(hero+0x47,int(defending));m.sh(hero+0x4A,0x90 if flagged else 0)
        for status in (4,6):
            if flagged:m.sw(SCENE+0x30A0+128+16*status,1)
        if alone:
            for i in range(2,7):
                slot=SCENE+0xB40+84*i;m.sh(slot+0x12,0);m.sb(slot+0x45,1);m.sb(slot+0x46,1)
    if cover is not None:
        guard=SCENE+0xB40+84*(cover['guard']+1)
        m.sh(guard+0x12,cover['hp']);m.sb(guard+0x47,int(cover['defending']));m.sh(guard+0x4A,0x8000 if cover['protected'] else 0)
        if cover.get('flagged',False):
            m.sh(guard+0x4A,m.rh(guard+0x4A)|0x90)
            for status in (4,6):m.sw(SCENE+0x30A0+128*2+16*status,1)
    if round_context is not None:
        import character_table
        records={r['id']:r for r in character_table.records()};prepared=[]
        for index,native in enumerate((8,2,6,35,38,32),1):
            record=0x80420000+128*index;seed=records[native]
            weapon=M.mword(0x80165890+4*seed['weapon_id']);curve=M.body()[weapon-M.MBASE+0x54]
            power=int.from_bytes(M.body()[0x801659D0-M.MBASE+32*curve+2*(seed['weapon_level']-1):][:2],'little')
            values=(round_context.get('attack',120)-power if index==1 else 10,255 if index==1 else 20,40,24 if index==1 else 0,50,0)
            m.sw(record,native);m.sh(record+4,round_context.get("initial_hp",100) if index==1 else 100);m.sh(record+6,round_context.get("initial_hp",100) if index==1 else 100);m.sb(record+0x0D,14)
            for column,value in enumerate(values):m.sb(record+0x10+column,value)
            m.sb(record+0x44,seed['weapon_id']);m.sb(record+0x45,seed['weapon_level']);m.sb(record+0x4C,(2,28,8,0,4,0)[index-1])
            m.sb(record+9,1)
            call(c,0x800D4EC0,record,SCENE+0xB40+84*index+0x24)
            prepared.append([m.rh(SCENE+0xB40+84*index+0x24+2*k) for k in range(8)])
        for column,value in enumerate((125,55,55,60,0,0)):m.sh(enemy+0x14+2*column,value)
        m.sh(hero+0x10,round_context.get('initial_hp',100))
        m.sw(SCENE+4,1)
        encounter=export.battle_placement.area_encounters(raw)['encounters'][3]
        assert int.from_bytes(raw[encounter['auxiliary_offset']+8:encounter['auxiliary_offset']+12],'little')==0
        m.sw(SCENE+0x133C,0)
        round_context['stats']=prepared
    if gremio_attack:
        guard=hero+84;m.sb(hero+0x47,1);m.sh(hero+0x2A,0)
        m.sb(guard+0x47,0);m.sb(guard+0x49,7);m.sh(guard+0x2A,24);m.sh(guard+0x30,180);m.sh(guard+0x26,9999);m.sh(guard+0x2E,0)
        if paired_attack:
            m.sb(hero+0x47,0);m.sh(hero+0x2A,24);m.sh(hero+0x30,90);m.sh(hero+0x2E,0)
            m.sh(guard+0x2A,23);m.sh(guard+0x30,90)
    if party_commands is not None:
        for member,target in enumerate(party_commands,1):
            slot=SCENE+0xB40+84*member
            m.sb(slot+0x47,1 if target is None else 0)
            if target is not None:m.sb(slot+0x49,7+target)
            for off,value in ((0x10,300),(0x12,300),(0x30,party_attack_power),(0x26,255),(0x32,40),(0x2A,24),(0x2E,0)):m.sh(slot+off,value)
        round_context['stats']=[[m.rh(SCENE+0xB40+84*member+0x24+2*k) for k in range(8)] for member in range(1,7)]
    if medicine:
        medicine_user,medicine_target=(1,0) if medicine_pair is None else medicine_pair
        record=0x80420000+128*(medicine_user+1);item_owner=SCENE+0xB40+84*(medicine_user+1)
        m.sb(record+0x1F,1);m.sh(record+0x20,25);m.sb(record+0x23,6)
        m.sb(item_owner+0x47,3);m.sb(item_owner+0x48,0);m.sb(item_owner+0x49,medicine_target+1)
        # Projection is output only; the recovery object, timers and pending-HP writers run.
        c.hooks[0x8014F5C4]=0;m.sw(SCENE+0x1284,1)
    if presentation:
        import battle_mock
        homes=battle_mock.party_world_positions()+[(-108,0,-10)]
        for index,home in enumerate(homes,1):
            actor=SCENE+0x50+140*index
            for axis,value in enumerate(home):
                m.sw(actor+0x5C+4*axis,(value*4096)&0xFFFFFFFF);m.sw(actor+0x68+4*axis,(value*4096)&0xFFFFFFFF)
        hero_data=images[0][1];section=int.from_bytes(hero_data[36:40],'little');ne=int.from_bytes(hero_data[section:section+2],'little')
        et=int.from_bytes(hero_data[section+16:section+20],'little')
        hero_poses={images[0][0]+int.from_bytes(hero_data[et+4*i:et+4*i+4],'little'):i for i in range(ne)}
        if cover is not None or round_context is not None or medicine or gremio_attack:
            base,body=images[1];section=int.from_bytes(body[36:40],'little');ne=int.from_bytes(body[section:section+2],'little');et=int.from_bytes(body[section+16:section+20],'little')
            guard_poses={base+int.from_bytes(body[et+4*i:et+4*i+4],'little'):i for i in range(ne)}
        section=0x239BC;ne=int.from_bytes(raw[section:section+2],'little');et=int.from_bytes(raw[section+16:section+20],'little')-0x80080000
        roc_poses={int.from_bytes(raw[et+4*i:et+4*i+4],'little'):i for i in range(ne)}
        def sample(actor,poses):
            signed=lambda value:value-0x100000000 if value&0x80000000 else value
            byte=lambda value:value-256 if value&128 else value
            return dict(position=dict(zip(('x','y','z'),[signed(m.rw(actor+0x68+4*i))/4096 for i in range(3)])),pose=poses[m.rw(m.rw(actor+0x84)+0x24)],offset=[byte(m.rb(actor+0x78)),byte(m.rb(actor+0x79))],visible=bool(m.rb(actor+3)))
    c.external_call=lambda pc:super(type(c),c).external_call(pc);del c.hooks[0x800E1654]
    def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
    def icon(cpu):cpu.r[31]=0x800E0750;return 0
    if party_commands is not None:
        party_pose_maps=[]
        for base,body in images[:6]:
            sec=int.from_bytes(body[36:40],'little');ne=int.from_bytes(body[sec:sec+2],'little');et=int.from_bytes(body[sec+16:sec+20],'little')
            party_pose_maps.append({base+int.from_bytes(body[et+4*i:et+4*i+4],'little'):i for i in range(ne)})
    c.hooks[0x800E1780]=numbers;c.hooks[0x800E0748]=icon;c.hooks[0x800F6110]=0;c.hooks[0x800F74A8]=0xFFFFFFFF
    # The normal command-menu interval lets the original unlocked-party driver select low-HP stance2.
    if ko_hp is not None and ko_hp<25:
        consumed=sum(pc==0x80147E38 for pc,args in c.effects);call(c,0x800E09BC)
        assert consumed==sum(pc==0x80147E38 for pc,args in c.effects)
    frame=[0];draws=[]
    def draw(cpu):draws.append(dict(tick=frame[0],value=51));return 51
    c.hooks[0x80147E38]=draw;rows=[]
    party_events=[]
    if party_commands is not None:
        original_word=c.word
        def party_word(address):
            if address==0x800F835C:party_events.append(dict(tick=frame[0],kind='command',actor=c.r[4]-1))
            if address==0x800F7E90:party_events.append(dict(tick=frame[0],kind='physical',actor=c.r[4]-1,target=c.r[5]-1))
            return original_word(address)
        c.word=party_word
    for tick in range(1,1200 if party_commands is not None else 650 if medicine or paired_attack else 349):
        frame[0]=tick;call(c,0x800DE0B0,0)
        coord=coordinator_snapshot(c,True)
        rows.append(dict(tick=tick,coordinator=coord,hero_hp=m.rh(hero+0x12),enemy_hp=m.rh(enemy+0x12),hero_lock=m.rb(SCENE+0x50+140+5),enemy_lock=m.rb(parent+5),enemy_down=m.rb(enemy+0x45),draws=len(draws)))
        if presentation:rows[-1].update(hero=sample(SCENE+0x50+140,hero_poses),roc=sample(parent,roc_poses))
        if party_commands is not None:
            rows[-1]['party_visuals']=[sample(SCENE+0x50+140*actor,poses) for actor,poses in enumerate(party_pose_maps,1)]
            rows[-1]['party_hp']=[m.rh(SCENE+0xB40+84*actor+0x12) for actor in range(1,7)]
            rows[-1]['party_locks']=[m.rb(SCENE+0x50+140*actor+5) for actor in range(1,7)]

        if cover is not None or round_context is not None or medicine or gremio_attack:
            guard_index=cover['guard'] if cover is not None else 1
            guard=SCENE+0xB40+84*(guard_index+1)
            guard_actor=SCENE+0x50+140*(guard_index+1)
            rows[-1].update(guard_hp=m.rh(guard+0x12),guard_lock=m.rb(guard_actor+5),guard_flags=m.rh(guard+0x4A),guard_down=bool(m.rb(guard+0x45)),ward_returning=0x8016C2CA<=m.rw(SCENE+0x50+140+12)<=0x8016C2D2)
            if presentation:rows[-1]['guard']=sample(guard_actor,guard_poses)
        if medicine and medicine_pair is None:
            rows[-1].update(uses=m.rb(record+0x23),item_acted=bool(m.rb(guard+0x46)),pending_hp=m.rh(hero+0x4E))
            particles=[]
            if 169<=tick<198:
                helper=m.rw(SCENE+0x50+140+0x58)
                signed=lambda value:value-0x100000000 if value&0x80000000 else value
                for index in range(4):
                    graphic=m.rw(helper+4+4*index)
                    particles.append(dict(position=dict(zip(('x','y','z'),[signed(m.rw(helper+0x24+12*index+4*axis))/4096 for axis in range(3)])),pose=hero_poses[m.rw(graphic+0x24)]))
            rows[-1]['particles']=particles
            graphic=m.rw(SCENE+0x50+140+0x84);packet=m.rw(graphic+0x28)
            rows[-1]['hero_light']=[m.rb(packet+4+axis) for axis in range(3)]

        if ko_hp is not None or gremio_attack or party_commands is not None:
            rows[-1].update(hero_down=bool(m.rb(hero+0x45)),hero_flags=m.rh(hero+0x4A),party_acted=[bool(m.rb(SCENE+0xB40+84*i+0x46)) for i in range(1,7)])
            if m.rw(0x8017DA94)==0x800F74A8:break
    if party_commands is not None:
        assert m.rw(0x8017DA94)==0x800F74A8
        return dict(commands=party_commands,attack_power=party_attack_power,stats=round_context['stats'],source_events=party_events,draws=draws,samples=rows)
    if paired_attack:
        assert m.rw(0x8017DA94)==0x800F74A8 and len(rows)==376 and len(draws)==29
        for row in rows:
            t=row['tick']
            assert row['hero_hp']==(100 if t<49 else 16) and row['guard_hp']==100
            assert row['enemy_hp']==(110 if t<210 else 75 if t<319 else 40)
            assert bool(row['hero_lock'])==(t<62 or 247<=t<375)
            assert bool(row['guard_lock'])==(146<=t<266)
            assert bool(row['enemy_lock'])==(t<145 or 146<=t<246 or 247<=t<355)
        return dict(actors=['hero','gremio'],timings=[export.party_attack_timing(identifier) for identifier in ('hero','gremio')],draws=draws,samples=rows)
    if gremio_attack:
        assert m.rw(0x8017DA94)==0x800F74A8
        timing=export.party_attack_timing('gremio')
        assert timing==dict(id='gremio',impact_tick=65,return_tick=89,release_tick=121,target_release_delay=36)
        assert len(rows)==340 and rows[48]['hero_hp']==58 and rows[209]['enemy_hp']==0
        assert rows[61]['hero_lock']==0 and rows[144]['enemy_lock']==0 and rows[145]['guard_lock']!=0
        assert rows[265]['guard_lock']==0 and rows[245]['enemy_down']==1 and rows[338]['enemy_lock']==0
        return dict(actor='gremio',timing=timing,source=source('/GRE.BIN')[1],draws=draws,samples=rows)
    if medicine and medicine_pair is None:
        assert m.rw(0x8017DA94)==0x800F74A8
        assert len(rows)==437 and len(draws)==22
        for row in rows:
            t=row['tick']
            assert row['uses']==(6 if t<146 else 5) and row['item_acted']==(t>=146)
            assert row['hero_hp']==(100 if t<49 or t>=200 else 16)
            assert row['pending_hp']==(65452 if t==199 else 0)
            assert bool(row['guard_lock'])==(146<=t<247)
            assert bool(row['hero_lock'])==(t<62 or 168<=t<232 or 235<=t<363)
            assert row['enemy_hp']==(110 if t<307 else 0)
            assert bool(row['enemy_down'])==(t>=343)
        assert {0x800F445C,0x800F5050,0x800F0708,0x800F215C,0x800F24E0,0x800F26CC}<=c.visited
        return dict(draws=draws,samples=rows)
    if round_context is not None:
        round_context.update(machine=c,parent=parent,hero=hero,enemy=enemy,sample=sample,hero_poses=hero_poses,guard_poses=guard_poses,roc_poses=roc_poses,frame=frame,draws=draws)
        return dict(draws=draws[:],samples=rows)
    if cover is not None:
        assert {0x800F79E0,0x800F5E90,0x800E1654,0x800E3FDC}<=c.visited
        assert all(row['hero_hp']==ko_hp for row in rows)
        del c.hooks[0x800F74A8];c.hooks[0x800F777C]=0;call(c,0x800F74A8,1)
        outcome=dict(remaining_enemies=m.rw(SCENE+0x2C),defeat=m.rw(SCENE+0x38)==1)
        assert outcome==dict(remaining_enemies=0,defeat=False)
        # Original persistent-record writers run; only framebuffer output is held.
        m.sw(0x8017DB24,0x80900000);c.hooks[0x800CA220]=0
        for i in range(1,7):m.sh(0x80420000+128*i+6,100)
        call(c,0x800DE5AC);call(c,0x800DE1EC,0)
        outcome['persistent_hp']=[m.rh(0x80420000+128*i+6) for i in range(1,7)]
        assert outcome['persistent_hp']==[ko_hp,rows[-1]['guard_hp'],100,100,100,100]
        return dict(**cover,hero_hp=ko_hp,draws=draws,samples=rows,outcome=outcome)
    if ko_hp is not None:
        del c.hooks[0x800F74A8];c.hooks[0x800F777C]=0;call(c,0x800F74A8,1)
        outcome=dict(remaining_enemies=m.rw(SCENE+0x2C),defeat=m.rw(SCENE+0x38)==1,terminal=c.r[2]==1)
        if outcome['defeat']:
            assert alone and {0x800E2C90,0x800E0778,0x800F8680}<=c.visited
            # Framebuffer copy and object frees are output/resource boundaries; both original HP writers run.
            gs=0x80900000;m.sw(0x8017DB24,gs);c.hooks[0x800CA220]=0
            m.sh(0x80420000+128+6,ko_hp)
            call(c,0x800DE0B0,0);assert m.rw(0x8017DA90)==0x800DE1EC and 0x800E818C not in c.visited
            call(c,0x800DE1EC,0)
            assert all(m.rh(0x80420000+128*i+6)==0 for i in range(1,7))
            record=export.battle_placement.area_encounters(raw)['encounters'][3]
            assert int.from_bytes(raw[record['auxiliary_offset']+16:record['auxiliary_offset']+20],'little')==0
            m.sw(SCENE+0x1340,0x80080000+record['descriptor_offset'])
            for address in (0x800E7D88,0x800E2B3C,0x800E7744,0x800E3248,0x800C2DC0,0x800C3104):c.hooks[address]=0
            call(c,0x800DE2B8,0)
            outcome.update(next_mode=m.rw(gs+0x1BB8),next_state=m.rw(gs+0x1BBC),next_selection=m.rw(gs+0x1BC0))
            assert (outcome['next_mode'],outcome['next_state'],outcome['next_selection'])==(0,99,10)
        return dict(hp=ko_hp,alone=alone,flagged=flagged,defending=defending,draws=draws,samples=rows,outcome=outcome)
    assert coord['stage']=='round_ready' and tick==348
    assert rows[48]['hero_hp']==16 and rows[217]['enemy_hp']==0
    assert rows[61]['hero_lock']==0 and rows[144]['enemy_lock']==0
    assert rows[253]['enemy_down']==1 and rows[346]['enemy_lock']==0
    assert len(draws)==22
    assert export.roc_timings(raw)==dict(impact_tick=49,return_tick=50,duration=145,target_release_delay=13)
    assert export.squirrel_knockout_ticks(raw,0x236C8)==94
    return dict(draws=draws,samples=rows)



def roc_two_round_case(initial_hp=100):
    from test_battle_picker import SCENE
    context={'initial_hp':initial_hp};first=roc_loop_case(True,initial_hp,round_context=context)
    c=context['machine'];m=c.mem;hero=context['hero'];enemy=context['enemy'];guard=SCENE+0xB40+84*2
    initial=len(context['draws'])
    def sample(tick):
        actor=lambda index:SCENE+0x50+140*index
        return dict(tick=tick,coordinator=coordinator_snapshot(c),hero_hp=m.rh(hero+0x12),enemy_hp=m.rh(enemy+0x12),hero_lock=m.rb(actor(1)+5),enemy_lock=m.rb(actor(7)+5),enemy_down=m.rb(enemy+0x45),draws=len(context['draws'])-initial,hero=context['sample'](actor(1),context['hero_poses']),roc=context['sample'](actor(7),context['roc_poses']),guard=context['sample'](actor(2),context['guard_poses']),hero_down=bool(m.rb(hero+0x45)),hero_flags=m.rh(hero+0x4A),party_acted=[bool(m.rb(SCENE+0xB40+84*i+0x46)) for i in range(1,7)],guard_hp=m.rh(guard+0x12),guard_lock=m.rb(actor(2)+5),guard_flags=m.rh(guard+0x4A),guard_down=bool(m.rb(guard+0x45)),ward_returning=0x8016C2CA<=m.rw(actor(1)+12)<=0x8016C2D2)
    assert len(first['samples'])==275 and first['samples'][-1]['enemy_hp']==48
    del c.hooks[0x800F74A8]
    context['frame'][0]=276;call(c,0x800DE0B0,0)
    assert m.rw(0x8017DA94)==0x800F64F0
    classifier=sample(276);classifier['coordinator']['stage']='round_setup'
    context['frame'][0]=277;call(c,0x800DE0B0,0)
    assert m.rw(0x8017DA94)==0x800F6C34 and m.rw(0x8017DA98)==0x800E9E90
    assert all(m.rb(SCENE+0xB40+84*i+0x47)==0 for i in range(1,8))
    reset=dict(hero_hp=m.rh(hero+0x12),enemy_hp=m.rh(enemy+0x12),acted=[bool(m.rb(SCENE+0xB40+84*i+0x46)) for i in range(1,8)],locks=[m.rb(SCENE+0x50+140*i+5) for i in range(1,8)],draws=len(context['draws'])-initial)
    # Menu choices have their own source gates; hold UI output while ordinary actor animation advances.
    c.hooks[0x800E9E90]=0xFFFFFFFF
    for tick in range(14):context['frame'][0]=278+tick;call(c,0x800DE0B0,0)
    for index in range(1,8):
        m.sb(SCENE+0xB40+84*index+0x47,int(index!=1));m.sb(SCENE+0xB40+84*index+0x49,7 if index==1 else 0)
    context['frame'][0]=0;m.sw(0x8017DA94,0x800F6DA8);call(c,0x800DE0B0,0)
    launch=sample(0)
    assert launch['draws']==1 and launch['coordinator']['remaining']==30
    assert all(not value for value in launch['party_acted'])
    assert context['stats']==[[m.rh(SCENE+0xB40+84*i+0x24+2*j) for j in range(8)] for i in range(1,7)]
    c.hooks[0x800F74A8]=0xFFFFFFFF;second=[]
    for tick in range(1,450):
        context['frame'][0]=tick;call(c,0x800DE0B0,0);second.append(sample(tick))
        if m.rw(0x8017DA94)==0x800F74A8:break
    assert len(second)==379 and second[248]['enemy_hp']==0
    assert second[79]['guard_hp']==(58 if initial_hp==100 else 100) and second[92]['guard_lock']==0 and second[103]['hero_lock']==0
    assert second[175]['enemy_lock']==0 and second[176]['hero_lock']==1
    assert second[284]['enemy_down']==1 and second[377]['enemy_lock']==0
    assert len(context['draws'])-initial==(26 if initial_hp==100 else 30)
    assert all(m.rb(0x80420000+128*i+9)==1 for i in range(1,7))
    assert {0x800F64F0,0x800F6B98,0x800F6DA8,0x800D4EC0,0x800F777C}<=c.visited
    return dict(initial_hp=initial_hp,stats=context['stats'],first=first,classifier=classifier,reset=reset,menu_updates=14,launch=launch,second=dict(draws=context['draws'][initial:],samples=second))



def roc_long_battle_case(self_medicine=False):
    """Run repeated original reset/command/launch cycles without an imposed two-round cap."""
    from test_battle_picker import SCENE
    context={'initial_hp':100 if self_medicine else 999,'attack':180 if self_medicine else 90}
    first=roc_loop_case(True,context['initial_hp'],round_context=context,medicine=self_medicine,medicine_pair=(0,0) if self_medicine else None)
    c=context['machine'];m=c.mem;hero=context['hero'];enemy=context['enemy'];guard=hero+84
    actor=lambda i:SCENE+0x50+140*i
    def sample(tick,initial):
        return dict(tick=tick,coordinator=None if m.rw(0x8017DA94)==0x800F6C34 else coordinator_snapshot(c),hero_hp=m.rh(hero+0x12),enemy_hp=m.rh(enemy+0x12),guard_hp=m.rh(guard+0x12),draws=len(context['draws'])-initial,
                    locks=[bool(m.rb(actor(i)+5)) for i in (1,2,7)],acted=[bool(m.rb(SCENE+0xB40+84*i+0x46)) for i in range(1,7)],
                    visuals=[context['sample'](actor(i),poses) for i,poses in ((1,context['hero_poses']),(2,context['guard_poses']),(7,context['roc_poses']))])
    rounds=[]
    while m.rh(enemy+0x12)>0:
        assert len(rounds)<8,'source battle did not terminate'
        before=len(context['draws'])
        del c.hooks[0x800F74A8]
        call(c,0x800DE0B0,0);assert m.rw(0x8017DA94)==0x800F64F0
        call(c,0x800DE0B0,0);assert m.rw(0x8017DA94)==0x800F6C34
        reset=sample(0,before)
        c.hooks[0x800E9E90]=0xFFFFFFFF
        for _ in range(14):call(c,0x800DE0B0,0)
        for index in range(1,8):
            m.sb(SCENE+0xB40+84*index+0x47,int(index!=1));m.sb(SCENE+0xB40+84*index+0x49,7 if index==1 else 0)
        context['frame'][0]=0;m.sw(0x8017DA94,0x800F6DA8);call(c,0x800DE0B0,0)
        launch=sample(0,before);c.hooks[0x800F74A8]=0xFFFFFFFF;samples=[]
        for tick in range(1,650):
            context['frame'][0]=tick;call(c,0x800DE0B0,0);samples.append(sample(tick,before))
            if m.rw(0x8017DA94)==0x800F74A8:break
        assert samples[-1]['coordinator']['stage']=='round_ready'
        rounds.append(dict(reset=reset,launch=launch,samples=samples,draws=context['draws'][before:]))
    assert len(rounds)>=(1 if self_medicine else 2) and m.rh(hero+0x12)>0
    first['samples']=[dict(tick=r['tick'],coordinator=r['coordinator'],hero_hp=r['hero_hp'],enemy_hp=r['enemy_hp'],guard_hp=r['guard_hp'],draws=r['draws'],locks=[bool(r[k]) for k in ('hero_lock','guard_lock','enemy_lock')],acted=r['party_acted'],visuals=[r[k] for k in ('hero','guard','roc')]) for r in first['samples']]
    return dict(initial_hp=context['initial_hp'],opening_medicine=self_medicine,stats=context['stats'],first=first,rounds=rounds)


def medicine_dispatch_cases():
    """Original battle dispatch: global locks, live target and per-character charges."""
    from test_battle_picker import SCENE
    raw=source('/B_DATA.BIN')[0];rows=[]
    for locked,hp,down,protected,uses,pending in itertools.product((0,1,2,7),(0,16,99,100),(False,True),(False,True),(1,6),(0,17)):
        c,_,_=rabbit_fixture(raw);m=c.mem;owner=SCENE+0xB40+84*2;target=owner-84;record=0x80420000+128*2
        m.sb(record+0x1F,2);m.sh(record+0x20,25);m.sb(record+0x23,uses)
        m.sh(record+0x24,26);m.sb(record+0x27,6)
        m.sb(owner+0x47,3);m.sb(owner+0x48,0);m.sb(owner+0x49,1)
        m.sh(target+0x12,hp);m.sh(target+0x4E,pending);m.sb(target+0x45,int(down));m.sh(target+0x4A,0x8000 if protected else 0)
        if locked:m.sb(SCENE+0x50+140*locked+5,8)
        # Dispatch proof stops at script installation; the full actor/effect path is separate below.
        c.hooks[0x800E3820]=0
        call(c,0x800F5050,2)
        expected=0 if locked else 0xFFFFFFFF if down or hp<pending else 0 if hp==pending else 1
        assert c.r[2]==expected,(locked,hp,down,protected,uses,pending,c.r[2])
        started=expected==1
        assert m.rh(target+0x12)==hp and m.rh(target+0x4E)==pending
        assert bool(m.rb(owner+0x46))==started
        assert m.rb(record+0x1F)==(1 if started and uses==1 else 2)
        assert m.rh(record+0x20)==(26 if started and uses==1 else 25)
        assert m.rb(record+0x23)==(6 if started and uses==1 else uses-int(started))
        launched=[args[:3] for pc,args in c.effects if pc==0x800E3820]
        assert launched==([(2,1,0x8016C194)] if started else [])
        assert not any(pc==0x80147E38 for pc,args in c.effects)
        rows.append(dict(locked=locked,hp=hp,down=down,protected=protected,uses=uses,pending=pending,result='started' if started else 'rejected' if expected==0xFFFFFFFF else 'waiting',remaining_count=m.rb(record+0x1F),first_item=m.rh(record+0x20),remaining_uses=m.rb(record+0x23)))
    return rows


def medicine_effect_cases():
    """Original preparation, particles, pending HP commit and independent actor releases."""
    from test_battle_picker import SCENE
    import struct
    from export_battle_trial import section_art
    raw=source('/B_DATA.BIN')[0];rows=[]
    # A second, linear script/f-record read establishes the deadlines without the instruction model.
    medicine=M.mword(0x80167658+25*4)
    assert (M.mword(medicine+0x18),M.mword(medicine+0x20))==(100,0x800F0708)
    assert struct.unpack_from('<21H',M.body(),0x8016C194-M.MBASE)==(15,0,1,4,13,5,4,14,5,26,0,8,3,60,4,15,5,16,0,1,0)
    assert struct.unpack_from('<14H',M.body(),0x8016C1C0-M.MBASE)==(15,0,1,3,60,4,15,5,4,0,16,0,1,0)
    assert struct.unpack_from('<17H',M.body(),0x8016C2F0-M.MBASE)==(15,0,1,4,0,30,0,35,0,9,34,1290,31,99,16,0,1)
    gre=source('/GRE.BIN')[0];_,animations,_=section_art(gre,int.from_bytes(gre[36:40],'little'),0)
    assert [sum(t or 256 for p,t in animations[i]) for i in (13,14,15)]==[21,1,20]
    assert M.mword(0x800F247C)==0x3402001E and M.mword(0x800F2784)==0x2442FFFC and M.mword(0x800F278C)==0x28420081
    for hp,maximum,protected in ((16,100,False),(99,100,False),(100,100,False),(16,100,True),(100,300,False)):
        c,parent,_=rabbit_fixture(raw);m=c.mem;images=[];read=c.read
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read
        arm_character(c,1,'SHU',images,True);arm_character(c,2,'GRE',images,True)
        rabbit_driver(c,parent);m.sb(parent+3,0)
        target=SCENE+0xB40+84;owner=target+84;record=0x80420000+128*2
        m.sb(record+0x1F,1);m.sh(record+0x20,25);m.sb(record+0x23,6)
        m.sb(owner+0x47,3);m.sb(owner+0x48,0);m.sb(owner+0x49,1)
        m.sh(target+0x10,maximum);m.sh(target+0x12,hp);m.sh(target+0x4A,0x8000 if protected else 0)
        c.external_call=lambda pc:super(type(c),c).external_call(pc);del c.hooks[0x800E1654]
        def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
        c.hooks[0x800E1780]=numbers;c.hooks[0x8014F5C4]=0;m.sw(SCENE+0x1284,1)
        call(c,0x800F5050,2)
        assert c.r[2]==1 and m.rb(record+0x23)==5 and m.rh(target+0x12)==hp
        # Keep the coordinator's next actor held; execute its actual item callback before actor updates.
        m.sw(0x8017DA98,0x80F00000);c.hooks[0x80F00000]=0xFFFFFFFF;pending=True;samples=[]
        for tick in range(1,103):
            if pending:
                call(c,0x800F0708,2);pending=c.r[2]==0xFFFFFFFF
            call(c,0x800DE0B0,0)
            target_actor=SCENE+0x50+140;owner_actor=target_actor+140
            if tick==23:
                helper=m.rw(target_actor+0x58)
                assert (m.rw(helper),m.rw(helper+0x144),m.rw(helper+0x164))==(4,30,0xFFFFFF9C)
            signed=lambda value:value-65536 if value&32768 else value
            samples.append(dict(tick=tick,hp=m.rh(target+0x12),pending_hp=signed(m.rh(target+0x4E)),uses=m.rb(record+0x23),target_locked=bool(m.rb(target_actor+5)),owner_locked=bool(m.rb(owner_actor+5)),preparing=pending,helper_active=bool(m.rw(target_actor+0x54)),target_flags=m.rh(target+0x4A)))
        amount=0 if protected else min(100,maximum-hp)
        for s in samples:
            tick=s['tick']
            assert s['hp']==hp+(amount if tick>=55 else 0)
            assert s['pending_hp']==(-amount if tick==54 else 0)
            assert s['target_locked']==(23<=tick<87) and s['owner_locked']==(tick<102)
            assert s['preparing']==(tick<23) and s['helper_active']==(23<=tick<87)
            assert s['uses']==5 and s['target_flags']==(0x8000 if protected else 0)
        assert {0x800F5050,0x800F0708,0x800F215C,0x800F24E0,0x800F26CC,0x800E1654}<=c.visited
        assert not any(pc==0x80147E38 for pc,args in c.effects)
        rows.append(dict(hp=hp,maximum=maximum,protected=protected,healed=amount,samples=samples))
    return rows



def medicine_party_cases():
    """All six source users/targets, including the distinct self-use script."""
    from test_battle_picker import SCENE
    from export_battle_trial import section_art
    import battle_mock,character_table,struct
    records={r['id']:r for r in character_table.records()}
    codes=[records[i]['sprite_file'][:-4] for i in (8,2,6,35,38,32)]
    raw=source('/B_DATA.BIN')[0];rows=[]
    for user,target_index in itertools.product(range(6),repeat=2):
        c,parent,_=rabbit_fixture(raw);m=c.mem;images=[];read=c.read
        def character_read(address,size):
            for base,data in images:
                if base<=address and address+size<=base+len(data):return sum(m.b.get(address+k,data[address+k-base])<<(8*k) for k in range(size))
            return read(address,size)
        c.read=character_read;poses=[];durations=[]
        for i,code in enumerate(codes,1):
            arm_character(c,i,code,images,True)
            base,body=images[-1];section=struct.unpack_from('<I',body,36)[0];ne=struct.unpack_from('<H',body,section)[0];et=struct.unpack_from('<I',body,section+16)[0]
            poses.append({base+struct.unpack_from('<I',body,et+4*k)[0]:k for k in range(ne)})
            _,clips,_=section_art(body,section,0);durations.append([sum(t or 256 for p,t in clips[k]) for k in (13,14,15)])
        rabbit_driver(c,parent);m.sb(parent+3,0)
        for i,home in enumerate(battle_mock.party_world_positions(),1):
            for axis,value in enumerate(home):m.sw(SCENE+0x50+140*i+0x5C+4*axis,value*4096&0xFFFFFFFF);m.sw(SCENE+0x50+140*i+0x68+4*axis,value*4096&0xFFFFFFFF)
        target=SCENE+0xB40+84*(target_index+1);owner=SCENE+0xB40+84*(user+1);record=0x80420000+128*(user+1)
        m.sb(record+0x1F,1);m.sh(record+0x20,25);m.sb(record+0x23,6)
        m.sb(owner+0x47,3);m.sb(owner+0x48,0);m.sb(owner+0x49,target_index+1)
        m.sh(target+0x10,100);m.sh(target+0x12,16)
        c.external_call=lambda pc:super(type(c),c).external_call(pc);del c.hooks[0x800E1654]
        def numbers(cpu):cpu.r[31]=0x800E1B50;return cpu.r[2]
        c.hooks[0x800E1780]=numbers;c.hooks[0x8014F5C4]=0;m.sw(SCENE+0x1284,1)
        call(c,0x800F5050,user+1);assert c.r[2]==1 and m.rb(record+0x23)==5
        m.sw(0x8017DA98,0x80F00000);c.hooks[0x80F00000]=0xFFFFFFFF;pending=True;samples=[]
        def visual(index):
            a=SCENE+0x50+140*(index+1);signed=lambda v:v-0x100000000 if v&0x80000000 else v;byte=lambda v:v-256 if v&128 else v
            return dict(position=dict(zip(('x','y','z'),[signed(m.rw(a+0x68+4*k))/4096 for k in range(3)])),pose=poses[index][m.rw(m.rw(a+0x84)+0x24)],offset=[byte(m.rb(a+0x78)),byte(m.rb(a+0x79))])
        for tick in range(1,181):
            if pending:call(c,0x800F0708,user+1);pending=c.r[2]==0xFFFFFFFF
            call(c,0x800DE0B0,0)
            ta=SCENE+0x50+140*(target_index+1);oa=SCENE+0x50+140*(user+1)
            signed=lambda v:v-65536 if v&32768 else v
            samples.append(dict(tick=tick,hp=m.rh(target+0x12),pending_hp=signed(m.rh(target+0x4E)),uses=m.rb(record+0x23),target_locked=bool(m.rb(ta+5)),owner_locked=bool(m.rb(oa+5)),preparing=pending,helper_active=bool(m.rw(ta+0x54)),target=visual(target_index),owner=visual(user)))
            if tick>23 and not pending and not m.rb(ta+5) and not m.rb(oa+5):break
        assert tick<180 and samples[-1]['hp']==100
        assert not any(pc==0x80147E38 for pc,args in c.effects)
        rows.append(dict(actor=user,target=target_index,durations=durations[user],samples=samples))
    return rows


def roc_cover_cases():
    rows=[roc_loop_case(True,hp,cover=dict(guard=1,hp=100,defending=True,protected=protected)) for hp,protected in itertools.product((16,24),(False,True))]
    rows += [roc_loop_case(True,hero_hp,cover=dict(guard=1,hp=hp,defending=True,protected=protected,flagged=flagged)) for hero_hp,hp,protected,flagged in ((16,42,False,False),(16,41,False,True),(16,16,False,False),(16,58,False,False),(24,1,False,False),(16,43,False,True),(16,42,True,True))]
    for row in rows:
        samples=row['samples'];remaining=row['hp'] if row['protected'] else max(0,row['hp']-42);down=remaining==0
        assert len(samples)==348 and len(row['draws'])==(17 if down else 18)
        assert samples[47]['guard_hp']==row['hp'] and samples[48]['guard_hp']==remaining
        flags=(0x8000 if row['protected'] else 0)|(0x90 if row.get('flagged',False) else 0)
        assert all(bool(sample['guard_lock'])==(i<62) and sample['guard_down']==(down and i>=62) and bool(sample['hero_lock'])==(i<73 or 146<=i<274) and sample['guard_flags']==(0 if down and i>=62 else flags) for i,sample in enumerate(samples,1))
        assert samples[217]['enemy_hp']==0 and samples[-1]['coordinator']['stage']=='round_ready'
        if down:assert not samples[60]['party_acted'][1] and samples[61]['party_acted'][1]
    return rows


def roc_knockout_cases():
    import struct
    assert struct.unpack_from('<9H',M.body(),0x8016C068-M.MBASE)==(15,0,1,4,3,16,0,1,1)
    gameover,origin=source('/GAMEOVER.BIN');record=M.mword(0x8016F258+4*10)
    assert (M.mword(record),M.mword(record+4))==(len(gameover),origin['lba'])

    rows=[roc_loop_case(True,hp,alone,flagged,defending) for hp,alone,flagged,defending in ((84,False,False,False),(83,False,True,False),(85,False,False,False),(84,True,False,False),(42,True,True,True),(16,True,False,False),(100,True,False,False))]
    for row in rows:
        samples=row['samples'];down=row['hp']<= (42 if row['defending'] else 84)
        assert len(samples)==(146 if down else 348)
        assert samples[48]['hero_hp']==max(0,row['hp']-(42 if row['defending'] else 84))
        assert samples[60]['hero_down']==False and samples[61]['hero_down']==down
        assert samples[60]['hero_flags']==(0x90 if row['flagged'] else 0) and samples[61]['hero_flags']==0
        assert row['outcome']['defeat']==(down and row['alone'])
    return rows


def verify(write=False):
    assert len(roc_loop_case(True,gremio_attack=True)["samples"])==340
    assert len(roc_loop_case(True,paired_attack=True)["samples"])==376
    scheduler=commander_scheduler_cases();assert len(scheduler)==50
    medicine=dict(dispatch=medicine_dispatch_cases(),effects=medicine_effect_cases(),roc=roc_loop_case(True,100,medicine=True))
    documents={'world_roc_two_round.json':[roc_two_round_case(hp) for hp in (100,200)],'world_roc_cover.json':roc_cover_cases(),'world_roc_knockout.json':roc_knockout_cases(),'world_roc_presentation.json':roc_loop_case(True),'world_roc_loop.json':roc_loop_case(),'world_party_critical.json':commander_dispatch_cases(True,False,True),'world_battle_end.json':coordinator_end_cases(),'world_party_knockout.json':commander_dispatch_cases(True,True),'world_party_overlap.json':commander_dispatch_cases(True),'world_order_picker.json':coordinator_picker_cases(),'world_commander_dispatch.json':commander_dispatch_cases(),'world_order_coordinator.json':scheduler,'world_commander_order.json':commander_order_cases(),'world_commander_choices.json':commander_choices(),'world_commander_status.json':commander_cases(),'world_cover_knockout.json':cover_cases(True),'world_cover.json':cover_cases(),'world_protection.json':protection_cases(),'world_resolvers.json':resolvers(),'world_encounters.json':encounter_cases(),'world_menus.json':menu_cases(),'world_rabbit_projectile.json':rabbit_cases(),'world_rabbit_ordinary.json':rabbit_ordinary_cases()}
    documents['world_medicine.json']=medicine
    documents['world_roc_long_battle.json']=roc_long_battle_case()
    documents['world_roc_medicine_round.json']=roc_long_battle_case(True)
    documents['world_medicine_party.json']=medicine_party_cases()
    for name,rows in documents.items():
        path=ROOT/'game/tests/fixtures'/name
        if write:path.write_text(json.dumps(rows,separators=(',',':'))+'\n')
        else:assert json.loads(path.read_text())==rows,name
    content,proof=export.export()
    from test_world_travel import verify_battle_export
    verify_battle_export(content)
    assert content==json.loads((ROOT/'game/assets/world_b.json').read_text())
    assert proof==json.loads((ROOT/'kit/data/reports/world_travel.json').read_text())
    # All exported B-map cell classes agree with the complete original foot predicate.
    import world_map_render as map_source
    blob,_=source('/B_DATA.BIN');plane=map_source.parse_worldmap(blob)
    c,_,_=encounter_machine();m=c.mem;m.sb(GS+2,1);m.sw(ST+0x10,0x80600000)
    m.sh(0x8016F298,0);m.sh(0x8016F29A,0)
    classes={}
    for code in set(plane['codes']):
        m.sh(0x80600000+2*(7*160+10),code)
        call(c,0x80127114,0);classes[code]=bool(c.r[2])
    assert content['walkable']==''.join('1' if classes[code] else '0' for code in plane['codes'])
    # The actual point driver reaches the selected VB6 edge and writes the field spawn.
    for x,y,accepted in ((86,83,True),(87,84,True),(85,83,False),(86,85,False)):
        c=fixture(1,x,y);m=c.mem;c.hooks[0x80127650]=0;c.hooks[0x8012731C]=0
        run(c,0x801280C4)
        assert (m.rb(GS)==5)==accepted
        if accepted:assert (m.rb(GS+1),m.rb(GS+2),m.rb(GS+4),m.rb(GS+6))==(0,1,33,43)
    # Execute the selected village's flag write and world-return fragment.
    area,_=source('/VB6.BIN');c=OverlayInstructions(area);m=c.mem
    m.sw(0x8017DB24,GS);m.sw(0x8017C164,GS);m.sw(0x8017BE20,SUB)
    m.sb(GS,5);m.sb(GS+1,0);m.sb(GS+2,1);m.sw(0x8017AF84,0x800448B0)
    assert run(c,0x8013E028)==0
    assert m.rb(GS+0x1B7)&16
    assert run(c,0x8013E028)==1
    assert (m.rb(GS+2),c.read(0x8016F298,2),c.read(0x8016F29A,2))==(1,86,85)
    # Full world driver consumes the random gate/picker BEFORE its0x200 arm guard.
    for suppression in (False,True):
        c,draws,_=encounter_machine(pick=4095);m=c.mem
        m.sb(GS+2,1);m.sw(ST+0x30,M.mword(0x80170064+4));m.sw(ST+0x38,0xFFFFFFFF)
        m.sh(0x8016F298,86);m.sh(0x8016F29A,90);m.sw(0x8017C20C,SUB+1024)
        m.sw(0x8017BDCC,0x200 if suppression else 0);m.sw(0x8017DA90,0)
        for pc in (0x80127650,0x8012731C,0x80126BCC,0x800C2EF8):c.hooks[pc]=0
        call(c,0x801280C4,0)
        assert len(draws)==2 and m.rw(GS+0x1BC0)==2 and m.rb(ST+0x24)==0
        assert m.rw(0x8017DA90)==(0 if suppression else 0x801285A4)
        if not suppression:
            c.hooks[0x800CA220]=0 # framebuffer copy only
            call(c,0x801285A4,0)
            assert (m.rw(GS+0x1BB8),m.rw(GS+0x1BBC))==(1,3)
    # A real completing world step heals first, then rolls poison, then rate and selection.
    for poison_roll in (0,255):
        c,_,_=encounter_machine(counter=4);m=c.mem
        values=(poison_roll,0,4095);frame_draws=[]
        def draw(cpu):
            value=values[len(frame_draws)];frame_draws.append(value);return value
        c.hooks[0x80147E38]=draw
        m.sb(GS+2,1);m.sb(GS+3,2);m.sb(GS+15,1)
        m.sw(GS+0x1B9C+4,OBJ+128);m.sw(OBJ+128+28,SUB+128)
        for record,maximum,hp in ((SUB,100,80),(SUB+128,17,16)):
            m.sh(record+4,maximum);m.sh(record+6,hp);m.sb(record+13,15)
        m.sh(SUB+22,1);m.sb(SUB+0x4C,20)
        m.sw(ST+0x30,M.mword(0x80170064+4));m.sw(ST+0x38,0xFFFFFFFF)
        m.sh(0x8016F298,86);m.sh(0x8016F29A,90);m.sw(0x8017C20C,SUB+1024)
        m.sw(ST+0x14,OBJ+512);m.sw(ST+0x18,OBJ+640);m.sw(ST+0x28,OBJ+768)
        m.sh(ST+0x20,1);m.sb(ST+0x22,0);m.sb(ST+0x23,4);m.sh(ST+0x42,1)
        for pc in (0x80127650,0x80126BCC,0x800C2EF8,0x800C4244,0x8014D888):c.hooks[pc]=0
        call(c,0x801280C4,0)
        assert frame_draws==list(values)
        assert (m.rh(SUB+6),m.rh(SUB+128+6))==(81 if poison_roll==0 else 61,17)
        assert m.rh(SUB+22)==(0 if poison_roll==0 else 1)
        assert m.rw(GS+0x1BC0)==2
    # The original step-healing consumer increments zero HP; knockout is HP-defined.
    c,_,_=encounter_machine();m=c.mem;m.sb(SUB+0x4C,20);m.sh(SUB+4,100);m.sh(SUB+6,0)
    call(c,0x80126408)
    assert m.rh(SUB+6)==1
    # Field movement counts updates; step-healing is every third moving update, poison follows each.
    c=OverlayInstructions(b'');m=c.mem;m.sw(0x8017BE20,OBJ);m.sw(0x8017BD74,0x00010000)
    c.hooks[0x80126408]=0;c.hooks[0x80126668]=0;c.hooks[0x801264B4]=0
    from test_journey_battle import until
    for frame in range(1,7):
        before=len(c.effects);until(c,0x80132ABC,0x80132B3C)
        assert [pc for pc,args in c.effects[before:]]==([0x80126408] if frame%3==0 else [])+[0x80126668,0x801264B4]
    # The regular foot-speed path scans the active native-character ID list.
    import character_table,preparation
    stallion=next(row for row in character_table.records() if row['id']==75)
    assert (stallion['name'],stallion['sprite_file'])==('Stallion','STA.BIN')
    bindings={row['id']:row['rune'] for row in preparation.rune_bindings()}
    assert (bindings['sunbeam_crystal'],bindings['champion_s_crystal'])==(20,24)
    for ids in ([],[8],[75],[8,75],[75,8],[8,12,35,21,9,75]):
        c=OverlayInstructions(b'');m=c.mem;m.sw(0x8017DB24,GS);m.sb(GS+3,len(ids));m.sb(0x8016F2A6,0)
        for i,identifier in enumerate(ids):m.sb(GS+8+i,identifier)
        call(c,0x80126840)
        assert c.r[2]==int(75 in ids)
        c.r[16]=ST;c.r[29]=0x80900000;c.hooks[0x80126FA4]=0
        until(c,0x80127BF4,0x80127C10)
        assert m.rh(ST+0x42)==(2 if 75 in ids else 1)
    # The world reload writer resets this counter, including a return from battle.
    c=OverlayInstructions(b'');m=c.mem;m.sw(0x8017A0B8,ST);m.sh(0x8017A0A8,99)
    from test_journey_battle import until
    until(c,0x80127F40,0x80127FAC)
    assert c.read(0x8017A0A8,2)==0
    print(f"PASS: {len(documents['world_resolvers.json'])} original resolver cases, {len(documents['world_encounters.json'])} complete gate/picker cases all19200 B-map cell classifications and4 VB6 point-driver/return cases, full post-roll arm suppression/mode3 request reload reset,16 menu/point/encounter priority combinations, retained menu-return motion/counters and2 complete heal/poison/encounter frames; supplied BIOS draw boundary only")
