#!/usr/bin/env python3
"""Suikoden PS1 STR video extractor.

Extracts the 3 STR videos from the disc image into FFmpeg-decodable files
(`ffmpeg -f psxstr -i <file>` -> mdec 320x240@15fps + adpcm_xa audio).

FORMAT (verified 2026-10-01, see kit/docs/str_video.md):

- 573LOGO.STR (LBA 24) and SUIKODEN.STR (LBA 1456): normal CD-XA STR sectors.
  Each 2352-byte MODE2 sector = 24-byte CD header + 32-byte STR header +
  2296 bytes MDEC/XA payload. Copied verbatim.
- OPEN15MX.STR (LBA 231476): stored as a plain ISO9660 file in MODE2/FORM1
  data sectors (submode 0x08). Concatenated 2048-byte user areas form:
      [8-byte header][2328-byte STR sector][8-byte sep]...
  with XA audio chunks interleaved (parse by STR-magic scan, not stride).
  This tool extracts the 2328-byte video sectors (magic 0x80010160) and
  prepends synthetic 24-byte CD headers -> 2352-byte FFmpeg sectors.

KEY FORMAT FINDING: the on-disc MDEC stream is VLC-coded (MPEG-1-like:
VLC DC diffs, MPEG-1 run/level VLC table, EOB=level-127), NOT the 16-bit
RLE the MDEC hardware takes (no 0xFE00 anywhere on disc). Ground truth
decoder: FFmpeg libavcodec/mdec.c `mdec_decode_block_intra`. Do NOT
implement halfword-RLE decoding here -- it desyncs immediately.

Usage:
    str_decode.py extract [--out DIR]     # extract all 3 STRs
    str_decode.py info                    # print LBAs / frame counts
    str_decode.py manifest --out PATH     # write suikoden-movies/1 JSON manifest
"""
import hashlib, json, shutil, struct, subprocess, sys, os, tempfile

# --- path portability (2026-10-03): derive from __file__, never $HOME ---
_TOOLS = os.path.dirname(os.path.abspath(__file__))
_KIT = os.path.dirname(_TOOLS)
_ROOT = os.path.dirname(_KIT)


# Resolved through tools/disc.py so both .bin (MODE2/2352) and .iso work.
# STR extraction needs raw 2352-byte sectors, so we read at the sector level
# rather than using disc.extract()'s payload framing.
def _open_disc():
    """Return (fileobj, 2352) for the RAW MODE2/2352 image.

    STR parsing reads sector subheaders (byte 18, the CD-XA submode), which
    only exist in the 2352-byte dump. disc.resolve() may legitimately hand back
    the .iso, so ask for the raw image explicitly rather than reading 2048-byte
    sectors as if they were 2352.
    """
    sys.path.insert(0, _TOOLS)
    import disc as _disc
    path, sector, _off = _disc.resolve_raw()
    return open(path, 'rb'), sector


DISC = None  # legacy name kept; use _open_disc()
SECTOR = 2352

STR_MAGIC = bytes.fromhex('60010180')  # LE u16 0x0160, 0x8001
SYNC = bytes.fromhex('00ffffffffffffffffffff00')

def cd_header(channel=1, submode=0x42):
    return SYNC + bytes([0, 0, 0, 2]) + bytes([0, channel, submode, 0x80]) * 2

def read_sectors(f, lba, n):
    f.seek(lba * SECTOR)
    return f.read(n * SECTOR)

def extract_raw(f, lba, n):
    """Verbatim 2352-byte sectors (573LOGO, SUIKODEN)."""
    return read_sectors(f, lba, n)

def extract_open15mx(f):
    """Parse the file-stream layout, return 2352-byte FFmpeg sectors (video only)."""
    # find submode-0x08 run starting at 231476
    lba, chunks = 231476, []
    # Bound the scan by the actual image size: past the end, read_sectors
    # returns short data and the old code raised IndexError on s[18].
    f.seek(0, os.SEEK_END)
    total_sectors = f.tell() // SECTOR
    f.seek(0)
    while lba < total_sectors:
        want = min(256, total_sectors - lba)
        raw = read_sectors(f, lba, want)
        done = False
        for i in range(want):
            s = raw[i*SECTOR:(i+1)*SECTOR]
            if len(s) < SECTOR or s[18] != 0x08:
                done = True
                break
            chunks.append(s[24:2072])
        lba += want
        if done:
            break
    if not chunks:
        raise RuntimeError(
            'no submode-0x08 stream found at LBA 231476; is this the right disc?')
    stream = b''.join(chunks)
    assert stream[:8] == bytes.fromhex('0001428000014280'), 'file header mismatch'
    # magic scan for video sectors
    pos, out = [], []
    i = 0
    while True:
        i = stream.find(STR_MAGIC, i)
        if i < 0:
            break
        if struct.unpack('<H', stream[i+2:i+4])[0] == 0x8001:
            pos.append(i)
        i += 1
    for p in pos:
        sec = stream[p:p+2328]
        if len(sec) < 2328:
            sec += b'\0' * (2328 - len(sec))
        out.append(cd_header() + sec)
    return b''.join(out), len(pos)

