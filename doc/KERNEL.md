# X816 — kernel specification

A small OS: a console prompt, a filesystem, and program loading. It is what the
core comes up in when nothing else is loaded.

Rows marked **planned** are not implemented. This is the spec, written before
the code the way [VERA816.md](VERA816.md) was, so the emulator and the firmware
could be built against the same statement rather than against each other — and
much of it is built now: §9 carries per-item status (console, SD and FAT32 are
green on hardware) and §10 records what is built today.

---

## 1. What this is, and what it is not

The kernel exists to do four things no program can do for itself:

* arbitrate the SD card and its filesystem, so two programs cannot corrupt it
* hold state that outlives a program — open files, the working directory,
  allocated memory, installed interrupt handlers
* be present *before* any program is loaded, so that something can do the
  loading
* own the console when no program has taken the screen

Everything else belongs in the library. That is not a stylistic preference; §2
gives the test and §2.3 applies it.

**Not in scope.** Multitasking, memory protection, user accounts, networking.
One program runs at a time and owns the machine while it does. The kernel is
the thing it returns to.

---

## 2. The boundary — kernel or library

The single most consequential decision in this document, so it gets decided by
rule rather than case by case.

### 2.1 The two tests

Apply in order:

1. **Would two programs each having their own copy corrupt something?**
   → kernel. The open-file table, FAT allocation, the memory allocator, the
   interrupt vectors, the keyboard buffer, the SMC I²C bus. There can only be
   one FAT32 writer.

2. **Would forcing one implementation on every program be wrong?**
   → library. Line drawing, PRNG, compression, fixed-point arithmetic,
   sprites. If a program might reasonably want a *different* version, a kernel
   call is the wrong home: it freezes one choice for every program ever
   written.

**The default is library.** Promote only when test 1 forces it. The costs are
asymmetric: a kernel entry costs a permanent jump-table slot, permanent bank
`$00` state, and an ABI that can never change. Library code costs nothing until
a program links it.

### 2.2 Policy, not mechanism

Most of the hard cases dissolve here. FAT32 *parsing* is mechanism and can live
in a library the kernel links; deciding **who owns file handle 3** is policy and
only that needs a kernel call. The kernel arbitrates who owns the text screen;
glyph blitting is library.

So a kernel call should be the narrowest thing that establishes ownership, and
everything above it should be ordinary linked code.

### 2.3 Applied to x16lib

Of the 67 library modules, **48 touch no KERNAL at all** and are library by
inspection. The rule only has to decide the other 19:

| Module | Where | Why |
|---|---|---|
| `storage/dos`, `dir`, `fileio`, `load` | **kernel** | one FAT32 owner; state outlives the program |
| `storage/bank`, `mem` | **kernel** | the allocator — but reshaped, see below |
| `system/irq`, `system/clock` | **kernel** | one vector table, one time source |
| `input/keyboard` (buffer), `comms/i2c` | **kernel** | the SMC I²C bus is shared with the keyboard |
| `gfx/console` | **kernel** | owns the prompt's screen when no program has taken it |
| `storage/bmx` | library | a *format* parser; its 36 KERNAL calls are all "give me the next byte" |
| `gfx/fb`, `gfx/graph` | library | thin wrappers over the X16's ROM graphics — retargeted onto the library's own primitives, §6 |
| `video/screen` | library | mode setting |
| `ui/filepick`, `input/mouse`, `input/input` | library | per-program UI and polling |
| `storage/iec` | **dropped** | there is no IEC bus on X816 |

`storage/bmx` is the case that shows the rule working: it has the most KERNAL
calls of anything in the tree and is still clearly a library.

**Port the intent, not the shape.** Several of these modules exist only to work
around the X16's 64 KB banking. `storage/bank`'s window management has no
reason to exist on a flat 16 MB machine — it becomes a plain allocator handing
out 24-bit addresses.

---

## 3. Where the kernel lives

| Range | Contents |
|---|---|
| `$F0:0000-$FF:FFFF` | kernel code and constant tables — the firmware region, HPS-loaded, write-protected |
| `$00:2000-$00:2FFF` | kernel state and its direct page |
| `$00:FE00-$00:FEFF` | native jump table — 64 entries × 4 bytes |
| `$00:FFE4-$00:FFFF` | 65C816 vectors — hardware, not ours to place |

