# blit816 — the VRAM fill/copy engine

**Status: normative.** This document is the contract. The RTL
(`vera/fpga/source/blit816.v` plus the DCSEL-33 decode in `top.v`) and the
emulator (`X816_Emulator/src/video.c`) implement it independently, so anything
left ambiguous here will diverge silently — which is exactly how this project
lost weeks to AUDIT.md H-3 and H-4.

**This is the only non-stock register bank in X816's VERA.** Everything else
was returned to stock on 2026-08-02 (the 352 KB VERA816 attempt; its documents were removed on 2026-08-03 and live in git history). The blitter stayed because it does
not depend on a larger VRAM and because it is worth roughly 50× on the one
operation VERA makes expensive.

---

## 1. Why it exists

VERA gives the CPU a single 8-bit data port. Clearing a framebuffer therefore
costs one `sta` per byte:

| | 320×240 8bpp (76,800 B) | 640×200 8bpp (128,000 B) |
|---|---|---|
| CPU through `DATA0`, 4 cyc/byte @ 8 MHz (≈2 MB/s) | ~38 ms | ~64 ms |
| `blit816`, 32 bits per granted VRAM slot @ 25 MHz (≈100 MB/s) | ~0.8 ms | ~1.3 ms |

38 ms is a 26 fps ceiling *before anything is drawn*. That is the difference
between a bitmap mode being usable and not, and it is the whole justification
for the engine.

The 100 MB/s figure is a design analysis — 32 bits per slot at the pixel clock
— not a hardware measurement. `BLITTEST.BIN` proves correctness on real
hardware; nothing has yet measured throughput there.

**What it does not accelerate.** The engine is VRAM→VRAM only. Loading assets
from CPU RAM into VRAM still goes byte-by-byte through `DATA0`. And in the
tile + sprite path the *renderer* does the drawing, so bulk fill barely
appears; this earns its keep in bitmap modes.

---

## 2. Priority — it cannot disturb the display

The engine runs on a fifth, **lowest-priority** `vram_if` port (`if4`). It is
granted the RAM only on cycles when no higher interface strobes:

```verilog
wire if4_grant = if4_strobe && !if0_strobe && !if1_strobe && !if2_strobe && !if3_strobe;
```

So it consumes idle VRAM slots — all of them during blanking, the leftovers
during active display. Scanout, the CPU data port, and both layer renderers
all outrank it.

**The consequence, and it is normative: there is no cycle guarantee.** The
engine is fast, not deterministic. A blit issued during active display on a
busy screen takes longer than the same blit in blanking. Software must poll
`BLT_CTRL` rather than count cycles.

---

## 3. Registers — DCSEL 33

Stock VERA uses DCSEL 0–1 for display control, 2–6 for VERA FX, and 63 for the
version registers. **33 is clear of all of them**, and every register here
resets to `$00`. Stock software never selects DCSEL 33, so it cannot observe
any of this — which is what makes the engine compatibility-safe.

With `CTRL = 33 << 1`:

| Address | Name | Behaviour |
|---|---|---|
| `$9F29` | `BLT_IDX` | R/W: index into the parameter file, 0–9. Only bits [3:0] exist. |
| `$9F2A` | `BLT_DATA` | R/W: the indexed parameter byte. **A write auto-increments `BLT_IDX` (mod 16); a read does not.** |
| `$9F2B` | `BLT_CTRL` | W: bit 0 = start **COPY**, bit 1 = start **FILL**. R: bit 0 = **busy** |
| `$9F2C` | `BLT_ID` | R: **`$B6`** — feature detect |

**Feature detection is `BLT_ID`.** On stock VERA, DCSEL 33 falls through to the
version bank and `$9F2C` reads `VERA_VERSION_PATCH`. Software must check for
`$B6` before writing anything else in this bank: on a stock VERA every write
here lands in the version registers.

If both start bits are set, **FILL wins** (`op_fill_r <= start_fill` in the
RTL; the emulator tests `value & 0x02` first).

### 3.1 Parameter file

All little-endian. Addresses are 17-bit VRAM **byte** addresses; lengths are in
bytes.

| Index | Field |
|---|---|
| 0–2 | `SRC` — bit 16 in the low bit of byte 2, upper 7 bits read 0 |
| 3–5 | `DST` |
| 6–8 | `LEN` |
| 9 | `VAL` — the FILL byte |

Indexes 10–15 read `$00` and discard writes.

