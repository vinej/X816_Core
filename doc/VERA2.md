# VERA2 — the SDRAM bitmap layer

**Status: normative.** This document is the contract. The RTL
(`rtl/vera2_engine.sv`, `rtl/vera2_regs.sv`, the framebuffer window in
`rtl/flat_sdram.sv`) and — when it exists — the emulator model implement it
independently, so anything ambiguous here will diverge silently.

Ported from `x16_mister/rtl/bitmap_engine.sv` and its `vera_2.md`, with the
differences in §6.

---

## 1. What it is

A 640×480 linear framebuffer held in SDRAM and **composited over VERA**. VERA
is untouched: it still owns the video timing, sprites, tiles, audio and SD, and
the bitmap rides its raster.

It exists because VERA cannot do this mode. Its 128 KB of VRAM cannot hold a
640×480 8bpp image (307,200 bytes), and its layer renderer truncates the
8bpp/640-wide line address after 205 lines regardless of memory
([MEMORY_MAP.md](MEMORY_MAP.md) §3). Both limits are absent here.

| | |
|---|---|
| Resolution | 640×480, 1:1 with the output raster |
| Depths | **4bpp** (16 colours) and **8bpp** (256) — both fit, §5 |
| Palette | independent 256 × RGB444 |
| Framebuffer | **`$E0:0000-$EF:FFFF`, ordinary CPU memory** |
| Registers | `$9F60-$9F6F` |
| Enable | OSD *VERA2 Bitmap Layer* **and** `CTRL[0]`, both default off |

---

## 2. The framebuffer is ordinary memory

This is the central difference from upstream and it shapes everything else.

The framebuffer is **flat CPU memory at `X816_VFB_BASE` (`$E0:0000`)**, 1 MB,
reserved whether or not the layer is on. Software draws with plain stores, C
pointers, and `mem_copy`/`mem_fill` — which are MVN block moves at **7
cycles/byte**. There is no data port to go through and no blitter to program.

Upstream needs both because its framebuffer is unreachable from the CPU. Ours
is not, so `$9F62-$9F65` carry a display base instead of an address/data port,
and `$9F69-$9F6F` are unimplemented.

**Why it is reserved unconditionally:** a heap end that moved with an OSD switch
could not be a single-sourced constant, and a program built against the larger
arena would corrupt the framebuffer the moment somebody enabled the layer.
`X816_HEAP_END` is `$DF:FFFF`, so the allocator stops one byte below.

### 2.1 Why SDRAM can keep up

`flat_sdram.sv` maps banks `$E0-$EF` **two bytes per 16-bit SDRAM word**,
unlike the rest of memory which uses one byte per word:

```
FB byte $E0:0000 + k  ->  word {4'hE, 1'b0, k[19:1]}, lane k[0]
```

so the scanout fetch reads a **pixel pair per access**. That halving is what
makes the mode possible at all; see §5 for the measured budget. Outside the
window the mapping is unchanged, so no existing access is affected.

---

## 3. Registers — `$9F60-$9F6F`

| Addr | Name | R/W | Description |
|---|---|---|---|
| `$9F60` | `CTRL` | R/W | `[0]` enable, `[2:1]` mode, `[3]` passthru. Read: `{4'b0, passthru, mode, enable}` |
| `$9F61` | `ID` | R | **`$B5`** — feature detect. Reads `$00` when the OSD switch is off |
| `$9F62` | `DISPL` | R/W | display base, byte offset `[7:0]`. **Bit 0 reads back 0** — the fetch works in words |
| `$9F63` | `DISPM` | R/W | `[15:8]` |
| `$9F64` | `DISPH` | R/W | `[19:16]` in bits `[3:0]`; `[7:4]` read 0 |
| `$9F66` | `PALADR` | W | palette index; auto-increments after `PALHI` |
| `$9F67` | `PALLO` | W | `{G[3:0], B[3:0]}` — latched, commits nothing |
| `$9F68` | `PALHI` | W | `{----, R[3:0]}` — commits `{R,G,B}` to `palette[idx]`, then `idx++` |

`$9F65` and `$9F69-$9F6F` are reserved: reads return `$00`, writes are ignored.

Everything resets to 0.

**Mode field (`CTRL[2:1]`)**

| Value | Mode |
|---|---|
| 0 | off |
| 1 | 640×480 8bpp — **see §5** |
| 2 | 640×480 4bpp |
| 3 | off |

