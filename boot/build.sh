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
# *** IMPORTANT ***  Changing boot.hex is NOT enough on its own.  Quartus's
# incremental flow will take a "MIF/HEX Update" fast path that regenerates the
# bitstream WITHOUT picking up the new contents -- it reports success in about
# a minute and produces a byte-identical .rbf.  Always force a full rebuild:
#
#     rm -rf db incremental_db
#     quartus_sh --flow compile X816.qpf
#
# and verify the result actually changed:
#
#     cmp output_files/X816.rbf releases/X816_bands.rbf
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
