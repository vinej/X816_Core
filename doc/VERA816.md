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
  $1F9C0-$1FFFF   1,600 B    ... crossed by VERA's register windows — see §2.2
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

### 2.2 The framebuffer crosses the register windows — normative

Stock VERA puts the PSG, palette and sprite-attribute files inside the CPU
data port's view of VRAM:

| Range | Contents |
|---|---|
| `$1F9C0-$1F9FF` | PSG registers (write-only) |
| `$1FA00-$1FBFF` | palette |
| `$1FC00-$1FFFF` | sprite attributes |

**A 640×480 8bpp framebuffer cannot avoid them.** It needs 307,200 contiguous
bytes; the largest clear runs in the 352 KB are `$00000-$1F9BF` (129,472 B) and
`$20000-$57FFF` (229,376 B). Every legal TILEBASE placement — 2048-byte
aligned, base ≤ `$0D000` for the picture to fit — therefore spans
`$1F9C0-$1FFFF`. For the `$00000` base above, that is **lines 202–204**, 1,600
bytes, two and a half scanlines sitting exactly at the 128 KB boundary.

Three rules follow, and all three are normative:

1. **The CPU data port must not be used to paint those 1,600 bytes.** A store
   there writes VRAM *and* the window it decodes to, so painting through it
   rewrites the palette from the picture's own pixels. Software wanting an
   uncorrupted 640×480 must skip the range.
2. **The blitter (§4.3) must be used instead, and can be.** Its traffic goes
   through its own `vram_if` port and never touches the PSG/palette/sprite
   shadows — those are written only by the external-bus decode in `top.v`.
   This is the only way to put pixels in the window band, and it is why the
   blitter is a dependency of the 640×480 mode rather than merely a speed-up.
3. **The window decodes must test the full 19-bit address.** They match
   `[16:0]` patterns, so without an explicit `addr[18:17] == 0` qualifier
   `$3FA00` is a second palette and `$3FC00` a second sprite-attribute file —
   both inside the framebuffer, so an ordinary paint would corrupt the palette
   partway down the screen. The picture then comes up in the wrong colours,
   which looks nothing like an addressing fault.

Rule 3 held on the read side (`addr_data.v` `vram_addr_lo128k`) and **did not
hold on the write side** (`top.v` `palette_write`, `sprite_attr_write`,
`audio_write`) until 2026-08-01; the emulator, which compares full absolute
addresses, was correct throughout. `examples/vera/scanout.c` probes `$3FA02`
and `$3FC00` before it paints, so the divergence cannot come back silently.

**The escape hatch — §4.4.** Everything above describes the reset state.
Setting `CTRL816.REGWIN` relocates all three windows to `$7F9C0-$7FFFF`,
inside the unpopulated region, after which rules 1 and 2 do not apply: the
whole 352 KB is plain VRAM, the CPU port may paint every byte of it, and the
blitter goes back to being a speed-up rather than a dependency. A program
that draws 640×480 should set the bit first and skip the choreography.

### 2.3 What actually fits

Framebuffer arithmetic against the 360,448 populated bytes, reserving the
53,248 the tile/sprite region needs (§2.1). "Windows" is whether the picture
can dodge `$1F9C0-$1FFFF` without §4.4's `REGWIN`.

| mode | frame | single-buffered | double-buffered | windows |
|---|---|---|---|---|
| 640×480 8bpp | 307,200 | yes, 53,248 spare | **no** — 667,648 exceeds even the 512 KB address space | always crosses |
| 640×480 4bpp | 153,600 | yes | **yes — 360,448 exactly, to the byte** | single: dodgeable at base `$20000`; double: one buffer crosses |
| 640×240 8bpp | 153,600 | yes | **yes — exactly, same arithmetic** | as 4bpp; line-double with `DC_VSCALE` |
| 640×480 2bpp | 76,800 | yes | yes, easily | dodgeable |

Two consequences worth stating plainly:

* **Double-buffered 640×480 8bpp is unreachable in any BRAM VERA** — it is not
  a fitter limit but an address-space one. That is the case, and the only
  case, for the VERA2 port [VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md)
  defers.
