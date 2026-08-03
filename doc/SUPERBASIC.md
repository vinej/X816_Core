# SUPERBASIC.md — porting BASIC816 to the X816

Status: **feasibility study, 2026-08-03.** No code exists yet. This document records
why the port is judged feasible, what the obstacles are, and the phased plan.
Companion reading: `DUREXFORTH.md` (the Forth plan, and §1 "Why Forth and not a
BASIC" — see §3.5 below for why that argument only partly applies here).

## 1. Which BASIC

The base is **pweingar/BASIC816** (https://github.com/pweingar/BASIC816), the
65816-native BASIC that shipped on the C256 Foenix. GPLv3, written in 64tass
assembly (`--m65816 --long-address --flat`, Intel HEX or raw binary out).

Naming trap: the thing called "SuperBASIC" in the Foenix world today
(https://github.com/FoenixRetro/f256-superbasic, by Paul Scott Robson) is a
**different codebase written for the 65C02** F256 line. It is not based on
BASIC816 and is not usable on a 65816-native flat-memory machine without a full
rewrite. The port target is BASIC816 itself.

## 2. Why it fits the X816 unusually well

- **Already native-mode 65816 for a flat 24-bit machine.** The C256 build keeps
  program text and heap at `$16:0000-$17:FFFF` with far pointers throughout.
  The usual "a BASIC is 16-bit pointers all the way down" objection does not
  apply.
- **A real porting seam exists.** A `SYSTEM` define selects per-platform
  `mmap_*.s` / `kernel_*.s` / `io_*.s` includes (`src/C256/`, partial
  `src/CBM/`). The core calls a small set of primitives — `SCREEN_PUTC`,
  `GETKEY`, locate/cursor, break-check — that map nearly one-to-one onto the
  kernel jump table at `$00:FE00` (`K_CON_PUTC/GETC/GETKEY/GOTOXY/CLS`).
- **ASCII, not PETSCII.** Our console is ASCII/CP437; `PRINT` needs no
  character translation.
- **Everything it needs already exists and is green on hardware**: 80×60
  console, 16-bit ASCII key events, FAT32 read/write via `K_FS_*` for
  LOAD/SAVE, `MEM_ALLOC` (13.6 MB arena), IRQs, ms clock.
- **Zero RTL changes.** It links at `$01:0000` with the 8-byte `"X816"` header
  and runs like any program. This matters: M10K is at 98%, and a software-only
  port never touches that budget. Interpreter code and BASIC program text both
  land in banks `$01-$04` BRAM — single-cycle memory.

## 3. Obstacles, in order of weight

### 3.1 Math is welded to C256 silicon

Verified in source: `OP_FP_ADD/SUB/MUL/DIV` exist **only** in
`src/C256/floats.s` as pokes to the C256's memory-mapped FP coprocessor
(`FP_MATH_*` registers), and 32-bit integer multiply drives GABE multiplier
registers (`M0_OPERAND_*`) unconditionally. `OP_INT_DIV` is an **empty stub
even on C256** (division presumably routes through floats — audit this), and
the repo's `status.md` is stale. The math layer needs an audit, not just a
port.

The fix is a software math module. BASIC816's float format is
IEEE-754-single-shaped (1 sign, 8 exponent, 23 mantissa bits); software
add/mul/div for that is classic, well-trodden 65816 code. `transcendentals.s`
is polynomial-based (Horner) on top of the primitives and should survive
unmodified.

A C256-compatible coprocessor block in fabric is a tempting *later* option —
it needs ALMs/DSP, not M10K, and ALMs sit at 46% — but it would drag the
emulator, the RTL, and hardware round-trips into what is otherwise a
software-only project. Not for the first pass.

### 3.2 Toolchain

64tass is not installed on this machine. `X816_Library` already treats it as a
known dialect (`build_64tass.ps1`, `tools/acme2tass.py`), so installing it is a
one-time step. The X816 image format needs no Calypsi involvement: 64tass can
emit the raw binary with the 8-byte header directly from source.

### 3.3 The 65,280-byte exec cap

`run` / `K_EXEC` refuse anything over `X816_EXEC_MAX = $FF00`
(`runtime/shell.c` `cmd_run`, `runtime/kexec.c`). The C256 build fits in one
bank so the interpreter is plausibly under the cap — Phase 0 measures it. If
not: ship as `boot1.rom` (uncapped) for bring-up, and/or implement the fix
`exec.s` already documents (outer loop over banks; the size check is in
`cmd_run`).

### 3.4 License

GPLv3. As a standalone program on the SD card (not linked into the kernel)
that is clean as long as source for modifications is published — but the
project has treated licensing as a gating question before (durexForth was
chosen partly for being MIT). Explicit decision required before Phase 1.

### 3.5 The project's recorded position against a BASIC

`DUREXFORTH.md` §1 argues a BASIC's variable table / string heap / GC would
need rewriting for flat memory. That reasoning targets 16-bit-pointer BASICs;
BASIC816 was designed for a flat Foenix and does not need that rewrite. The
Forth plan is unaffected either way (see §6).

## 4. Memory plan

| What | Where | Notes |
|---|---|---|
| Globals / direct page | `$3000` | page-aligned (D alignment rule, `MEMORY_MAP.md`); BASIC816's globals block is ≤256 B |
| Interpreter stacks (return / argument / operator) | inside `$3000-$9DFF` | 3 × 4 KB on C256; fits the application window with room to spare |
| Interpreter code | `$01:0000` (+8-byte header, entry `$01:0004`) | BRAM |
| Program text + heap | `BASIC_BOT` = end of code … `HEAP_TOP` = `$04:FFFF` | ≈190 KB of BRAM after a ~64 KB interpreter |
| Bulk/expansion later | `K_MEM_ALLOC` arena `$20:0100-$DF:FFFF` | 32-block cap → grab one big block and sub-allocate |

Respect the standing carve-outs: `$2000-$2FFF` kernel, `$9E00` guard page
(never a DP base), `$9F00-$9FFF` I/O, `$FE00-$FEFF` jump table,
`$FFE4-$FFFF` vectors. Do **not** park live data in `FarRAM` `$10:0000+` —
that overlaps the EXEC staging area and is clobbered by the next `run`.

## 5. Phased plan

**Phase 0 — probe (half a day, decides everything).** Install 64tass; build
the stock C256 target unmodified; collect three numbers: binary size vs
65,280; count of Foenix kernel call sites; count of VICKY/GABE/coprocessor
register touches. Audit how `/` actually works on C256 given the `OP_INT_DIV`
stub.

**Phase 1 — platform skeleton, REPL in the emulator.** Add `SYSTEM_X816` and
`src/X816/`: `mmap_x816.s` per §4, `kernel_x816.s` binding console/keyboard to
`jsl` calls into `$00:FE00` (carry-flag error ABI; D and DBR preserved by the
kernel). Break = poll `K_CON_GETKEY` for Ctrl-C (`$03`). Milestone: `READY`
prompt and `PRINT 1` under the emulator with `-autokeys` — integer-only is
fine here.

**Phase 2 — math.** Software int32 mul/div/mod and FP
add/sub/mul/div/compare behind the existing `OP_*` names. Drive BASIC816's own
`tests/` through `-autokeys`, with a negative control per the house rule —
this is exactly the layer where stale status docs could hide a vacuous green.

**Phase 3 — files and the full language pass.** LOAD/SAVE/OPEN →
`K_FS_*`, DIR → `K_DIR_*`. Sweep the statement set against the Command Sheet;
stub what is C256-only (sprite/tile statements) and note VERA/VERA2
equivalents as future extensions.

**Phase 4 — hardware.** One change per round trip: first boot as
`boot1.rom`, then as a shell-run `.bin` once size vs the exec cap is settled.
No RTL changes, so the sim suite is not involved — emulator plus board is the
loop.

**Phase 5 (optional, later).** VERA/VERA2 graphics statements; the fabric
math coprocessor only if interpretation speed disappoints.

## 6. Open decisions

1. **Accept GPLv3** into the ecosystem (standalone program → obligations are
   modest, but decide explicitly).
2. **BASIC's place in the boot story.** Recommendation: keep the shell as the
   boot program and launch BASIC from it — leaves the Forth plan undisturbed
   and keeps BASIC an ordinary, replaceable program.