**`passthru` (`CTRL[3]`)** shows VERA's *opaque* pixels — sprites, the hardware
mouse pointer — over the bitmap. Without it the bitmap replaces the whole
active display.

### 3.1 Feature detection, normative

```
    lda $9F61
    cmp #$B5
    bne no_vera2
```

`ID` reads `$00` when the OSD master switch is off, so **"absent" and "present
but switched off" are distinguishable** — tell the user to enable it rather
than silently falling back.

### 3.2 Display base — page flipping

`DISPBASE` is a byte offset into the 1 MB window, **latched at vsync**. A page
flip is one register write and is tear-free by construction: a write landing
mid-frame takes effect at the next frame boundary.

Upstream has no such register (`vera_2.md` §8 lists double-buffering as future
work). It fits here because 1 MB holds:

| Mode | Frame | Frames in 1 MB |
|---|---:|---:|
| 640×480 8bpp | 307,200 | **2** |
| 640×480 4bpp | 153,600 | **6** |

---

## 4. Pixel format

**8bpp** — one byte per pixel, left to right. Byte *k* of a line is pixel *k*.

**4bpp** — two pixels per byte, **high nibble is the left pixel**. Byte *k*
holds pixels 2*k* (high) and 2*k*+1 (low). Only palette entries 0–15 are used.

Line *y* starts at `$E0:0000 + DISPBASE + y * bytes_per_line`, with
`bytes_per_line` = 640 (8bpp) or 320 (4bpp). There is no pitch register.

---

## 5. Speed — measured, both modes fit

`sim/run.sh vfb` T9 times a real line fetch through the real controller and
prints the result on every run. A 640×480/60 line is 3200 `sdram_clk`;
framebuffer reads take `flat_sdram`'s **`FB_CYC` early-completion path** at
**~8.1 clocks per word** — `sdram.v` has the data latched by its state 5, so
the generic 11-clock envelope was pure over-wait, and completing early puts
back-to-back words on the controller's natural 8-state cadence. (Upstream's
`ext_ram_sdram.sv` does exactly this, proven on its hardware; the optimisation
was lost when `flat_sdram` was stripped down from it, which is why 8bpp
briefly looked impossible here.)

| Mode | Words/line | Cost | Slack per line |
|---|---:|---:|---:|
| 4bpp | 160 | ~1300 clk | ~1900 clk |
| 8bpp | 320 | ~2595 clk | ~600 clk |

**Both modes are usable.** Only framebuffer *reads* take the early exit — CPU
and loader accesses (writes included, which genuinely need the full row cycle)
keep the untouched `CYCLE_LEN = 9` envelope, so the path carrying
`flat_sdram`'s three silicon-bug invariants is unchanged.

The fetch runs at **lowest priority**, below the CPU. That bounds CPU stall to
a single access, at the cost that a CPU saturating SDRAM can starve the fetch
and glitch a line. In 8bpp the display takes ~80% of the slots during active
lines: code runs from BRAM so most programs never notice, but one hammering a
large heap array will feel it. 4bpp leaves the CPU well over half.

## 6. Differences from upstream `vera_2.md`

| | Upstream | X816 |
|---|---|---|
| Framebuffer access | `ADDR`/`DATA` port with signed auto-increment strides | **ordinary CPU memory**, plain stores and MVN |
| Blitter | `$9F69-$9F6F` SDRAM→SDRAM copy | **not ported** — `mem_copy` is MVN at 7 cyc/byte |
| Display base | none; always scans offset 0 | **`$9F62-$9F64`**, latched at vsync |
| Framebuffer location | word `$800000` | banks `$E0-$EF`, word `$E00000` |
| Depths | 8bpp, 4bpp | same |

Upstream software does not run on X816 regardless (different CPU, memory model
and KERNAL), so register-level compatibility was not a goal; where the two
differ, this document wins.

---

## 7. Tests

| Where | What |
|---|---|
| `sim/run.sh vera2` | End to end on the real chain: `vera2_regs` + `vera2_engine` + `flat_sdram` + the SDRAM model. ID/CTRL, `DISPBASE` readback, a 4bpp line written with ordinary CPU stores checked pixel by pixel through the real palette, and that a disabled layer never raises `bmp_active`. |
| `sim/run.sh vfb` | The framebuffer window mapping (byte pairs share a word, nothing outside moved) and the fetch stream, including the measured rate above. |

Both peek inside the SDRAM model where necessary: the packing is invisible from
the CPU side, because a round-trip reads back correctly under either mapping.
