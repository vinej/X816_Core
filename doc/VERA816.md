# VERA816 — extended VERA specification for X816

**This document is a contract.** The RTL core and the emulator implement it
separately, so anything left ambiguous here will diverge silently — software
developed against one would break on the other, and the failure would surface
long after the cause. Nothing outside this document is agreed.

Base: VERA v0.9 as ported in this repository (`vera/fpga/source/`, derived from
X16Community/vera-module v47.0.2). VERA816 is a strict superset: every stock
VERA register keeps its address, layout and meaning.

---

## 1. Why

640×480 at 8bpp needs **307,200 bytes**. Stock VERA has 128 KB, which is why
the Commander X16 core had to bolt on a separate SDRAM bitmap layer ("VERA2")
at `$9F60`. X816 had M10K to spare — the X16 core sat at 550/553 RAM blocks,
X816 at 282/553 *before this widening* — so the framebuffer goes in real VRAM
instead, and VERA2 stops being necessary. **The widening consumed the spare:**
the fitted core now sits at ~507/553 RAM blocks, so 352 KB is also where VRAM
stops. The BRAM-vs-VERA2 trade, and why the answer to "gaming is fill-rate
limited" is the §4.3 blitter rather than more memory, is analysed in
[VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md).

## 2. Address space

| | Stock VERA | VERA816 |
|---|---|---|
| Byte address | 17-bit | **19-bit** |
| Word address (`bus_addr`) | 15-bit | **17-bit** |
| Address space | 128 KB | **512 KB** |
| Populated | 128 KB | **352 KB** |

```
$00000-$4AFFF   307,200 B  640x480 8bpp framebuffer
$4B000-$57FFF    53,248 B  tilemaps, tile data, sprite data
                 -------
                 360,448 B = 352 KB populated
$58000-$7FFFF   163,840 B  UNPOPULATED — see §3
```

**352 KB is not arbitrary.** It is 2.75× the stock 128 KB, which is 352 M10K
blocks (see §7), the most that fits alongside everything else.

### 2.1 Why the tile/sprite region cannot shrink further

Only the bitmap layer reads VRAM sequentially. Tilemap, tile-data and sprite
fetches are random-access at roughly 160 scattered accesses per scanline, which
is why VERA's own hardware uses on-chip SPRAM and why the X16's VERA2 had to be
a line-prefetch streaming engine rather than a memory. Anything random-access
must stay in this window.

## 3. The unpopulated region — normative

Addresses `$58000-$7FFFF`:

* **Reads return `$00`.**
* **Writes are discarded.**
* No mirroring, no wrap, no aliasing onto populated VRAM.

Chosen because 352 KB is not a power of two, so mirroring would need a modulo
in the data path. Both implementations must behave identically here; a
conformance test asserts it (§8).

## 4. Register extensions

Stock VERA has no spare bits for two more address bits, so the extensions live
in a new DCSEL bank.

**`$9F3D` is NOT available.** It reads `$00`, but that is because it is
write-only `AUDIO_DATA` — `top.v` line 544 drives `audio_fifo_write` from it.
Using it would break PCM audio.

DCSEL allocation in the base design:

| DCSEL | Owner |
|---|---|
| 0, 1 | display composer (stock) |
| 2-6 | **VERA FX** (`addr_data.v` lines 629-764) |
| 7-62 | unused |
| **32** | **VERA816 extensions** |
| **33** | **VERA816 blitter** (§4.3) |
| 63 | **version registers** `DC_VER0-3` — reads return the VERA version string |

DCSEL **32** (`6'h20`) is used. Note that 63 is *not* free despite looking
unused: it holds the version registers, which is why a stock DCSEL read falls
through to `vera_version_string[i % 4]`. 32 sits clear of both FX below and the
version bank above, with room either side.

### 4.1 DCSEL = 32 register bank

