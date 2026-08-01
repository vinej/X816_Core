#!/usr/bin/env bash
# Build and run the HOST-side FAT32 harness: the guest's fat32.c compiled for
# the PC against a file-backed block device, read back against an image that
# pyfatfs wrote -- two independent implementations agreeing.
#
# THE ONE TRAP, captured here because it cost a debugging session: fat32.c
# does `#include "x816_sd.h"`, and gcc resolves quote-includes RELATIVE TO THE
# INCLUDING FILE'S DIRECTORY before any -I path. Compiling fat32.c in place
# therefore picks up the GUEST header -- volatile pointers at $9F8x -- and the
# harness segfaults on the first MMIO dereference. So fat32.c is COPIED next
# to hostfat_sd.h (renamed x816_sd.h) and compiled there.
#
#   sh hostfat.sh [image]        default image: fat32.img here
set -eu
cd "$(dirname "$0")"

GCC=${GCC:-/c/msys64/ucrt64/bin/gcc}
RT=${RT:-../../X816_Calypsi/runtime}
IMG=${1:-fat32.img}

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

cp "$RT/fat32.c" "$RT/fat32.h" "$OUT/"
cp hostfat_sd.h "$OUT/x816_sd.h"

"$GCC" -Wall -O0 -g -o "$OUT/hostfat.exe" hostfat_main.c "$OUT/fat32.c" \
       -I "$OUT"

"$OUT/hostfat.exe" "$IMG"
