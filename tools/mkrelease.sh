#!/usr/bin/env bash
# Assemble a MiSTer release tree under releases/mister/.
#
#     sh tools/mkrelease.sh
#
# Produces a directory that maps 1:1 onto the MiSTer SD card, so installing is
# a copy rather than a set of instructions to follow carefully:
#
#     releases/mister/
#       _Computer/X816_<date>.rbf     the core
#       games/X816/boot1.rom          the shell, auto-loaded at core start
#       games/X816/boot0.img          the starter SD card image,
#                                     auto-mounted into slot 0
#
# THE .rbf NAME MATTERS. MiSTer's launcher expects <Name>_<date>.rbf, and a
# file that does not follow the pattern misbehaves in ways that look exactly
# like a broken bitstream -- black screen, unresponsive board. That cost an
# afternoon of RTL debugging on this project, so the name is derived here
# rather than left to whoever is copying files.
#
# boot1.rom is the shell. X816.sv decodes ioctl_index 16'h0040 as the
# bootN.rom auto-load with N=1, writing to PROG_BASE ($01:0000), which is where
# boot/boot.s looks for the "X816" magic. Confirmed working on hardware from
# games/X816/ -- the core reaches its prompt with no user action.
set -u

CORE=$(cd "$(dirname "$0")/.." && pwd)
CALYPSI=${CALYPSI_DIR:-$(cd "$CORE/../X816_Calypsi" 2>/dev/null && pwd || echo "")}
OUT="$CORE/releases/mister"

# NEWEST by modification time, across both locations. Picking "whichever glob
# matched last" shipped a stale bitstream from releases/ while a fresher one sat
# in output_files/ -- and a core that is a day old but labelled as current is
# indistinguishable from a core that is broken.
RBF_SRC=$(ls -t "$CORE"/output_files/X816_*.rbf "$CORE"/releases/X816_2*.rbf \
          2>/dev/null | head -1)
if [ -z "$RBF_SRC" ]; then
    echo "no built bitstream found." >&2
    echo "  expected output_files/X816_<date>.rbf -- run the Quartus compile first." >&2
    exit 1
fi

# Date from the bitstream's own mtime, not from today: the name has to describe
# the file being shipped, and re-packaging an old build must not relabel it.
STAMP=$(date -r "$RBF_SRC" +%Y%m%d 2>/dev/null || date +%Y%m%d)
RBF_DST="X816_${STAMP}.rbf"

# If the source filename already carries a date, it must agree with the mtime.
# A disagreement means someone renamed a file, and the whole point of deriving
# the name here is that the name is trustworthy.
SRC_STAMP=$(basename "$RBF_SRC" | sed -n 's/^X816_\([0-9]\{8\}\)\.rbf$/\1/p')
if [ -n "$SRC_STAMP" ] && [ "$SRC_STAMP" != "$STAMP" ]; then
    echo "note   : $(basename "$RBF_SRC") is dated $SRC_STAMP but was last" >&2
    echo "         modified $STAMP; shipping it as X816_${STAMP}.rbf" >&2
fi

# ---- BUILD before packaging, and before destroying anything ----------------
# Packaging used to copy whatever shell.bin happened to exist and trust that
# someone had rebuilt it. They had not: a stale shell shipped three times --
# a release missing the Shift key and half the commands, which looks like a
# broken core rather than an old file.
#
# So build it here. A release is now correct by construction rather than by
# anyone remembering, and the staleness check below is only a backstop for when
# the toolchain is absent and an old binary is being reused deliberately.
#
# Done BEFORE `rm -rf`, so a failure leaves the previous good release intact --
# refusing after the wipe turns a caught mistake into a worse one.
SHELL_BIN="$CALYPSI/examples/shell/shell.bin"
KERNEL_BIN="$CALYPSI/examples/shell/kernel.bin"
if [ -n "$CALYPSI" ] && [ -x "$CALYPSI/Calypsi/calypsi-65816-5.18/bin/cc65816" ]; then
    echo "build  : $CALYPSI/examples/shell"
    if ! (cd "$CALYPSI/examples/shell" && sh build.sh >/dev/null 2>&1); then
        echo "REFUSING: the shell failed to build." >&2
        echo "  run: sh $CALYPSI/examples/shell/build.sh   to see why." >&2
        echo "  the existing release under releases/mister/ is untouched." >&2
        exit 1
    fi
