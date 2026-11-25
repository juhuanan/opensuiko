#!/usr/bin/env python3
"""
PS1 VAB (Voice And Bank) -> WAV converter

VAB format:
- .VA: header with sample metadata
- .VB: body with ADPCM-compressed samples (16 bytes -> 28 PCM samples)

Usage: python3 vab_to_wav.py <file.VA> <file.VB> -o <output_dir>
"""

import struct
import argparse
import os
import wave

# PS1 ADPCM filter coefficients
FILTERS = [
    [0, 0],
    [60, 0],
    [115, -52],
    [98, -55],
    [122, -60],
]

# Filter state, carried ACROSS blocks. The SPU does not reset DecodeM1/M2 at a
# block boundary; a decoder that does gets every non-boundary sample right and
# corrupts only the samples just after each 16-byte boundary. Kept as module
# state so a caller decoding a stream block-by-block stays correct -- see
# reset_decoder_state() if you deliberately want to start a fresh stream.
_prev1 = 0
_prev2 = 0


def reset_decoder_state():
    """Clear cross-block filter history to start decoding a new stream."""
    global _prev1, _prev2
    _prev1 = _prev2 = 0

def decode_adpcm_block(block):
    """Decode one low-nibble-first SPU block, carrying predictor history.

    Out-of-range predictors use zero weights. Illegal shifts use shift8
    and the source-word mask0x8888, matching Mednafen RunDecoder.
    """
    global _prev1, _prev2
    if len(block) < 16:
        return []

    shift = block[0] & 0x0F
    filter_idx = (block[0] >> 4) & 0x0F

    if filter_idx > 4:
        filter_idx = 0
    illegal_shift = shift > 12
    if illegal_shift:
        shift = 8

    f0, f1 = FILTERS[filter_idx]

    samples = []
    prev1, prev2 = _prev1, _prev2

    for i in range(2, 16):
        byte = block[i]
        # SPU reads little-endian words and extracts their low nibble first.
        for nibble_shift in [0, 4]:
            nibble = (byte >> nibble_shift) & 0x0F
            if illegal_shift:
                nibble &= 8
            # Sign-extend, then mask to 16 bits BEFORE shifting -- mirrors the
            # hardware's (int16)(coded & 0xF000) >> shift.
            sample = (nibble << 12) & 0xF000
            if sample & 0x8000:
                sample -= 0x10000
            sample >>= shift
            # Truncating terms, NOT rounded: the SPU computes
            # (DecodeM2*w2)>>6 and (DecodeM1*w1)>>6 separately. An earlier
            # version added +32 here, which biased every filtered sample by
            # 1..13 LSB and made this decoder disagree with render_seq.py on
            # 188,283 of 190,372 samples.
            sample += (prev1 * f0) >> 6
            sample += (prev2 * f1) >> 6
            # Clamp to 16-bit
            sample = max(-32768, min(32767, sample))

            samples.append(sample)
            prev2 = prev1
            prev1 = sample

    _prev1, _prev2 = prev1, prev2
    return samples

def vab_to_wav(va_path, vb_path, output_dir):
    """Convert VAB to WAV files."""
    with open(vb_path, 'rb') as f:
        vb_data = f.read()
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Decode all ADPCM blocks
    all_samples = []
    for i in range(0, len(vb_data), 16):
        block = vb_data[i:i+16]
        if len(block) < 16:
            break
        samples = decode_adpcm_block(block)
        all_samples.extend(samples)
    
    # Write as single WAV (for now; proper splitting needs header parse)
    output_path = os.path.join(output_dir, "vab_decoded.wav")
    with wave.open(output_path, 'wb') as wav:
        wav.setnchannels(1)  # Mono
        wav.setsampwidth(2)  # 16-bit
        wav.setframerate(44100)  # PS1 native is 44100? Actually 37800 for ADPCM
        # PS1 ADPCM is 37800 Hz, but we'll use 44100 for compatibility
        wav.writeframes(struct.pack(f'<{len(all_samples)}h', *all_samples))
    
    print(f"Wrote {output_path}: {len(all_samples)} samples")
    return output_path

def main():
    parser = argparse.ArgumentParser(description='VAB to WAV converter')
    parser.add_argument('va', help='VAB header (.VA)')
    parser.add_argument('vb', help='VAB body (.VB)')
    parser.add_argument('-o', '--output', required=True, help='Output directory')
    args = parser.parse_args()
    
    vab_to_wav(args.va, args.vb, args.output)

if __name__ == '__main__':
    main()
