# X816 on MiSTer — install and use

Building a release tree is one command:

```sh
sh tools/mkrelease.sh
```

It writes `releases/mister/`, which maps 1:1 onto the MiSTer SD card so that
installing is a copy rather than a procedure:

```
releases/mister/
  _Computer/X816_<date>.rbf     the core
  games/X816/boot1.rom          the shell, auto-loaded (confirmed)
  games/X816/boot0.img          starter SD card image (mount once)
  INSTALL.TXT
```

Copy `_Computer/` and `games/` onto `/media/fat/`, merging with what is there,
and pick **X816** from the Computer menu.

---

## 1. The `.rbf` filename is load-bearing

MiSTer's launcher expects `<Name>_<date>.rbf`. A file that does not follow the
pattern misbehaves in ways that look **exactly** like a broken bitstream — black
screen, unresponsive board. That cost an afternoon of RTL debugging on this
project before anyone thought to check the filename.

`mkrelease.sh` derives the name from the bitstream's own modification time, so
it cannot drift. It also picks the **newest** `.rbf` across `output_files/` and
`releases/`, because shipping yesterday's core labelled as today's is
indistinguishable from shipping a broken one.

---

## 2. What the OSD offers

From `CONF_STR` in [X816.sv](../X816.sv):

| Entry | What it does |
|---|---|
| `Mount SD` | attach an `.img` as the guest's SD card |
| `Load Image` | load a `.bin` into flat memory at `$01:0000` |

`Mount SD` is declared `SC0` rather than plain `S`. Only `SC` entries are
remembered and re-mounted by MiSTer Main at core start, so the card you picked
last time comes back by itself; a plain `S` would mount fine and forget by the
next boot.

### Mount the card once; it sticks

**The card is not auto-mounted by name.** Mount it once from the OSD and MiSTer
remembers it from then on, including across power cycles:

> OSD (F12) → **Mount SD** → `games/X816/boot0.img`

The entry is declared `SC0` rather than plain `S`, and that is what makes it
stick: only `SC` entries are remembered and re-mounted by Main at core start. A
plain `S` would mount fine and forget by the next boot.

There is no `bootN.img` equivalent of the `bootN.rom` auto-load, and it is worth
recording the evidence because the symmetry of the names invites the opposite
assumption:

* the reference core `x16_mister` has the same `SC0,IMG,Mount SD` entry and
  **no `boot0` handling anywhere in the repository**, while it *does* decode the
  `bootN.rom` auto-load explicitly — if an image equivalent existed, that is
  where it would be;
* its `CONF_STR` comment states the mechanism directly, from reading Main's
  source: *"Main only remembers and AUTO-REMOUNTS SC entries at core start
  (user_io.cpp checks 'S','C')"*;
* observed here on a clean install: nothing mounted on the first boot, reliable
  on every boot after a manual mount.

All three agree. The file is still called `boot0.img` for symmetry with
`boot1.rom` and because slot 0 is where it mounts — but the name is a label, not
a mechanism.

---

## 3. How a program gets in

The HPS loader writes the file's **byte offset as its flat address**, plus
`PROG_BASE` = `$01:0000`. So an image linked for `$01:0000` lands where it was
linked for, and `boot/boot.s` finds the four-byte magic `"X816"` at the base and
jumps to `$01:0004`.

Two ways in, and they end up at the same place:

* **`boot1.rom`, automatically — CONFIRMED on hardware.**
  [X816.sv](../X816.sv) decodes `ioctl_index == 16'h0040` as MiSTer's
  `bootN.rom` auto-load with N=1. With the shell at
  `/media/fat/games/X816/boot1.rom`, the machine comes up at a prompt with no
  user action at all.
* **OSD → Load Image, by hand.** `ioctl_index[5:0] == 6'd1`. The fallback, and
  how any other program gets loaded today.

If nothing is loaded, `boot.s` falls back to the colour-bands demo. That
fallback is the signal: **bands mean no program, not a broken core.**

### What the confirmed auto-load tells us about `boot0.img`

`boot1.rom` auto-loading from `games/X816/` proves MiSTer Main **does** scan
that directory for the core's boot files, and that the core name derived from
`CONF_STR` (`"X816;;"`) resolves to the folder we expect.

So if `boot0.img` in the *same* folder does not auto-mount on a clean install,
the difference is in Main's mount logic, not in the placement — the directory is
demonstrably being read. The likeliest remaining explanation is that the mount
scan only runs once a core config exists, which would match the observed
behaviour: nothing on the very first boot, reliable from then on.