* **Tear-free 640×480 4bpp and 640×240 8bpp are available today**, which is
  what makes §4.4 worth having: with `REGWIN` set both are plain memory and
  page-flipping is a `TILEBASE` write.

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
| **34** | **VERA816 control** (§4.4) |
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

### 4.4 `CTRL816` — DCSEL 34, normative

| Address | Name | Bits |
|---|---|---|
| `$9F29` | `CTRL816` | `[0]` = `REGWIN`, `[7:1]` reserved: write 0, read 0 |
| `$9F2A-$9F2C` | — | reserved. Reads currently return the version bytes; do not rely on this. Writes are ignored. |

`CTRL816` powers up to `$00`. Detection: on a core with this bank, `CTRL816`
reads `$00` at reset; on an older VERA816 the same read falls through to the
version string and returns `$56` (`'V'`). Write 1 and read it back to be sure.

**`REGWIN` = 0** (reset): stock behaviour, exactly as before this section
existed. The PSG/palette/sprite-attribute windows decode at `$1F9C0-$1FFFF`, a
write there lands in **both** VRAM and the register file, and a read returns
the VRAM shadow underneath.

**`REGWIN` = 1**: the three windows decode at **`$7F9C0-$7FFFF`** instead —
the same `[16:0]` offsets (PSG `$7F9C0-$7F9FF`, palette `$7FA00-$7FBFF`,
sprite attributes `$7FC00-$7FFFF`), relocated to the top of the 512 KB space,
inside the §3 unpopulated region where they collide with nothing. Normative
consequences:

* **`$1F9C0-$1FFFF` becomes plain VRAM through every path** — data ports,
  FX, blitter. This is the point: with the windows out of the way, §2.2's
  rules 1 and 2 do not apply, the CPU port may paint the whole framebuffer,
  and the entire 352 KB is ordinary memory. It is what makes double-buffered
  640×480 4bpp and 640×240 8bpp (which fill the 352 KB **exactly**, to the
  byte) writable like any other picture.
* **The relocated windows are write-only.** A read at `$7F9C0-$7FFFF` returns
  `$00` — the §3 hole rule, unchanged. Stock-position readback was only ever
  the VRAM shadow underneath the window, and under the high position there is
  no memory; keep a shadow in CPU RAM if you need one (the PSG always
  required this anyway).
* **Switching moves no data.** Palette, sprite-attribute and PSG state keep
  their contents; the VRAM at `$1F9C0-$1FFFF` keeps whatever the stock-mode
  shadow writes left there. The renderers are unaffected by the bit in both
  positions — they read their own RAMs, never these windows.
* The FX niceties gated off window addresses (nibble writes, cache,
  transparency — `addr_data.v`) follow the windows: available on the freed
  `$1F9C0-$1FFFF`, suppressed on `$7F9C0-$7FFFF`.

Both implementations must honour the bit identically; §8 test 8 asserts it.

**GREEN ON HARDWARE**, DE10-Nano, 2026-08-01. `RUN REGWIN.BIN` goes white →
blue → blue with a single yellow sprite near the top left: the relocated
`$7FA02` reached the palette, the stock `$1FA02` write that followed did not,
and a sprite programmed entirely through `$7FC08` rendered while the stock
`$1FC10` slot stayed inert. The freed range is ordinary VRAM on real silicon,
which is what the 352 KB needed to be worth having.

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

### 5.0 It is not one limit, and it is not the same line in every mode

Worth stating explicitly, because "the 128 KB limit" sounds like a single wall
and is really three independent ones — only the first about memory size:

1. **Capacity.** 128 KB of VRAM. §2.
2. **This truncation.** The shift applied to `line_idx_mul5` differs per depth,
   so the wrap line differs per depth — nothing to do with how much VRAM is
   fitted.
3. **The renderer↔arbiter wire widths.** AUDIT.md H-3, equal in every mode.

A fourth exists and is **deliberately kept**: FX affine's two base registers
reach only the first 128 KB. It is not in the list above because it limits
where affine's *source data* may live rather than what a display can scan
out, and because §9.1 decides — with a measurement — that lifting it would
buy a configuration too slow to use. Read §9.1 before proposing an
`FX_BASEX`; the argument for one is more obvious than it is good.

For 640-wide bitmaps, stock VERA's 15-bit result truncates as:

