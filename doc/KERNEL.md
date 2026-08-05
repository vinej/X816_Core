# X816 — kernel specification

A small OS: a console prompt, a filesystem, and program loading. It is what the
core comes up in when nothing else is loaded.

Rows marked **planned** are not implemented. This is the spec, written before
the code, so the emulator and the firmware
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
| `system/irq`, `system/clock` | **kernel** | one vector table, one time source (§11.5) |
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
| `CON_CURSOR` | `C` = 1 blink at the console cursor, 0 off | — |
| `CON_COLOR` | `C` = foreground, `X` = background (0-15) | — |

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

`CON_COLOR` sets the attribute every later `CON_PUTC` writes — foreground in
the low nibble, background in the high one. It is a kernel call rather than a
byte a program pokes because the blinking cursor must undraw with the SAME
attribute: that value was a `#define` in `console.c` and a matching `.equ` in
`ccursor.s`, with a comment warning what happens when the two drift. Making it
settable made drifting the normal case, so there is one `con_attr` now and the
cursor reads it live, deriving its own reversed attribute by swapping nibbles.

`CON_CURSOR` is the policy switch over `runtime/ccursor.s`: a cursor belongs
only at an input point, so a program turns it on around its key WAIT and off
the moment a key is taken — everything printed in between runs cursor-free.
The kernel arms it at boot for its own prompt; durexForth brackets `KEY`'s
poll loop with it. Independent of the switch, `con_scroll` suspends the
cursor for the whole copy: its reversed attribute is the one cell that
breaks scroll's "every attribute is the same" premise, and a blink landing
mid-copy would otherwise be duplicated into the row above and stranded
there — the stray reversed cells that used to litter scrolled output.

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

### 5.6 System and interrupts

| Call | Arguments | Returns |
|---|---|---|
| `SYS_VERSION` | — | `C` = (major << 8) \| minor |
| `IRQ_SET` | `C` = slot, `X` = handler low 16, `Y` = handler bank | `C:X` = the **previous** handler |
| `TIME_GET` | — | `C` = ms low 16, `X` = ms high 16 |
| `TIME_SET` | `C` = ms low 16, `X` = ms high 16 | — |
| `IRQ_FRAMES` | — | `C` = VSYNC frames, 16-bit, wraps |

`SYS_RESET` is named but not numbered; nothing needs it yet.

**One slot per SOURCE, not one per CPU vector.** The 65816 has a single IRQ
vector with seven devices behind it — VERA's VSYNC, raster line, sprite
collision and audio-FIFO-low, both VIAs, and the YM2151 — and deciding which
one fired is the kernel's job. A program that wants a raster split should not
have to service the audio FIFO to get it.

| Slot | | Slot | |
|---|---|---|---|
| `KIRQ_VSYNC` | 0 | `KIRQ_YM` | 6 |
| `KIRQ_LINE` | 1 | `KIRQ_SPURIOUS` | 7 |
| `KIRQ_SPRCOL` | 2 | `KIRQ_NMI` | 8 |
| `KIRQ_AFLOW` | 3 | `KIRQ_BRK` | 9 |
| `KIRQ_VIA1` | 4 | `KIRQ_COP` | 10 |
| `KIRQ_VIA2` | 5 | | |

Slot numbers are ABI. Appending is fine; renumbering is not. Installing `0`
clears a slot, which is why zero is not a legal handler address — nothing can
be executing at `$00:0000`, that is the direct page. `IRQ_SET` returns the
previous handler because a caller cannot reconstruct it afterwards and it
costs nothing to hand back.

**The environment a handler runs in is normative:** native mode, `M=0` and
`X=0`, `D` = `$0000`, `DBR` = `$00`, reached by `jsl` so it must finish with
`rtl`. `A`, `X` and `Y` are free — the dispatcher saved the interrupted code's.

`D = $0000` rather than the kernel's direct page is a decision, not an
accident. It is what the X16 KERNAL does before calling `CINV`, it is what
x16lib's zero-page scratch needs, and above all it does not depend on what was
running when the interrupt landed — a handler that assumed it inherited the
interrupted code's `D` would work until the interrupt arrived during a kernel
call. **A handler must not enable interrupts**; there is one dispatch scratch
pointer and one ISR snapshot.