`$00:FF00-$00:FFE3` is deliberately **not** claimed; see §6.

**Buffers go in SDRAM, not bank `$00`.** FAT32 wants a 512-byte sector buffer
per open file plus a FAT cache; that is exactly the kind of thing that would
eat the machine's only fast memory. Bank `$00` holds the hot state — the handle
table, the cursor, the keyboard queue — and nothing that scales with the number
of open files.

### 3.1 Bank `$00` budget

Bank `$00` is 64 KB, permanently, and is the scarce resource
([MEMORY_MAP.md](MEMORY_MAP.md)). The kernel's claim on it is normative:

| Range | Owner |
|---|---|
| `$0000-$0021` | application — C runtime pseudo-registers |
| `$0022-$0031` | application — x16lib scratch (`X16_P0`..`X16_T7`) |
| `$0032-$00FF` | application — free direct page |
| `$0100-$1FFF` | stack |
| `$2000-$2FFF` | **kernel** — state, and the kernel's own direct page at `$2000` |
| `$3000-$9DFF` | application |
| `$9E00` | guard page — never allocate as a direct page |
| `$9F00-$9FFF` | I/O |
| `$A000-$FDFF` | application |
| `$FE00-$FEFF` | **kernel** — native jump table |
| `$FF00-$FFE3` | application — freed by dropping the X16 shim (§6) |
| `$FFE4-$FFFF` | CPU vectors |

The kernel gets **4 KB plus two pages**. If it needs more than that, the design
is wrong; move it into the firmware region or into an SDRAM buffer.

---

## 4. Calling convention — normative

Every kernel entry is reached by `jsl` through the jump table and returns with
`rtl`. That is what lets the kernel live in bank `$F0` while callers run
anywhere in the 16 MB.

**On entry:** native mode, `M=0`, `X=0` — 16-bit accumulator and index
registers. This is the X816 convention everywhere; there is no 8-bit entry
point.

**Arguments:** up to three 16-bit values in `C`, `X`, `Y`. A 24-bit pointer
occupies `C` (low 16 bits) and the low byte of `X` (bank). Anything larger, or
any call with more than three arguments, passes a pointer to a parameter block
instead — see §5.3.

**Returns:** carry clear on success with the result in `C`; **carry set on
failure with an error code in `C`**. Every call reports this way, including the
ones that cannot currently fail, so that adding a failure mode later is not an
ABI break.

**Preserved:** `D` and `DBR`. A kernel call may clobber `A`, `X`, `Y` and the
flags. The kernel switches to its own direct page on entry and restores the
caller's before returning — a program must never have to know the kernel uses
direct page at all.

**Not preserved:** nothing else. In particular the kernel does not preserve the
x16lib scratch at `$0022-$0031`; a program that cares must save it.

---

## 5. Native API

Names are indicative; the normative part is the shape — flat 24-bit addresses
and 32-bit file offsets throughout. **This is the reason not to build on the
X16 KERNAL**: its API passes 16-bit addresses and cannot express "load this
file at `$07:0000`" at all.

### 5.1 Console

| Call | Arguments | Returns |
|---|---|---|
| `CON_PUTC` | `C` = character | — |
| `CON_PUTS` | `C:X` = 24-bit pointer to a NUL-terminated string | — |
| `CON_GETC` | — | `C` = key, blocking |
| `CON_GETKEY` | — | `C` = key, or 0 if none, non-blocking |
| `CON_CLS` | — | — |
| `CON_GOTOXY` | `C` = column, `X` = row | — |
| `CON_GETXY` | — | `C` = column, `X` = row |
| `CON_PUTRAW` | `C` = column, `X` = row, `Y` = glyph code | — |

**A key is sixteen bits, and the top byte is what makes it unambiguous:**

| `C` | Meaning |
|---|---|
| `$0000` | nothing waiting (`CON_GETKEY` only) |
| `$0001`–`$00FF` | a **character**, CP437 |
| `$0100 \| n` | a **key with no character**, `n` = its position number |

