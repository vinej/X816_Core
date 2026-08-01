#!/usr/bin/env python3
"""Build the X816 starter SD card image for MiSTer.

    pip install pyfatfs
    python tools/mksdcard.py [out.img]      # default: releases/boot0.img

This is NOT boot/mkfat32.py. That one builds a deliberately awkward image for
the FAT32 conformance test -- a file spread over 40 clusters with a
position-dependent pattern, so a reader that follows the chain wrongly fails
instead of returning plausible bytes. This one builds something a person would
want to find on the card: readable text, a couple of directories to move
around in, and the demo binaries.

Everything is 8.3 and UPPERCASE on purpose. The console font is $20-$5F, so
lower case folds to upper on screen anyway, and FAT32 long filenames are
skipped by the reader -- a file stored only under a long name would be
invisible from the prompt.
"""
import os
import sys

from pyfatfs.PyFat import PyFat
from pyfatfs.PyFatFS import PyFatFS

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.dirname(HERE)
CALYPSI = os.path.join(os.path.dirname(CORE), "X816_Calypsi")

# boot0.img is a naming convention only -- there is no bootN.img auto-mount.
# The core's Mount SD entry is declared SC0, so the user mounts the image once
# from the OSD and MiSTer Main remembers and re-mounts it at every core start
# -- see doc/MISTER.md and the CONF_STR comment in x816.sv.
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(CORE, "releases",
                                                         "boot0.img")
os.makedirs(os.path.dirname(out), exist_ok=True)

README = """\
X816 -- A FLAT 16 MB 65C816

THIS CARD IS READ AT THE X816 PROMPT.

COMMANDS:
  HELP              LIST EVERY COMMAND
  LS [PATH]         LIST A DIRECTORY
  DIR [PATH]        SAME AS LS
  CD PATH           CHANGE DIRECTORY
  PWD               PRINT THE CURRENT DIRECTORY
  TYPE FILE         SHOW A TEXT FILE
  DUMP ADDR [LEN]   HEX DUMP, 24-BIT ADDRESSES
  PEEK ADDR         READ ONE BYTE
  POKE ADDR VAL     WRITE ONE BYTE
  FILL ADDR LEN VAL FILL A RANGE
  MOVE DST SRC LEN  COPY A RANGE, OVERLAP SAFE
  RUN FILE          LOAD A PROGRAM AND START IT
  LOAD FILE [ADDR]  LOAD WITHOUT RUNNING, TO INSPECT
  SAVE FILE ADDR LEN  WRITE MEMORY OUT AS A FILE
  COPY SRC DST      COPY A FILE
  RENAME OLD NEW    RENAME A FILE OR DIRECTORY
  DEL FILE          DELETE A FILE
  MKDIR PATH        CREATE A DIRECTORY
  RMDIR PATH        REMOVE AN EMPTY DIRECTORY
  CLS               CLEAR THE SCREEN
  VER               VERSION

ADDRESSES ARE HEX AND MAY BE WRITTEN 01:0000 OR 010000.
THE WHOLE 16 MB IS DIRECTLY ADDRESSABLE: THERE IS NO BANKING.

TRY:
  TYPE README.TXT
  CD DEMO
  LS
  RUN GREEN.BIN         PAINTS THE SCREEN GREEN
  RUN CHARMAP.BIN       EVERY CP437 CHARACTER, WITH ITS HEX CODE
  RUN KERNTEST.BIN      KERNEL JUMP TABLE -- GREEN IS PASS
  RUN KFSTEST.BIN       KERNEL FILE CALLS -- GREEN IS PASS
  RUN LIBFS.BIN         X16LIB OVER THE KERNEL -- GREEN IS PASS
  RUN KEYSCAN.BIN       WHAT EVERY KEY SENDS -> /KEYMAP.TXT
  RUN BLITTEST.BIN      VERA BLITTER + SPRITE REACH -- GREEN IS PASS
  RUN SCANOUT.BIN       640X480 8BPP -- EIGHT COLOUR BANDS, TOP TO BOTTOM:
                        WHITE RED CYAN PURPLE GREEN BLUE YELLOW ORANGE.
                        ANY REPEAT BELOW THE PURPLE BAND IS A TRUNCATION.
                        SCANOUT FLASHES A BLACK GAP IN THE PURPLE BAND WHILE
                        IT PAINTS. THAT IS EXPECTED -- IT IS THE REGISTER
                        WINDOW, FILLED BY THE BLITTER AT THE END.
  RUN SCANFULL.BIN      THE SAME PICTURE THE WAY A REAL PROGRAM WOULD DRAW
                        IT: CTRL816.REGWIN SET, ALL 307200 BYTES PAINTED BY
                        THE CPU, NO BLITTER AND NO BLACK GAP AT ALL.
  RUN REGWIN.BIN        REGISTER-WINDOW RELOCATION -- BLUE + ONE SPRITE IS
                        PASS. RED: THE OLD ADDRESS STILL HITS THE PALETTE.
                        LIGHT BLUE OR LIGHT GREEN: THIS BITSTREAM HAS NO
                        CTRL816 YET, SO RECOMPILE BEFORE BELIEVING IT.
                        (NONE OF THESE FOUR HAS ESC: RESET FOR THE PROMPT)

ESC RETURNS TO THE SHELL FROM ANY OF THESE.
  DUMP 01:0000 40

THE CARD IS WRITABLE:
  FILL 03:0000 20 5A
  SAVE /PROGS/TEST.BIN 03:0000 20
  DIR /PROGS
  COPY /PROGS/TEST.BIN /PROGS/BACKUP.BIN

/DEMO HOLDS THE CONFORMANCE TEST IMAGES. RUN THEM FROM HERE.
RUN REPLACES THE SHELL, SO RESET THE CORE TO GET THE PROMPT BACK.
"""