**The dispatcher touches VERA's `ISR` and `IEN`, the VIAs' `IFR`/`IER`, and the
YM's status — and nothing else.** In particular it never goes near VERA's
address registers or data ports at `$9F20-$9F24`. That is a requirement: an
interrupt can land between a console write setting the VERA address and the
store that uses it, and a dispatcher that reprogrammed the address port would
corrupt the interrupted write with no trace. Handlers get no such protection
for free.

#### The stuck-source defence

Every IRQ source here is **level** sensitive. If one asserts and nothing clears
it, `rti` returns to an instruction that is immediately interrupted again,
forever — a machine that is completely dead with no diagnostic and no way in.
That is the worst failure the kernel can produce, so it is designed out:

| Source | How it is prevented from hanging the machine |
|---|---|
| VSYNC, LINE, SPRCOL | acknowledged by the dispatcher itself, **always**, before any handler runs and whether or not one is installed |
| AFLOW | cannot be acknowledged at all — it clears only when the audio FIFO is refilled. With no handler, its **enable** bit is cleared |
| VIA1, VIA2 | only the VIA's own registers can clear it. With no handler, `$7F` goes to `IER`, disabling all of that VIA's sources |
| YM2151 | with no handler, register `$14` gets `$30`: both timer flags reset and both timer IRQ enables cleared |

Each records a bit in `kirq_disabled`, so a test can prove the defence fired
rather than inferring it from a machine that did not hang. The cost is a
footgun worth naming: **enable a source after installing its handler, never
before**, or the first interrupt turns the source back off.

#### The first thing built on it: the console cursor

`runtime/ccursor.s`, switched on by `ccur_on()` and installed in
`KIRQ_VSYNC`. It is worth reading as the worked example of a handler, because
it has to break the rule stated just above — drawing *is* touching VERA — and
shows what a handler must do instead.

It draws by writing the **reversed attribute** to the cell's second byte, so
the glyph underneath is never touched and "undraw" is a constant rather than
something to remember. That also makes scrolling free: every cell carries the
same attribute, so a scrolled cursor cell needs no fixing up.

It uses VERA's **port 1**, because `console.c` drives everything through port
0 — and it still saves and restores both `CTRL` *and* port 1's address,
because `con_scroll` uses port 1 as its copy destination. The two together
make the handler invisible to a half-finished `con_putc` and to a scroll in
progress. The alternative is a console that corrupts one character in a few
thousand, only while the cursor happens to blink.

`run-cur.sh` (`CURTEST.BIN`, with `--negative`) covers it in five checks: the
cell takes **both** attribute values over time — a cursor drawn once and never
undrawn passes "the attribute is reversed" and is not a cursor; the glyph
survives; it follows the console, settling the cell it left; `ccur_off` leaves
no trace; and text printed **while it is blinking** comes back byte-for-byte,
which is what pays for all the save/restore.

#### The two clocks, and why there are two

`TIME_GET` reads a **free-running hardware counter at `$00:9F90`**
([rtl/ms_timer.sv](../rtl/ms_timer.sv), [MEMORY_MAP.md](MEMORY_MAP.md) §2),
gated by nothing — not `cpu_rdy`, not a chip select. `IRQ_FRAMES` reads a
VSYNC count the dispatcher maintains.

They are different clocks on purpose, and **they disagree during an SD
transfer**: the CPU and both VIAs are frozen for its whole length, so the
frame count stops and the millisecond count does not. Anything measuring
duration wants milliseconds; anything that must not tear — a raster effect, a
page flip — wants frames.

This is the disposition of `doc/AUDIT.md` L-4, which accepted the VIA freeze
on the grounds that nothing kept time yet. Something does now, and it is
built on the one counter the freeze cannot reach. A jiffy count driven from
VERA's VSYNC would not have done: VSYNC is a single latch, so a freeze
spanning four frames still presents one interrupt and the other three are
lost.

`TIME_SET` moves the kernel's **epoch** rather than the counter — the counter
is read-only, and making it writable would have cost a write path into a
register whose entire value is that nothing can perturb it. Reads afterwards
are offset by the difference; 32-bit two's complement wraps correctly, so
setting a time earlier than the hardware count needs no sign anywhere.

**Reading `$9F90` first is normative.** The low byte's read latches bits 31:8
into a shadow that `$9F91-$9F93` return, so two 16-bit reads give one coherent
32-bit value. Read them the other way round and a value straddling a carry
comes back that was never true — and can go backwards.

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

Same shape as the other conformance suites and the toolchain tests: a green
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
8. Interrupts dispatched to the right slot, and both clocks running

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