F1 and the CP437 glyph at `$70` cannot be told apart in eight bits, and a
program legitimately receives both. Rather than invent control codes for the
keys that lack characters — a table that would have to be kept in step with
nothing — the key number is reported directly, so the low byte is exactly what
`KEYSCAN.BIN` measures and the two cannot drift.

The SMC sends **IBM key position numbers**, not ASCII and not PS/2 scancodes.
Bit 7 set is a key-up. Measured on a DE10-Nano with `KEYSCAN.BIN`; every value
agrees with `rtl/smc_x16.sv` and with the emulator's
`keynum_from_SDL_Scancode`.

| Key | | Key | | Key | |
|---|---|---|---|---|---|
| ESC | `$6E` | INS | `$4B` | KP0 | `$63` |
| F1-F11 | `$70`-`$7A` | DEL | `$4C` | KP1 | `$5D` |
| PRTSCR | `$7C` | HOME | `$50` | KP2 | `$62` |
| TAB | `$10` | END | `$51` | KP3 | `$67` |
| CAPS | `$1E` | PGUP | `$55` | KP4 | `$5C` |
| LSHIFT | `$2C` | PGDN | `$56` | KP5 | `$61` |
| RSHIFT | `$39` | UP | `$53` | KP6 | `$66` |
| LCTRL | `$3A` | DOWN | `$54` | KP7 | `$5B` |
| RCTRL | `$40` | LEFT | `$4F` | KP8 | `$60` |
| LWIN | `$3B` | RIGHT | `$59` | KP9 | `$65` |
| RWIN | `$3F` (*) | KP / | `$5F` | KP . | `$68` |
| MENU | `$41` | KP * | `$64` | KP - | `$69` |
| LALT | `$3C` | KP ENTER | `$6C` | KP + | `$6A` |
| RALT | `$3E` | | | | |

(*) Right GUI is `$3F` per the RTL. The keyboard used for the scan has no such
key -- both the RWIN and MENU prompts answered `$41` -- so that one value comes
from the RTL and everything else in this table was actually pressed.

**The keypad IS distinct from the top row**, which was the open question: KP1 is
`$5D` while the top-row 1 is `$02`. A program can tell them apart; the keymap
chooses not to, mapping both to `'1'`, and NumLock does not turn the keypad into
the navigation keys the way a PC does.

**Four keys never arrive on MiSTer.** The framework claims them before the core
sees them:

| Key | Taken by |
|---|---|
| F12 | the OSD menu |
| Scroll Lock | switch joystick |
| Num Lock | keyboard/joystick mapping |
| Pause | MiSTer's own use |

Binding any of them works in the **emulator** and silently does nothing on the
board, which is the worst way for a binding to fail. F1–F11 are yours.
`KEYSCAN.BIN` does not ask for these four: pressing one during a scan does not
merely fail to answer, it opens a menu over the top of the scan.

`CON_PUTRAW` places a glyph by code and interprets nothing. `CON_PUTC` has to
intercept `$08`, `$0A` and `$0D` as backspace, newline and return, which makes
those three glyphs unreachable through it — and CP437 has real pictures there.
Anything drawing with box, block or control-code glyphs wants this instead.

### 5.2 Filesystem

| Call | Arguments | Returns |
|---|---|---|
| `FS_OPEN` | `C:X` = path, `Y` = mode | `C` = handle |
| `FS_CLOSE` | `C` = handle | — |
| `FS_READ` | parameter block | `C` = bytes read |
| `FS_WRITE` | parameter block | `C` = bytes written |
| `FS_SEEK` | parameter block | new offset |
| `FS_SIZE` | `C` = handle | 32-bit, in the block |
| `FS_DELETE` | `C:X` = path | — |
| `FS_RENAME` | parameter block | — |
| `DIR_OPEN` | `C:X` = path | `C` = handle |
| `DIR_NEXT` | `C` = handle, `X:Y` = entry buffer | carry set at end |
| `DIR_CLOSE` | `C` = handle | — |
| `FS_CHDIR` | `C:X` = path | — |
| `FS_GETCWD` | `C:X` = buffer | — |
| `FS_MKDIR`, `FS_RMDIR` | `C:X` = path | — |