| depth | shift | stock wraps after | frame bytes | stock verdict |
|---|---|---|---|---|
| 1bpp | ≪2 | line 1638 — never | 38,400 | **worked** |
| 2bpp | ≪3 | line 819 — never | 76,800 | **worked** |
| 4bpp | ≪4 | **line 409** | 153,600 | broken twice: 70 lines short, and over 128 KB |
| 8bpp | ≪5 | **line 204** | 307,200 | broken twice: 275 lines short, and over 128 KB |

So stock VERA could display 640×480 at 1bpp and 2bpp only, and **both**
high-colour modes failed for two independent reasons each — which is why more
memory alone would never have fixed either. 320-wide 8bpp shifts by 4 and
wraps after line 409, comfortably clear of 240 lines, which is why 320×240
worked and hid the problem.

VERA816 removes all three, and **both high-colour modes are now tested**.
§8 test 5 covers 8bpp; `run-scanout.sh --4bpp` covers 4bpp, built from the
same source with `USE_4BPP=1` and shipped as `SCAN4.BIN`.

Writing it was worth more than the arithmetic suggested, which is the point.
The 4bpp case *does* share `bm_line_addr_tmp` and `l0_addr`, and both were
correct — but the test based its framebuffer at `$20000` (153,600 bytes there
clear the register windows outright, so it needs neither §2.2's choreography
nor the blitter), and that made it **the first thing in this tree to write
`L0_BASEX` non-zero**. Everything else writes the reset value, which proves
nothing about the register. It failed immediately, and the fault was in the
**emulator**: `refresh_layer_properties()` recomputes the cached `map_base`
and `tile_base` and is reached only from a write to `$9F2D-$9F33`, so a
program that set `TILEBASE` and then extended it with `BASEX` — the natural
order — left the cache holding the un-extended base. The layer rendered from
`$00000` while the CPU port wrote where it was told, so every read-back the
program could do still passed.

Two things worth keeping from that:

* **The RTL was right.** `top.v` feeds `{l0_basex_r[3:2], l0_tile_baseaddr_r}`
  combinationally; there is no cache to go stale. This is the mirror image of
  AUDIT.md H-3 and H-4 — an emulator-only divergence, where those two were
  RTL-only — and it says the risk runs in both directions.
* **`--4bpp-negative` breaks the right thing.** Flattening the ramp would only
  re-prove what `--negative` already proves, so it clears `L0_BASEX` instead:
  the layer then fetches from `$00000` while the program still paints and
  verifies at `$20000` through the data port, so every read-back passes and
  only the screen can catch it. 453 of 480 lines wrong.

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
> **Test 5 now exists and is GREEN ON HARDWARE**, DE10-Nano, 2026-08-01
> (`examples/vera/scanout.c`, `run-scanout.sh`, `RUN SCANOUT.BIN` from the demo
> card). It paints 640×480 8bpp as eight 60-line colour bands, reads the
> framebuffer back through the data port before it will trust the screen, and
> the runner checks all 480 lines of the last GIF frame against the band rule —
> "line 205 must differ from line 0" is one case of it. Green on the emulator
> with a negative control, and the board shows the eight bands in order:
> **white, red, cyan, purple, green, blue, yellow, orange**. Bands 4–7 are
> fetched entirely from above 128 KB. **The 352 KB is now proved end to end on
> silicon for the mode it exists for.**
>
> **Expected while it paints:** a ragged black gap about 2.5 rows tall opens in
> the middle of the purple band and closes at the end. That is the §2.2 window
> band — skipped by the data port, filled by the blitter afterwards — and it
> sits exactly on the 128 KB boundary at line 204.8. `SCANFULL.BIN`, the same
> test with §4.4's `REGWIN` set, shows **no gap at all** — confirmed on a
> DE10-Nano, 2026-08-01 — because with the windows relocated there is nothing
> to paint around. Run the two back to back: same eight bands, one painted in
> a single sweep by the CPU and one choreographed around the register windows.
> That pair is the clearest statement of what §4.4 buys, and `SCANOUT.BIN`
> keeps the stock path covered because `REGWIN` resets to 0.
>
> Writing it found two things nothing else had. §2.2 is the first: no 640×480
> framebuffer can avoid VERA's register windows, the CPU port must not paint
> that band and the blitter must. The second is that `top.v`'s palette,
> sprite-attribute and audio *write* decodes ignored address bits [18:17], so
> `$3FA00` aliased onto the palette — inside the framebuffer, so the first run
> of this test repainted the palette with its own pixels and came up a uniform
> `$0404`. Fixed the same day; the test probes for it before painting, and
> **that probe passing on the board is what confirms the fix** — an unfixed
> bitstream fails preflight 4 and paints grey, so a screen with bands on it
> is itself the evidence.

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
   the one test that catches a truncation mismatch. It also covers §2.2: the
   band at `$1F9C0-$1FFFF` must be painted by the blitter, and a store to
   `$3FA02`/`$3FC00` must leave the palette and sprite attributes alone.
   `examples/vera/scanout.c` + `run-scanout.sh` (`--negative` flattens the
   ramp, so line 205 stops differing from line 0 and the check must fire).