Test 8 is **written and green** at three levels, because interrupts are the
one subsystem where the RTL, the ABI and the library each have a failure the
other two cannot see.

`X816_Calypsi/examples/kernel/irqtest.c`, run by `run-irq.sh` (with
`--negative`) and shipped as `IRQTEST.BIN`, covers the **ABI** in nine checks:
the four CPU vectors really point at installed trampolines and ABORT does not;
`IRQ_FRAMES` advances, which proves VSYNC is both dispatched *and*
acknowledged; an installed handler runs; `IRQ_SET` reports the previous
handler, and **clearing a slot stops the handler while the frame count keeps
advancing**; `BRK` dispatches and execution *resumes*; `TIME_GET` advances
monotonically and agrees with the frame counter; `TIME_SET` moves the epoch;
an out-of-range slot is refused with `KERR_BADARG`; and AFLOW enabled with
nothing to service it gets disabled rather than locking the machine.

The fourth of those is the one that matters most, and its shape is the lesson.
"An installed handler runs" passes for a dispatcher that calls every slot
unconditionally, or that ignores the table and calls a hard-wired address.
Only *the counter stops when the slot is cleared* separates a dispatcher that
reads the table from one that merely happens to reach the right code — and
requiring the frame count to keep advancing at the same time is what stops
that check being satisfied by interrupts having quietly died.

`sim/run.sh timer` covers the **RTL**, on `rtl/ms_timer.sv` directly: the
divider's rate, the read latch checked *across a carry*, and — the property
the whole device exists for — that the count keeps advancing while `cpu_rdy`
is held low. That last one cannot be tested from software on hardware, because
the software that would look is itself frozen. It is measured twice, stalled
and running, and the two must agree.

`examples/kernel/libirq.s` (`run-libirq.sh`, `--negative`, `LIBIRQ.BIN`)
covers the **library**, and exists for one property neither of the others
reaches: the 8-bit/16-bit crossing running *inward*. Everywhere else in the
tree, 8-bit library code calls a 16-bit kernel; an interrupt handler is the
kernel calling into the library, and the trampolines in `system/x816kernel.asm`
must `sep` down, run 65C02 code, `rep` back and `rtl`. Get that wrong and the
dispatcher's own stack pulls take the wrong number of bytes — silently, and
not where the mistake is.

All three negative controls patch the **code under test**, not the test's
expectation: `run-irq.sh` makes the VSYNC path dispatch through the spurious
slot, `run-libirq.sh` cuts the LINE trampoline before it reaches the library,
and the RTL control gates the counter with `cpu_rdy`. Each was run and each
turned exactly one check red.

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
`runtime/kmem.c`, §5.5), `SYS_VERSION` (48) returning `$0001`, and
`IRQ_SET`/`TIME_GET`/`TIME_SET`/`IRQ_FRAMES` (49–52, `runtime/kirq.s`, §5.6).
Everything else is `k_nosys` — carry set, `C` = `KERR_NOSYS`.
All 64 slots are filled, so calling an unimplemented number is a clean refusal
rather than a jump into whatever bank `$00` happened to contain, and filling a
slot later is not an ABI break.

The table is stamped into `$00:FE00` at run time by `kern_install`, because the
HPS loader only ever writes bank `$01` — bank `$00` comes up as whatever was
there, so the linker cannot place it. The linker script does reserve the page
(HiRAM now stops at `$FDFF`) so no `near` object lands on top of it.

`kirq_install` is a **separate** call and deliberately so: `kern_install` only
writes a table nobody executes until it is called, whereas `kirq_install`
repoints the CPU's own vectors and finishes with `cli`. A program that links
the table privately and does not want interrupts must be able to have one
without the other. `runtime/kernel.h` declares both; `examples/shell/kernelmain.c`
calls both.

**The interrupt vectors cannot live with the rest of the kernel, and that is
structural.** The 65816's native vectors at `$00:FFE4-$00:FFEF` are *sixteen
bits* — the CPU jumps into bank `$00` for every interrupt, full stop, and no
register supplies a bank. The kernel's code is at `$F0:0000`, which a 16-bit
vector cannot name. So `kirq_install` stamps a four-byte `jmp long:`
trampoline into bank `$00` for each vector and points the vector at that:
the same technique `kern_install` and `x816_exec_init` already use, and for
the same reason.

