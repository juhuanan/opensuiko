#!/usr/bin/env python3
"""Disc-derived game-over CD-XA candidate; no playback or accepted promotion."""
import argparse
from array import array
import hashlib
import json
from pathlib import Path
import struct
import sys
import wave

from disc import resolve_raw, ShortReadError, MODE2_SYNC
from dot8_probe import _iso_listing
from export_first_room import source
import maindec
from xa_decode import XADecoder, VERSION

ROOT = Path(__file__).resolve().parents[2]


def contract():
    raw, origin = source('/GAMEOVER.BIN')
    for offset, expected in {0: 0x800100B0, 4: 0x800100D8, 0xC0: 0x0C004530,
                             0x14D4: 0x3C02800C, 0x14D8: 0x34424FE0,
                             0x14E4: 0x0040F809, 0x14E8: 0x34040303}.items():
        if struct.unpack_from('<I', raw, offset)[0] != expected:
            raise ValueError(f'game-over audio initializer changed at {offset:#x}')
    for pc, expected in {
        0x800C080C: 0x800C5044, 0x800C5048: 0x0C0318DD,
        0x800C6390: 0x000210C0, 0x800C6398: 0x24214E31,
        0x800C63A0: 0x90220000, 0x800C63B4: 0x34020303,
        0x800C63C4: 0xA0209C90, 0x800C642C: 0x34040002,
        0x800C6510: 0xA0239120, 0x800C6534: 0x3042000F,
        0x800C65A8: 0x242155F8, 0x800C65C0: 0x8C230000,
        0x800C65D0: 0x3C021000, 0x800C6610: 0xA0209BED,
        0x800C8CDC: 0x0082202B, 0x800C8CF4: 0x14400021,
        0x800C8D6C: 0x0C031C29, 0x800C8D70: 0x34040005,
    }.items():
        if maindec.mword(pc) != expected:
            raise ValueError(f'game-over audio consumer changed at {pc:#x}')
    packed, volume, _, duration = struct.unpack_from('<BBHI', maindec.body(), 0x80164E48-maindec.MBASE)
    if (packed, volume, duration) != (0x12, 80, 0x10000300):
        raise ValueError('game-over CD-XA descriptor changed')
    lba = maindec.mword(0x801655F8+(packed >> 4)*4)
    entry = next(row for row in _iso_listing() if row['lba'] == lba and row['path'].endswith('/XA1.'))
    return dict(command=0x303, file=entry['path'], lba=lba, source_bytes=entry['size'],
                file_number=1, channel=packed & 15, volume=volume, repeat=False,
                timeout_ticks=duration & 0x0fffffff, initializer=origin)


def decode_channel(binding):
    path, stride, _ = resolve_raw()
    if stride != 2352:
        raise ValueError('CD-XA decoding requires raw MODE2 sectors')
    with Path(path).open('rb') as stream:
        stream.seek(binding['lba']*stride)
        raw = stream.read(binding['source_bytes']//2048*stride)
    if len(raw) != binding['source_bytes']//2048*stride:
        raise ShortReadError('incomplete CD-XA source')
    decoder = XADecoder()
    samples = array('h')
    selected = []
    compressed = bytearray()
    ended = False
    for offset in range(0, len(raw), stride):
        data = raw[offset:offset+stride]
        if data[16:18] != bytes([binding['file_number'], binding['channel']]) or not data[18] & 4:
            continue
        if ended or data[:12] != MODE2_SYNC or data[15] != 2 or data[16:20] != data[20:24] or data[18] & 0x64 != 0x64 or data[19] != 1:
            raise ValueError('invalid CD-XA sector routing/format')
        selected.append(offset//stride)
        compressed.extend(data)
        left, right = decoder.decode_sector(data[24:2348])
        samples.extend(value for pair in zip(left, right, strict=True) for value in pair)
        ended = bool(data[18] & 0x80)
    if not selected or not ended:
        raise ValueError('CD-XA channel has no complete EOF boundary')
    if sys.byteorder != 'little':
        samples.byteswap()
    pcm = samples.tobytes()
    return pcm, selected, bytes(compressed)


def export(output):
    output = Path(output).resolve()
    accepted = (ROOT/'kit/work/accepted').resolve()
    if output == accepted or accepted in output.parents:
        raise ValueError('candidate output cannot be accepted staging')
    binding = contract()
    pcm, selected, compressed = decode_channel(binding)
    output.mkdir(parents=True, exist_ok=True)
    with wave.open(str(output/'defeat.wav'), 'wb') as wav:
        wav.setparams((2, 2, 37800, len(pcm)//4, 'NONE', 'not compressed'))
        wav.writeframes(pcm)
    packet = dict(schema='suikoden-defeat-audio/1', id='defeat', path='defeat.wav',
                  sample_rate=37800, frames=len(pcm)//4, volume=binding['volume'], repeat=False,
                  sha256=hashlib.sha256((output/'defeat.wav').read_bytes()).hexdigest())
    (output/'defeat.json').write_text(json.dumps(packet, indent=2)+'\n')
    proof = dict(schema='suikoden-defeat-audio-proof/1', status='candidate; listening and promotion pending',
                 binding=binding, source_sectors=selected, raw_sector_sha256=hashlib.sha256(compressed).hexdigest(), decoder=VERSION,
                 pcm_sha256=hashlib.sha256(pcm).hexdigest(), scope='Source selection and PCM; exact CD/device/fade timing remains open.')
    (output/'defeat_provenance.json').write_text(json.dumps(proof, indent=2)+'\n')
    return packet


def validate(folder, packet):
    folder = Path(folder)
    keys = {'schema', 'id', 'path', 'sample_rate', 'frames', 'volume', 'repeat', 'sha256'}
    if not isinstance(packet, dict) or set(packet) != keys or packet['schema'] != 'suikoden-defeat-audio/1' or packet['id'] != 'defeat' or packet['path'] != 'defeat.wav' or packet['repeat'] is not False:
        raise ValueError('invalid defeat audio identity/one-shot policy')
    if any(type(packet[key]) is not int for key in ('sample_rate', 'frames', 'volume')) or not (8000 <= packet['sample_rate'] <= 48000 and 0 < packet['frames'] <= 48000*600 and 0 <= packet['volume'] <= 127):
        raise ValueError('invalid defeat audio dimensions')
    digest = packet['sha256']
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
        raise ValueError('invalid defeat audio hash')
    path = folder/packet['path']
    if path.is_symlink() or not path.resolve().is_relative_to(folder.resolve()) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise ValueError('defeat audio hash/path mismatch')
    try:
        with wave.open(str(path), 'rb') as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes(), wav.getcomptype()) != (2, 2, packet['sample_rate'], packet['frames'], 'NONE'):
                raise ValueError('defeat audio WAV dimensions mismatch')
            if len(wav.readframes(packet['frames'])) != packet['frames']*4:
                raise ValueError('truncated defeat audio PCM')
    except (wave.Error, EOFError) as error:
        raise ValueError('invalid defeat audio WAV') from error


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT/'kit/work/build/battle_review/defeat_audio')
    args = parser.parse_args()
    result = export(args.out)
    print(f"Exported {result['frames']} game-over PCM frames without playback")
