#!/usr/bin/env python3
"""lzss.py -- consolidated STRICT LZSS decoder for Suikoden (PS1). Version 2.0.0.

Implements text_decode_stream @0x800C3144 (MAIN.EXE, load base 0x800C0800).

Ground truth established 2026-10-02 by direct disassembly of
kit/work/mainexe_code.bin (capstone), adjudicating the review-vs-corpus
dispute. The review's formulas were RIGHT; the intermediate adjudication
(docs/codec_correction.md, now superseded by
docs/lzss_consolidation.md) was wrong about the loop bounds.

Hardware (verified instruction-by-instruction):
- Flag bytes, LSB-first. Each flag byte is ORed with 0xFF00; bit 0 is tested,
  then the word shifts right; when bit 8 (0x100) clears, the next flag byte
  is loaded (load is UNCONDITIONAL -- one OOB byte is fetched and discarded
  when input ends exactly at a refill point).
- Flag 0: literal -- one input byte -> output + history. The byte is STORED
  to output BEFORE the a1<t4 check, so a literal at the last input byte is
  emitted and then the function returns.
- Flag 1: control byte t0 (loaded with NO bounds check):
  - t0 < 0x80: 2-byte match. bound = (t0 >> 2) + 2
    (sra $v1,$t0,2 @0x800C31F8; addiu $t0,$v1,2 @0x800C31FC),
    offset = next_byte | ((t0 & 3) << 8)  (10-bit ABSOLUTE history index).
    The copy loop is do-while (copies while a0 <= bound): it writes
    bound+1 = (t0>>2)+3 bytes. There is NO per-iteration input bounds check
    (matches consume no input anyway).
  - 0x80 <= t0 < 0xC0: 1-byte match. bound = ((t0 & 0x30) >> 4) + 1
    (addiu $t0,$v0,1 @0x800C326C), back = t0 & 0x0F,
    offset = (hpos - back) & 0x3FF. Loop writes bound+1 =
    ((t0&0x30)>>4)+2 bytes.
  - t0 >= 0xC0: LITERAL RUN. bound = (t0 & 0x3F) + 7
    (addiu $t0,$v0,7 @0x800C32C4); the loop at @0x800C32D8 does
    lbu $v1,($a1) + addiu $a1,$a1,1 EVERY iteration with NO bounds check:
    it consumes bound+1 = (t0&0x3F)+8 FRESH input bytes (NOT RLE).
- History: 0x400 bytes at 0x8017AB1C; the function word-zeroes
  [base, base+0x3E0) (248 sw's; the 32 bytes at [0x3E0, 0x400) keep stale
  RAM contents -- unknowable offline, we zero the full 0x400).
  Write index STARTS at 0x3DE (ori $a3,$zero,0x3DE @0x800C3184),
  wraps with & 0x3FF.

Decisive validation: with these formulas ALL 234 c-blobs in the 78
DATA/04_PLAY files decode to EXACTLY 16384 bytes (the 64-word x 128-row
LoadImage upload rect) with 100% input consumption and zero truncations.
The old "+2/+1/+7" decoders produced short, desync'd garbage (e.g. AIL
15304/15506/15719 bytes); the "1080 bytes of stale heap" was an artefact
of the under-copying decoder. There is no size mismatch.

Strictness contract (this module is the strict decoder):
- decode()/decode_strict()/decode_container() RAISE TruncationError when the
  stream ends MID-TOKEN (control/offset byte missing, literal run short).
- A stream that ends exactly at a TOKEN BOUNDARY with flag bits remaining
  stops CLEANLY with no error -- this is how all 234 real blobs terminate
  (207 mid-flag-byte, 27 refill-exact; the next pending bit is always 0 in
  real data). Documented hardware divergences, unknowable offline:
  (a) a pending literal bit makes hardware append 1 out-of-bounds byte;
  (b) a pending control bit makes hardware decode OOB garbage; (c) the
  32 stale history bytes; (d) the unconditional OOB flag fetch at refill.
- There is no silent partial success.
- The ONLY lenient entry point is iter_candidates(), clearly marked
  EXPLORATORY, for scanning unknown blobs. Production asset code must use
  the strict API.

This module consolidates kit/tools/text_lzss.py and kit/tools/btsky_lzss.py,
which are now thin wrappers over it. (btsky's LONG/SHORT were already
correct at bound+1; its literal run was wrong at +7.)
"""