**§3.1's budget is now the binding constraint, and this is what hit it
first.** Measured before `kirq.s` existed, the resident kernel's KernRAM
(`$2100-$2FFF`) was **99% full — 38 bytes free**, against the 92 the vector
table, the trampolines and the dispatch scratch need. But the other half of
the same claim, the kernel's direct page at `$2000-$20FF`, was 7.8% used:
Calypsi's pseudo-registers take 20 bytes of 256 and the remaining 236 were
doing nothing. So `kirq.s` puts its state in `ztiny` when assembled
`-DKERNEL_RESIDENT` and in `near` otherwise — the same assembly-time split
`kerntab.s` makes with `KENTER`/`KLEAVE`, and it required no growth of the
claim and evicted nothing. The next thing to need bank `$00` will not be so
lucky: `shell.o` alone holds 1,372 bytes of initialised `data` there.

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
| `core/sugar` | the `xm_fio_*` macros follow the handle model; `xm_fs_*` changed ARITY with the load redesign (the dead device argument is gone, so old call sites break loudly); `xm_dos_cmd`/`xm_dos_status`/`xm_fs_setname`/`xm_fs_prg_entry` reference things that no longer exist and fail on use |
| `ui/filepick` | its copy path — sixty lines of channel juggling became a read/write loop; then (2026-08-03) `dos_*` ops through the converted dos, double-click timed in milliseconds over `clock_get_ms`, the charset switch removed, and one over-range branch relayed — the first full-gate assembly found both |
| `input/input` | `key_get`/`key_wait` on `CON_GETKEY`/`CON_GETC`; joystick and mouse entries now **report absence** (nothing is wired to the core) instead of jumping into a ROM that is not there |
| `video/screen` | rewritten 2026-08-03: text and cursor through `CON_*`; `screen_set_mode` is native and supports exactly `$00` (the console) and `$80` (320×240×8 bitmap on layer 1 at `SCREEN_BITMAP_BASE`, round-trips without a font reload); the tilemap address math reads **layer 0** — the console's layer, not the X16's; `screen_scode` is identity (CP437: the byte IS the glyph); `screen_color`/`screen_charset` are gone |
| `storage/dos` | converted 2026-08-03 — see §11.6 |
| `storage/bmx` | converted 2026-08-03 — see §11.6 |
| `storage/load` | redesigned 2026-08-03 — see §11.6 |

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

### 11.3 The queue is empty; what remains is parked, loudly

The three modules this section used to list — `dos`, `bmx`, `load` — were
converted 2026-08-03 (§11.6), and with them the last KERNAL call site in any
sourced module. **`const_kernal.asm` and `const_rom.asm` are no longer
sourced by `x16.asm`**; the whole non-parked library assembles without either
symbol table, which was this section's definition of done.

What did not convert got **parked**: its `X16_USE_*` gate is an `!error`
(`#error` on the Calypsi path) naming the replacement, so asking for it is an
assembly failure with an explanation, never code that jumps into a missing
ROM. Parked, and why:

| Gate | Why, and what replaces it |
|---|---|
| `gfx/fb`, `gfx/graph` | X16 ROM graphics wrappers, queued for a retarget onto the library's own `bitmap*`/`shapes` (§6) |
| `gfx/console` | the kernel console is the console — `CON_*`, `video/screen` |
| `input/keyboard` | wrapped the KERNAL key buffer; `input/input` over `CON_GETKEY` is the successor |
| `comms/i2c` | the SMC I²C bus is the kernel's (§2.3) |
| `storage/iec` | no IEC bus |
| `storage/bank`, `bankalloc` | `storage/mem` carries the intent (§11.4) |
| `audio/rom` | wrapped the X16 audio ROM driver; `ym_write` and `audio/zsm` drive the chips directly. `audio/ym`'s ROM note/patch surface went with it |
| `util/float` | wrapped the X16 BASIC ROM float package (`+jsrfar` into `BANK_BASIC` — a dependency the KERNAL-symbol counts missed, because it hid inside a macro); `util/double` and `util/fixed` are self-contained |

The `+jsrfar`/`+set_rambank`/`+set_rombank`/`+rom_call_fast`/`+basic_stub`
macros are deleted outright: on this machine `$00`/`$01` are the C runtime's
pseudo-registers, so a banking macro would not merely do nothing — it would
corrupt the runtime two bytes at a time. `input/mouse` is the one park that
stays callable: its entries **report absence** (position 0,0, no buttons,
joystick absent), which is the X16 API's own word for hardware that is not
there, so filepick and friends run keyboard-only instead of crashing.

### 11.5 `system/irq` and `system/clock` — done