6. **Sprite reach (§5.1).** A sprite whose attribute address points above
   128 KB (bits [5:4] of byte 1 non-zero) renders the pixels stored there; the
   same attribute with those bits zero renders from the low copy.
7. **Blitter (§4.3).** ID reads `$B6`; fill and copy at every alignment;
   `LEN=0` no-op; wrap at `$7FFFF`; hole semantics; pointer readback;
   busy polling.
8. **Register-window relocation (§4.4).** `CTRL816` reads 0 at reset and
   reads back a written 1. With `REGWIN` set: a palette write at the stock
   `$1FA02` must **not** change a displayed colour (the address is plain
   VRAM now); the same write at `$7FA02` must; `$7FA02` reads back `$00`
   (write-only); a sprite programmed entirely through the `$7FC00` window
   renders. `examples/vera/regwin.c` + `run-regwin.sh` (`--negative` leaves
   `REGWIN` clear, so the stock-address write must repaint the screen and
   the relocated one must not — proving the checks can fail).
   Test 5 also runs a second time with `REGWIN` set
   (`run-scanout.sh --regwin`, shipped as `SCANFULL.BIN`): the same 480
   lines, painted entirely by the data port with the blitter never invoked.
   Its negative control (`--regwin-negative`) writes 0 to `CTRL816` and
   paints straight through anyway — the live windows then rewrite the
   palette from the picture's own pixels and **all 480 lines come out
   wrong**, which is what makes the positive run mean something.
   Test 5 runs a **third** time at 640×480 **4bpp** based at `$20000`
   (`run-scanout.sh --4bpp`, shipped as `SCAN4.BIN`) — §5.0's other broken
   mode, wrapping after line 409 rather than 204 and taking a different arm
   of the line-address shift. It is also the only image in this tree that
   writes `L0_BASEX` non-zero, and therefore the only one that proves the
   widened tile base does anything; everything else writes the reset value.
   Its negative control (`--4bpp-negative`) clears `L0_BASEX`, so the layer
   fetches from `$00000` while the program still paints and verifies at
   `$20000` through the data port — every read-back passes and only the
   screen catches it. 153,600 bytes at `$20000` clear the register windows
   outright, so this build needs neither §2.2's choreography nor the blitter.
9. **FX affine (§9.1).** `examples/vera/fxtest.c` + `run-fx.sh`, at 320×240
   with map and tile data below 128 KB — so it needs no RTL change and
   asserts nothing about `FX_BASEX`. Six checks: FX returns a texture rather
   than a constant; an identity walk; a **fractional** increment (the
   sub-pixel stepping affine exists for); a two-axis walk with a negative x
   step; clipping (outside the map gives tile 0); and wrapping (with clip off
   the map repeats). Each is compared against a plain-C tilemap walk written
   from the documented semantics, **not** from the RTL's own expressions —
   otherwise the test would prove only that two copies of one reading agree.
   `--negative` shifts that reference by one bit and the walks must disagree.
   It also **measures** the affine fill rate, which is what §9.1's decision
   rests on.

   Two properties it pinned down, both of which cost a failing run and both
   of which any Mode 7 code will meet: the sub-pixel remainder **survives a
   position write** (bits `[8:1]` of the position are not writable at all),
   and it **starts at half a pixel**, not zero — `fx_pixel_pos_x_r <=
   20'd256` in the RTL, `0x8000` in the emulator, which agree. A whole-pixel
   increment hides both completely.

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
* VERA FX, and DCSEL 0-6 — unchanged, and **decided so**, see §9.1.
* The `$9F20-$9F3F` window position in the X816 I/O page
* Sprite and tile rendering semantics — only address widths change, plus the
  two formerly reserved sprite-attribute bits §5.1 gives meaning to (zero =
  stock behaviour)