Paths are NUL-terminated ASCII with `/` separators, absolute or relative to the
working directory. Not PETSCII, and no device numbers or secondary addresses —
those are CBM concepts that exist because of the IEC bus, which this machine
does not have.

### 5.3 Parameter block

Any call taking more than three arguments, or a 32-bit one, is passed a
24-bit pointer in `C:X` to a block of little-endian fields. Reserved fields
must be written as zero so that later revisions can define them.

### 5.4 Program loading

| Call | Arguments | Returns |
|---|---|---|
| `EXEC` | `C:X` = path | does not return on success |
| `EXIT` | `C` = exit status | does not return |

`EXEC` loads an image with the existing `"X816"` magic at its base and its
entry point four bytes in — the same format
[boot/boot.s](../boot/boot.s) already recognises and that every image built by
X816_Calypsi already carries. `EXIT` returns control to the prompt.

### 5.5 Memory

| Call | Arguments | Returns |
|---|---|---|
| `MEM_ALLOC` | `C` = size low 16, `X` = size high 16 | `C:X` = 24-bit address |
| `MEM_FREE` | `C:X` = address | — |

Flat 24-bit addresses. There is no banking API because there is no banking.

**The size is a register pair, not a parameter block** — an earlier draft of
this table said "32-bit size in a block", and it was changed before anything
implemented it. Three reasons, in order of weight:

1. A parameter block would make the one call whose job is *"I have nothing,
   give me something"* require the caller to already have twelve bytes of
   writable memory to describe the request. That is a bootstrapping wart
   nothing else in this ABI has.
2. §4's own rule admits "up to three 16-bit values in `C`, `X`, `Y`". A 32-bit
   size is two of them, so the block was never required.
3. `FS_SIZE` already carries a 32-bit value as `C` plus `X`. The split is an
   established convention here, not a new one.

The cost is that `MEM_ALLOC` can never grow a fourth argument without a new
call number. That is accepted: alignment and zeroing are the plausible
candidates, and both are better served by a library over one big block than
by a flag every caller has to pass.

**What it hands out.** `$20:0000-$EF:FFFF`, from `X816_HEAP_BASE` — banks
`$20-$EF`, 13.6 MB. Everything below already has an owner: `$00` is BRAM,
`$01-$0F` is the program image, `$10-$1F` is `FarRAM` and the `EXEC` staging
area. `tools/contract.py --check` verifies that the linker scripts and the
arena still meet exactly, with no gap and no overlap, because a disagreement
there would hand a program its own `far` data as scratch.

**Granularity.** Sizes round up to one page and every returned address is
page-aligned — a 65816 direct page must be page-aligned to avoid a cycle
penalty on every `dp` access, and a caller taking a block to use as one should
not have to align it again.

**A fixed table, not a free list.** `X816_HEAP_BLOCKS` live allocations, held
in one page at `X816_HEAP_TABLE` that `MEM_ALLOC` never hands out. Boundary
tags — a header immediately before each block — would put the bookkeeping one
byte past the end of what the caller was given, so the commonest overrun there
is would corrupt the allocator and surface in a later, unrelated call. Exceeded
cleanly with `KERR_NOSPACE`. A program needing a thousand small objects takes
one block and sub-allocates: that is a library's job by §2.1's second test, and
the policy is one the kernel has no business freezing.

Nothing is zeroed, and there is no `realloc`.

### 5.6 System

`SYS_VERSION`, `TIME_GET`, `TIME_SET`, `IRQ_SET` (`C` = vector index,
`X:Y` = 24-bit handler), `SYS_RESET`.

---

## 6. No X16 compatibility shim

An earlier draft of this document specified one: eleven CBM calls (`SETLFS`,
`SETNAM`, `OPEN`, `CLOSE`, `CHKIN`, `CHKOUT`, `CLRCHN`, `CHRIN`, `CHROUT`,
`READST`, `GETIN`) at their X16 addresses in the vector page, mapped onto §5.
**That was wrong, and the numbers say so.**

Count what a shim would actually still be serving. The 19 KERNAL-dependent
x16lib modules split into the twelve that §2.3 moves *into* the kernel — those
get rewritten and need no shim — and seven that stay library. Across those
seven there are 104 KERNAL call sites, and the eleven-call shim covers **54**.
The other **50** are the X16's ROM graphics library (`FB_*`, `GRAPH_*`),
`MOUSE_*`, `JOYSTICK_*`, `SCREEN_MODE`, `PLOT` and PETSCII.