def extract_open15mx_av(f):
    """Parse OPEN15MX.STR 2336-byte chunks into 2352-byte CD-XA sectors (video + XA audio)."""
    lba, chunks = 231476, []
    f.seek(0, os.SEEK_END)
    total_sectors = f.tell() // SECTOR
    f.seek(0)
    while lba < total_sectors:
        want = min(256, total_sectors - lba)
        raw = read_sectors(f, lba, want)
        done = False
        for i in range(want):
            s = raw[i * SECTOR:(i + 1) * SECTOR]
            if len(s) < SECTOR or s[18] != 0x08:
                done = True
                break
            chunks.append(s[24:2072])
        lba += want
        if done:
            break
    if not chunks:
        raise RuntimeError(
            'no submode-0x08 stream found at LBA 231476; is this the right disc?')
    stream = b''.join(chunks)
    assert stream[:8] == bytes.fromhex('0001428000014280'), 'file header mismatch'
    prefix = SYNC + bytes([0, 0, 0, 2])
    out = []
    frames = set()
    nv = 0
    na = 0
    for pos in range(0, len(stream) - 2335, 2336):
        hdr = stream[pos:pos + 8]
        pay = stream[pos + 8:pos + 2336]
        if pay[:4] == STR_MAGIC and struct.unpack('<H', pay[2:4])[0] == 0x8001:
            nv += 1
            frames.add(struct.unpack('<H', pay[8:10])[0])
            out.append(prefix + stream[pos:pos + 2336])
        elif hdr[2] == 0x64:
            na += 1
            out.append(prefix + stream[pos:pos + 2336])
    return b''.join(out), nv, na, len(frames)


def _pack_sjv(frame_dir, sjv_path, width=320, height=240, fps=15):
    """Pack numbered PNG frames into an indexed SJV1 stream."""
    names = sorted(n for n in os.listdir(frame_dir) if n.endswith('.png'))
    if not names:
        raise RuntimeError(f'no PNG frames produced in {frame_dir}')
    blobs = []
    for name in names:
        with open(os.path.join(frame_dir, name), 'rb') as h:
            blobs.append(h.read())
    header_size = 14 + len(blobs) * 8
    offset = header_size
    with open(sjv_path, 'wb') as out:
        out.write(struct.pack('<4sHHHI', b'SJV1', width, height, fps, len(blobs)))
        for blob in blobs:
            out.write(struct.pack('<II', offset, len(blob)))
            offset += len(blob)
        for blob in blobs:
            out.write(blob)
    return len(blobs)


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as handle:
        while True:
            chunk = handle.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def movie_manifest(f):
    """Build disc-verified suikoden-movies/1 metadata without promoting unreviewed media."""
    movies = []
    xa_specs = (
        ('logo', 'DEMO/573LOGO.STR', 24, 1135, 'opening'),
        ('opening', 'DEMO/SUIKODEN.STR', 1456, 16489, 'title'),
    )
    for movie_id, disc_path, lba, n, next_stage in xa_specs:
        raw = read_sectors(f, lba, n)
        frames, nv, na = set(), 0, 0
        for i in range(n):
            s = raw[i * SECTOR:(i + 1) * SECTOR]
            if s[24:28] == STR_MAGIC:
                nv += 1
                frames.add(struct.unpack('<H', s[32:34])[0])
            elif s[18] == 0x64:
                na += 1
        frame_count = len(frames)
        movies.append({
            'id': movie_id,
            'disc_path': disc_path,
            'lba_start': lba,
            'lba_end': lba + n - 1,
            'sector_count': n,
            'video_sectors': nv,
            'xa_sectors': na,
            'frames': frame_count,
            'fps': 15,
            'sample_rate_hz': 37800 if na > 0 else None,
            'duration_ms': round(frame_count * 1000 / 15),
            'next_stage': next_stage,
            'skip_to': 'title',
            'media_accepted': False,
        })
    _, open_nv, open_na, open_count = extract_open15mx_av(f)
    movies.append({
        'id': 'attract',
        'disc_path': 'OPEN15MX.STR',
        'lba_start': 231476,
        'lba_end': 250750,
        'sector_count': 19275,
        'video_sectors': open_nv,
        'xa_sectors': open_na,
        'frames': open_count,
        'fps': 15,
        'sample_rate_hz': 37800 if open_na > 0 else None,
        'duration_ms': round(open_count * 1000 / 15),
        'next_stage': 'title',
        'skip_to': 'title',
        'media_accepted': False,
    })
    return {
        'schema': 'suikoden-movies/1',
        'decoder': 'kit/tools/str_decode.py',
        'media_accepted': False,
        'movies': movies,
    }


