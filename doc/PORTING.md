# X816 — porting notes

Source project: `c:\quartus\projects\x16_mister` (Commander X16 for MiSTer, v1.4).
This project: a **flat 16 MB, native-mode-only 65C816 machine**. It reuses the
X16 core's peripherals and the MiSTer framework; it does **not** reuse its
architecture, and it cannot run X16 software.

---

## Why none of the X16 software carries over

The X16's 256 KB system ROM — KERNAL, BASIC, CBDOS, FAT32, GRAPH, the lot — is
8-bit 65C02 code built entirely around two hardware bank latches (`$0000` =
RAM bank, `$0001` = ROM bank) and the `$A000-$BFFF` window they page. A flat
model has no latches and no window, so every one of those 256 KB is dead here.
The FPGA work in this repo is a few weeks; **writing the software stack is the
actual project.**

What *is* preserved is the I/O page layout: `$00:9Fxx` is byte-for-byte the
X16's, so VERA, VIA and YM2151 register offsets — and any driver written
against them — port over unchanged.

---

## What was reused, and how much changed

| Block | Files | Change |
|---|---|---|
| VERA (video, audio, SPI) | 24 | **6 files widened** — the VERA816 extension: 352 KB VRAM, 19-bit addresses ([VERA816.md](VERA816.md)) |
| IKAOPM (YM2151) | 11 | none |
| VIA 6522, SMC, I²C, PS/2 bridge | 6 | `smc_x16.sv` — key-FIFO pop-race fix (silently ate keystrokes; found on hardware) + debug taps |
| `sdram.v` (MiST byte controller) | 1 | none |
| `x16_periph.sv` (snes_pad, i2s_rx) | 1 | none |
| MiSTer framework `sys/`, PLL IP | all | none |
| P65C816 core (X16-fixed fork) | 7 | none |
| CPU wrapper | 1 | **rewritten** — 24-bit |
| Memory system | 3 | **new** |
| Top level | 1 | **new** |

The PLL IP is carried over unmodified, so no IP regeneration is needed:
25.0 MHz pixel / 12.5 MHz spare / 8.0 MHz CPU / 100.0 MHz SDRAM.

---

## The three architectural pieces

### 1. `rtl/cpu/65C816/p65c816_flat_wrap.vhd`

The X16 wrapper did `addr <= a24_int(15 downto 0)` and threw the bank byte
away. This one exposes all 24 bits — the bank byte *is* the address. `VPB` is
dropped (it existed only to force the X16's ROM-bank latch to 0 during vector
pulls; there is no latch here), and `RDY_OUT` is brought out as `wait_state`
since the '816 implements WAI/STP natively.

`bus_valid` (VDA|VPA) is retained and every chip select is qualified with it.
This is not optional: on internal cycles `A_OUT` carries in-flight address
math — ghost addresses that, undecoded, fire VERA's data-port auto-increment
and the VIA's flag clears. Write cycles are deliberately exempt from the
qualification, because dropping a write whose VA flag mis-synthesises made
'816 `STA abs,X` writes vanish on X16 silicon while being perfect in sim.

### 2. Memory

```
$00:0000-$00:9EFF   bank0_ram.sv    64 KB M10K, single cycle
$00:9F00-$00:9FFF   I/O page
$00:A000-$00:FEFF   bank0_ram.sv
$00:FF00-$00:FFFF   boot_rom.sv overlay (reads) / bank0_ram.sv (writes)
$01:0000-$FF:FFFF   flat_sdram.sv   SDRAM, stalls the CPU per access
```

**Bank 0 is in BRAM on purpose.** The 65816 forces the stack *and* direct page
into bank 0 no matter what DBR/PBR hold, so every JSR/RTS, interrupt, push/pull
and dp-addressed operand lands there. Backing it with single-cycle BRAM takes
the stall out of the hottest paths. The split is invisible to software.

**`flat_sdram.sv`** is `ext_ram_sdram.sv` with every X16 client (cart loader,
cart backer, bitmap framebuffer stream, blitter) stripped out. Three things in
it are load-bearing and documented in its header — read that before touching
the `ready` expression.

### How `sdram.v` actually maps addresses — read this before changing anything

`sdram.v` takes a 25-bit address but decomposes it unusually (lines 164-167):

```verilog
sd_ba   <= addr[22:21];        // bank
sd_addr <= addr[20:8];         // row
caddr   <= {addr[23], addr[7:0]};   // column (addr[23] is the column MSB)
bt      <= addr[24];           // byte lane WITHIN the 16-bit word
```

So **`addr[23:0]` is a word address and `addr[24]` picks the byte lane.**
Consecutive byte addresses land in *different words*, not in the two lanes of
one word.

`flat_sdram` currently drives `acc_addr = {1'b0, cpu_a}`, i.e. lane 0 of word
`cpu_a`. That is correct, but it has two consequences:

