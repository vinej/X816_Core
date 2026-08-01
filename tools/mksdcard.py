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

# boot0.img, because MiSTer auto-mounts it into slot 0 when it is present.
# The name is the mechanism, not decoration -- see doc/MISTER.md.
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