def export_runtime_videos(video_dir):
    """Decode disc STR movies into SJV1 frame packs + WAV audio + video/movies.json."""
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise RuntimeError('ffmpeg is required to decode STR videos for live playback')
    os.makedirs(video_dir, exist_ok=True)
    f, _sector = _open_disc()
    try:
        payload = movie_manifest(f)
        streams = {
            'logo': extract_raw(f, 24, 1135),
            'opening': extract_raw(f, 1456, 16489),
            'attract': extract_open15mx_av(f)[0],
        }
    finally:
        f.close()
    with tempfile.TemporaryDirectory() as tmp:
        for entry in payload['movies']:
            mid = entry['id']
            raw_path = os.path.join(tmp, f'{mid}.bin')
            with open(raw_path, 'wb') as h:
                h.write(streams[mid])
            fdir = os.path.join(tmp, mid)
            os.makedirs(fdir, exist_ok=True)
            subprocess.run(
                [ffmpeg, '-y', '-loglevel', 'error', '-f', 'psxstr', '-i', raw_path,
                 '-an', os.path.join(fdir, '%04d.png')],
                check=True,
            )
            sjv_name = f'{mid}.sjv'
            sjv_path = os.path.join(video_dir, sjv_name)
            decoded_frames = _pack_sjv(fdir, sjv_path, width=320, height=240, fps=entry['fps'])
            wav_name = f'{mid}.wav'
            wav_path = os.path.join(video_dir, wav_name)
            subprocess.run(
                [ffmpeg, '-y', '-loglevel', 'error', '-f', 'psxstr', '-i', raw_path,
                 '-vn', '-acodec', 'pcm_s16le', wav_path],
                check=True,
            )
            entry['frames'] = decoded_frames
            entry['duration_ms'] = round(decoded_frames * 1000 / entry['fps'])
            entry['width'] = 320
            entry['height'] = 240
            entry['video_path'] = f'video/{sjv_name}'
            entry['video_sha256'] = _sha256_file(sjv_path)
            entry['audio_path'] = f'video/{wav_name}'
            entry['audio_sha256'] = _sha256_file(wav_path)
    out_manifest = os.path.join(video_dir, 'movies.json')
    with open(out_manifest, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2)
        handle.write('\n')
    return payload


def export_manifest(out_path):
    """Inspect the disc STRs and write the suikoden-movies/1 JSON manifest."""
    f, _sector = _open_disc()
    try:
        payload = movie_manifest(f)
    finally:
        f.close()
    parent = os.path.dirname(os.path.abspath(out_path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as handle:
        json.dump(payload, handle, indent=2)
        handle.write('\n')
    return payload


def info(f):
    import collections
    for name, lba, n in (('573LOGO.STR', 24, 1135), ('SUIKODEN.STR', 1456, 16489)):
        raw = read_sectors(f, lba, n)
        frames, nv, na = set(), 0, 0
        for i in range(n):
            s = raw[i*SECTOR:(i+1)*SECTOR]
            if s[24:28] == STR_MAGIC:
                nv += 1
                frames.add(struct.unpack('<H', s[32:34])[0])
            elif s[18] == 0x64:
                na += 1
        print(f'{name}: LBA {lba}-{lba+n-1}, {n} sectors '
              f'({nv} video, {na} XA), {len(frames)} frames')
    _, nsec = extract_open15mx(f)
    print(f'OPEN15MX.STR: LBA 231476-250750 file-stream, {nsec} video sectors')

def main():
    out = os.path.join(_KIT, "work/str")
    args = sys.argv[1:]
    if args and args[0] == 'info':
        f, _sector = _open_disc()
        try:
            info(f)
        finally:
            f.close()
        return
    if args[:1] == ['manifest']:
        manifest_out = os.path.join(_KIT, "work/str/movies.json")
        if len(args) > 2 and args[1] == '--out':
            manifest_out = args[2]
        export_manifest(manifest_out)
        print('wrote', manifest_out)
        return
    if args[:1] == ['extract'] and len(args) > 2 and args[1] == '--out':
        out = args[2]
    os.makedirs(out, exist_ok=True)
    f, _sector = _open_disc()
    try:
        for name, lba, n in (('573logo', 24, 1135), ('suikoden', 1456, 16489)):
            p = os.path.join(out, f'{name}_raw.bin')
            with open(p, 'wb') as o:
                o.write(extract_raw(f, lba, n))
            print('wrote', p)
        data, nsec = extract_open15mx(f)
        p = os.path.join(out, 'open15mx_ff.bin')
        with open(p, 'wb') as o:
            o.write(data)
        print('wrote', p, f'({nsec} video sectors)')
    finally:
        f.close()
    print('decode with: ffmpeg -f psxstr -i <file> ...')

if __name__ == '__main__':
    main()