import struct
from collections import namedtuple

__version__ = "2.0.0"
GAME_FUNCTION = "text_decode_stream @0x800C3144 (MAIN.EXE load base 0x800C0800)"

HIST_SIZE = 0x400
HIST_START = 0x3DE  # hardware write-index init (ori $a3,$zero,0x3DE)


class LZSSError(Exception):
    """Base class for all lzss.py decode failures."""


class TruncationError(LZSSError):
    """Input ends mid-token: the stream is incomplete.

    Raised only when a token's required input bytes are missing. A stream
    that ends at a token boundary (flag bits remaining) is NOT truncation --
    it stops cleanly, matching how every real game blob terminates."""


class TrailingBytesError(LZSSError):
    """Strict decode finished with unconsumed input bytes remaining."""


def _decode_impl(payload: bytes, strict: bool):
    """Shared core. strict=True raises TruncationError on mid-token shortage;
    strict=False (exploratory) stops at the shortage and returns partial
    output, for candidate scanning of unknown blobs."""
    n = len(payload)
    hist = bytearray(HIST_SIZE)  # hw zeroes [0, 0x3E0); we zero all (documented)
    hpos = HIST_START
    out = bytearray()
    pos = 0

    if n == 0:
        return bytes(out), 0
    t2 = payload[0] | 0xFF00
    pos = 1
    if pos >= n:
        # hw: first flag byte loaded, a1>=t4 -> return with no output
        return bytes(out), pos

    while True:
        if pos >= n:
            # Token boundary, flag bits remain: clean stop. (Hw would OOB-read
            # one more byte for a pending literal bit / OOB t0 for a pending
            # control bit; both unknowable offline -- we stop. All 234 real
            # 04_PLAY blobs terminate exactly this way.)
            return bytes(out), pos
        if t2 & 1:
            # flag=1: control byte (hw loads with NO bounds check)
            t0 = payload[pos]
            pos += 1
            if t0 < 0x80:
                # 2-byte absolute match; copies (t0>>2)+3 (do-while: bound+1)
                if pos >= n:
                    if strict:
                        raise TruncationError(
                            "2-byte match: offset byte missing at pos %d/%d"
                            % (pos, n))
                    return bytes(out), pos
                t1 = payload[pos]
                pos += 1
                length = (t0 >> 2) + 3
                offset = (t1 | ((t0 & 3) << 8)) & 0x3FF
                for _ in range(length):
                    b = hist[offset]
                    out.append(b)
                    hist[hpos] = b
                    hpos = (hpos + 1) & 0x3FF
                    offset = (offset + 1) & 0x3FF
            elif t0 < 0xC0:
                # 1-byte relative match; copies ((t0&0x30)>>4)+2
                length = ((t0 & 0x30) >> 4) + 2
                offset = (hpos - (t0 & 0x0F)) & 0x3FF
                for _ in range(length):
                    b = hist[offset]
                    out.append(b)
                    hist[hpos] = b
                    hpos = (hpos + 1) & 0x3FF
                    offset = (offset + 1) & 0x3FF
            else:
                # LITERAL RUN: (t0&0x3F)+8 FRESH input bytes (hw: lbu every
                # iteration, no bounds check -- NOT RLE)
                length = (t0 & 0x3F) + 8
                if pos + length > n:
                    if strict:
                        raise TruncationError(
                            "literal run: needs %d bytes, %d remain (pos %d/%d)"
                            % (length, n - pos, pos, n))
                    return bytes(out), pos
                for _ in range(length):
                    b = payload[pos]
                    pos += 1
                    out.append(b)
                    hist[hpos] = b
                    hpos = (hpos + 1) & 0x3FF
        else:
            # flag=0: literal. (Hw stores BEFORE the bounds check; a literal
            # at the last input byte is emitted, then it returns -- our
            # top-of-loop check models the same stop, minus the 1 OOB byte.)
            b = payload[pos]
            pos += 1
            out.append(b)
            hist[hpos] = b
            hpos = (hpos + 1) & 0x3FF

        t2 >>= 1
        if t2 & 0x100:
            continue
        if pos >= n:
            return bytes(out), pos  # refill-exact: clean stop
        # hw: unconditional lbu here (1 OOB byte fetched & discarded when
        # input ends exactly at refill); no output effect.
        t2 = payload[pos] | 0xFF00
        pos += 1