So every one of those modules has to be converted anyway. A shim would only
shrink the diff inside files already being edited, in exchange for a permanent
cost: 228 bytes of the vector page, a stateful CBM channel model (logical file
numbers, device and secondary addresses, a global "current channel") leaking
into a handle-based kernel, an ABI frozen forever, and two ways to do
everything for library modules to disagree about.

Nor does it buy much outside the library. Porting an X16 *application* means a
new load address and image format, no banked RAM at `$A000`, no ROM at
`$C000`, PETSCII to ASCII, and native-mode direct-page arithmetic that wraps
within the bank rather than within the page. Against all that, the I/O calls
are a small share of the work.

**What replaces it.** X816_Library is converted to call §5 directly. The
conversion is cheaper than it looks, because most of the 50 uncovered calls do
not want a kernel at all:

| Calls | Retargeted onto |
|---|---|
| file and console (54) | §5.1 and §5.2 |
| `FB_*`, `GRAPH_*` (≈35) | the library's own primitives — `bitmap2h/4l/8h`, `shapes` already implement line, rect, circle, pset, fill, blit and char in software |
| `MOUSE_*`, `JOYSTICK_*` (≈12) | the hardware directly, as library code |
| `SCREEN_MODE`, `PLOT`, PETSCII (≈10) | `video/screen`, as library code |

`gfx/graph` and `gfx/fb` are thin wrappers over the X16's ROM graphics; on
X816 they point at code the library already contains. Test 2 of §2.1 says
graphics primitives are library, so routing them through a kernel would have
been the wrong answer regardless of the shim question.

If X16 porting help is wanted later, the right shape is **source-level macros**
in the library — `+chrout` expanding to a native call — not a runtime jump
table. Zero runtime cost, no bank `$00` claim, and no ABI commitment.

Consequently `$00:FF00-$00:FFE3` is **not** reserved; only the CPU vectors at
`$00:FFE4-$00:FFFF` are.

---

## 7. Boot sequence

1. Reset. The boot overlay is mapped at `$00:FF00`; `boot.s` runs as it does
   today.
2. The overlay copies itself out of the vector page and clears `SYSCTL[0]`.
3. **New:** if the firmware region carries the kernel's magic, jump to its
   entry. Otherwise fall through to step 5.
4. The kernel installs both jump tables, brings up console and SD, and prints
   the prompt.
5. **Unchanged fallback:** if there is no kernel, look for the `"X816"` magic
   at `$01:0000` and jump to `$01:0004`.

Step 5 is deliberately preserved. Every test image built so far — `libtest.bin`,
`ctest.bin`, the VERA and SDRAM conformance tests — boots that way, and they
must keep working with no kernel present, because they are what proves the
machine before the kernel is trusted.

---

## 8. Conformance tests

Same shape as [VERA816.md](VERA816.md) §8 and the toolchain tests: a green
screen means pass, one colour per failing test, and a result byte for a
debugger. Both the emulator and the hardware must pass before anything is built
on the kernel.

1. Jump table present and every entry reaching its handler
2. `D` and `DBR` preserved across every call
3. Carry-set/`C`-error reported for a bad handle, a missing path, a full disk
4. Read back what was written, across a sector boundary and past 64 KB
5. Directory enumeration terminating exactly once at the end
6. `EXEC` of a known image landing at its entry point
7. `MEM_ALLOC`/`MEM_FREE` returning distinct non-overlapping ranges

**A test that cannot fail proves nothing** — each one needs its negative
control, as `run-emu.sh --negative` does in X816_Calypsi.