**Converted 2026-08-02**, and both shrank, which is the interesting part.

`irq.asm` chained onto the KERNAL's `CINV`: it took over `$0314`, serviced its
own sources, and jumped to whatever was there before so the KERNAL could still
scan the keyboard and acknowledge VSYNC. Three things went with that model and
none of them came back:

* **No chaining.** The kernel dispatches by source, so a raster handler sits
  in the LINE slot and is never called for anything else. Chaining was the
  answer to one vector shared by every device.
* **Every `sta VERA_ISR` is gone from the handler path.** The old file had to
  acknowledge LINE and SPRCOL itself — *"or the moment the handler returns the
  same interrupt fires again and the machine livelocks"* — because the KERNAL
  only ever acked VSYNC. The kernel acks all three before calling anybody, and
  §5.6's stuck-source defence makes that whole class of hang impossible.
* **The frame counter is the kernel's.** It advances whether or not the module
  was installed, so `irq_frames` and `vsync_wait` work with no `irq_install`
  at all — and the subtle re-read at the end of the old handler, which existed
  because "the KERNAL we chain to acks VSYNC without telling us", went with
  the thing that caused it.

`irq_save_regs` shrank too: it saved the KERNAL's `r0-r15` at `$02-$21`
because every KERNAL call went through them. X816 passes arguments in `C`, `X`
and `Y` and preserves the caller's direct page, so those 32 bytes have no
owner to protect and are no longer copied.

**One thing got harder and is worth naming**: `irq_line_install` now fills the
kernel's slot *before* enabling `VERA_IEN`, because a source that asserts with
no handler installed is disabled by the defence. Arming the hardware first
would work most of the time and fail whenever the scanline came round in
between.

`clock.asm` lost every one of its five entries. `RDTIM`/`SETTIM` carried a
24-bit jiffy count and the kernel's clock is milliseconds, so
`clock_get_timer`/`clock_set_timer` are **not defined at all** rather than
redefined — a port that used them gets an assembly error naming the line,
instead of source that compiles unchanged and runs sixteen times fast. `UDTIM`
is gone because `$9F90` is hardware and there is nothing to tick. The two RTC
calls are gone because there is no RTC; wall-clock time would have to come
from the HPS, and inventing an API here would freeze a shape before the thing
it describes. What replaces them is `clock_get_ms`/`clock_set_ms` (32-bit,
49.7 days before it wraps), `clock_mark`/`clock_elapsed`, and `clock_delay` —
which reads the clock rather than counting instructions, so an SD transfer
mid-delay does not make it run long.

Green in the emulator with a negative control: `run-libirq.sh`, shipped as
`LIBIRQ.BIN`. §8 test 8 describes what it covers and why it is a third test
rather than a repeat of the other two.

**A trap found on the way, since FIXED at the converter (2026-08-03).**
`x16_code.s` derives `X16_USE_IRQ_ANY` from `X16_USE_IRQ` through a chain of
`#ifdef A` → define → `#ifdef B` steps, and `acme2calypsi.py` used to emit the
middle of every such chain as an *assembler* `.equ`, which the C preprocessor
cannot see — so the chain stopped after one link and `system/irq.s` was
silently never included. The converter now emits every `X16_USE_*` symbol as
a `#define` (they are never used as operands, so no assembler symbol is
missed), and `libirq.s` was changed from setting every derived gate by hand to
defining **only the umbrellas** — making that build the standing regression
test: if the chain ever breaks again, it fails with "undefined symbol:
`irq_frames`".

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

**Both now run on `MVN` (2026-08-02), and green on a DE10-Nano** — `LIBMEM.BIN`
on the card, which is where the bank splitting met real SDRAM rather than the
emulator's flat array. Measured 7.0 cycles/byte against the
byte loop's 96.1 for copy and 55.1 for fill — `run-membench.sh`, and
[AUDIT.md](AUDIT.md) §6.2 records the table and the four bugs the rewrite
produced. The overlap decision became a choice of *opcode* (`MVN` ascends,
`MVP` descends) rather than of loop, so the direction logic survived intact.
The 16-bit half is `kern_block_move`/`kern_block_fill` in
`system/x816kernel.asm`, because that file owns `rep`/`sep` and a block move
is inherently 16-bit.

The device-register path stays a byte loop: `MVN` always advances both
pointers, and not advancing is the whole point of a register. And `MVN`'s `X`
and `Y` wrap **within their bank**, so every move is split wherever a side
reaches a boundary — `run-libmem.sh` tests 8 and 9 cover that, including the
case where source and target cross at different points.