### 9.1 FX affine reaches only the first 128 KB — normative, and deliberate

**Decided 2026-08-02: this stays. There is no `FX_BASEX`.** What follows is
the limit, why it is not worth lifting, and the measurement that settled it —
recorded because "the last removable limit" is an argument that will be made
again by whoever reads §5.0 next.

**The limit.** `addr_data.v`'s `fx_map_base_address_r` and
`fx_tiledata_base_address_r` are 6 bits shifted left 11, giving a 17-bit
address. So **all FX affine source data — the tilemap and the tile data —
must live below `$20000`.** FX's own `ADDR0`/`ADDR1` are full 19-bit, so line
draw, polygon fill and cache writes reach the whole 352 KB; only the two
affine base registers are narrow.

Lifting it would be small: two more bits per base, and `$9F2A`'s high nibble
in the DCSEL-32 bank is free (`{4'b0, l0_basex_r}` on read), so it needs no
new register and no new bank. Defaulting the bits to zero would preserve
stock behaviour exactly, the same way §5.1's sprite-attribute bits do. It was
never a difficulty. It is simply not worth it.

**Why not — the arithmetic that decides it.** Affine is CPU-mediated: one
read from `DATA1` per pixel, and one store to put the pixel somewhere. The
cost is therefore **per pixel and independent of colour depth** — 640×480 is
307,200 pixels at 4bpp and at 8bpp alike, so the lower depth buys nothing.

`examples/vera/run-fx.sh` measures **6.00 cycles per pixel** for the FX read
alone, on the emulator at 8 MHz. That is a floor; a real fill also stores.

| affine area per frame | pixels | floor | realistic |
|---|---|---|---|
| 640×480 | 307,200 | 230 ms | ~2.5 fps |
| 320×240 | 76,800 | 57 ms | ~10 fps |
| 640×160 strip | 102,400 | 77 ms | ~7 fps |
| 320×120 strip | 38,400 | 29 ms | ~20 fps |

The rule is to budget by **pixels affine-mapped per frame**, not by screen
mode: roughly 8,000 at 60 fps, 16,000 at 30, 32,000 at 15.

**And that is what makes the limit moot.** `FX_BASEX` is needed for exactly
one configuration — affine alongside a *full-screen 640×480 8bpp*
framebuffer, which occupies `$00000-$4AFFF` and leaves affine nowhere to put
its sources. That configuration is also the one the table says is far too
slow to build. The single case that needed the fix is the case nobody would
ship.

At the resolutions where affine *is* fast enough to use, there is no
constraint at all. A 320×240 8bpp framebuffer is 76,800 bytes,
`$00000-$12BFF`, leaving about **51 KB free below `$20000`** — a 128×128
tilemap (16 KB) and 256 tiles of 8×8 data (16 KB) fit with room to spare, at
the 2048-byte base granularity the registers impose.

**Normative, for software:** place FX affine tilemaps and tile data below
`$20000`. Nothing else in VERA816 constrains where VRAM objects go; this one
does.

**Reopen this only if** a concrete program wants affine over a full-screen
640×480 8bpp picture *and* can live with a few frames per second — or if the
fill loop gets substantially cheaper than 6 cycles/pixel. The guard for that
work already exists: `run-fx.sh` covers affine addressing, so the widening
would not be attempted blind (§8 test 9).

**One honest gap in the above.** The read-only figure is measured; the
"realistic" column is inferred from it, because the read-plus-store loop in
`fxtest.c` reports zero elapsed cycles and the cause has not been found — the
test says `UNMEASURED` rather than printing a number. The conclusion does not
depend on it: at the optimistic floor 640×480 is still 4.3 fps.

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
