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
  RUN FORTH.BIN         DUREXFORTH, A FORTH REPL ON THE KERNEL CONSOLE.
                        TRY: 1 2 + .        (EXPECT: 3 OK)
                        NO ESC YET: RESET THE CORE FOR THE PROMPT.
  TYPE README.TXT
  CD DEMO
  LS
  RUN GREEN.BIN         PAINTS THE SCREEN GREEN
  RUN CHARMAP.BIN       EVERY CP437 CHARACTER, WITH ITS HEX CODE
  RUN KERNTEST.BIN      KERNEL JUMP TABLE -- GREEN IS PASS
  RUN KFSTEST.BIN       KERNEL FILE CALLS -- GREEN IS PASS
  RUN IRQTEST.BIN       INTERRUPTS AND BOTH CLOCKS -- GREEN IS PASS
  RUN CURTEST.BIN       THE CONSOLE CURSOR -- GREEN IS PASS
  RUN LIBIRQ.BIN        X16LIB IRQ/CLOCK OVER THE KERNEL -- GREEN IS PASS
  RUN BANKBNCH.BIN      WHAT EXECUTING FROM SDRAM COSTS. FOUR HEX NUMBERS:
                          TIME(BANK 01)  0001  TIME(BANK 00)  0000
                        THE SAME LOOP, RUN FROM SDRAM THEN FROM BRAM.
                        THE 0001/0000 ARE THE BANK IT REALLY RAN IN.
                        ESC RETURNS TO THE PROMPT.
  RUN MEMBENCH.BIN      BLOCK-MOVE TIMINGS. NOT PASS/FAIL: SIX HEX NUMBERS,
                        MILLISECONDS FOR 4 X 32 KB, IN THIS ORDER --
                          LIBCOPY W16COPY MVNCOPY LIBFILL W16FILL MVNFILL
                        LIBCOPY AND MVNCOPY SHOULD MATCH: THE LIBRARY USES
                        MVN NOW. W16 IS A 16-BIT LOOP, FOR COMPARISON.
                        ESC RETURNS TO THE PROMPT.
  RUN LIBFS.BIN         X16LIB OVER THE KERNEL -- GREEN IS PASS
  RUN KEYSCAN.BIN       WHAT EVERY KEY SENDS -> /KEYMAP.TXT
  RUN BLITTEST.BIN      VERA BLITTER FILL/COPY -- GREEN IS PASS
                        (NO ESC: RESET FOR THE PROMPT)
  RUN V2DEMO.BIN        VERA2 640X480 4BPP. NEEDS THE OSD "VERA2 BITMAP
                        LAYER" SWITCH SET TO ON. EXPECT 16 VERTICAL COLOUR
                        BANDS, A WHITE BAR TOP, A BLUE BAR BOTTOM, AND A
                        STRAIGHT DIAGONAL. A BENT OR REPEATING PICTURE MEANS
                        THE LINE STRIDE IS WRONG. NOTHING HAPPENING MEANS THE
                        OSD SWITCH IS STILL OFF. (NO ESC: RESET)
  RUN FXTEST.BIN        VERA FX AFFINE -- PRINTS CYCLES PER PIXEL

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
    # MEM_ALLOC/MEM_FREE, doc/KERNEL.md section 8 test 7. Seven checks, and
    # every one writes through the address the kernel handed back -- an
    # allocator that returns plausible addresses backed by nothing passes
    # every arithmetic test there is. Green = pass; run-mem.sh names the
    # colours. On the card it meets the RESIDENT kernel, which is the one
    # thing the emulator run cannot cover: there it links a private copy.
    ("MEMTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "memtest.bin")),
    # IRQTEST is on the card for a reason MEMTEST is not: the millisecond
    # counter it cross-checks is REAL HARDWARE (rtl/ms_timer.sv), and the
    # frame rate it is checked against is the real 59.52 Hz VERA frame.
    ("IRQTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "irqtest.bin")),
    ("CURTEST.BIN", os.path.join(CALYPSI, "examples", "shell", "curtest.bin")),
    # The same ground through the reshaped x16lib memory API -- mem_alloc,
    # mem_fill, mem_copy (including an overlapping range), mem_crc against a
    # published check value. On the card it runs against the RESIDENT kernel;
    # run-libmem.sh links a private copy.
    ("LIBMEM.BIN",  os.path.join(CALYPSI, "examples", "shell", "libmem.bin")),
    ("LIBIRQ.BIN",  os.path.join(CALYPSI, "examples", "shell", "libirq.bin")),
    # MEMBENCH is not a pass/fail test: it prints six timings. It is on the
    # card because 7.0 cycles/byte is an EMULATOR figure -- uniform memory,
    # no SDRAM wait states -- and only the board says what MVN really costs.
    ("MEMBENCH.BIN", os.path.join(CALYPSI, "examples", "shell", "membench.bin")),
    # BANKBENCH answers a question the emulator CANNOT: its memory is
    # uniform, so it reports 1.00x by construction. Only the board has
    # BRAM and SDRAM to tell apart.
    ("BANKBNCH.BIN", os.path.join(CALYPSI, "examples", "shell", "bankbench.bin")),
    # Asks for every key the 64-entry keymap cannot express -- F-keys, the
    # arrows, the keypad, the right-hand modifiers -- and writes what the SMC
    # actually sent to /KEYMAP.TXT. Those codes are DISCARDED before any
    # program sees them today, so they cannot be found any other way.
    ("KEYSCAN.BIN", os.path.join(CALYPSI, "examples", "shell", "keyscan.bin")),
    # Blitter conformance (doc/BLIT816.md) and the firmware write-protect
    # (KERNEL.md 3). This is the only route those two have to real hardware --
    # the emulator can only ever prove the contract, not the bitstream. Unlike
    # the others it does not link the console, so ESC does not return: reset
    # for the prompt.
    #
    # 2026-08-02: SCANOUT / SCANFULL / SCAN4 / REGWIN used to ship here too.
    # All four needed the removed 352 KB VERA816 attempt (git history); their
    # job -- high resolution on a real screen -- is V2DEMO's now.
    ("BLITTEST.BIN", os.path.join(CALYPSI, "examples", "vera", "blittest.bin")),
    # VERA2, the SDRAM bitmap layer (doc/VERA2.md). 640x480 4bpp, judged BY EYE
    # -- there is no green verdict, the picture is the verdict. Needs the OSD
    # "VERA2 Bitmap Layer" switch On; with it Off the program detects $9F61 =
    # $00 and leaves VERA's screen alone rather than going black, which is
    # feature detection working and not a failure.
    ("V2DEMO.BIN",  os.path.join(CALYPSI, "examples", "vera", "v2demo.bin")),
    # FX affine: six correctness checks against a C reference, then it PRINTS
    # the measured cycles per pixel -- worth taking on real hardware where the
    # CPU timing is the real one rather than the emulator's model of it.
    ("FXTEST.BIN",  os.path.join(CALYPSI, "examples", "vera", "fxtest.bin")),
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

# durexForth (X816_DurexForth) goes at the ROOT, not /DEMO: `run FORTH.BIN`
# works straight from the prompt, and the root is where the kernel's future
# auto-start would look (X816_core doc/DUREXFORTH.md, order of work step 8).
forth = os.path.join(os.path.dirname(CORE), "X816_DurexForth", "build",
                     "forth.bin")
if os.path.exists(forth):
    with open(forth, "rb") as src, fs.open("/FORTH.BIN", "wb") as dst:
        dst.write(src.read())
    added += 1
    print("  added: /FORTH.BIN")
else:
    print("  skipped (not built): FORTH.BIN")

fs.makedir("/PROGS")
fs.writetext("/PROGS/PUT.TXT", "PUT YOUR OWN PROGRAMS HERE.\n")
fs.close()

print("%s: %d bytes, %d demo image(s)" % (out, os.path.getsize(out), added))