NOTES = """\
X816 IS NATIVE MODE ONLY. NO EMULATION MODE, NO 64K BANKS.

BANK 00      0000-9EFF  FAST BRAM: DIRECT PAGE, STACK, DATA
             9F00-9FFF  I/O
             A000-FEFF  MORE BRAM
BANK 01+     SDRAM, WHERE PROGRAMS LOAD AND RUN

A LOADED IMAGE STARTS WITH THE MAGIC X816 AND A JUMP AT 01:0004.
"""

# Demo images worth having on the card. Missing ones are skipped rather than
# fatal: this script has to work in a checkout that has not built them.
DEMOS = [
    # Smallest possible proof that RUN works: paints green, touches nothing
    # else. First thing to try when a program will not start.
    ("GREEN.BIN",  os.path.join(CALYPSI, "examples", "shell", "greentest.bin")),
    # Every CP437 glyph in a 16x16 grid, plus drawn boxes to show they join.
    ("CHARMAP.BIN", os.path.join(CALYPSI, "examples", "shell", "charmap.bin")),
    # Kernel jump table conformance: green if every $00:FE00 entry behaves.
    ("KERNTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "kerntest.bin")),
    # The filesystem half of the table, and then the same ground through the
    # converted x16lib. Both WRITE to the card -- they create and remove their
    # own directory, and kfstest leaves /KEEP.TXT behind on purpose.
    ("KFSTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "kfstest.bin")),
    ("LIBFS.BIN",   os.path.join(CALYPSI, "examples", "shell", "libfs.bin")),
    # Asks for every key the 64-entry keymap cannot express -- F-keys, the
    # arrows, the keypad, the right-hand modifiers -- and writes what the SMC
    # actually sent to /KEYMAP.TXT. Those codes are DISCARDED before any
    # program sees them today, so they cannot be found any other way.
    ("KEYSCAN.BIN", os.path.join(CALYPSI, "examples", "shell", "keyscan.bin")),
    # VERA816 conformance: the blitter (doc/VERA816.md 4.3), the sprite reach
    # above 128 KB (5.1) and the firmware write-protect (KERNEL.md 3). This is
    # the only route those three have to real hardware -- the emulator can
    # only ever prove the contract, not the bitstream. Unlike the others it
    # does not link the console, so ESC does not return: reset for the prompt.
    ("BLITTEST.BIN", os.path.join(CALYPSI, "examples", "vera", "blittest.bin")),
    # VERA816 conformance test 5 (doc/VERA816.md 8): a 640x480 8bpp picture,
    # which is the mode the whole 352 KB exists for and the one thing no test
    # displayed until 2026-08-01. Eight colour bands top to bottom; bands 4-7
    # are fetched from above 128 KB, so a truncated renderer repeats the top
    # of the screen from line 205 down. Judge it BY EYE -- there is no green
    # verdict, the picture IS the verdict. Same as BLITTEST: no console, so
    # reset for the prompt.
    ("SCANOUT.BIN", os.path.join(CALYPSI, "examples", "vera", "scanout.bin")),
    # VERA816 conformance test 8 (doc/VERA816.md 4.4/8): CTRL816.REGWIN moves
    # the PSG/palette/sprite-attribute windows out of the framebuffer's way,
    # which is what makes the whole 352 KB plain VRAM for real programs.
    # BLUE screen with one sprite = pass; RED = the stock address still
    # reaches the palette; other colours are named in run-regwin.sh. On a
    # bitstream without CTRL816 it paints LIGHT GREEN and stops -- that is
    # feature detection working, not a failure of the card.
    ("REGWIN.BIN", os.path.join(CALYPSI, "examples", "vera", "regwin.bin")),
    # The same 640x480 test as SCANOUT.BIN, built with USE_REGWIN=1: it sets
    # CTRL816.REGWIN and paints all 307,200 bytes with the CPU data port, no
    # blitter. Same eight bands -- but WITHOUT the black gap that flashes
    # through the purple band, because there is no window to paint around.
    # That difference is the whole point of section 4.4, and it is the way a
    # real program should drive this mode.
    ("SCANFULL.BIN", os.path.join(CALYPSI, "examples", "vera", "scanfull.bin")),
    ("SHELL.BIN",  os.path.join(CALYPSI, "examples", "shell", "shell.bin")),
    ("SHTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "shtest.bin")),
    ("KBDECHO.BIN", os.path.join(CALYPSI, "examples", "shell", "kbdecho.bin")),
    ("KBDSTAT.BIN", os.path.join(CALYPSI, "examples", "shell", "kbdstat.bin")),
]

with open(out, "wb") as f:
    f.truncate(64 * 1024 * 1024)

fat = PyFat()
fat.mkfs(out, fat_type=PyFat.FAT_TYPE_FAT32, sector_size=512, label="X816")
fat.close()

fs = PyFatFS(out)
fs.writetext("/README.TXT", README)
fs.writetext("/NOTES.TXT", NOTES)
fs.makedir("/DEMO")

added = 0
for name, path in DEMOS:
    if not os.path.exists(path):
        print("  skipped (not built): " + name)
        continue
    with open(path, "rb") as src, fs.open("/DEMO/" + name, "wb") as dst:
        dst.write(src.read())
    added += 1
    print("  added: /DEMO/" + name)

fs.makedir("/PROGS")
fs.writetext("/PROGS/PUT.TXT", "PUT YOUR OWN PROGRAMS HERE.\n")
fs.close()

print("%s: %d bytes, %d demo image(s)" % (out, os.path.getsize(out), added))