Test 7 is **written and green**: `X816_Calypsi/examples/kernel/memtest.c`,
run by `run-mem.sh` (with `--negative`) and shipped on the card as
`MEMTEST.BIN`. "Distinct non-overlapping ranges" is the weakest property
worth checking — an allocator that returned the same address every time would
fail it and almost nothing else would — so it is one of seven, and every one
of them **writes through the address the kernel returned and reads it back**.
An allocator that hands out plausible, disjoint, page-aligned addresses backed
by nothing passes every arithmetic check there is; only a store-and-load
distinguishes an allocator from an address generator. The seven are: a first
allocation is aligned and backed; three live blocks are pairwise disjoint; a
freed block is reused at *exactly* its own address; the refusals (zero,
oversized, unaligned free, free of a non-block, double free) each report the
right `KERR_`; a refused allocation leaves the heap byte-identical; the table
fills, refuses with `KERR_NOSPACE`, and recovers completely; and filling eight
adjacent blocks disturbs none of them — which is the check that would find
bookkeeping living inside the arena.

---

## 9. Order of work

The console and file management both stand on FAT32, so:

1. **SD card** — **done and green on hardware**: `rtl/sd_block.sv`, a DMA
   block device rather than the X16's SPI emulation (see
   [MEMORY_MAP.md](MEMORY_MAP.md)), with `boot/sdtest.s` green on a DE10-Nano
   and in the emulator
2. FAT32 read **done and green on hardware** — `runtime/fat32.c` in
   X816_Calypsi, with `examples/fat32` green on a DE10-Nano. Write is next.
3. Native API §5, and its tests
4. Console **done and green on hardware** (output; the keyboard read is
   still unverified there) — `runtime/console.c` in X816_Calypsi. Then
   the prompt: [SHELL.md](SHELL.md)
5. Convert X816_Library to §5 (§6) — file and console calls first, then
   retarget `gfx/fb` and `gfx/graph` onto the library's own primitives

---

## 10. What is built today

The table exists and is green in the emulator: `runtime/kerntab.s` and
`runtime/kernel.h` in X816_Calypsi, tested by `examples/shell/kerntest.c`.

Both of those are now generated from one source. The call numbers in
`kernel.h` and the 64 rows of `kern_proto` in `kerntab.s` used to be two
hand-kept lists — one giving each call a NUMBER, the other giving it a
POSITION — with nothing checking that entry 21 in one was entry 21 in the
other. A mismatched pair produces no diagnostic anywhere: the program jumps to
a real, working, wrong routine. Adding or moving a call now means editing the
`CALLS` table in `X816_core/tools/contract.py`, which emits both.

**Implemented:** the eight console entries 0–7, the fifteen filesystem
entries 16–30, `EXEC` (32, `runtime/kexec.c`) and `EXIT` (33, a guarded
restart through the firmware entry), `MEM_ALLOC` and `MEM_FREE` (40/41,
`runtime/kmem.c`, §5.5) and `SYS_VERSION` (48) returning
`$0001`. Everything else is `k_nosys` — carry set, `C` = `KERR_NOSYS`.
All 64 slots are filled, so calling an unimplemented number is a clean refusal
rather than a jump into whatever bank `$00` happened to contain, and filling a
slot later is not an ABI break.

The table is stamped into `$00:FE00` at run time by `kern_install`, because the
HPS loader only ever writes bank `$01` — bank `$00` comes up as whatever was
there, so the linker cannot place it. The linker script does reserve the page
(HiRAM now stops at `$FDFF`) so no `near` object lands on top of it.

**Residency — FIXED as of 2026-08-01.** The kernel now ships as a firmware
image: `runtime/x816-kernel.scm` links the shell into banks `$F0+` (magic at
`$F0:0000`, entry `$F0:0004`, state and direct page in the §3.1 claim at
`$2000-$2FFF`), `examples/shell/build.sh` emits it as `kernel.bin`, and
`tools/mkrelease.sh` ships it as `games/X816/boot2.rom` — HPS-loaded (ioctl
index `16'h0080`) and **write-protected** by the core (`x816.sv` `fw_region`).
`boot/boot.s` checks the firmware magic before the `$01:0000` fallback (§7),
every kernel entry switches to the kernel context and back (`kerntab.s`
`KENTER`/`KLEAVE`, assembled with `-DKERNEL_RESIDENT`), and `run` erasing
`$01:0000` no longer touches the code the table points at. Proven in
simulation (`X816_core/sim/run.sh fw` — firmware branch + write-protect on
real RTL), in the emulator (`examples/shell/run-fwboot.sh` — boot to
prompt from `$F0:0000`, with a corrupted-magic negative control), and
**confirmed green on a DE10-Nano on 2026-08-01** with the bitstream of that
date. The loadable-shell path stays as boot1.rom fallback, and the interface
did not change — which was the point of fixing the interface first.