* **each CPU byte consumes a whole 16-bit word**, wasting the high half — this
  is the real reason a **32 MB or larger** module is required for a 16 MB flat
  space (8 MB parts cannot back a flat '816 regardless);
* **the entire upper lane (`addr[24]=1`) is unused** — 16 MB of SDRAM sitting
  free. See the VERA2 note below, and the performance section at the end.

### 3. Getting into native mode — `boot/boot.s`

The 65816 always leaves reset in emulation mode and always fetches its reset
vector from `$00FFFC`. That is silicon; no pin changes it. So a 256-byte
non-volatile page is unavoidable — it is the smallest window covering both
vector tables (`$FFE4-$FFEF` native, `$FFF4-$FFFF` emulation).

The overlay is temporary. `SYSCTL` bit 0 (`$00:9F80`) powers up set, mapping
the ROM over bank-0 RAM **for reads only**; writes always reach the RAM
underneath. So the stub copies itself ROM-over-RAM at the *same* address and
then clears the bit — the next instruction fetch comes from RAM holding
identical bytes, and from that point bank 0 is 64 KB of uniform RAM with
patchable vectors in it.

`boot.hex` is committed so a bare `quartus_sh --flow compile` works with no
toolchain. Rebuild with `sh boot/build.sh` (needs cc65).

---

## What this build does at power-on

1. reset → emulation mode, vector from `$00FFFC` → `$FF00`
2. `CLC / XCE` → native, `REP #$30` → M=0, X=0
3. `S = $7FFF`, `D = $0000`, `DBR = $00`
4. copy the boot page down, clear `SYSCTL[0]`
5. VERA → 320×240 8bpp bitmap on layer 0
6. paint 240 lines, colour = line number → horizontal bands
7. `WAI` loop

Bands on screen means CPU, native mode, flat bus, I/O decode and video are all
working. It is font-free on purpose: there is no charset in VRAM and no KERNAL
to upload one.

---

## Deliberately not wired yet

Each is a straight lift from `x16_mister` when wanted, in roughly this order:

1. **Guest SD** — `spi_sd_master100.sv` + `sys/sd_card.sv` + an `hps_io`
   virtual block device. Needed before any filesystem work.
2. **RTC / NVRAM** — `rtc_x16.sv` + `nvram_backer.sv` (second I²C slave at
   `$6F`, backed by a mounted image).
3. **Serial** — `x16_serial_card.sv` ×2 at `$9FE0`/`$9FE8`.
4. **SDRAM bitmap layer ("VERA2")** — `bitmap_regs.sv` + `bitmap_engine.sv`,
   a 1 MB planar framebuffer in SDRAM at word base `FB_BASE_WORD`. *Since
   superseded: the VERA816 widening puts a 640×480 8bpp framebuffer in real
   VRAM, so VERA2 stops being necessary ([VERA816.md](VERA816.md) §1); the
   notes below are kept in case it is ever wanted anyway.*
   **Two things must change before it can be ported:**
   * `FB_BASE_WORD = 24'h800000` is a *word* base, which in the flat mapping
     is CPU address `$80:0000` — it would sit inside the flat space and
     corrupt it. Relocate it into the **unused upper lane** (`addr[24]=1`),
     which the CPU port never touches, and it cannot collide at all.
   * it now *competes* with the CPU for SDRAM bandwidth, which it did not in
     the X16 (where the CPU mostly ran out of BRAM and only the HiRAM/cart
     windows hit SDRAM). Measure before enabling.

   Note that VERA's own **VRAM is unaffected by any of this** — it is M10K
   inside `vera/fpga/source/main_ram.v` (widened by VERA816 from 128 KB to
   352 KB, 8 nibble arrays × 90,112 words — see [VERA816.md](VERA816.md)),
   reachable only through VERA's data port at `$9F23`/`$9F24`, and it is
   already present and working in this build.

---

## Known performance ceiling, and what to do about it

Every access outside bank 0 costs a full SDRAM window: ~9 cycles at 100 MHz
plus the CDC handshake, so roughly 2–3 stalled cpu_clk per access. Code
executing from banks `$01+` will feel it, because in a flat model instruction
fetch goes through the same path as data.

Two fixes, in order of value:

1. **Use the 16-bit bus — but the address mapping has to change first.**
   `sdram.v` exposes `dout16` (currently only referenced to keep Quartus
   quiet), and native mode does 16-bit loads and stores constantly, so
   returning a word per access is the obvious win. It does **not** work with
   the current mapping: because `addr[24]` is the lane bit,
   `acc_addr = {1'b0, cpu_a}` puts consecutive CPU bytes in different words,
   and `dout16` would return byte `A` alongside byte `A + 0x1000000` —
   unrelated data.

   The fix is to move the CPU's LSB into the lane bit:

   ```verilog
   acc_addr = {cpu_a[0], 1'b0, cpu_a[23:1]};   // lane = A0, word = A[23:1]
   ```

   Then bytes `2N` and `2N+1` are the two lanes of word `N`, `dout16` returns
   both, and a flat 16 MB uses exactly 16 MB of the part instead of 32 MB.
   The write path is already lane-correct for either value of `bt`
   (`sd_addr[12:11]` -> `sd_dqm`, `sdram.v` line 174), so no controller change
   is needed. A small instruction line buffer on top of that is the step after.
2. **Grow the BRAM window.** Killing the X16's `rom_banks` (256 KB) and
   `lowram_bram` (40 KB) freed ~288 M10K blocks against a 553-block budget that
   was previously 99% full. Bank 0 currently takes ~52. Most of that headroom
   has since gone to VERA816's 352 KB VRAM — 506/553 blocks used, 47 free
   ([MEMORY_MAP.md](MEMORY_MAP.md) §4) — so backing part of bank `$01` too is
   now a much tighter fit.