---

## 4. The starter card

`tools/mksdcard.py` builds `boot0.img` (needs `pip install pyfatfs`):

```
/README.TXT     the command list
/NOTES.TXT      the memory map
/DEMO/GREEN.BIN the smallest possible program: paints the screen green
/DEMO/          the conformance-test images
/PROGS/         empty, for your own
```

This is deliberately **not** `boot/fat32.img`. That one is built awkwardly on
purpose for the FAT32 conformance test — a file spread over 40 clusters with a
position-dependent pattern, so a reader that follows the chain wrongly fails
instead of returning plausible bytes. This one is built to be pleasant to find.

Everything is 8.3 and uppercase. The console font is `$20-$5F` so lower case
folds to upper on screen anyway, and the FAT32 reader skips long filenames — a
file stored only under a long name would be invisible from the prompt.

Mount it once from the OSD — see above — then type `LS`.

---

## 5. First run

```
X816
> HELP                 every command
> LS                   read the card
> TYPE README.TXT
> DUMP 01:0000 40      the shell's own image
> RUN /DEMO/GREEN.BIN  load a program off the card and go
```

The card is WRITABLE, **confirmed on a real MiSTer** -- create, write,
truncate, delete, rename, mkdir and rmdir all run on the board, which means the
SD block device's write command and the whole FAT32 write layer are exercised
on hardware and not only in the emulator:

```
> FILL 03:0000 20 5A
> SAVE /PROGS/TEST.BIN 03:0000 20
> DIR /PROGS
> COPY /PROGS/TEST.BIN /PROGS/BACKUP.BIN
> RENAME /PROGS/BACKUP.BIN OLD.BIN
> DEL /PROGS/OLD.BIN
> MKDIR /PROGS/SUB
> RMDIR /PROGS/SUB
```

`save`, `del` and `copy` do not ask for confirmation, matching `poke` and `fill`. The
FAT32 writer keeps every FAT copy in step and maintains the end-of-directory
marker, so a card written here still reads correctly on a PC -- verified against
pyfatfs rather than against our own reader.

`run` overwrites the shell with the program, which is the point -- KERNEL.md's
EXEC does not return. Reset the core to get the prompt back. `load file [addr]`
puts an image in memory WITHOUT running it, for poking at with `dump`.

**Confirmed on hardware:** `run` loads a program off the card, relocates it over
the shell and starts it, on a real DE10-Nano.

GREEN.BIN is the thing to try first if a program will not start: it is 164 bytes
and touches nothing but VERA, so a green screen means the whole load-and-go path
works and the fault is in the program.

### Keys MiSTer keeps for itself

Four keys never reach the core, because the framework claims them first:

| Key | Taken by |
|---|---|
| F12 | the OSD menu |
| Scroll Lock | switch joystick |
| Num Lock | keyboard/joystick mapping |
| Pause | MiSTer's own use |

Anything bound to one of these **works in the emulator and silently does
nothing on the board** — the worst way for a key binding to fail. F1–F11 are
yours. `KEYSCAN.BIN` deliberately does not ask for these four: pressing one
mid-scan opens a menu over the top of the scan rather than answering it.

`KEYSCAN.BIN` is how the rest were established. It asks for each key by name,
reads the raw byte the SMC sent, and writes the table to `/KEYMAP.TXT` on the
card — readable afterwards with `TYPE /KEYMAP.TXT`. The measured table is in
[KERNEL.md §5.1](KERNEL.md).

**ESC returns to the prompt** from `LIBFS.BIN`, `KFSTEST.BIN`, `KERNTEST.BIN`,
`CHARMAP.BIN` and `KEYSCAN.BIN`. It reloads `/DEMO/SHELL.BIN` and hands over the
way `RUN` does, so reading one result no longer means power-cycling the board to
get to the next.

If keys are dropped or ignored, `games/X816/` also carries `KBDECHO.BIN` and
`KBDSTAT.BIN` under `/DEMO/`. Load either from the OSD: they count keystrokes at
six points between the wire and the glyph, and the first count that falls short
of what you typed names the stage. Two separate keyboard bugs were found that
way — a miscompiled shift in the I2C bit-banging, and a FIFO pop race in
`smc_x16.sv` — after four wrong diagnoses reached from reasoning alone.

Hardware counters at `$9F8D`–`$9F8F` (arrive / pushed / dropped) are read by
those tools; if they read `00` while keys plainly work, the bitstream predates
them and nothing below should be believed.