Green in the emulator with a negative control:
`X816_Calypsi/examples/kernel/run-libmem.sh`, shipped on the card as
`LIBMEM.BIN` so it also meets the resident kernel. `mem_crc` is checked
against the **published** CRC-16/IBM-3740 value for `"123456789"` (`$29B1`)
rather than against itself, and the negative control patches the *library* —
it disables the copy-direction logic and requires test 5 to catch the smear.
That control earned its keep immediately: the first version of it patched a
file the C preprocessor never read, reported a pass, and proved nothing.

### 11.6 `storage/dos`, `bmx` and `load` — done, and the queue with them

**Converted 2026-08-03.** These were §11.3's whole list; each changed shape
the way its intent demanded rather than keeping the KERNAL's.

**`storage/dos`** kept its names and its `(address, length)` signatures — that
is what filepick and the `+xm_dos_*` macros call — and lost the command
channel: `dos_delete`/`mkdir`/`rmdir`/`chdir`/`rename` copy the name into a
NUL-terminated buffer and call the same `kern_*` entries `fio_*` uses.
`dos_cmd` and `dos_status` are **not defined at all** (there is no drive to
send a string to), and the status convention is the kernel's: 0 or a `KERR_*`
code, carry unchanged. An overlong name is refused up front with
`KERR_BADARG`, and the refusal lands in `dos_code` so `dos_lasterr` does not
answer for the previous command.

**`storage/bmx`** had the most KERNAL calls in the tree and is now the
demonstration that §2.3's "library by inspection" call was right: handles
replaced channels, the 16-byte header is one counted read into memory,
`fio_seek` replaced the byte-loop that drained the palette/pixel gap, and
`READST` vanished because a short read IS the error, reported by the call that
suffered it. `MACPTR`'s stream-to-a-fixed-port trick has no `fio_read`
equivalent — the kernel delivers to ascending memory — so bulk pixels go
through a 255-byte bounce buffer. One new trap, recorded in the module header:
`fio_read`/`fio_write` answer their byte counts in `X16_P6`/`P7`, two of the
registers the caller's VRAM address arrives in, so the target is captured into
module state *before* the first kernel call.

**`storage/load`** was redesigned, not translated (§11.3's old row said it
would be): `fs_load`/`fs_save`/`fs_vload` move **raw whole files** — no PRG
header written or skipped — with 24-bit destinations (`X16_P4` is the bank
now, where `fs_load` used to take the secondary address; a file crossing a
bank boundary keeps loading into the next one). `fs_setname` and
`fs_prg_entry` are not defined: no SETNAM, no BASIC stub — an X816 image
declares itself with its 8-byte header, and launchers use `EXEC`. The
`+xm_fs_*` macros changed **arity** (the dead device argument went away) so
every old call site fails to assemble instead of quietly feeding a device
number into a bank.

Green in the emulator, each proven able to fail: `run-libfs.sh` grew test 7
(the `dos_*` layer end-to-end, including the duplicate-mkdir `KERR_EXISTS`
path and the BADARG refusal — a one-off control that made `dos_rename` lie
was caught by the delete-after-rename check) and test 8 (`fs_save` of 20 KB
of bank `$01`, `fs_load` back into bank `$03` across both arms of the read
loop, CRCs compared, `fs_vload` read back byte-for-byte against the copy via
`mem_peek`, and a missing file refused). Test 8's first version failed
honestly and taught something worth keeping: it saved bank `$00`'s
application area and compared CRCs later, but that region holds the test's
own variables and the runtime's fat32 state, which mutate with every `fio`
call in between — the CRCs disagreed *by construction*. Stable ground for a
round trip is the program's own code, not its data. `run-libbmx.sh` is new:
a save/wipe/load/compare round trip over a real card (chunk seams land on
different pattern values by choice of a 255-coprime recurrence), plus the
FORMAT and IO refusal paths, with a negative control that cuts the pump's
port store and requires the byte compare to notice.

With the queue empty, `x16.asm` stopped sourcing `const_kernal.asm` and
`const_rom.asm` (§11.3), and the C glue (`runtime/x816_glue.s`) went
per-module: every stub sits behind its gate's `#ifdef`, with new wrappers for
`util/zx0`, `video/palette` and `storage/bmx` beside the existing math nine —
`examples/c-lib` proves the palette one end-to-end by reading the written
entry back through the data port.