### 10.1 Calling it from C

Assembly callers just `jsl $00FExx` with a constant. C cannot: the entry number
is a variable and the 65816 has no `jsl` through a pointer. `runtime/kcall.s`
synthesises it — `phk` / `per` to push an `rtl`-shaped return address, then
`jmp [abs]`, the one transfer that takes its target from memory. `per` rather
than `pea` keeps it position independent, which matters the moment the kernel
moves banks.

Its arguments travel in globals — `kern_c`, `kern_x`, `kern_y`, and `kern_carry`
on return — rather than as parameters, because **Calypsi's argument passing
changes with arity and with type**. Measured from `cc65816 -S`, not assumed:
argument one is in `A`; a second 16-bit argument is pushed; a third is pushed
too, before the second; but a `__far` pointer ignores all of that and travels in
the direct-page pseudo-registers `_Dp` and `_Dp+2` whatever position it holds.
A shim that reverse-engineers that per signature is a shim that breaks — and
this one did, twice, before the rule was measured rather than inferred. One
parameter is unambiguous under every variant: it is in `A`.

Test 4 of `kerntest.c` is the negative control §8 asks for: it calls an
unimplemented entry and fails unless carry comes back set with `KERR_NOSYS`.

---

## 11. Converting x16lib — where it has got to

§2.3 decided which modules belong where; this is how far the work has run.
Source of truth is X816_Library `src_acme/`, regenerated into X816_Calypsi
`src/` by `tools/acme2calypsi.py`.

### 11.1 One crossing, not ninety

x16lib is 65C02 code and runs with A, X and Y eight bits wide. The ABI above is
16-bit. `src_acme/system/x816kernel.asm` is the only file that crosses it —
every converted module calls a `kern_*` routine there, and `rep`/`sep`/`jsl`
appear nowhere else in the tree.

That is not tidiness. A module that switches register width itself has to
switch it back on **every** path including the error ones, and a missed `sep`
does not crash: it leaves 65C02 code executing with 16-bit registers, reading
and writing one byte too many, with the symptom appearing somewhere else
entirely.

The crossing file also contains **no 16-bit immediates**. `lda #$1234`
assembles to a different length depending on the accumulator width, so an
assembler must be told which is in force and emits the wrong length silently if
that tracking drifts. Every value goes through zero page instead, where the
addressing mode is identical either way.

**Nothing survives in X or Y across a kernel call.** They carry ABI arguments.
A 65C02 programmer holds a loop counter in X by reflex, and that is now a bug —
it cost one test failure while writing `libfs.s`.

### 11.2 Converted

| Module | What changed |
|---|---|
| `core/const_kernel` | new — the `$00:FE00` entry numbers, replacing `const_kernal`'s `$FFxx` |
| `system/x816kernel` | new — the 8-bit/16-bit crossing |
| `storage/fileio` | rewritten on **handles**; the channel model is gone |
| `storage/dir` | rewritten on `DIR_*`; the BASIC-listing parser is gone |
| `core/sugar` | the `xm_fio_*` macros follow the handle model |
| `ui/filepick` | its copy path — sixty lines of channel juggling became a read/write loop |
| `input/input` | `key_get`/`key_wait` on `CON_GETKEY`/`CON_GETC` |
| `video/screen` | `screen_puts` on `CON_PUTC` |

What a caller notices: no device numbers, no secondary addresses, no logical
file numbers, no `CHKIN`/`CHKOUT`/`CLRCHN`, and no `READST` — status is per
call and per handle rather than a machine-wide byte describing whichever
channel was last selected. `dir_next` now returns `.` and `..`; FAT32 has no
file type, so everything that is not a directory reports `DIR_TYPE_PRG`. Keys
arrive as **ASCII, not PETSCII** — the two agree on digits and punctuation and
disagree on case, which is the way round that makes a bug quiet.

