#!/bin/sh
# Build the boot ROM overlay image consumed by rtl/boot_rom.sv.
#
#   boot.s --ca65--> boot.o --ld65--> boot.rom (256 raw bytes)
#                                  --od--> boot.hex (256 lines, one hex byte)
#
# boot.hex is committed, so a plain `quartus_sh --flow compile` works without
# cc65 installed.  Re-run this after editing boot.s.
set -e
cd "$(dirname "$0")"

ca65 --cpu 65816 boot.s -o boot.o
ld65 -C boot.cfg boot.o -o boot.rom

size=$(wc -c < boot.rom)
[ "$size" -eq 256 ] || { echo "boot.rom is $size bytes, expected 256" >&2; exit 1; }

od -An -v -tx1 boot.rom | tr -s ' ' '\n' | grep -v '^$' > boot.hex
echo "boot.hex: $(wc -l < boot.hex) bytes"
