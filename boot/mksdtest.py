#!/usr/bin/env python3
"""Generate boot/sdtest.img for boot/sdtest.s.

Every block carries a pattern derived from its OWN LBA:

    byte i of block n = (n*7 + i*3 + 1) & 0xFF

so a device that ignores the LBA and returns block 0 every time fails the
test, rather than passing because it returned 512 plausible bytes. The two
multipliers are coprime with 256, so neither the block stride nor the byte
stride aliases.

128 blocks = 64 KB: big enough for the multi-block test and for a read past
the end to be genuinely past the end.
"""
import sys

BLOCKS = 128
SIZE = 512

def block(n):
    return bytes(((n * 7 + i * 3 + 1) & 0xFF) for i in range(SIZE))

out = sys.argv[1] if len(sys.argv) > 1 else "sdtest.img"
with open(out, "wb") as f:
    for n in range(BLOCKS):
        f.write(block(n))
print(f"{out}: {BLOCKS} blocks, {BLOCKS*SIZE} bytes")