elif [ -n "$CALYPSI" ] && [ -f "$KERNEL_BIN" ]; then
    # No toolchain: fall back to whatever is there, but refuse it if the
    # sources have moved on.
    NEWER=$(find "$CALYPSI/runtime" "$CALYPSI/examples/shell" \
                 \( -name '*.c' -o -name '*.h' -o -name '*.s' \) 2>/dev/null \
            | while read -r f; do
                  [ "$f" -nt "$KERNEL_BIN" ] && echo "$f"
              done)
    if [ -n "$NEWER" ]; then
        echo "REFUSING: no toolchain, and kernel.bin is older than its sources:" >&2
        echo "$NEWER" | sed 's|.*/|    |' >&2
        echo "  the existing release under releases/mister/ is untouched." >&2
        exit 1
    fi
fi

rm -rf "$OUT"
mkdir -p "$OUT/_Computer" "$OUT/games/X816"

cp "$RBF_SRC" "$OUT/_Computer/$RBF_DST"           || exit 1
echo "core   : _Computer/$RBF_DST  ($(stat -c%s "$RBF_SRC") bytes)"

# boot2.rom = the RESIDENT KERNEL, loaded into the write-protected firmware
# region at $F0:0000 (doc/KERNEL.md sections 3 and 7). boot1.rom stays as the
# loadable-shell fallback at $01:0000: boot.s prefers the firmware, so with
# both present the kernel wins, and a build without a kernel still boots.
if [ -n "$CALYPSI" ] && [ -f "$KERNEL_BIN" ]; then
    cp "$KERNEL_BIN" "$OUT/games/X816/boot2.rom"  || exit 1
    echo "kernel : games/X816/boot2.rom       ($(stat -c%s "$KERNEL_BIN") bytes)"
else
    echo "kernel : SKIPPED -- $KERNEL_BIN not built" >&2
fi
if [ -n "$CALYPSI" ] && [ -f "$SHELL_BIN" ]; then
    cp "$SHELL_BIN" "$OUT/games/X816/boot1.rom"   || exit 1
    echo "shell  : games/X816/boot1.rom       ($(stat -c%s "$SHELL_BIN") bytes)"
else
    echo "shell  : SKIPPED -- $SHELL_BIN not built" >&2
fi

# ALWAYS rebuild the card, never "only if missing". It carries the demo
# binaries, so an existing image goes stale the moment the shell is rebuilt --
# the same trap the shell itself fell into three times, and just as silent:
# everything looks fine until /DEMO holds last week's programs.
IMG="$CORE/releases/boot0.img"
echo "card   : building releases/boot0.img"
python "$CORE/tools/mksdcard.py" "$IMG" >/dev/null 2>&1 || {
    echo "card   : SKIPPED -- mksdcard.py failed (pip install pyfatfs)" >&2
    IMG=""
}
if [ -n "$IMG" ] && [ -f "$IMG" ]; then
    cp "$IMG" "$OUT/games/X816/boot0.img"         || exit 1
    echo "card   : games/X816/boot0.img       ($(stat -c%s "$IMG") bytes)"
fi

cat > "$OUT/INSTALL.TXT" <<'TXT'
X816 for MiSTer
===============

Copy the two folders in here onto the root of your MiSTer SD card, merging
with what is already there:

    _Computer/   ->  /media/fat/_Computer/
    games/       ->  /media/fat/games/

Then pick X816 from the Computer menu.

The core comes up at the X816 prompt with no further action -- boot2.rom
(the resident kernel) is auto-loaded into the firmware region, and boot1.rom
(the same prompt as a loadable program) rides along as a fallback. Type HELP.

Colour bands instead of a prompt mean no program was loaded, not a broken
core. In that case open the OSD (F12), choose "Load Image" and pick
games/X816/boot1.rom by hand.

The supplied card is NOT mounted automatically. Mount it once:

    open the OSD (F12) -> "Mount SD" -> games/X816/boot0.img

MiSTer remembers that choice and re-mounts it at every core start from then
on, including across power cycles, so this is a one-time step.

Then type LS at the prompt. LS reporting NO CARD just means nothing is
mounted yet.
TXT

echo "notes  : INSTALL.TXT"
echo
echo "release tree: $OUT"
find "$OUT" -type f | sed "s|$OUT|  .|"
