#!/usr/bin/env python3
"""
Suikoden .8 asset ripper - Stage 1: Nibble decoder

Decodes the 28-nibble delta payloads from .8 records.
Outputs intermediate JSON with accumulated values per record.

Usage: python3 rip_8_stage1.py <file.8> -o <output.json>
"""

import struct
import json
import sys
import argparse

def decode_nibbles(payload):
    """Decode 14-byte payload to 28 signed nibbles, then accumulate."""
    nibbles = []
    for b in payload:
        nibbles.append((b >> 4) & 0xF)
        nibbles.append(b & 0xF)
    # Signed: 0-7 positive, 8-15 negative (-8 to -1)
    signed = [n if n < 8 else n - 16 for n in nibbles]
    # Accumulate (delta decoding)
    acc = []
    total = 0
    for s in signed:
        total += s
        acc.append(total)
    return {
        'nibbles': nibbles,
        'signed': signed,
        'accumulated': acc,
    }

def parse_8_file(path):
    """Parse .8 file into records."""
    with open(path, 'rb') as f:
        data = f.read()
    
    records = []
    for i in range(0, len(data), 16):
        rec = data[i:i+16]
        if len(rec) < 16:
            break
        tag = struct.unpack('<H', rec[0:2])[0]
        payload = rec[2:16]
        records.append({
            'index': i // 16,
            'tag': f"0x{tag:03X}",
            'tag_int': tag,
            'payload_hex': payload.hex(),
            'decoded': decode_nibbles(payload),
        })
    return records

def main():
    parser = argparse.ArgumentParser(description='Decode .8 nibble payloads')
    parser.add_argument('input', help='Input .8 file')
    parser.add_argument('-o', '--output', help='Output JSON file')
    parser.add_argument('--tag', help='Filter by tag (e.g. 0x225)')
    args = parser.parse_args()
    
    records = parse_8_file(args.input)
    
    if args.tag:
        tag_int = int(args.tag, 16)
        records = [r for r in records if r['tag_int'] == tag_int]
    
    print(f"Decoded {len(records)} records from {args.input}")
    
    # Tag distribution
    from collections import Counter
    tags = Counter(r['tag'] for r in parse_8_file(args.input))
    print(f"\nTop 10 tags:")
    for tag, count in tags.most_common(10):
        print(f"  {tag}: {count}")
    
    if args.output:
        with open(args.output, 'w') as f:
            json.dump(records, f, indent=2)
        print(f"\nWrote {args.output}")

if __name__ == '__main__':
    main()
