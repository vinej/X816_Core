# X816 — toolchain

**Calypsi C** is the toolchain for X816. It is the only actively maintained
high-level compiler that targets the 65816 in **native mode** with a **flat
24-bit address space**, which is exactly and only what this machine is.

Author: Håkan Thörngren. Version 5.18 (released 2026-07-17), actively
maintained. Home: <https://www.calypsi.cc/>.

---

## 1. License — read before committing the project to it

**Free of charge. No purchase, no registration, no time limit, no evaluation
restriction.** The constraint is on *who* uses it, not for how long.

From the [Calypsi-tool-chains](https://github.com/hth313/Calypsi-tool-chains)
README:

> You can use them free of charge for hobby purposes, which means you are not
> allowed to make your living based on using the tools, either directly or
> indirectly.

<https://www.calypsi.cc/> qualifies this: *"a small side or hobby based income
from using the Calypsi tools is permitted."* Commercial use requires explicit
permission from the author (hth313@gmail.com). The BSD exception that permits
free commercial use covers **only the HP-41 Nut target — not the 65816.**

**This binds the project, not just the individual.** Fine while X816 is a hobby
core; revisit if that ever changes.

### What this means for distributing X816 software

The compiler is closed source, but the **runtime you link into your binaries is
not**. Guide §1.2:

> The C library runtime is based on NuttX, which is under the Apache license.

Apache-2.0 is permissive and redistributable, so shipping X816 firmware built
with Calypsi appears clean alongside this repo's MIT/GPL-3.0 licensing. That
reading is from the copyright notice, not from legal advice — **confirm with the
author before distributing binaries.**

### Two things not to put in this repository

* **The toolchain itself** — closed source. Users install it themselves, the
  same as cc65.
* **The PDF guide** — explicitly *"may not be reproduced without the written
  consent from Håkan Thörngren."* Link to the release, do not vendor it.

---

## 2. Install

Releases: <https://github.com/hth313/Calypsi-tool-chains/releases>

| Platform | Asset |
|---|---|
| Debian / Ubuntu | `calypsi-65816-5.18.deb` |
| Fedora / RHEL | `calypsi-65816-5.18-1.x86_64.rpm` |
| Arch / Manjaro | `calypsi-65816-5.18-1-x86_64.pkg.tar.zst` |
| macOS | `calypsi-65816-5.18.pkg` |
| Windows | `calypsi-65816-5.18.zip` |

**All builds are x86-64.** There is no ARM build, so it will not run natively on
Apple Silicon (Rosetta required), on a Raspberry Pi, or on the DE10-Nano's own
HPS. Cross-compiling from a PC is the intended workflow regardless.

Also in each release: `Calypsi65816Guide.pdf` (the reference) and
`ReleaseNotes-65816.md`.

### Tools

| Tool | Purpose |
|---|---|
| `cc65816` | C compiler (one source file → one `.o`) |
| `as65816` | assembler |
| `ln65816` | linker (takes objects, libraries and a `.scm` placement script) |
| `nlib` | librarian |
| `db65816` | debugger, with an on-target agent available |

Object format is ELF/DWARF, so ordinary debugging tooling applies.

---

## 3. Configuration for X816

**Language:** C99 (ISO/IEC 9899:1999), with some C11 extensions enabled by
default (disable with `--pedantic-errors`).

### Code model — use Large

| Model | Function pointer | Limit |
|---|---|---|
| Small | 16-bit | 64K, first bank only |
| Compact | 16-bit | 64K, any bank |
| **Large** *(default)* | **24-bit** | **16 MB** |

Large is both the compiler default and the correct choice: code can live
anywhere in the flat space, with `JSL`/`RTL`/`JML` between banks.

### Data model — use Small

Counter-intuitive, and it is the right answer. From the guide:

> In the small data model all default data is located in the first 64K of
> memory. This allows for using efficient 16 bits pointers, also for functions
> provided in the C library runtime. You can still have data outside the first
> 64K, but you have to use keywords on such objects and pointers to them.

On X816 "the first 64K" is **bank `$00`, which is BRAM** — the machine's only
zero-wait memory. So Small data model means *by default, all data lands in fast
memory and uses cheap 16-bit pointers*, and anything bulk goes to SDRAM only
when you explicitly say so with `__far24`.

**The compiler's default configuration matches this machine's memory hierarchy
without any annotation at all.** That is a better fit than Calypsi gets on the
Foenix machines it ships board support for.

(Note: in the Small data model the `__near` attribute is disabled, since only
bank `$00` is used for default data.)

### Address spaces

| Memory type | Keyword | Address range | Pointer | Index type | Maps to on X816 |
|---|---|---|---|---|---|
| Direct page | `__tiny` | `$00-$ff` | 16-bit | `int8_t` | direct page — bank 0 BRAM, fastest |
| Near | `__near` | `$0000-$ffff` | 16-bit | `int16_t` | one bank via DBR |
| **Far24** | `__far24` | `$000000-$ffffff` | **24-bit** | `int16_t` | **the full flat 16 MB** |
| Far | `__far` | full | 32-bit | `int16_t` | as above, 32-bit pointer |
| Huge | `__huge` | full | 32-bit | `int32_t` | as above, 32-bit indices |

These are type qualifiers, used like `const`:

```c
__tiny  int  counter;              // direct page — BRAM, 3-cycle access
int __far24 *framebuffer;          // 24-bit pointer anywhere in 16 MB
```

`__tiny` + `__far24` together express the idiom described in
[MEMORY_MAP.md](MEMORY_MAP.md): **pointers in direct page, data anywhere.**

### No `--target`

Calypsi's `--target` option exists for C256/F256/SNES and enables hosted
behaviour (and hardware-math codegen on some). X816 has no built-in target, so
builds are **freestanding**: `printf` and friends need I/O primitives you
supply. Not a limitation so much as a reminder that this machine has no KERNAL.

---

## 4. Board support package

A Calypsi board package is remarkably small. The reference to copy is
[Calypsi-65816-F256](https://github.com/hth313/Calypsi-65816-F256) — *"board
support for Foenix F256 with 65816 flat memory"*, the closest existing analogue
to X816 — and it is **two files**: a linker script and a startup module.

### 4.1 Linker script — draft, UNTESTED

Derived from [MEMORY_MAP.md](MEMORY_MAP.md). Nobody has run this yet; treat it
as a starting point, not a working file.

```scheme
(define memories
  '((memory LoMem    (address (#x000000 . #x009eff)) (type ANY))  ; bank 0 BRAM
    (memory IO       (address (#x009f00 . #x009fff)))             ; do not place
    (memory LoMem2   (address (#x00a000 . #x00feff)) (type ANY))  ; bank 0 BRAM
    (memory Vector   (address (#x00ffe4 . #x00ffff)))             ; see below
    (memory Flat     (address (#x010000 . #xefffff)) (type ANY))  ; SDRAM
    (memory Firmware (address (#xf00000 . #xffffff)) (type ANY))  ; SDRAM, WP
    ))
```

**Open question — who owns the vectors.** The F256 script places a `Vector`
region at `$FFE4-$FFFF`, and X816 puts its native vector table at the same
addresses. But on X816 that page is the **boot ROM overlay** at reset: the stub
owns it until it copies itself into the RAM underneath and clears `SYSCTL[0]`
(see [boot/boot.s](../boot/boot.s)). A Calypsi application loaded *after* that
would be overwriting the stub's vectors rather than defining them at link time.

Decide before using the region: either the loaded application installs its
vectors with ordinary stores at run time (and `Vector` is dropped from the
script), or the loader is taught to place a link-time vector block there. The
draft above keeps the region declared but places nothing in it.

### 4.2 Startup module

The F256 `cstartup.s` opens with the same sequence [boot/boot.s](../boot/boot.s)
already uses:

```asm
clc
xce                     ; native mode
rep     #0x38           ; 16-bit registers, decimal cleared
ldx     ##.sectionEnd stack
txs                     ; stack
lda     ##_DirectPageStart
tcd                     ; direct page
...
plb                     ; data bank
```

Two things to carry over when writing the X816 version:

* `rep #$38` also clears the **decimal** flag. Ours uses `#$30`. Reset clears D
  anyway, so this is belt-and-braces — but it is free, and matching Calypsi's
  convention avoids a difference nobody will remember later.
* `_DirectPageStart` comes from the linker. Keep it **page-aligned** — a
  non-zero low byte of D costs one extra cycle on *every* direct-page access
  (see [MEMORY_MAP.md](MEMORY_MAP.md) for the RTL that implements the penalty).

---

## 5. Building

The shape of a build, from the guide's hello-world:

```sh
cc65816 --core=65816 --code-model=large --data-model=small \
        --list-file=obj/main.lst -o obj/main.o src/main.c

ln65816 -o app.elf obj/main.o x816-plain.scm clib-lc-sd.a \
        --list-file=app.lst --cross-reference
```

`clib-lc-sd.a` is the runtime for **l**arge **c**ode / **s**mall **d**ata —
match the library to the two model flags.

Loading onto the machine: the ELF must be converted to a flat image whose byte
offset is its X816 address, then supplied as `boot1.rom` in the core's folder or
through the OSD *Load Image* slot. See [MEMORY_MAP.md](MEMORY_MAP.md) §1.

---

## 6. Open item — the boot ROM still uses ca65

[boot/boot.s](../boot/boot.s) is assembled with **cc65's `ca65`**
(`sh boot/build.sh`), which predates this decision. It works and
`boot/boot.hex` is committed, so the bitstream builds with no toolchain at all.

Worth converting to `as65816` once Calypsi is installed, so the project has a
single toolchain dependency instead of two. The syntax differs — Calypsi uses
`##` for 16-bit immediates, `.section`, `.rtmodel` — so this is a rewrite of the
stub, not a flag change. Not urgent.

---

## Alternatives considered

**Prog8** was evaluated and rejected. Three structural blockers, any one of
which is disqualifying: its README states 65816 CPU specifics are not supported
and the CPU list is 6502/65c02/6510 only; its pointer type is `uword`, i.e.
16-bit, so the memory model tops out at 64 KB; and its answer for going beyond
64 KB is `@bank` annotations driving the Commander X16's bank latches — the exact
mechanism X816 exists to remove. It could be made to work as a 64 KB
emulation-mode target, but that would use 0.4% of the address space and none of
the native-mode CPU.
