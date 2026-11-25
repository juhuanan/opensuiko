#!/usr/bin/env python3
"""Decode STONE/BOOK/PAPER (and FACE) .BIN blobs with the game's real LZSS.

There is no "packed variant" codec. Every STONE_*/BOOK_*/PAPER_*/FACE_*.BIN
file in DATA/03_SHIRO/DATA (and the other area DATA dirs) shares one container
and one compression scheme -- the same routine the game itself calls
(text_decode_stream @ 0x800C3144 in MAIN.EXE, reached via the UI vtable
offset +132 from STONE.BIN/BOOKS.BIN and from the portrait decoder
@ 0x80140A28).

Container:  [u32 LE compressed_len][LZSS stream of compressed_len bytes]
            compressed_len is always file_size - 4.

LZSS -- canonical description: kit/tools/lzss.py v2.0.0, verified
instruction-by-instruction against the 0x800C3144 disassembly (this tool
delegates to it through kit/tools/text_lzss.py):
  - flags LSB-first, 1 = control, 0 = literal byte
  - 0x400-byte history, zero-initialised, write position starts at 0x3DE
  - control byte t0:
      t0 < 0x80 : 2-byte match, copies (t0 >> 2) + 3,
                  abs offset = t1 | ((t0 & 3) << 8)   (10-bit absolute index)
      0x80 <= t0 < 0xC0 : 1-byte match, copies ((t0 & 0x30) >> 4) + 2,
                  rel offset = (hpos - (t0 & 0xF)) & 0x3FF
      t0 >= 0xC0 : LITERAL RUN, copies (t0 & 0x3F) + 8 FRESH input bytes
                  (the hardware does an lbu per iteration; this is NOT an RLE
                  repeat and NOT +7)

CORRECTION 2026-10-03 -- this docstring used to state the OLD WRONG codec
(1 = literal / 0 = match, lengths +2/+1/+7, and "else = RLE"). Those lengths
under-copy by one byte per token, which desynchronises the stream at the first
run token and produced a whole generation of invalid renders. Authority:
kit/tools/lzss.py v2.0.0 and kit/docs/lzss_consolidation.md.

NOTE: kit/tools/face_decompress.py is a SEPARATE codec (MSB-first flags, 4KB
zero window, 12-bit absolute offsets) and is a black-box guess: no code path in
MAIN.EXE or the overlays has been located for it, and it must not be used for
the files this tool handles.

Pixel interpretation of the decompressed blobs is NOT yet cracked: the bytes
do not render as coherent images under any 8/4/16bpp, planar, or transposed
geometry tried (see kit/docs/tile_variant_codec.md, "Open problems").
"""
import struct
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from text_lzss import decompress


def decode_blob(path):
    """Return the decompressed bytes of a STONE/BOOK/PAPER/FACE .BIN file."""
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) < 4:
        raise ValueError("%s: too short for header" % path)
    (clen,) = struct.unpack("<I", data[:4])
    if clen != len(data) - 4:
        raise ValueError(
            "%s: header %d != file_size-4 %d" % (path, clen, len(data) - 4)
        )
    return decompress(data[4:4 + clen])


def main():
    for path in sys.argv[1:]:
        out = decode_blob(path)
        sys.stdout.write("%s -> %d bytes decompressed\n" % (path, len(out)))


if __name__ == "__main__":
    main()
