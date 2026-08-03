# X816 — porting durexForth

How to get a Forth prompt on X816, starting from
[vinej/X16_durexforth](https://github.com/vinej/X16_durexforth). **The port
lives in `C:\quartus\projects\X816_DurexForth`** — a clone with history, cut
loose on 2026-08-03.

**Stage A is GREEN ON HARDWARE (2026-08-03).** Confirmed on a DE10-Nano:
`run FORTH.BIN` from the kernel prompt brings up the REPL on the real
keyboard and console. In the emulator, `run-emu.sh` is green with its
negative control: the kernel shell `EXEC`s `FORTH.BIN` off a FAT32 card,
`1 2 + .` answers `3 ok`, `xyzzy` answers `xyzzy?`. No bitstream change was
needed — the image plus the existing kernel firmware are the whole feature.
`FORTH.BIN` ships at the root of `boot0.img` (`tools/mksdcard.py`). The
hardware run also confirms the real RTL handles `(dp),y` with `DBR=$01`
correctly — the case the emulator got wrong below.

Getting from "assembles" to "boots" found four bugs, each recorded in the
port's `7f95e89`: the C64 split-stack indexing relied on 6502 zp,x *page*
wrap (native dp indexing wraps within bank 0); the relocated stack first
landed in `$00-$21`, which §3.1 of [KERNEL.md](KERNEL.md) reserves for the
C-runtime pseudo-registers — and that is enforced by reality, not
convention: the VSYNC cursor handler runs C at interrupt time on exactly
those bytes; the entry shim assumed more than `EXEC` guarantees (D, the I
flag, S); and **the emulator's `(dp)`-indirect modes ignored DBR** — every
program before Forth ran with `DBR=$00`, so the emulator had never been
wrong before (X816_Emulator `a99751b`; the RTL's real 65816 core is
believed correct — the hardware round will confirm).

Two findings changed the plan after work started, both recorded in place:

* **§4.1's converter route is dead, and ACME stays.** `acme2calypsi.py`
  cannot convert this tree: the `BACKLINK` macro builds the dictionary by
  reassigning the program counter at every word definition, which has no
  equivalent in Calypsi's section model. ACME 0.97 assembles the 65816
  natively (verified byte-for-byte), Forth links against nothing, so Calypsi
  buys nothing here — the port keeps the ACME dialect and `BACKLINK`
  verbatim.
* **Hooks come before widening.** With no conversion step in the way, the
  cheapest path to a green REPL is to run the existing 16-bit-cell 8-bit
  Forth against the kernel console first — the whole C64-shaped image
  relocated unchanged into bank `$01` with `PBR = DBR = $01` — and get
  `test.fs` green as a baseline. §7's order (widen, then hooks) assumed the
  conversion pain came first; inverting it means the regression suite exists
  *before* the risky 32-bit widening, not after. Cell widening (§2) is
  unchanged as the goal; it is stage B.

Stage A also paid for four 65816 traps worth knowing about (all fixed in the
port's `d2bec06`): an 8-bit `txs` in native mode zeroes SH and moves the
return stack into the direct page; `jmp (abs)` fetches its pointer from bank
`$00` regardless of DBR; `lda $103,x` stack-frame reads go through DBR to the
wrong bank (stack-relative `lda n,s` is the fix, and is shorter); and the I/O
page is `$00:9F00` while DBR is `$01`, so every VERA word switches DBR around
its body.

**The wait is over (2026-08-03).** Forth's whole value is the interactive
prompt, and its platform hooks are almost entirely console I/O — which is why
this waited on [KERNEL.md](KERNEL.md) §9 steps 1-4. Those are now green: SD
card and FAT32 on hardware, the native API implemented, the console on
hardware, and the shell prompt with `run` behind it ([SHELL.md](SHELL.md)).
One caveat carries over: the keyboard read is verified only in the emulator,
and a Forth REPL is exactly what will exercise it on the board — a dead prompt
there is a console bug before it is a Forth bug.

---

## 1. Why Forth and not a BASIC

A BASIC's memory model *is* its variable table, string heap and garbage
collector, all built on 16-bit pointers. Making one address 16 MB means
rewriting those three things — a new interpreter wearing the old one's syntax.

Forth has none of them. A dictionary, two stacks, and a text input buffer.
Widening addresses touches the cell representation and the words that
dereference, and leaves the rest alone.

durexForth is **MIT licensed**, so unlike the X16 KERNAL question there is no
provenance problem — see [KERNEL.md](KERNEL.md) §6.

---

## 2. Decisions

### 2.1 Cells are 32 bits

Not negotiable on this machine, for a reason that has nothing to do with
arithmetic: **the dictionary lives outside bank `$00`, so `HERE` and every
compilation target is a 24-bit address.** With 16-bit cells the compiler could not express
its own targets without a far-word escape hatch, and `@`/`!` would reach 64 KB
while everything else in the machine is flat — recreating exactly the banking
awkwardness X816 exists to remove.

The cost is real and should be stated: every stack operation moves twice the
data, and a 32-bit `+` is two adds on a 16-bit ALU.

### 2.2 The stack planes widen from bytes to words

This is the part that makes the port tractable rather than a rewrite.
durexForth already splits the data stack into two **byte** planes indexed by X
(`asm/durexforth.asm`):

```
LSB = $41   ; low-byte  stack, [$09 .. $40]
MSB = $79   ; high-byte stack, [$41 .. $78]
```

so `dup` is:

```
DUP  dex
     lda MSB + 1, x
     sta MSB, x
     lda LSB + 1, x
     sta LSB, x
```

On a 16-bit machine with 32-bit cells those become two **word** planes — low
word and high word — and the shape is unchanged. The same instruction count,
with a 16-bit accumulator instead of an 8-bit one. The stack is not
restructured; it is widened.

### 2.3 The dictionary starts in one bank

durexForth compiles **native code**, not threaded tokens: `asm/compiler.asm`
emits `OP_JSR`, `OP_JMP`, `OP_RTS`, `OP_INX` directly. Keeping the whole
dictionary inside one bank means those stay `jsr`/`rts` and the code generator
barely changes.

Since 2026-08-02 the first bank is also the fastest place on the machine:
banks `$01-$04` are single-cycle BRAM ([MEMORY_MAP.md](MEMORY_MAP.md)), so a
one-bank dictionary at `$01:0000` runs with zero wait states.

64 KB of *compiled Forth* is a great deal of Forth, and **data is not subject
to this limit** — 32-bit cells and long addressing reach the whole 16 MB. Take
the 64 KB code ceiling first and treat `jsl`/`rtl` compilation as a later
upgrade, not a prerequisite.

---

## 3. The mechanical mappings

| durexForth (6502) | X816 (65816 native) |
|---|---|
| two **byte** planes, 16-bit cell | two **word** planes, 32-bit cell |
| `lda LSB,x` with 8-bit A | `lda LO,x` with 16-bit A |
| `lda (W),y` | `lda [W],y` — long indirect, reaches 16 MB |
| `W` = 2-byte direct-page pointer | `W` = 3-byte (pad to 4) |
| `PUTCHR = $ffd2` (KERNAL CHROUT) | `CON_PUTC` ([KERNEL.md](KERNEL.md) §5.1) |
| dictionary `$801..$9EFF`, grows down | `$01:0000`+, 24-bit `HERE` |
| `TIB = $600` | bank `$00`, see §5 |

`@` is the pattern for every word that dereferences a Forth address: it copies
the cell into `W` and then does `lda (W),y`. The 65816 provides exactly the
addressing mode needed — `[W],y` — so these convert one line at a time rather
than needing new machinery.

---

## 4. What converts, what does not, what disappears

Measured over the tree: 5,307 lines in `asm/`, 1,458 lines of Forth in
`forth/`, 3,830 lines of Forth tests in `test/`.

### 4.1 Converts mechanically

**The sources are ACME.** 15 files use `!byte`/`!word`/`!zone`/`!macro`, and
`+BACKLINK "drop", 4` is an ACME macro call — the same dialect
`X816_Calypsi/tools/acme2calypsi.py` already converts for 75 library modules,
including anonymous labels, `!zone` and the macro layer.

Expect the same classes of work the library port needed: `dp:` on direct-page
operands, `.word0` on code references, and the code/data section split. Those
rules are already in the converter.

### 4.2 Needs hand work

**`asm/compiler.asm` (308 lines) and the `OP_*` sites** in `control.asm`,
`core.asm`, `io.asm`, `durexforth.asm`. The code generator emits opcodes, so it
has to learn 65816 encodings — and, more subtly, it has to have a **discipline
about the M and X flags**, because compiled code and the primitives must agree
on register widths at every entry and exit. Decide that convention once, write
it down, and make every primitive honour it. Getting this wrong produces
failures that look random.

**The primitives in `core.asm`** — widening is mechanical per word but there
are a lot of words, and each is an opportunity for an off-by-one in the plane
indexing.

### 4.3 Deleted outright

* `asm/bank.asm` (181 lines) and `asm/farcall.asm` (55) — a flat machine has
  no banking. The 16 `RAM_BANK` references go with them.
* `asm/disk.asm`, `asm/romdisk.asm` — CBM DOS and the X16 romdisk, replaced by
  the kernel's file API ([KERNEL.md](KERNEL.md) §5.2).

**The port removes more code than it adds.**

---

## 5. Memory map

Against [MEMORY_MAP.md](MEMORY_MAP.md) and [KERNEL.md](KERNEL.md) §3.1:

| | Where | Why |
|---|---|---|
| data + return stack planes | bank `$00` | indexed every primitive; BRAM is single-cycle |
| `W` and scratch | direct page, bank `$00` | forced there by the architecture anyway |
| TIB | bank `$00` | small, touched constantly |
| dictionary (code + data) | `$01:0000`+ — BRAM to `$04:FFFF`, SDRAM beyond | this is the program, in single-cycle RAM |

Two constraints to check before choosing addresses:

* **The direct page is already spoken for.** `$00:0000-$0021` is the C
  runtime's pseudo-registers and `$00:0022-$0031` is x16lib's scratch
  ([KERNEL.md](KERNEL.md) §3.1). Forth needs its own region, and if it never
  links against either of those it can reuse them — but say so explicitly
  rather than letting it collide by accident.
* **durexForth's stack is only ~56 cells deep** (`$09..$40`). At 32-bit cells
  with two word planes, 256 cells costs 1 KB per stack in bank `$00`. That is
  affordable and worth taking; the original depth was a C64 zero-page
  compromise, not a Forth requirement.

---

## 6. Platform hooks

Small: `CHROUT` 7, `CHRIN` 2, `SETLFS` 5, `SETNAM` 4, `VERA` 18, `RAM_BANK`
16 — about 50 sites in 5,307 lines.

* `CHROUT`/`CHRIN` → `CON_PUTC` / `CON_GETC`
* `SETLFS`/`SETNAM` and the disk words → `FS_OPEN`/`FS_READ`/`FS_CLOSE`
* `VERA` — mostly already direct register access; X816's I/O page is
  byte-for-byte the X16's, so most of these need nothing
* `RAM_BANK` — deleted with the banking

---

## 7. Getting to the prompt

1. **Convert and assemble.** Run `acme2calypsi.py` over `asm/`, fix what falls
   out, and get a clean assembly with no linking yet. Expect the converter to
   handle the dialect and the hand work to be in the code generator.
2. **Widen the stack and cells.** Two word planes, 32-bit cells, `[W],y` for
   dereferences. Do this before the code generator, so the primitives are a
   fixed target.
3. **Retarget the code generator** to 65816 opcodes, with an explicit M/X
   convention.
4. **Point the hooks at the kernel** (§6).
5. **Link as an ordinary X816 program** — the `"X816"` magic at `$01:0000`,
   entry at `$01:0004`, exactly like every conformance test so far. Load it
   from the kernel prompt with `EXEC`.
6. **Only then consider auto-start**: the kernel looking for `FORTH.BIN` at
   boot and running it if present. Making Forth the default shell before it is
   trustworthy would mean a machine that cannot get to a prompt when Forth is
   broken.

The `.fs` sources are a separate question. durexForth compiles them in at build
time via a romdisk; on X816 they should come off FAT32 through the kernel's
file API. **Embed a minimal set in the image first** so bring-up does not
depend on the filesystem, then move to loading from disk.

---

## 8. Testing

durexForth ships **3,830 lines of Forth tests** in `test/`. That is the single
most valuable thing in the repository for this port: a large, independent
conformance suite for behaviour that is easy to break silently while widening
cells.

* Get `test/test.fs` running as early as possible — before the nice-to-have
  words, before disk support.
* The 32-bit cell change wants tests the 16-bit suite does not have: values
  above `$FFFF`, addresses above bank `$00`, and `@`/`!` across a bank
  boundary. Write those.
* Keep the green/red screen convention for anything that runs before the
  console works, as the other conformance tests do, so a failure is visible
  without a working terminal.

**A test that cannot fail proves nothing** — each conformance test needs its
negative control, as `run-emu.sh --negative` does in X816_Calypsi.

---

## 9. Order of work

1. SD card, FAT32, native API, console — [KERNEL.md](KERNEL.md) §9
2. Convert `asm/` with `acme2calypsi.py`; assemble clean
3. Widen cells and stack planes to 32 bits
4. Retarget the code generator; fix the M/X convention
5. Hooks to the kernel console; link as an X816 program
6. `test/test.fs` green
7. File words on the kernel API; `.fs` sources from FAT32
8. Optional: auto-start at boot
