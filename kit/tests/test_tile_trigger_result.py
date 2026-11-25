#!/usr/bin/env python3
"""R010: query writes, collision-result consumer and separate transition writer."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from disc import extract
import event_vm_semantics as vm


def check():
    exe = extract(17976, 757760)
    base, size = struct.unpack_from('<II', exe, 0x18)
    image = exe[2048:2048 + size]
    assert base == 0x800C0800

    def words(start, end):
        return [(pc, struct.unpack_from('<I', image, pc - base)[0])
                for pc in range(start, end, 4)]

    # Query outputs are stack locals in this caller. No callback dispatch exists
    # in either query, the collision wrapper, or the talk proximity query.
    for start, end, store_bases, targets in (
        (0x8012E308, 0x8012E5A0, {7, 29}, []),
        (0x8012E5A0, 0x8012E75C, {29}, [0x8012E308, 0x8012E308]),
        (0x8012E75C, 0x8012E8B4, {29}, [0x8013D8E0, 0x8012E5A0]),
        (0x801378DC, 0x801379AC, set(), []),
    ):
        calls = []
        for pc, word in words(start, end):
            op = word >> 26
            if op in (40, 41, 42, 43, 46):
                assert (word >> 21) & 31 in store_bases, hex(pc)
            assert not (op == 0 and word & 63 == 9), hex(pc)
            if op == 3:
                calls.append((pc & 0xF0000000) | ((word & 0x3FFFFFF) << 2))
        assert calls == targets, (hex(start), calls)

    anchors = {
        0x8012E65C: 0x27A70010, 0x8012E670: 0x27A70014,
        0x8012E860: 0x14400008, 0x8012E864: 0x3402000D,
        0x8012DB84: 0x0C04B9D7, 0x8012DB98: 0x00408821,
        0x8012DC38: 0x00A01021, 0x8012DC3C: 0x00511025,
        0x8012DC40: 0x02429025, 0x8012DC44: 0x3222FFFF,
        0x8012DC48: 0x14400003, 0x8012DC7C: 0x0C04D0ED,
        0x8012DC94: 0x90421C28, 0x8012DC9C: 0x104000C1,
        0x8012E05C: 0x00001021, 0x8012E060: 0x324200FF,
        0x801343D0: 0x8E04000C, 0x801343F8: 0x0C030F6B,
        0x8013440C: 0x0C0310BA, 0x80134440: 0xA2220019,
        0x80134458: 0xA0620019,
    }
    for pc, word in anchors.items():
        assert words(pc, pc + 4)[0][1] == word, hex(pc)
    # Positive corroboration from the actual transition producer, rather than
    # concluding absence from a direct-call scan.
    assert (0x8017BE20, 0x4E0) in vm.scan(0x43).swrites
    assert (0x8017BE20, 0x498) in vm.scan(0x43).swrites
    print('PASS: complete query/wrapper write and call sets; collision mask '
          'consumer, facing updates, and separate opcode43 transition writer')


if __name__ == '__main__':
    check()
