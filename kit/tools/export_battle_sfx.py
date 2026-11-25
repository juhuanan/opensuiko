#!/usr/bin/env python3
"""Export source-bound battle actor sound candidates without playing or promoting them."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import wave

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent / 'seq'))

from disc import extract
import maindec
import render_seq
import vag_extract
from spu import Voice, voice_levels
from spu_fir import FIR
from reverb import mix_sample

BANK_REQUESTS = (0x21, 0x22, 0x23, 0x24, 0x4d)
SOUND_TABLE = 0x801651bc
TIMED_REQUESTS = (0x819, 0x81b, 0x81e, 0x81f)


def cues(actors, reactions=()):
    result = {instruction['command']['sound']
              for program in actors['programs']['programs']
              for instruction in program['instructions']
              if 'sound' in instruction.get('command', {})}
    result.update(row['id'] for row in actors.get('enemy_magic', {}).get('effect', {}).get('sounds', []))
    for row in actors.get('enemy_area_magic', []):
        result.update(sound['id'] for sound in row.get('worker', {}).get('sounds', []))
    for unite in actors.get('unites', []):
        controller = unite.get('controller') or {}
        result.update(sound['id'] for sound in (controller.get('orbit') or {}).get('sounds', []))
        if unite.get('wave_heights') is not None:
            import unite_trick_controller
            wave = unite_trick_controller.build()
            if unite['record'] != 14 or unite['wave_heights'] != wave['phases'][1]['heights']:
                raise ValueError('Trick wave sound binding differs')
            result.update(phase.get('start_sound', phase.get('sound')) for phase in wave['phases'] if 'start_sound' in phase or 'sound' in phase)
    result.update(sound['id'] for reaction in reactions for sound in reaction.get('sounds', []))
    if any(type(value) is not int or not 0 <= value <= 65535 for value in result):
        raise ValueError('invalid actor sound request')
    return sorted(result)


def load_bank(request):
    if not 0x21 <= request < 0x50:
        raise ValueError('invalid sound bank request')
    row = 0x80164834 - maindec.MBASE + 32 * (request - 0x21)
    _, _, va_size, va_lba, _, _, vb_size, vb_lba = struct.unpack_from('<8I', maindec.body(), row)
    if maindec.body()[row + 1] != maindec.body()[row + 17]:
        raise ValueError('sound bank header/body slots differ')
    va, vb = extract(va_lba, va_size), extract(vb_lba, vb_size)
    samples, programs, loops = render_seq.parse_vab_bytes(va, vb)
    raw = [b''.join(blocks) for blocks in vag_extract.split_vb(va, vb)]
    return dict(request=request, va_lba=va_lba, va_size=va_size,
                vb_lba=vb_lba, vb_size=vb_size,
                va_sha256=hashlib.sha256(va).hexdigest(),
                vb_sha256=hashlib.sha256(vb).hexdigest(),
                samples=samples, programs=programs, loops=loops, raw=raw)


def banks():
    result = []
    slots = tuple(request for request in range(0x21, 0x50)
                  if maindec.body()[0x80164834 - maindec.MBASE + 32 * (request - 0x21) + 1] == 0)
    if slots != BANK_REQUESTS:
        raise ValueError('common sound bank request inventory changed')
    for request in BANK_REQUESTS:
        row = 0x80164834 - maindec.MBASE + 32 * (request - 0x21)
        if maindec.body()[row + 1] != 0 or maindec.body()[row + 17] != 0:
            raise ValueError('common sound bank slot changed')
        result.append(load_bank(request))
    return result


def timed_levels(entry, tone):
    return voice_levels((tone['bank_vol'], entry['table_level'], tone['program_vol'], tone['vol']),
                        (tone['pan'], tone['program_pan'], 64), direct=True)


def resolve_timed(request, source_banks):
    if request not in (*TIMED_REQUESTS, 0x813):
        return None, 'unqualified timed sound request'
    offset = 0x8016546c-maindec.MBASE+12*(request-0x800)
    bank, program, index, note, period, delta, duration, mode, level = struct.unpack_from('<4B3H2B', maindec.body(), offset)
    if bank != 0 or (period, delta, mode) != (1, int(request == 0x813), 1) or not 0 < duration <= 600 or not 0 < level <= 127:
        return None, 'unqualified timed sound controller'
    if request == 0x813:
        if (program, index, note, duration, level) != (2, 3, 40, 8, 45):
            raise ValueError('founding timed sound descriptor changed')
        for start, end, digest in (
                (0x800c5b5c, 0x800c5e60, '91f4dc9139312972a9a46efdcc4c326d95da8f5839ea26f14a4dfb036f11e915'),
                (0x800c8ed8, 0x800c9388, '62391184490911dc64b9851af7aa486bf09873ec3af56ddfa6e839163fd8a405')):
            if hashlib.sha256(maindec.body()[start-maindec.MBASE:end-maindec.MBASE]).hexdigest() != digest:
                raise ValueError('founding timed sound controller changed')
    tones = [data['programs'][program][index] for data in source_banks]
    if any(tone != tones[0] for tone in tones[1:]):
        return None, 'direct tone is bank-dependent'
    tone = tones[0]
    sample = tone['vag']
    if any(data['raw'][sample] != source_banks[0]['raw'][sample] or data['loops'][sample] != source_banks[0]['loops'][sample] for data in source_banks[1:]):
        return None, 'sample is bank-dependent'
    if source_banks[0]['loops'][sample][2] or not source_banks[0]['samples'][sample]:
        return None, 'looping or empty timed sample'
    entry = dict(id=request, bank=bank, program=program, note=note, tone_index=index,
                 table_level=level, duration_updates=duration, sample=sample,
                 pitch=render_seq.pitch_register(note, tone['center'], tone['shift']),
                 reverb=bool(tone['mode'] & 4), retrigger=False,
                 sample_sha256=hashlib.sha256(source_banks[0]['raw'][sample]).hexdigest())
    left, _ = timed_levels(entry, tone)
    entry['occupied_updates'] = duration+max(1, (max(0, left-1)+511)//512)-1
    if delta:
        entry['pitch_delta'] = delta
    return entry, None


def render_timed(entry, source_banks):
    data = source_banks[0]
    tone = data['programs'][entry['program']][entry['tone_index']]
    levels = timed_levels(entry, tone)
    voice = Voice(data['samples'][entry['sample']], 0, 0, False,
                  min(entry['pitch'], 0x3fff)/4096, tone['adsr1'], tone['adsr2'])
    voice.env.key_on()
    frames = entry['occupied_updates']*735
    if not 0 < frames <= 441000:
        raise ValueError('timed sound exceeds the bounded clip duration')
    left, right = [0.0]*frames, [0.0]*frames
    for update in range(entry['occupied_updates']):
        if update:
            # Mode1 updates the retained Q12 pitch, initialized separately from the note.
            voice.step = min((4096 + update * entry.get('pitch_delta', 0)) & 65535, 0x3fff)/4096
        reduction = max(0, update-entry['duration_updates']+1)*512
        voice.vol_l, voice.vol_r = (max(0, level-reduction)/16384 for level in levels)
        voice.render(FIR, left, right, update*735, 735, 44100)
    return b''.join(struct.pack('<hh', mix_sample(int(l), 0, 0), mix_sample(int(r), 0, 0))
                    for l, r in zip(left, right))


def resolve(request, source_banks, *, slot=0, restore_stream=False):
    if restore_stream and request != 0x52a:
        return None, 'unqualified stream restoration cue'
    if slot != 0 and (slot != 2 or request != 0x5a1 or
                      [data['request'] for data in source_banks] != [0x4b]):
        return None, 'unqualified mode sound bank'
    if request >> 8 == 8:
        return resolve_timed(request, source_banks)
    if request >> 8 != 5:
        return None, 'different sound-command class'
    if request in (0x52a, 0x595) and not restore_stream:
        return None, 'sound request also changes stream volume'
    offset = SOUND_TABLE - maindec.MBASE + 4 * (request - 0x500)
    packed, note, level = struct.unpack_from('<HBB', maindec.body(), offset)
    bank, program = packed >> 8, packed & 255
    if bank != slot:
        return None, 'sound bank slot differs from supplied banks'
    if (max(20, level + 55) & 255) > 127:
        return None, 'source stereo level exceeds supported voice range'
    matches = [[tone for tone in data['programs'][program] if tone['min'] <= note <= tone['max']]
               for data in source_banks]
    if any(len(tones) != 1 for tones in matches) or any(tones != matches[0] for tones in matches[1:]):
        return None, 'tone is missing, layered or bank-dependent'
    tone = matches[0][0]
    index = tone['vag']
    if any(data['raw'][index] != source_banks[0]['raw'][index] or
           data['loops'][index] != source_banks[0]['loops'][index] for data in source_banks[1:]):
        return None, 'sample is bank-dependent'
    loop = source_banks[0]['loops'][index]
    if loop[2] or not source_banks[0]['samples'][index]:
        return None, 'looping or empty sample requires live voice control'
    return dict(id=request, bank=bank, program=program, note=note, table_level=level,
                sample=index, pitch=render_seq.pitch_register(note, tone['center'], tone['shift']),
                reverb=bool(tone['mode'] & 4),
                retrigger=request not in (0x520, 0x521, 0x532, 0x53a, 0x56a),
                sample_sha256=hashlib.sha256(source_banks[0]['raw'][index]).hexdigest(),
                **({'restore_stream': True} if restore_stream else {})), None


def render(entry, source_banks):
    if 'tone_index' in entry:
        return render_timed(entry, source_banks)
    data = source_banks[0]
    tone = next(t for t in data['programs'][entry['program']]
                if t['min'] <= entry['note'] <= t['max'])
    sample = data['samples'][entry['sample']]
    step = min(entry['pitch'], 0x3fff) / 4096
    if step <= 0:
        raise ValueError('zero sound pitch')
    frames = math.ceil(len(sample) / step) + 1
    if frames > 44100 * 10:
        raise ValueError('sound sample is too long')
    # shortcut: this isolated clip is dry; mix the source reverb bus at runtime.
    voice = Voice(sample, 0, 0, False, step, tone['adsr1'], tone['adsr2'])
    left, right = [0.0] * frames, [0.0] * frames
    # SsUtKeyOn stores the requested level in a byte before voice setup.
    gain = max(20, entry['table_level'] + 55) & 255
    levels = voice_levels((tone['bank_vol'], gain, tone['program_vol'], tone['vol']),
                          (tone['pan'], tone['program_pan'], 64), direct=True)
    voice.vol_l, voice.vol_r = (level / 16384 for level in levels)
    voice.env.key_on()
    used = voice.render(FIR, left, right, 0, frames, 44100)
    return b''.join(struct.pack('<hh', mix_sample(int(l), 0, 0), mix_sample(int(r), 0, 0))
                    for l, r in zip(left[:used], right[:used]))


def export(actors, output, reactions=()):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('candidate audio cannot enter accepted staging')
    for address, word in {0x800c583c: 0x2482fb00, 0x800c589c: 0x94220000,
                          0x800c58b8: 0x90220000, 0x800c58d8: 0x90220000,
                          0x800c58e0: 0x94639c12, 0x800c5464: 0x34020037,
                          0x800c54d0: 0x34020041, 0x800c5968: 0x0c057c4d,
                          0x800c5988: 0x0c056c6e, 0x801577b0: 0xa032c148,
                          0x80154f1c: 0x9084c148}.items():
        if maindec.mword(address) != word:
            raise ValueError(f'sound dispatcher changed at {address:#x}')
    if any(request >> 8 == 8 for request in cues(actors, reactions)):
        for address, word in {0x800c5b98:0x144000a1, 0x800c5d04:0x34021000,
                              0x800c5e44:0x2c420003, 0x800c0d88:0x800c9090,
                              0x800c8fa4:0x0043102b, 0x800c8fbc:0xa0220000,
                              0x800c9028:0x3c018018, 0x800c9024:0x34020010,
                              0x800c90c0:0x00621821, 0x800c92bc:0x2463fe00,
                              0x800c92dc:0x28630002, 0x800c9330:0xa0200000}.items():
            if maindec.mword(address) != word:
                raise ValueError(f'timed sound consumer changed at {address:#x}')
    source_banks = banks()
    output.mkdir(parents=True, exist_ok=True)
    entries, unsupported = [], []
    for request in cues(actors, reactions):
        entry, reason = resolve(request, source_banks)
        if reason:
            unsupported.append(dict(id=request, reason=reason))
            continue
        pcm = render(entry, source_banks)
        path = f'{request:04x}.wav'
        with wave.open(str(output / path), 'wb') as stream:
            stream.setnchannels(2); stream.setsampwidth(2); stream.setframerate(44100)
            stream.writeframes(pcm)
        entry.update(path=path, frames=len(pcm) // 4,
                     sha256=hashlib.sha256((output / path).read_bytes()).hexdigest())
        entries.append(entry)
    packet = dict(schema='suikoden-battle-sfx/5' if any(row['id'] == 0x813 for row in entries) else 'suikoden-battle-sfx/2' if any('tone_index' in row for row in entries) else 'suikoden-battle-sfx/1', status='candidate; dry; listening and promotion pending',
                  sample_rate=44100, cues=entries, unsupported=unsupported,
                  sources=[{k: v for k, v in data.items() if k not in ('samples', 'programs', 'loops', 'raw')}
                           for data in source_banks],
                  source_table='MAIN.EXE 0x801651BC/0x8016546C; dispatchers 0x800C5830/0x800C5B5C',
                  source_level='0x05xx stereo +55/mono +65, minimum20 then unsigned-byte voice storage; 0x08xx direct table level without that offset')
    (output / 'battle_sfx.json').write_text(json.dumps(packet, indent=2) + '\n')
    return packet


def validate(folder, packet):
    folder = Path(folder)
    if not isinstance(packet, dict) or packet.get('schema') not in ('suikoden-battle-sfx/1', 'suikoden-battle-sfx/2', 'suikoden-battle-sfx/3', 'suikoden-battle-sfx/4', 'suikoden-battle-sfx/5') or packet.get('sample_rate') != 44100 or not isinstance(packet.get('cues'), list) or len(packet['cues']) > 256:
        raise ValueError('invalid battle sound manifest')
    seen = set()
    for cue in packet['cues']:
        if not isinstance(cue, dict) or any(type(cue.get(key)) is not int for key in ('id', 'bank', 'program', 'note', 'frames')):
            raise ValueError('invalid battle sound fields')
        ident = cue['id']
        founding = packet['schema'] == 'suikoden-battle-sfx/5'
        timed = (packet['schema'] != 'suikoden-battle-sfx/1' and ident in TIMED_REQUESTS) or (founding and ident == 0x813)
        if type(cue.get('pitch_delta', 0)) is not int or cue.get('pitch_delta', 0) != int(founding and ident == 0x813):
            raise ValueError('unqualified timed pitch delta')
        mode_bank = packet['schema'] in ('suikoden-battle-sfx/3', 'suikoden-battle-sfx/4', 'suikoden-battle-sfx/5') and ident == 0x5a1 and cue['bank'] == 2
        restore = cue.get('restore_stream', False)
        if type(restore) is not bool or (restore and (packet['schema'] not in ('suikoden-battle-sfx/4', 'suikoden-battle-sfx/5') or ident != 0x52a)) or (ident == 0x52a and not restore):
            raise ValueError('unqualified stream restoration cue')
        if timed:
            if type(cue.get('tone_index')) is not int or not 0 <= cue['tone_index'] < 16 or type(cue.get('occupied_updates')) is not int or not 0 < cue['occupied_updates'] <= 600 or cue['frames'] != cue['occupied_updates']*735 or cue.get('retrigger') is not False:
                raise ValueError('invalid timed sound fields')
        elif 'tone_index' in cue or 'occupied_updates' in cue:
            raise ValueError('timed sound fields on an ordinary cue')
        if ((not 0x500 <= ident <= 0x5ff and not timed) or ident in seen or cue.get('path') != f'{ident:04x}.wav' or
                (cue['bank'] != 0 and not mode_bank) or not 0 <= cue['program'] < 128 or not 0 <= cue['note'] < 128 or
                not 0 < cue['frames'] <= 441000 or type(cue.get('retrigger')) is not bool):
            raise ValueError('invalid battle sound identity or dimensions')
        seen.add(ident)
        digest = cue.get('sha256')
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('invalid battle sound digest')
        path = folder / cue['path']
        if path.is_symlink() or not path.resolve().is_relative_to(folder.resolve()):
            raise ValueError('invalid battle sound path')
        data = path.read_bytes()
        if len(data) != 44 + cue['frames'] * 4 or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('battle sound size or digest mismatch')
        if (data[:4] != b'RIFF' or struct.unpack_from('<I', data, 4)[0] != len(data) - 8 or
                data[8:16] != b'WAVEfmt ' or struct.unpack_from('<IHHIIHH', data, 16) != (16, 1, 2, 44100, 44100 * 4, 4, 16) or
                data[36:40] != b'data' or struct.unpack_from('<I', data, 40)[0] != cue['frames'] * 4):
            raise ValueError('invalid battle sound PCM')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--actors', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    packet = export(json.loads(args.actors.read_text()), args.out)
    print(f"{len(packet['cues'])} candidate cues; {len(packet['unsupported'])} requests need another source path")
