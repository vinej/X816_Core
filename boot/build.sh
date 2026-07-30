#!/bin/sh
# Build a boot ROM overlay image for rtl/boot_rom.sv.
#
#   sh build.sh            -> boot.s      (the colour-bands bring-up demo)
#   sh build.sh vramtest   -> vramtest.s  (the VERA816 conformance test)
#
# Either way the result lands in boot.hex, which is what boot_rom.sv reads
# with $readmemh.  boot.hex is committed so a plain `quartus_sh --flow compile`
# works with no cc65 installed.
#
# *** WHY THIS SCRIPT TOUCHES rtl/boot_rom.sv ***
#
# boot.hex is not a project source: it appears nowhere in files.qip or
# X816.qsf, only inside the $readmemh string in rtl/boot_rom.sv.  Quartus
# therefore has no dependency on it, and smart-recompile sees no changed
# source file -- so `quartus_sh --flow compile` skips Analysis & Synthesis and
# the OLD memory contents stay baked into the bitstream.  It reports success,
# and the .rbf is byte-identical to the previous build.
#
# $readmemh contents are captured during synthesis, not at assembly time, so
# the fix is to force re-synthesis of the module that reads the file.  Touching
# boot_rom.sv does exactly that, and only that -- far cheaper than deleting
# db/ and incremental_db/, which forces a full rebuild of everything.
#
set -e
cd "$(dirname "$0")"

SRC="${1:-boot}"
[ -f "$SRC.s" ] || { echo "no such source: $SRC.s" >&2; exit 1; }

ca65 --cpu 65816 "$SRC.s" -o "$SRC.o"
ld65 -C boot.cfg "$SRC.o" -o "$SRC.rom"

size=$(wc -c < "$SRC.rom")
[ "$size" -eq 256 ] || { echo "$SRC.rom is $size bytes, expected 256" >&2; exit 1; }

od -An -v -tx1 "$SRC.rom" | tr -s ' ' '\n' | grep -v '^$' > boot.hex
echo "boot.hex <- $SRC.rom ($(wc -l < boot.hex) bytes)"

# Give Quartus a dependency it can actually see (see the note above).
touch ../rtl/boot_rom.sv
echo "touched rtl/boot_rom.sv so Quartus re-reads boot.hex"
