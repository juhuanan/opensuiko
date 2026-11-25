"""Drops of Kindness source scene, in callback-update units. Review-only producer.

Disc parsing stays here; exported draw commands contain named rectangles, colours,
vertices and depths rather than original addresses or packed packet layouts.
"""
import struct

import numpy as np
import battle_bin
import battle_mock as math_source
import maindec
from spell_effect_entries import entry_image
from spell_effect_sources import report

VERSION = 'drops-scene/1'
UPDATES = 306


def trunc(value, divisor):
    return (abs(value) // divisor) * (-1 if value < 0 else 1)


def short(value):
    return (int(value) + 32768) % 65536 - 32768


def block_at(address):
    return list(struct.unpack_from('<12i', maindec.body(), address-maindec.MBASE))


def camera_at(update, initial=None):
    start = block_at(0x8016B878) if initial is None else initial
    end = block_at(0x8016D97C)
    n = min(max(update, 0), 60)
    # The four source channels divide the Q12 difference once, then accumulate.
    return [(b if n == 60 else a + trunc(b-a, 60)*n) >> 12 for a, b in zip(start, end)]


def transform(point, angles, scale, translation=(0, 0, 0)):
    r = math_source.scale_matrix(math_source.rot_matrix(angles), scale)
    return [short(((translation[i] << 12) + sum(r[3*i+j]*point[j] for j in range(3))) >> 12) for i in range(3)]


def projected(point, block, centered=True):
    r = math_source.scale_matrix(math_source.rot_matrix(block[3:6]), block[9:12])
    def raw(p):
        v = [((block[6+i] << 12) + sum(r[3*i+j]*p[j] for j in range(3))) >> 12 for i in range(3)]
        # RTPS's quotient is bounded at 2; screen coordinates saturate at signed11.
        divisor = max(512, v[2])
        return [max(-1024, min(1023, (v[i]*1024)//divisor)) for i in range(2)] + [v[2]]
    p = raw(point)
    if centered:
        origin, focus = raw((0, 0, 0)), raw(block[:3])
        p[0] += 160 + origin[0] - focus[0]
        p[1] += 120 + origin[1] - focus[1]
    return p


def parameters(update):
    """State after a 1-based source callback; drawing follows state mutation."""
    if not 0 <= update <= UPDATES:
        raise ValueError('Drops update outside its lifetime')
    a, b = min(update, 64), min(max(update-64, 0), 32)
    c, d, e = min(max(update-96, 0), 90), min(max(update-186, 0), 60), min(max(update-246, 0), 60)
    return dict(caster_visible=0 < update < 96, targets_visible=96 < update < 306,
                caster_scale=1+64*a+128*b,
                intensity=((8192*a-16384*b+5779*c-8669*e) >> 12) & 255,
                spread=(1+186413*c-279620*e) >> 12,
                column_top=-5-3*d,
                wash=[0, max(0, (2048*a-2184*e) >> 12), max(0, (4096*a-4369*e) >> 12)],
                orbit_updates=max(update-96, 0), healed=update == 306)


class Scene:
    def __init__(self, random_draws):
        if len(random_draws) != 18 or any(not 0 <= x <= 32767 for x in random_draws):
            raise ValueError('Drops requires eighteen 15-bit source draws')
        self.draws = list(random_draws)
        sections, atlases, errors, self.data = battle_bin.parse()
        if errors: raise ValueError(errors)
        self.source = report()
        self.effect = self.source['effects'][1]
        self.section = sections[self.effect['section']]
        blobs = {a['offset']: a['atlas'] for a in atlases}
        palette_blob = blobs[self.effect['palette_source']['blob_offset']]
        self.textures, self.entries = [], []
        self.pieces = []
        for piece in self.effect['pieces']:
            indices = []
            for en in piece['entries']:
                raw = blobs[self.section['atlas_offsets'][en[2]]]
                indices.append(len(self.entries))
                self.entries.append(dict(dx=en[0]-piece['header'][4], dy=en[1]-piece['header'][5], width=en[4]+1, height=en[5]+1))
                self.textures.append(np.array(entry_image(raw, palette_blob, en)))
                # Spell packets force semi-transparency, and these used CLUTs all set STP.
                off = 128*(en[6]//2)+64+32*(en[6]%2)
                colors = struct.unpack_from('<16H', palette_blob, off)
                if any(w and not w & 32768 for w in colors):
                    raise ValueError('Drops requires a separate opaque texel pass')
            self.pieces.append(indices)
        self.animation = self.effect['animations'][3]['frames']
        if [f['ticks'] for f in self.animation] != [5, 5, 5]:
            raise ValueError('Drops animation duration changed')
        # F-header bit0 enables advancement; graphics constructor argument a3=1
        # separately forces target looping. Caster animation0 is drawn without advance.
        for i in (0, 3):
            off = self.effect['animations'][i]['source_offset']
            if self.data[off+1] != 1: raise ValueError('Drops animation flags changed')

    def sprite(self, piece, anchor, scale, intensity):
        result = []
        # Writer visits entries backwards; OT head insertion restores entry order.
        r = math_source.scale_matrix(math_source.rot_matrix((0, 0, 1)), (scale,)*3)
        for index in self.pieces[piece]:
            en = self.entries[index]
            x, y, w, h = (en[k] for k in ('dx', 'dy', 'width', 'height'))
            corners = []
            for px, py in [(x,y), (x+w,y), (x,y+h), (x+w,y+h)]:
                corners.append([anchor[0]+((r[0]*px+r[1]*py) >> 12), anchor[1]+((r[3]*px+r[4]*py) >> 12)])
            result.append(dict(kind='texture', vertices=corners, texture=index,
                               intensity=intensity, depth=max(5, min(379, anchor[2]//4))))
        return result

    def frame(self, update, caster, target, initial_camera=None):
        p = parameters(update)
        block = camera_at(update, initial_camera)
        commands = []
        scene_scale = trunc(block[9] << 10, block[8])
        if p['caster_visible']:
            anchor = projected([caster[0], caster[1], caster[2]-70], block)
            commands += self.sprite(0, anchor, trunc(scene_scale*p['caster_scale'], 4096), p['intensity'])
        if p['targets_visible']:
            elapsed = p['orbit_updates']
            # Before the first draw the update decrements the initial five-tick
            # duration. The forced loop returns to piece8 on the fifteenth update.
            frame = (elapsed // 5) % 3
            piece = int(self.animation[frame]['piece'].split('_')[1])
            for i in range(6):
                size, height, angle = self.draws[3*i:3*i+3]
                local = (20, 0, -(height % 100))
                position = transform(local, (0, 0, angle % 4096 + 32*elapsed), (p['spread'], p['spread'], 4096), target)
                anchor = projected(position, block)
                commands += self.sprite(piece, anchor, trunc(scene_scale*(2048+size%4096), 4096), p['intensity'])
        # Source fan and annular column run throughout the effect, even while
        # their XY scale is initially zero. Both use additive untextured colours.
        if 0 < update < 306:
            ring0, ring1 = [], []
            radius = 30
            for i in range(32):
                angle = -128*i
                for ring, z in ((ring0, p['column_top']), (ring1, 0)):
                    world = transform((radius, 0, z), (0, 0, angle), (p['spread'], p['spread'], 4096), target)
                    ring.append(projected(world, block))
            center = projected(target, block)
            for i in range(32):
                j = (i+1) % 32
                commands.append(dict(kind='color', vertices=[center[:2], ring1[i][:2], ring1[j][:2]],
                                     colors=[[0,0,0], [127,127,127], [127,127,127]], depth=379))
                depth = max(1, min(509, sum(v[2] for v in (ring0[i],ring0[j],ring1[i],ring1[j]))//16))
                commands.append(dict(kind='color', vertices=[ring0[i][:2], ring0[j][:2], ring1[i][:2], ring1[j][:2]],
                                     colors=[[0,0,0],[0,0,0],[0,0,80],[0,0,80]], depth=depth))
        # The final callback disables auxiliary objects before entering its draw tail.
        return dict(update=update, camera=block, commands=commands, wash=p['wash'] if update < 306 else [0,0,0], healed=p['healed'])

    def proof(self):
        return dict(schema=VERSION, ready_for_runtime=False, source=self.source['source'],
                    random_draws=self.draws, source_effect=self.effect['id'],
                    note='Review scene starts at effect initialization; excludes actor preparation/loading. No accepted assets changed.')


def geometry_vectors():
    seed=17; draws=[]
    for _ in range(18):
        seed=(1103515245*seed+12345)&0xffffffff
        draws.append((seed>>16)&32767)
    scene=Scene(draws)
    cases=[]
    mapping={scene.pieces[p][0]:i for i,p in enumerate((0,8,9,10))}
    for update in (1,32,64,95,96,97,101,186,246,275,305,306):
        f=scene.frame(update,(120,50,0),(112,0,0))
        picks=sorted(set(range(min(7,len(f['commands'])))) | ({len(f['commands'])-1} if f['commands'] else set()))
        commands=[]
        for index in picks:
            c=f['commands'][index]
            commands.append(dict(index=index,texture=mapping[c['texture']] if c['kind']=='texture' else None,
                                 vertices=[dict(x=v[0],y=v[1]) for v in c['vertices']],depth=c['depth'],
                                 intensity=c.get('intensity',128)))
        cases.append(dict(update=update,camera=f['camera'],command_count=len(f['commands']),commands=commands,wash=f['wash']))
    return dict(draws=draws,caster=[120,50,0],target=[112,0,0],cases=cases)