Green in the emulator, both with a negative control:
`X816_Calypsi/examples/kernel/run-libfs.sh` drives `fio_*` and `dir_*` over a
real card and then has pyfatfs check what is on it;
`examples/asm-lib/run-emu.sh` still passes, so the conversion did not disturb
the rest of the tree.

### 11.3 Not converted yet, and why

| Module | Blocked on |
|---|---|
| `storage/load` | **No longer blocked** — this row said "`EXEC` is not implemented" and that stopped being true when `K_EXEC` landed (§10). What remains is the redesign it also names: `LOAD`/`SAVE` carry PRG headers, BASIC `SYS` stubs and VRAM loads through `LOAD`'s A register, none of which describe this machine. The X816 answer is `EXEC` plus flat addresses, so the module's interface changes rather than its innards — same shape as `fileio`, which is done. |
| `storage/dos` | the DOS command channel: `"S:FILE"` strings sent to a drive. The native equivalents are `FS_DELETE`, `FS_RENAME`, `FS_MKDIR`, so the module's whole *interface* changes. |
| `storage/bmx` | ~30 `CHRIN`/`READST` sites. Mechanical — `fio_getc` and `fio_read` are already there — but 942 lines, and it is a library either way (§2.3). |
| `system/irq`, `clock` | need `IRQ_SET` and the time source (§5.6), neither of which exists. Note L-4 in `doc/AUDIT.md` before designing the clock: SD transfers freeze the VIAs, so a VIA-derived time source drifts with card activity. |

`core/const_kernal.asm` is still sourced, so those four still assemble against
the KERNAL symbols. Removing it is the last step, not the first: a build that
had to choose between the two tables could not contain a module halfway
between them.

### 11.4 `storage/bank`, `bankalloc` and `mem` — done, by collapsing them

**Converted 2026-08-01**, and the shape changed rather than the names, which
is what §2.3 means by *port the intent, not the shape*.

`storage/bank` managed the 8 KB window at `$A000`; `storage/bankalloc` was a
bitmap handing out bank **numbers** to map into it. The window, `RAM_BANK`,
"offset 0..8191", the copies that auto-advance across bank boundaries — every
one of those exists to work around 64 KB of address space, and this machine
has 16 MB. There is no window to map, so there is nothing to select, so a bank
number is not a thing to allocate.

So all three collapse into one `storage/mem`:

| X16 | X816 |
|---|---|
| `bank_alloc` / `bank_free` | `mem_alloc` / `mem_free` — over `MEM_ALLOC`/`MEM_FREE` |
| `bank_peek` / `bank_poke` | `mem_peek` / `mem_poke`, 24-bit, no window |
| `mem_to_bank`, `bank_to_mem`, `bank_copy_far`, `mem_copy` | `mem_copy` — the distinction was window-versus-flat |
| `bank_set` / `bank_get` | gone; nothing to select |
| `bank_alloc_init` / `bank_reserve` | gone; the kernel owns the pool |
| `mem_fill`, `mem_crc` | reimplemented natively — there is no KERNAL to wrap |
| `mem_decompress` | **dropped**: it was one instruction of x16lib and 700 of X16 ROM. A decompressor is not a memory routine, `util/zx0` already provides one, and §2.1 says choosing a compression format is the program's call. |

`bank.asm` and `bankalloc.asm` stay in the tree but are out of the
`X16_USE_STORAGE` bundle — pay-per-use, like `storage/iec`, and they describe
a machine this is not.

Two properties were kept deliberately. Addresses in `$00:9F00-$00:9FFF` are
**not** advanced, so a copy or fill streams through VERA's data port with no
staging buffer — the one genuinely useful thing about the KERNAL originals.
And `mem_copy` handles overlap by direction, which is the only reason it is
more than a byte loop.

Green in the emulator with a negative control:
`X816_Calypsi/examples/kernel/run-libmem.sh`, shipped on the card as
`LIBMEM.BIN` so it also meets the resident kernel. `mem_crc` is checked
against the **published** CRC-16/IBM-3740 value for `"123456789"` (`$29B1`)
rather than against itself, and the negative control patches the *library* —
it disables the copy-direction logic and requires test 5 to catch the smear.
That control earned its keep immediately: the first version of it patched a
file the C preprocessor never read, reported a pass, and proved nothing.
