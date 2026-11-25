"""Find jal instructions targeting a given absolute address across a corpus,
without relying on disassembling data at the right base.

jal encoding: target = ((pc+4) & 0xF0000000) | (imm26 << 2). For any pc in
0x80000000-0x8FFFFFFF the top nibble is 8, so the target's low 28 bits equal
imm26<<2 -- which means the *instruction word* alone determines the target for
all such pc. We can therefore search for the word (op=3 | imm26) directly and
then verify pc's top nibble.
"""
import os, struct, glob

def files(root):
    return (sorted(glob.glob(os.path.join(root,'kit','extracted','bin_overlays','DATA','**','*.BIN'), recursive=True))
            + [os.path.join(root,'kit','work','mainexe_code.bin')])

def jal_word(target):
    return (3 << 26) | ((target & 0x0FFFFFFF) >> 2)

def find_jal(root, target):
    pat = struct.pack('<I', jal_word(target))
    hits = []
    for f in files(root):
        d = open(f,'rb').read()
        i = d.find(pat)
        while i >= 0:
            if i % 4 == 0:
                hits.append((f, i))
            i = d.find(pat, i+1)
    return hits
