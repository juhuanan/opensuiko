"""Kasios's playlist order and three original compositions for the candidate."""
from functools import cache
import hashlib
import struct
import wave

import numpy as np

from export_first_room import source

RATE = 32000
AUTHORED = {
    17: ('River Lanterns', 88, (
        (50, 3, (74, 77, 81, 79)), (46, 4, (77, None, 74, 72)),
        (48, 4, (76, 79, 84, 81)), (45, 4, (76, 73, 69, None)),
        (50, 3, (74, 77, 81, 84)), (46, 4, (82, 81, 77, 74)),
        (48, 4, (76, 79, 77, 76)), (45, 4, (73, 76, 74, None)),
    )),
    21: ('Evening at the Keep', 76, (
        (53, 4, (69, None, 72, 77)), (48, 4, (76, 74, 72, None)),
        (50, 3, (69, 72, 74, 77)), (46, 4, (77, 74, 70, None)),
        (43, 3, (70, 74, 79, 77)), (48, 4, (76, 72, 67, 72)),
        (53, 4, (69, 72, 77, 74)), (48, 4, (72, 67, 69, None)),
    )),
    23: ('High Pass', 108, (
        (55, 4, (71, 74, 79, 81)), (50, 4, (81, 78, 74, None)),
        (52, 3, (76, 79, 83, 81)), (48, 4, (79, 76, 72, 76)),
        (55, 4, (74, 79, 83, 86)), (50, 4, (84, 81, 78, 74)),
        (48, 4, (76, 79, 84, 83)), (50, 4, (81, 78, 79, None)),
    )),
}


@cache
def playlist_indices():
    overlay, _ = source('DATA/03_SHIRO/SD_TEST.BIN')
    requests = tuple(struct.unpack_from('<H', overlay, 0x7640 + 8 * row)[0] for row in range(16))
    if (struct.unpack_from('<I', overlay, 0x0864)[0] != 0x94230000
            or struct.unpack_from('<I', overlay, 0x0878)[0] != 0x0020f809
            or len(set(requests)) != len(requests) or any(not 0x401 <= request <= 0x445 for request in requests)):
        raise ValueError('Kasios music selector changed')
    return tuple(request - 0x400 for request in requests)


def add_note(mix, start, frames, midi, level, pan, upper):
    time = np.arange(frames, dtype=np.float64) / RATE
    pitch = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    phase = 2.0 * np.pi * pitch * time
    attack = np.minimum(time / 0.032, 1.0)
    release = np.minimum((frames - 1 - np.arange(frames)) / (RATE * 0.12), 1.0)
    tone = (np.sin(phase) + upper * np.sin(2.0 * phase)) * attack * release * level
    mix[start:start + frames, 0] += tone * (1.0 - pan)
    mix[start:start + frames, 1] += tone * (1.0 + pan)


def render(index, output):
    title, tempo, score = AUTHORED[index]
    beat = round(60 * RATE / tempo)
    mix = np.zeros((len(score) * 4 * beat, 2), dtype=np.float64)
    overtone = {17: 0.16, 21: 0.06, 23: 0.26}[index]
    for bar, (root, third, melody) in enumerate(score):
        start = bar * 4 * beat
        add_note(mix, start, 4 * beat, root - 12, 0.12, 0, 0.1)
        for offset, interval in enumerate((0, 7, third + 12, 7)):
            add_note(mix, start + offset * beat, beat, root + interval, 0.09, -0.20, 0.11)
        for offset, note in enumerate(melody):
            if note is not None:
                add_note(mix, start + offset * beat, beat, note, 0.22, 0.18, overtone)
    assert np.max(np.abs(mix)) < 1.0 and not np.any(mix[[0, -1]])
    payload = np.rint(mix * 32767).astype('<i2').tobytes()
    identity = f'track_{index:02d}'
    relative = f'bgm/{identity}.wav'
    path = output / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(payload)
    return {'id': identity, 'path': relative, 'title': title, 'sample_rate': RATE, 'frames': len(mix),
            'loop_start_frame': 0, 'volume': 100,
            'authored': {'renderer': 'jukebox_music/1', 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}}


def attach_playlist(output, manifest):
    playlist = playlist_indices()
    authored_ids = {f'track_{index:02d}' for index in AUTHORED}
    tracks = [row for row in manifest['tracks'] if row['id'] not in authored_ids]
    existing = {row['id'] for row in tracks}
    for index in playlist:
        if index not in AUTHORED and f'track_{index:02d}' not in existing:
            raise ValueError(f'Kasios playlist source index {index} is missing from the candidate')
    tracks.extend(render(index, output) for index in AUTHORED)
    manifest['tracks'] = sorted(tracks, key=lambda track: track['id'])
    manifest['jukebox'] = [f'track_{index:02d}' for index in playlist]
    return manifest
