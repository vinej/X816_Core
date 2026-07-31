# X816 — kernel specification

A small OS: a console prompt, a filesystem, and program loading. It is what the
core comes up in when nothing else is loaded.

Rows marked **planned** are not implemented. Nothing in this document is built
yet — this is the spec, written before the code the way
[VERA816.md](VERA816.md) was, so the emulator and the firmware can be built
against the same statement rather than against each other.

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
| `gfx/fb`, `gfx/graph`, `video/screen` | library | drawing; touch the KERNAL only to set a mode |
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
| `$00:FF00-$00:FFE3` | X16 compatibility jump table (§6) |
| `$00:FFE4-$00:FFFF` | 65C816 vectors — hardware, not ours to place |

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
| `$FE00-$FFFF` | **kernel** — jump tables and vectors |

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
| `CON_GETC` | — | `C` = character, blocking |
| `CON_GETKEY` | — | `C` = character or 0 if none, non-blocking |
| `CON_CLS` | — | — |
| `CON_GOTOXY` | `C` = column, `X` = row | — |
| `CON_GETXY` | — | `C` = column, `X` = row |

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
| `MEM_ALLOC` | 32-bit size in a block | `C:X` = 24-bit address |
| `MEM_FREE` | `C:X` = address | — |

Flat 24-bit addresses. There is no banking API because there is no banking.

### 5.6 System

`SYS_VERSION`, `TIME_GET`, `TIME_SET`, `IRQ_SET` (`C` = vector index,
`X:Y` = 24-bit handler), `SYS_RESET`.

---

## 6. X16 compatibility shim

Eleven calls, at their X16 addresses, mapped onto §5:

```
SETLFS $FFBA   SETNAM $FFBD   OPEN   $FFC0   CLOSE  $FFC3
CHKIN  $FFC6   CHKOUT $FFC9   CLRCHN $FFCC   CHRIN  $FFCF
CHROUT $FFD2   READST $FFB7   GETIN  $FFE4
```

Those eleven account for roughly half of all KERNAL call sites in x16lib, which
is why the shim is worth having: it keeps the 19 KERNAL-dependent modules
working and keeps porting X16 software easy — the reason the core runs at
8 MHz in the first place.

**The shim is a compatibility layer, not the foundation.** It is implemented on
top of §5, never the reverse. It runs in 8-bit mode as its callers expect, and
converts. Anything it cannot express — a file above bank `$00`, an offset past
64 KB — is a failure the caller sees, not something the native API is bent to
accommodate.

Explicitly **not** provided: IEC (`LISTEN`, `TALK`, `SECOND`, `TKSA`), because
there is no serial bus; the banking calls, because there is no banking; and
`MEMORY_COPY`, because a flat machine's block move is `MVN`.

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

1. Jump tables present and every entry reaching its handler
2. `D` and `DBR` preserved across every call
3. Carry-set/`C`-error reported for a bad handle, a missing path, a full disk
4. Read back what was written, across a sector boundary and past 64 KB
5. Directory enumeration terminating exactly once at the end
6. `EXEC` of a known image landing at its entry point
7. `MEM_ALLOC`/`MEM_FREE` returning distinct non-overlapping ranges
8. Shim: `CHROUT` reaching the console and `CHRIN` reading a file

**A test that cannot fail proves nothing** — each one needs its negative
control, as `run-emu.sh --negative` does in X816_Calypsi.

---

## 9. Order of work

The console and file management both stand on FAT32, so:

1. **SD card** — `spi_sd_master.sv` from the X16 core, and a block-level
   conformance test
2. FAT32 read, then write
3. Native API §5, and its tests
4. Console and prompt
5. The §6 shim, once there is something for it to sit on
