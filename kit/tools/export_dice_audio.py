#!/usr/bin/env python3
"""Export fixed-dice stream candidates; no playback or accepted promotion."""
from array import array
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import subprocess
import wave

from disc import extract
from dot8_audio import resources, channel_bytes
from export_first_room import source
from export_opening_audio import export_resource
from export_dice_presentation import SOURCE_SHA256, MAIN_SHA256
import vab_to_wav
import export_battle_sfx as sfx

ROOT = Path(__file__).resolve().parents[2]
REPORT = ROOT / 'kit/data/reports/dice_audio.json'


def export_founding_xa(output, request):
    from export_defeat_audio import decode_channel
    from xa_decode import VERSION

    if (request['request'], request['file_index'], request['file_number'], request['channel'],
            request['volume'], request['repeat'], request['restart_counter_threshold']) != (0x304, 2, 1, 0, 127, True, 7248):
        raise ValueError('unqualified founding CD-XA request')
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('candidate CD-XA cannot enter accepted staging')
    binding = dict(lba=request['source']['lba'], source_bytes=request['source']['size'],
                   file_number=request['file_number'], channel=request['channel'])
    if (binding['lba'], binding['source_bytes']) != (183804, 97632256):
        raise ValueError('founding CD-XA extent changed')
    pcm, sectors, compressed = decode_channel(binding)
    if sectors != list(range(0, 18377, 8)) or len(pcm) != 2298 * 2016 * 4:
        raise ValueError('founding CD-XA channel extent changed')
    output.mkdir(parents=True, exist_ok=True)
    raw_path = output / 'founding.raw'
    try:
        raw_path.write_bytes(compressed)
        independent = subprocess.run(['ffmpeg', '-v', 'error', '-f', 'psxstr', '-i', str(raw_path),
                                      '-map', '0:a:0', '-f', 's16le', '-acodec', 'pcm_s16le', '-'],
                                     check=True, capture_output=True).stdout
    finally:
        raw_path.unlink(missing_ok=True)
    if independent != pcm:
        raise ValueError('founding CD-XA decoders disagree')
    path = output / 'founding.wav'
    with wave.open(str(path), 'wb') as wav:
        wav.setparams((2, 2, 37800, len(pcm) // 4, 'NONE', 'not compressed'))
        wav.writeframes(pcm)
    track = dict(id='founding', path=path.name, sample_rate=37800, frames=len(pcm) // 4,
                 volume=127, loop_start_frame=0, restart_after_ticks=request['restart_counter_threshold'] + 1,
                 sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    proof = dict(request=request, source_sectors=dict(first=sectors[0], last=sectors[-1], stride=8, count=len(sectors)),
                 raw_sector_sha256=hashlib.sha256(compressed).hexdigest(),
                 decoder=VERSION, independent_decoder='FFmpeg psxstr/adpcm_xa; exact PCM equality',
                 pcm_sha256=hashlib.sha256(pcm).hexdigest(),
                 scope='native counter-based restart; original device/counter cadence and full event binding remain unqualified')
    return track, proof


def export_sounds(output, *, common_cues=(0x501, 0x52a)):
    if not common_cues or len(set(common_cues)) != len(common_cues) or set(common_cues) - {0x501, 0x508, 0x50b, 0x52a, 0x813}:
        raise ValueError('unqualified common sound inventory')
    overlay, origin = source('/VB2.BIN')
    if origin['sha256'] != SOURCE_SHA256:
        raise ValueError('unsupported dice sound source identity')
    for offset, expected in {0x3438: 0x8c4200ac, 0x3440: 0x0040f809,
                             0x3444: 0x3404004b, 0x6830: 0x0040f809,
                             0x6834: 0x340405a1, 0x788c: 0x0040f809,
                             0x7890: 0x34040501, 0x80d4: 0x3404052a,
                             0x8118: 0x34040505}.items():
        if struct.unpack_from('<I', overlay, offset)[0] != expected:
            raise ValueError(f'dice sound caller changed at {offset:#x}')
    mode = sfx.load_bank(0x4b)
    common = sfx.banks()
    main, main_origin = source('MAIN.EXE')
    if main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported dice sound MAIN identity')
    base = struct.unpack_from('<I', main, 0x18)[0]
    descriptor = struct.unpack_from('<8I', main, 2048 + 0x80164834 - base + 32 * (0x4b - 0x21))
    if (descriptor[0], descriptor[4]) != (0x201, 0x202) or descriptor[2:4] != (mode['va_size'], mode['va_lba']) or descriptor[6:8] != (mode['vb_size'], mode['vb_lba']):
        raise ValueError('dice bank descriptor disagrees with independent extraction')
    for suffix, prefix in (('/CHIN.VA', 'va'), ('/CHIN.VB', 'vb')):
        _, bank_origin = source(suffix)
        if any(bank_origin[key] != mode[f'{prefix}_{key}'] for key in ('lba', 'size', 'sha256')):
            raise ValueError('dice bank catalog disagrees with source descriptor')
        mode[f'{prefix}_file'] = bank_origin['file']
    catalog = json.loads((ROOT / 'kit/data/catalogs/extracted/iso_files.json').read_text())
    for bank in common:
        for prefix in ('va', 'vb'):
            row, = [r for r in catalog if r['lba'] == bank[f'{prefix}_lba'] and r['size'] == bank[f'{prefix}_size']]
            bank[f'{prefix}_file'] = row['path']
    direct_cue = struct.unpack_from('<HBB', main, 2048 + sfx.SOUND_TABLE - base + 4 * (0x5a1 - 0x500))
    if direct_cue != (0x200, 24, 30):
        raise ValueError('dice landing sound descriptor changed')
    if struct.unpack_from('<HBB', main, 2048 + sfx.SOUND_TABLE - base + 4) != (0, 24, 226):
        raise ValueError('dice box sound descriptor changed')
    if 0x508 in common_cues and struct.unpack_from('<HBB', main, 2048 + sfx.SOUND_TABLE - base + 32) != (0, 32, 20):
        raise ValueError('ruins passage sound descriptor changed')
    if 0x50b in common_cues and struct.unpack_from('<HBB', main, 2048 + sfx.SOUND_TABLE - base + 44) != (1, 39, 20):
        raise ValueError('founding sound descriptor changed')
    for address, expected in {0x800c58f0: 0xa4229068, 0x801577b0: 0xa032c148,
                              0x80154f1c: 0x9084c148, 0x800c5874: 0xa4209c0c,
                              0x800c50cc: 0x0c031a80, 0x800c6a0c: 0xa0249bf5,
                              0x800c6a14: 0xa0259bf7, 0x800c6a1c: 0xa0269bf8,
                              0x800c6b18: 0xa6820000, 0x800c8c4c: 0x0c031a8e,
                              0x800c295c: 0x0c030c31, 0x800c30cc: 0x0c0322dc}.items():
        if struct.unpack_from('<I', main, 2048 + address - base)[0] != expected:
            raise ValueError(f'dice sound level consumer changed at {address:#x}')
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('candidate sounds cannot enter accepted staging')
    output.mkdir(parents=True, exist_ok=True)
    entries = []
    for cue, banks, slot in (*((cue, common, 0) for cue in common_cues), (0x5a1, [mode], 2)):
        entry, reason = sfx.resolve(cue, banks, slot=slot, restore_stream=cue == 0x52a)
        if reason:
            raise ValueError(f'dice sound {cue:#x}: {reason}')
        raw = banks[0]['raw'][entry['sample']]
        end = next((i + 16 for i in range(0, len(raw), 16) if raw[i + 1] & 1), len(raw))
        vab_to_wav.reset_decoder_state()
        independent = [sample for i in range(0, end, 16)
                       for sample in vab_to_wav.decode_adpcm_block(raw[i:i + 16])]
        if independent != banks[0]['samples'][entry['sample']]:
            raise ValueError('dice sound ADPCM decoders disagree')
        pcm = sfx.render(entry, banks)
        path = output / f'{cue:04x}.wav'
        with wave.open(str(path), 'wb') as stream:
            stream.setnchannels(2)
            stream.setsampwidth(2)
            stream.setframerate(44100)
            stream.writeframes(pcm)
        entries.append({**entry, 'path': path.name, 'frames': len(pcm) // 4,
                        'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    packet = {'schema': 'suikoden-battle-sfx/5' if 0x813 in common_cues else 'suikoden-battle-sfx/4', 'sample_rate': 44100, 'cues': entries,
              'status': 'candidate; dry; user listening and promotion pending',
              'unsupported': [{'id': 0x505, 'reason': 'active common bank context remains unbound'}],
              'sources': [{k: v for k, v in bank.items() if k not in ('samples', 'programs', 'loops', 'raw')}
                          for bank in [*common, mode]],
              'overlay': origin,
              'timing': 'VB2 8001788C: text-box allocation; 80016830: each flight landing; loss caller 80018114 remains unbound',
              'box_level': 'MAIN 800C58F0 retains 226+55=281 in halfword; 801577B0 stores low byte25; 80154F1C reads unsigned byte25 for voice setup',
              'win_stream_restore': {'start': 0, 'step': 1, 'updates_per_poll': 1,
                                     'target': 'current stream descriptor volume',
                                     'source': 'MAIN 800C5868..800C587C -> class20 800C50C0 -> 800C6A00; queued state10 -> 800C6A38',
                                     'scope': 'native simulation-step ramp; original cross-system polling cadence remains open'},
              'poll_order': {'mode_callback': 'MAIN 800C2870', 'draw_submission': 'MAIN 800C2940',
                             'audio_queue': 'MAIN 800C295C -> 800C30C4 -> 800C8B70',
                             'scope': 'one queue poll after the mode callback per normal main-loop iteration; blocking loader loops also poll independently'},
              'bank': 'VB2 80013440 requests 4B before entry readiness; MAIN 80164834 descriptor selects slot2',
              'independent_verification': 'direct bank descriptor agrees; selected ADPCM PCM agrees between render_seq and vab_to_wav'}
    sfx.validate(output, packet)
    (output / 'battle_sfx.json').write_text(json.dumps(packet, indent=2) + '\n')
    return packet


def contract():
    overlay, origin = source('/VB2.BIN')
    main, main_origin = source('MAIN.EXE')
    if origin['sha256'] != SOURCE_SHA256 or main_origin['sha256'] != MAIN_SHA256:
        raise ValueError('unsupported dice audio source identity')
    base = struct.unpack_from('<I', main, 0x18)[0]
    def word(address):
        return struct.unpack_from('<I', main, 2048 + address - base)[0]
    for offset, expected in {0x2f74: 0x34160003, 0x2f88: 0xa0760001,
                             0x3458: 0x8c42022c, 0x3484: 0x3404042b,
                             0x3490: 0x34020001, 0x48c0: 0x8c42022c, 0x48d0: 0x1440004c,
                             0x48ec: 0x3404042b, 0x4988: 0x3404040c}.items():
        if struct.unpack_from('<I', overlay, offset)[0] != expected:
            raise ValueError(f'dice audio caller changed at {offset:#x}')
    for address, expected in {0x80165834: 0x800c30e4, 0x800c30ec: 0x0c031439,
                              0x800c0810: 0x800c5058, 0x800c505c: 0x0c031e52,
                              0x800c50e8: 0x90429beb, 0x800c50fc: 0x90429c00,
                              0x800c5110: 0x90429bf3, 0x800c7960: 0xa0500000,
                              0x800c7974: 0x00021080, 0x800c797c: 0x24214e72}.items():
        if word(address) != expected:
            raise ValueError(f'dice audio consumer changed at {address:#x}')
    records = {r['index']: r for r in resources()}
    selected = []
    for name, index in (('area_b', 12), ('dice', 43)):
        row = records[index]
        # Independent direct descriptor read checks the resource catalog projection.
        direct = struct.unpack_from('<I4H', main, 2048 + 0x80164e68 - base + index * 12)
        if direct != (row['lba'], row['rate'], row['loop_sector'], row['end_sector'], row['volume']):
            raise ValueError('stream descriptor disagrees with independent extraction')
        selected.append((name, row))
    return selected, {'overlay': origin, 'main': main_origin,
                      'entry': 'VB2 0x80012F74/0x80012F88 -> major3 0x80013450..0x80013498: idle wait, stream request 0x42B',
                      'exit': 'VB2 0x800148B8..0x80014900: busy query, stream request 0x42B, major4',
                      'cleanup': 'VB2 0x80014904..0x800149EC: fixed mode requests 0x40C before freeing UI and publishing balance',
                      'consumer': 'MAIN 0x800C4FE0/0x800C7948; descriptor table 0x80164E68',
                      'readiness': 'MAIN 0x800C50E4: bank/XA/SPU-stream loader busy state; not playing-voice completion'}


def export_verified_resource(output, name, row):
    output = Path(output)
    track, origin = export_resource(output, name, row)
    track['sha256'] = hashlib.sha256((output / track['path']).read_bytes()).hexdigest()
    raw = extract(row['lba'], row['end_sector'] * 2048)
    channels = []
    for channel in channel_bytes(raw):
        vab_to_wav.reset_decoder_state()
        samples = array('h')
        for offset in range(0, len(channel), 16):
            samples.extend(vab_to_wav.decode_adpcm_block(channel[offset:offset + 16]))
        channels.append(samples)
    interleaved = array('h', (sample for pair in zip(*channels) for sample in pair))
    if sys.byteorder != 'little':
        interleaved.byteswap()
    with wave.open(str(output / track['path']), 'rb') as wav:
        if wav.readframes(wav.getnframes()) != interleaved.tobytes():
            raise ValueError('stream decoders disagree')
    return track, origin


def export(output):
    output = Path(output).resolve()
    accepted = (ROOT / 'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('candidate output cannot be accepted staging')
    selected, proof = contract()
    output.mkdir(parents=True, exist_ok=True)
    tracks, origins = [], []
    for name, row in selected:
        track, origin = export_verified_resource(output, name, row)
        tracks.append(track)
        origins.append(origin)
    packet = {'schema': 'suikoden-dice-audio/1', 'tracks': tracks}
    (output / 'dice.json').write_text(json.dumps(packet, indent=2) + '\n')
    sounds = export_sounds(output / 'sfx')
    report = {'schema': 'suikoden-dice-audio-proof/1', **proof, 'sources': origins,
              'tracks': tracks, 'sounds': sounds, 'status': 'candidate; user listening and promotion pending',
              'independent_verification': 'full stereo PCM agrees between render_seq and vab_to_wav with separate per-channel predictor histories',
              'scope': 'fixed entry and pre-exit EV8 requests, cleanup AREAB_1 request, stream identity/rate/volume/loop and load-readiness barrier; box, win/stream-restoration and slot2 landing cues; loss cue, full scene scheduling and hardware pitch/faders remain separate'}
    (output / 'dice_provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    REPORT.write_text(json.dumps(report, indent=2) + '\n')
    return packet


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / 'kit/work/build/review/dice/audio')
    args = parser.parse_args()
    result = export(args.out)
    print(f"Exported {len(result['tracks'])} independently verified dice stream candidates; no playback/promotion")