def decode(payload: bytes):
    """Decode payload. Returns (output_bytes, bytes_consumed).

    Raises TruncationError if the stream ends mid-token. A well-formed blob
    consumes 100% of the input (consumed == len(payload)).
    """
    return _decode_impl(bytes(payload), strict=True)


def decode_strict(payload: bytes) -> bytes:
    """Decode payload, requiring 100% input consumption.

    Raises TruncationError on mid-token truncation. Streams ending at a token
    boundary with flag bits remaining stop cleanly (all real game blobs do).
    This is the entry point production asset code must use.
    """
    payload = bytes(payload)
    out, consumed = _decode_impl(payload, strict=True)
    if consumed != len(payload):
        raise TrailingBytesError(
            "decode consumed %d of %d input bytes" % (consumed, len(payload)))
    return out


def decode_container(blob: bytes, offset: int = 0):
    """Decode a [u32 LE comp_len][comp_len bytes payload] container.

    Honors the compressed-length field: decodes exactly comp_len bytes and
    requires full consumption of that region. Returns (output, 4 + comp_len).

    Raises TruncationError if the header or the claimed payload overruns the
    input, or if the payload stream itself is truncated mid-token.
    """
    blob = bytes(blob)
    n = len(blob)
    if offset + 4 > n:
        raise TruncationError(
            "container header overruns input (offset %d, size %d)" % (offset, n))
    (comp_len,) = struct.unpack_from("<I", blob, offset)
    start = offset + 4
    if start + comp_len > n:
        raise TruncationError(
            "container claims %d payload bytes, only %d available"
            % (comp_len, n - start))
    out = decode_strict(blob[start:start + comp_len])
    return out, 4 + comp_len


def decode_container_strict(blob: bytes, offset: int = 0):
    """decode_container() plus the "container ends exactly here" check.

    Returns output only. Raises TrailingBytesError when the container does not
    finish the input -- i.e. the blob is longer than the unit the header
    declares, so what follows is NOT part of this stream. Use this wherever a
    blob's extent is unknown and a partial read would silently become pixels.
    (This is the check every caller of decode_container() was expected to make
    against `used`; see AGENTS.md §3.)
    """
    blob = bytes(blob)
    out, used = decode_container(blob, offset)
    if offset + used != len(blob):
        raise TrailingBytesError(
            "container consumed %d of %d bytes (offset %d): %d bytes unconsumed"
            % (used, len(blob), offset, len(blob) - offset - used))
    return out


Candidate = namedtuple("Candidate", "offset consumed output ratio")


def iter_candidates(data: bytes, *, start: int = 0, end=None, step: int = 2,
                    min_ratio: float = 0.85):
    """EXPLORATORY candidate scanner. NOT for production asset decoding.

    Non-greedy scan: tries the lenient decoder at every `step`-byte offset
    (default every 2 bytes, because valid framings overlap -- a greedy scan
    silently drops real candidates) and yields Candidate(offset, consumed,
    output, ratio) for each offset where consumed/len(available) >= min_ratio
    (default 0.85, the tile-hunt validation threshold).

    Every candidate should be re-decoded with decode_strict() once its exact
    bounds are known.
    """
    data = bytes(data)
    n = len(data)
    hi = n if end is None else min(end, n)
    for off in range(start, hi, step):
        out, consumed = _decode_impl(data[off:hi], strict=False)
        avail = hi - off
        ratio = consumed / avail if avail else 0.0
        if ratio >= min_ratio and consumed > 0:
            yield Candidate(off, consumed, out, ratio)