| Address | Name | Bits |
|---|---|---|
| `$9F29` | `ADDRX` | `[1:0]` = `ADDR0[18:17]`, `[3:2]` = `ADDR1[18:17]`, `[7:4]` reserved, read 0 |
| `$9F2A` | `L0_BASEX` | `[1:0]` = `L0_MAPBASE[9:8]`, `[3:2]` = `L0_TILEBASE[9:8]`, `[7:4]` reserved |
| `$9F2B` | `L1_BASEX` | `[1:0]` = `L1_MAPBASE[9:8]`, `[3:2]` = `L1_TILEBASE[9:8]`, `[7:4]` reserved |
| `$9F2C` | `VRAMCAP` | read-only capability: populated VRAM in 16 KB units. VERA816 = `22` (`352/16`). **Stock VERA reads `$00` here**, so software can detect the extension. |

All four power up to `$00`, which makes VERA816 behave exactly like stock VERA
until software opts in.

Reserved bits must be written as 0 and read back as 0.

**`ADDRX` is a live window, not a latch — normative.** It is part of the
address registers, not a separate copy of their top bits. Reading it returns
the *current* `ADDR0[18:17]` / `ADDR1[18:17]`, so it tracks auto-increment
carry; writing it sets those bits immediately, regardless of the order
relative to `ADDR_L`/`ADDR_M`/`ADDR_H` writes.

This is easy to get wrong in a software implementation, where the natural
thing is to store the written value and return it. The RTL gets the correct
behaviour for free because the bits physically live in `vram_addr_{0,1}`; the
emulator has to derive them. A shadow-latch implementation passes the
conformance tests by accident — the march starts from zero, so a stale zero
reads back as the correct zero — and then diverges the first time software
reads the address after crossing a 128 KB boundary.

`L0_BASEX` and `L1_BASEX` *are* ordinary latches; only `ADDRX` has this
property.

**Write ADDRX before ADDR_L/M/H when setting up a read.** The data-port
fetch-ahead refreshes on `ADDR_L/M/H` writes only (`addr_data.v`
`fetch_ahead`), not on `ADDRX` — identically in both implementations — so an
"L/M/H then ADDRX" order leaves the first `DATA0` read holding the byte from
{old `[18:17]`, new low bits}. ADDRX-first costs nothing and is always
correct.

### 4.2 Why MAPBASE and TILEBASE need two more bits each

Current address arithmetic in `graphics/layer_renderer.v`:

```verilog
wire [14:0] map_addr  = {map_baseaddr, 7'b0} + map_idx[15:1];      // line 107
wire [14:0] tile_addr = {tile_baseaddr, 7'b0} + tile_addr_xbpp;    // line 188
```

`map_baseaddr` and `tile_baseaddr` are 8 bits, shifted left 7, giving a 15-bit
word address. For a 17-bit word address both must become **10 bits**:

```verilog
wire [16:0] map_addr  = {map_baseaddr, 7'b0} + map_idx[15:1];      // baseaddr now [9:0]
wire [16:0] tile_addr = {tile_baseaddr, 7'b0} + tile_addr_xbpp;
```

Granularity is unchanged: MAPBASE stays 512-byte aligned, TILEBASE stays
2048-byte aligned (`top.v` forces `tile_baseaddr[1:0] = 0` on write).

### 4.3 The blitter — DCSEL 33, normative

VRAM-to-VRAM bulk fill and copy without the CPU's one-byte data port. It runs
on a fifth, **lowest-priority** VRAM arbiter port (`blit816.v`,
`vram_if.v` if4), so it can never disturb scanout: it consumes idle VRAM
slots — all of them in blanking, the leftovers during active display.
Rationale and the performance ladder: [VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md).

With `DCSEL = 33`:

| Address | Name | Behaviour |
|---|---|---|
| `$9F29` | `BLT_IDX` | R/W: index into the parameter file, 0-9 |
| `$9F2A` | `BLT_DATA` | R/W: the indexed parameter byte. **A write auto-increments `BLT_IDX`; a read does not.** |
| `$9F2B` | `BLT_CTRL` | W: bit 0 = start **COPY**, bit 1 = start **FILL**. R: bit 0 = **busy** |
| `$9F2C` | `BLT_ID` | R: **`$B6`** — feature detect (stock VERA reads the version byte here) |

Parameter file (all little-endian; addresses are 19-bit VRAM **byte**
addresses, lengths in bytes):

| Index | Field |
|---|---|
| 0-2 | `SRC` (`[18:16]` in the low bits of byte 2) |
| 3-5 | `DST` |
| 6-8 | `LEN` |
| 9 | `VAL` — the FILL byte |

Semantics, all normative:

* Byte-granular: any `SRC`/`DST` alignment, any `LEN`. `LEN = 0` starts
  nothing (busy never rises).
* COPY is **ascending**. Overlap is defined only for `DST < SRC` or disjoint
  ranges; the VERA2 "doubling" idiom (`DST = SRC + LEN`) is disjoint and is
  the intended fast-fill pattern.
* Addresses advance **modulo 512 KB**, matching the data-port auto-increment
  wrap (§8 test 4). The unpopulated region behaves exactly as §3: writes
  discarded, reads 0.
* `SRC`/`DST`/`LEN` read back as the engine left them (`LEN = 0`, pointers
  one-past-end) — the readable-pointer convention VERA2 established.
* Parameter writes while busy are **ignored**. Poll `BLT_CTRL` bit 0.
* Writes through the blitter are plain byte writes: no FX transparency, no
  4-bit mode, no cache interaction.

Speed (RTL): FILL sustains a 32-bit word per granted slot on aligned runs
(~100 MB/s in blanking); COPY runs word-in/word-out when `SRC` and `DST` are
co-aligned, else byte writes backed by a cached source word. A full 640×480
8bpp frame fills in ~3 ms and copies in ~6 ms of idle slots.

## 5. The bitmap line-address truncation — the actual blocker

`graphics/layer_renderer.v` line 197:

```verilog
2'd3: bm_line_addr_tmp = tile_width ? {line_idx_mul5[9:0],  5'b0}    // 8bpp, 640 wide
                                    : {line_idx_mul5[10:0], 4'b0};   // 8bpp, 320 wide
```

`line_idx_mul5` is **12 bits** (`line_idx * 5`). For 640-wide 8bpp only bits
`[9:0]` survive, so the address wraps once `line_idx * 5 >= 1024`, i.e. **after
line 204**. Stock VERA cannot scan out 640×480 8bpp *even with unlimited VRAM*.
This is the wall VERA2 was built to climb.

Required change — keep all 12 bits and widen the result to 17:

```verilog
reg [16:0] bm_line_addr_tmp;
...
2'd3: bm_line_addr_tmp = tile_width ? {line_idx_mul5[11:0], 5'b0}
                                    : {line_idx_mul5[11:0], 4'b0};
wire [16:0] bitmap_line_addr = {tile_baseaddr, 7'b0} + bm_line_addr_tmp;
```

The lower colour depths (`2'd0`-`2'd2`) widen the same way. **Both
implementations must widen identically** — a mismatch here shows up only past
line 204 of an 8bpp bitmap.

### 5.1 Sprite data above 128 KB — normative

The layout in §2 puts sprite data at `$4B000+`, which stock sprite attributes
cannot address: the attribute's 12-bit address field reaches
`{addr,3'b0}` = 15 bits of 32-bit words = the first 128 KB only.

VERA816 widens the field using two formerly reserved attribute bits.
Sprite attribute byte 1 (offset 1 of the 8-byte record):

| Bit | Stock VERA | VERA816 |
|---|---|---|
| 7 | mode (4/8 bpp) | unchanged |
| 6 | reserved, write 0 | still reserved |
| **5:4** | reserved, write 0 | **address bits `[18:17]`** (VRAM byte address) |
| 3:0 | address `[16:13]` | unchanged |