`LEN` is 17 bits, so a single operation can cover the whole of VRAM.

---

## 4. Semantics — all normative

* **Byte-granular.** Any `SRC`/`DST` alignment, any `LEN`. The word fast path
  is an optimisation the programmer never has to think about.
* **`LEN = 0` starts nothing.** Busy never rises and the parameter file is left
  exactly as programmed.
* **COPY is ascending.** Overlap is defined only for `DST < SRC` or disjoint
  ranges. The **doubling idiom** — `DST = SRC + LEN`, run repeatedly to grow a
  seed 16 → 32 → 64 → … — is disjoint and is the intended fast-fill pattern
  for a repeating byte sequence.
* **Addresses advance modulo 128 KB**, matching stock VERA's data-port
  auto-increment wrap. A fill at `$1FFFE` of length 4 writes `$1FFFE`,
  `$1FFFF`, `$00000`, `$00001`.
* **`SRC`/`DST`/`LEN` read back as the engine left them** — `LEN = 0`, pointers
  one-past-end, *through* any wrap. This is what lets software confirm an
  operation completed as asked.
* **Parameter writes while busy are ignored.** Poll `BLT_CTRL` bit 0.
* **Writes go through as plain byte writes.** No FX transparency, no 4-bit
  mode, no cache interaction.
* The engine writes VRAM only. It does **not** drive the PSG / palette /
  sprite-attribute windows at `$1F9C0-$1FFFF`; a blit across that range updates
  the VRAM underneath and nothing else. (The CPU data port *does* drive both.)

### 4.1 Timing model in the emulator

The emulator completes a blit **instantaneously** inside the `BLT_CTRL` write,
so `busy` always reads 0. This is permitted: the contract says software must
poll, and a poll loop that exits on its first read is a correct poll loop. It
does mean the emulator cannot be used to measure blit throughput, and cannot
reproduce a race between a blit and the code that started it.

---

## 5. Programming sketch

```c
#define VERA_CTRL     (*(volatile uint8_t *)0x9F25)
#define VERA_BLT_IDX  (*(volatile uint8_t *)0x9F29)   /* DCSEL 33 */
#define VERA_BLT_DATA (*(volatile uint8_t *)0x9F2A)
#define VERA_BLT_CTRL (*(volatile uint8_t *)0x9F2B)
#define VERA_BLT_ID   (*(volatile uint8_t *)0x9F2C)

VERA_CTRL = 33 << 1;
if (VERA_BLT_ID != 0xB6) { /* stock VERA -- fall back to the data port */ }

VERA_BLT_IDX  = 0;               /* nine writes, index auto-increments */
VERA_BLT_DATA = dst & 0xff;      /* ...SRC first (0-2), then DST, then LEN */
/* ... */
VERA_BLT_IDX  = 9;
VERA_BLT_DATA = colour;
VERA_BLT_CTRL = 0x02;            /* start FILL */
while (VERA_BLT_CTRL & 0x01) { } /* poll busy down */
```

---

## 6. Tests

| Where | What it covers |
|---|---|
| `sim/run.sh blit` (`sim/tb_blit816.v`) | RTL against `vram_if` + the real 128 KB `main_ram`: aligned/misaligned fill and copy, the doubling idiom, `LEN=0`, wrap at the top of VRAM, and fill under 50% renderer contention. A behavioural shadow model mirrors every operation. |
| `examples/vera/run-blit.sh` (`blittest.c`) | The same contract through the **register interface** on the emulator, judged by screen colour. `--negative` corrupts the fill expectation and requires the screen to come up in test 2's colour — the proof the test can fail. |
| `BLITTEST.BIN` on the demo card | The only route this has to real hardware. The emulator can prove the contract; only a board proves the bitstream. |

Two traps these tests have already paid for, recorded so they are not
re-learned:

* **`cache_tag_r` width.** The source-word cache tag is 15 bits. Under the
  19-bit VERA816 addressing it was compared against a 17-bit `src_n[18:2]`, so
  a copy crossing a 128 KB boundary could report a false cache hit and move the
  wrong bytes. Narrowing to 17-bit addresses made the widths match exactly and
  retired the bug.
* **A 17-bit loop counter cannot verify a range ending at `$1FFFF`** — `ma + 1`
  wraps to 0 and is still `<= to`. `tb_blit816.v`'s `verify` uses an `integer`
  for exactly this reason. Cost one hung simulation.