Granularity stays 32 bytes; software that writes the reserved bits as zero —
which stock software must — sees exactly stock behaviour. RTL:
`sprite_renderer.v` `sprite_attr_addr` is now `[13:0]`. The emulator must
decode the same two bits identically.

## 6. RTL change list

| File | Change |
|---|---|
| `vera/fpga/source/main_ram.v` | see §7 |
| `vera/fpga/source/vram_if.v` | `if0_addr` 17→19 (CPU byte), `if1_addr`/`if2_addr`/`if3_addr` 15→17 (word); **if4** = the blitter's lowest-priority R/W word port (§4.3) |
| `vera/fpga/source/top.v` | `vram_addr_0_r`/`vram_addr_1_r` 17→19; DCSEL-32 decode; `l0/l1_map_baseaddr` and `l0/l1_tile_baseaddr` 8→10 bits; DCSEL-33 blitter bank + `blit816` instantiation; **`l0_addr`/`l1_addr`/`spr_addr` 15→17 — the wires joining the renderers to `vram_if`, missed until 2026-08-01 (§8)** |
| `vera/fpga/source/addr_data.v` | `ADDRX` live-window bits, FX interaction with the 19-bit addresses (this row was missing from earlier revisions of this list) |
| `vera/fpga/source/graphics/layer_renderer.v` | `bus_addr` 15→17; `map_addr`/`tile_addr` 15→17; §5 fix |
| `vera/fpga/source/graphics/sprite_renderer.v` | `bus_addr` 15→17; `sprite_attr_addr` 12→14 bits (§5.1) |
| `vera/fpga/source/blit816.v` | **new** — the §4.3 blitter engine |

## 7. `main_ram.v` restructuring

Stock layout is two groups of 8 nibble arrays (`blk10_n0-7`, `blk32_n0-7`),
each 16384 deep, selected by `bus_addr[14]`. That split is a legacy of the
original Lattice SP256K primitives (256 Kbit each), not a requirement.

VERA816 collapses it to **one group of 8 nibble arrays, each 90,112 deep**,
indexed directly by `bus_addr[16:0]`:

* 8 arrays × 4 bits = 32 bits per word
* 90,112 words × 4 bytes = 360,448 B = 352 KB
* M10K: ×4 mode is 2048 deep, so 90112/2048 = 44 blocks per array × 8 = **352
  blocks**

This is simpler than the stock arrangement as well as larger — the group-select
bit disappears.

Nibble granularity is retained because VERA FX needs 4-bit write enables. It
costs 20% packing efficiency (M10K ×4 mode uses 4 of 5 bits) and cannot be
recovered without dropping FX.

## 8. Conformance tests

> **Status, corrected 2026-08-01.** `boot/vramtest.s` implements tests **1–4**
> and paints green on pass, red on fail; those four are green on the emulator
> and on a DE10-Nano. **Test 5 was never implemented** — an earlier revision of
> this document claimed all five were passing, and that claim is what let the
> bug in the box below survive for weeks. Build the test bitstream with
> `sh boot/build.sh vramtest` — and read the warning in that script about
> Quartus's hex-update fast path first, or you will flash a bitstream that
> still contains the previous boot ROM.
>
> **Read this before trusting any "the widening works" claim.** Tests 1–4 all
> reach VRAM through the **CPU data port**, which is a different physical path
> (`vram_if` if0) from the one the display uses. They can pass with every
> RENDERER still truncated — and they did. Until 2026-08-01 the three wires in
> `top.v` joining the renderers to `vram_if` were 15 bits wide while both ends
> were 17, so layer 0, layer 1 and sprites could only ever fetch from the first
> 128 KB. Nothing caught it: test 5 would have, and did not exist; the paint
> at the end of `vramtest.s` is 320×240, which fits inside 128 KB. It took a
> sprite on real hardware rendering the wrong pixels. Fixed and **confirmed on
> hardware 2026-08-01** (tests 6–7 below); `sim/run.sh lint` now fails on any
> such truncation.
>
> **Test 5 is still not implemented, and is now the only untested path.**
> Sprites proved a renderer can fetch above 128 KB, and the tile layers share
> that fix and that arbiter — but "share the fix, so presumably fine" is the
> reasoning that caused this episode. A 640×480 8bpp scanout is the reason the
> 352 KB exists, and nothing has displayed one yet.

Both implementations must pass identically before any application software is
written against VERA816.

1. **March test.** Write a pseudo-random pattern seeded by address across all
   352 KB via `ADDR`/`DATA0` with auto-increment; read back and compare.
   Exercises the widened address path end to end.
2. **Hole test.** Write `$FF` to eight addresses spread through
   `$58000-$7FFFF`; read back — all must be `$00`. Confirm the corresponding
   populated addresses are unaffected (no aliasing).
3. **Capability test.** `VRAMCAP` reads 22.
4. **Address wrap.** Auto-increment across `$7FFFF` wraps to `$00000`.
5. **Bitmap scanout.** 640×480 8bpp with a per-line colour ramp; **line 205
   must differ from line 0.** This is the specific regression §5 fixes and is
   the one test that catches a truncation mismatch.
6. **Sprite reach (§5.1).** A sprite whose attribute address points above
   128 KB (bits [5:4] of byte 1 non-zero) renders the pixels stored there; the
   same attribute with those bits zero renders from the low copy.
7. **Blitter (§4.3).** ID reads `$B6`; fill and copy at every alignment;
   `LEN=0` no-op; wrap at `$7FFFF`; hole semantics; pointer readback;
   busy polling.

> **Status of 6 and 7: GREEN ON HARDWARE**, DE10-Nano, 2026-08-01, with the
> 14:18 bitstream. `BLITTEST.BIN` paints green and shows one **white**
> rectangle (sprite data at `$34000`, reached through the §5.1 attribute bits
> and put there by the blitter) beside one **blue** (the same stock address
> field with those bits zero). That is the whole widening proved end to end on
> silicon: the CPU wrote it, the blitter moved it, a renderer fetched it from
> above 128 KB, and the display showed it.
>
> It took two hardware rounds. The first showed **two blue** rectangles —
> a 15-bit sprite address truncates `$34000` to `$14000`, which is exactly
> where the low copy lives, so the failure rendered as a plausible picture.
> The cause was the `top.v` wire width in the box above, not this attribute
> decode.
>
> Worth keeping, because it is what those two rounds bought: sim and the
> emulator agreeing proves the CONTRACT is consistent. Only the board proves
> the BITSTREAM implements it.

## 9. Explicitly unchanged

* Every stock VERA register address, layout and reset value
* Palette, sprite attribute RAM storage, line buffers, audio, SPI
* VERA FX, and DCSEL 0-6
* The `$9F20-$9F3F` window position in the X816 I/O page
* Sprite and tile rendering semantics — only address widths change, plus the
  two formerly reserved sprite-attribute bits §5.1 gives meaning to (zero =
  stock behaviour)

## 10. Consequence for the core

VERA816 replaces the SDRAM bitmap layer ("VERA2": `bitmap_regs.sv`,
`bitmap_engine.sv`, `$9F60`) for everything capacity was not the bottleneck
for — and [VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md) shows capacity was
never the gaming bottleneck; fill rate was, which the §4.3 blitter addresses
in VRAM at higher speed than VERA2's SDRAM engine could. VERA2 is therefore
**deferred, not dropped**: it becomes worth porting only when a concrete
target needs double-buffered 640×480 **8bpp** or more than 352 KB of live
pixel data, and the review lists what that port must include (burst SDRAM
reads, a display-base register, the lane carve-out) before it is viable on
X816's CPU-in-SDRAM architecture.
