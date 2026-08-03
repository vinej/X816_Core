# X816 — memory map

Two independent address spaces. The CPU's flat 16 MB, and VERA's VRAM, which is
**not** in the CPU map — it is reachable only through VERA's data port at
`$9F23`/`$9F24`.

Rows marked **planned** are not in the current bitstream. Everything else is
built and compiling today.

---

## 1. CPU flat address space — 16 MB

| Range | Size | Backing | Status | Contents |
|---|---:|---|---|---|
| `$00:0000-$00:9EFF` | 40,704 B | bank-0 BRAM | built | direct page, stack, OS variables |
| `$00:9F00-$00:9FFF` | 256 B | — | built | I/O page (see §2) |
| `$00:A000-$00:FEFF` | 24,320 B | bank-0 BRAM | built | RAM |
| `$00:FF00-$00:FFFF` | 256 B | boot ROM (reads) / bank-0 BRAM (writes) | built | vectors + boot stub; overlay drops on `SYSCTL[0]=0` |
| **bank `$00` total** | **64 KB** | **BRAM, single cycle** | | 65,280 B RAM + 256 B I/O |
| `$01:0000-$04:FFFF` | 262,144 B = 256 KB | **BRAM, single cycle** | built | user RAM — **program code lands here**, see below |
| `$05:0000-$EF:FFFF` | 15,400,960 B ≈ 14.69 MB | SDRAM | built | user RAM |
| `$F0:0000-$FF:FFFF` | 1,048,576 B = 1 MB | SDRAM, write-protected | **planned** | firmware (HPS-loaded) |
| **Total** | **16,777,216 B = 16 MB** | | | |

**Why bank 0 is BRAM.** The 65816 forces the stack *and* direct page into bank
`$00` regardless of DBR/PBR, so every JSR/RTS, interrupt, push/pull and
dp-addressed operand lands there. It gets the zero-wait memory; banks `$01+`
stall per access. The split is invisible to software.

**Firmware region.** There is no ROM hardware beyond the 256-byte overlay.
Firmware is an image the HPS streams into SDRAM at core start (`boot1.rom`, or
OSD *Load Image*) with the CPU held in reset; the file's byte offset is its flat
address. Write protection is a compare in the `we` path only — putting it high
makes that a 4-bit match (`cpu_a[23:20] == 4'hF`), and it must **never** enter
the `ready` cone (see the header of [rtl/flat_sdram.sv](../rtl/flat_sdram.sv)).

### Bank 0 is the scarce resource — constraints for whatever runs on this

Bank `$00` is **64 KB, permanently**. That is not a budget decision that could be
revisited by spending more M10K: the 65816 forces both the **stack** and the
**direct page** into bank `$00` regardless of what DBR/PBR hold, and a bank is
64 KB by architecture. It is already fully BRAM-backed, so this is the whole of
the machine's fast memory, forever. Concurrency is capped by bank 0, not by the
16 MB.

**Direct pages: 254 usable, not 256.** Direct page is set by the 16-bit D
register, and any page-aligned value works — except that the I/O page and the
vector page are not RAM:

| | Pages |
|---|---:|
| `$0000-$9E00` | 159 usable |
| `$9F00` | I/O — unusable |
| `$A000-$FE00` | 95 usable |
| `$FF00` | vectors — reserve |
| **Usable** | **254** |

**Never allocate `$9E00` as a direct page.** Native-mode direct-page arithmetic
wraps within *bank 0*, not within the page (unlike emulation mode), so an
indexed access such as `lda $80,x` from a `$9E00` base can reach `$9F4x` and hit
the YM2151. Leave that page unallocated as a guard.

**Keep D page-aligned.** If `D & $00FF != 0`, *every* direct-page access costs
one extra cycle. The core implements this exactly as the real part does --
`DLNoZero` at [P65C816.vhd:97](../rtl/cpu/65C816/P65C816.vhd#L97), applied at
line 134 and gated on native mode (`EF = '0'`; in emulation mode D is forced to
`$0000` so the penalty cannot arise). With D aligned, direct page is exactly as
fast as 6502 zero page — and unlike a real 65816 with uniform RAM, here it is
also stall-free, because bank 0 is BRAM while banks `$01+` stall on SDRAM.

**Interrupt handlers must establish their own D and DBR.** The interrupt
sequence forces PBR to `$00`
([P65C816.vhd:100](../rtl/cpu/65C816/P65C816.vhd#L100)), sets I and clears the
decimal flag (line 373), and leaves **D and DBR untouched** — DBR is written
only by `PLB` (lines 431-440) and by reset (line 410). So a handler cannot
assume either register and must save and set both:

```asm
    phd
    phb
    lda #$0000
    tcd                 ; kernel direct page
    phk
    plb                 ; DBR = $00
    ; ... handler body ...
    plb
    pld
    rti
```

That is roughly 14 cycles of prologue/epilogue — the price of D being
relocatable, and a strong argument for pinning the kernel's direct page at a
fixed, well-known address.

**The upside.** Because D and S are both registers, a context switch swaps the
direct page with `TCD` and the stack with `TCS` — two instructions for both,
with both landing in BRAM. That is impossible on a 6502 and is the natural
design here.

---

### Banks `$01-$04` — 256 KB of BRAM

`rtl/fast_ram.sv`. The HPS loader drops a program image at `X816_PROG_BASE`
(`$01:0000`), and every linker map in the tree places code from there — so a
program's code is in single-cycle BRAM **without being rebuilt**.

That is worth 4.47x, measured on hardware: `BANKBNCH.BIN` ran one workload from
bank `$01` and the same bytes from bank `$00` and took 850 ms against 190
(`doc/AUDIT.md` §6.2). An SDRAM access costs about 6 CPU cycles against 1 for
BRAM, and since every instruction byte is a memory access, ordinary code pays
that on almost every fetch.

**VERA dropped from 352 KB to a stock 128 KB to pay for it** — 224 M10K blocks
moved from VRAM to program RAM. A design that made the block switchable
between VERA and the CPU was tried first and could not be built (three
synthesis failures; Quartus M10K inference rejects every packing a runtime
mux needs), which is why there is no mode and no register: the allocation is
permanent. The attempt's documents live in git history.

The array is 32 bits wide with byte enables, not byte-wide: M10K is 10,240 bits
and a byte-wide array uses only 8,192 of them, so 256 KB would have cost 260
blocks instead of 205. `addr[1:0]` picks the byte.

Nothing else moved. `MEM_ALLOC`'s arena still starts at `$20:0000` and is still
SDRAM, so the ~13 MB heap is unchanged, and the firmware region `$F0-$FF` is
untouched.

## 2. I/O page — `$00:9F00-$00:9FFF`, 256 B

Deliberately byte-for-byte the Commander X16's layout, so VERA/VIA/YM register
offsets and any driver written against them port over unchanged.

| Range | Size | Device |
|---|---:|---|
| `$9F00-$9F0F` | 16 B | VIA #1 — SNES pads, I²C to the SMC |
| `$9F10-$9F1F` | 16 B | VIA #2 — user port |
| `$9F20-$9F3F` | 32 B | VERA |
| `$9F40-$9F4F` | 16 B | YM2151 (IKAOPM) |
| `$9F50-$9F7F` | 48 B | unmapped — open bus |
| `$9F80-$9F8F` | 16 B | SYSCTL (X816-specific, see below) |
| `$9F90-$9F93` | 4 B | free-running millisecond timer (see below) |
| `$9F94-$9FFF` | 108 B | unmapped — open bus |

Unmapped reads return the last byte on the data bus (floating-bus emulation),
not `$00` — returning zero makes device-probing code false-positive.

**SYSCTL `$9F80`** — bit 0 boot ROM overlay enable (1 at reset, write 0 to drop
it); bit 1 reads the CPU's live E flag, so software can assert it is really in
native mode.

### Millisecond timer — `$9F90-$9F93`

`rtl/ms_timer.sv`, and `timer_step`/`timer_read` in the emulator's
`src/memory.c`. A 32-bit little-endian count of milliseconds since reset,
read-only. `cpu_clk` is 8.000 MHz and the divider is 8000, so the tick is 1 kHz
exactly and 32 bits is 49.7 days.

| Range | |
|---|---|
| `$9F90` | `MS[7:0]` — **reading this latches bits 31:8** |
| `$9F91-$9F93` | `MS[31:8]`, from that latch |

**It is gated by nothing.** Not `cpu_rdy`, not a chip select — just `cpu_clk`
and reset. That is the entire point of the device and not an oversight: both
VIAs take `.enable(cpu_rdy)` and stop dead for the whole length of an SD
transfer (`doc/AUDIT.md` L-4), and VERA's VSYNC interrupt is a single latch, so
a freeze spanning four frames still presents one interrupt and loses the other
three. Every timebase this machine already had ran slow in proportion to card
activity, silently. The keyboard diagnostic counters at `$9F8D-$9F8F` are the
same shape and the precedent.

**Software must read `$9F90` first, and that is normative.** The counter does
not pause for a four-byte read, so a read straddling a carry (`$..FF` → `$..00`
between two byte reads) returns a value that was never true and can go
*backwards* — fatal in a monotonic clock and intermittent enough to survive
testing. Reading the low byte captures bits 31:8 into a shadow, so a 16-bit
`lda $9F90` followed by a 16-bit `lda $9F92` yields one coherent 32-bit value.
That is what `runtime/kirq.s` does for `TIME_GET`.

Proven on the real RTL by `sim/run.sh timer`: the rate, the latch checked
across a carry, and the count still advancing while `cpu_rdy` is held low —
measured twice, stalled and running, and required to agree.

### SD block device — `$9F81-$9F8C`

`rtl/sd_block.sv`, and `src/sdblock.c` in the emulator. The guest SD card is a
FAT32 image file on the MiSTer's own SD card, mounted from the OSD
(`SC0,IMG,Mount SD`) and served block-by-block by the HPS. FAT32 is parsed by
the guest; the HPS only moves 512-byte blocks.

| Address | Register |
|---|---|
| `$9F81-$9F84` | `LBA[31:0]`, little-endian |
| `$9F85-$9F87` | `MEM[23:0]` DMA address, little-endian (`READ` only) |
| `$9F88` | `COUNT` — blocks, 1-255 (`READ` only) |
| `$9F89` | `CMD` — write-only |
| `$9F8A` | `STATUS` — read-only |
| `$9F8B` | **reserved — must stay unmapped**, see below |
| `$9F8C` | `DATA` — block-buffer window, auto-incrementing |

`CMD`: 1 = `READ` (card → memory, `COUNT` blocks, by DMA), 2 = `WRITE`
(buffer → card, one block), 3 = `READBUF` (card → buffer, one block, memory
untouched), 4 = rewind the buffer window.
`STATUS`: bit 0 busy, bit 1 error, bit 7 card present.

**`CMD` and `STATUS` are separate addresses on purpose.** The obvious design is
one register — write the command, read the status back — and it does not
survive a C compiler: Calypsi elides a volatile read that immediately follows a
volatile write to the *same* address, and tests the value it wrote instead.
`SD_CMD = 3; return SD_CMD & 2;` loses its read, and command 3 has bit 1 set,
so every status check returned "error". Splitting the addresses removes the
hazard at the source: a read of `STATUS` is never a read of the address just
written, so there is nothing for an optimiser to fold. It is also the more
honest description of the hardware — these were always two different registers
wearing one address.

**Error means "that block is not on this card".** Every request is
bounds-checked against the mounted image's size, per block, so a multi-block
read that runs off the end fails at the block that does and leaves the earlier
ones in memory. An unmounted card reads as zero blocks, so every request
errors — which is what a caller wants when there is no card. This check is the
device's *only* way to fail: `hps_io` has no error line, so without it a
request past the end returns whatever the HPS supplies and `ack` still
arrives. A block device that always reports success is worse than a slow one,
because the filesystem above it cannot tell a short card from a good one.

**Software never polls.** The CPU is frozen for the whole transfer, so the
instruction after the `CMD` write executes once it has completed — read
`STATUS` (`$9F8A`) afterwards to check for an error. Busy therefore always
reads back 0; the CPU cannot observe itself stalled, for the same reason
`cpu_wait_state` is not exposed in SYSCTL.

`READBUF` exists because a FAT chain walk or a directory scan inspects a few
bytes of a sector, and copying it into RAM first would be wasted work.

**`$9F8B` is a deliberate gap and nothing readable may ever go there.** `DATA`
has a read side effect — it advances the buffer pointer — and a 16-bit read is
two bus cycles, so reading the register immediately *below* `DATA` also reads
`DATA` and eats a byte. When `DATA` sat at `$9F8A`, next to the status
register, every status check silently consumed a byte of the sector. That is
not an exotic case: the Calypsi manual states the compiler "may generate code
that reads 8 and 24 bit objects using 16 bit access", so an ordinary C status
poll does it. It showed up as an assembly test passing while the identical C
sequence failed. Only the register *below* a side-effecting one is at risk;
registers above it are fine.

**This is not the X16's SD path.** The X16 bit-bangs VERA's SPI at `$9F3E` with
an emulated SPI card behind it — CMD17/CMD24, CRC7, R1 polling, one byte per
transfer, and a CPU stall on `$9F3E` reads to stop a fast write loop dropping
bytes. X816's kernel is written from scratch (see [KERNEL.md](KERNEL.md)), so
there is nothing to be compatible with: a 24-bit DMA address is the natural
shape for a flat 16 MB machine, and the stall hack disappears with the SPI.

Writes go through the buffer rather than by DMA on purpose. The memory loader
ports are write-only, so a memory-to-card DMA would have to read main memory
through the CPU port, which means muxing into the stall network that
[rtl/flat_sdram.sv](../rtl/flat_sdram.sv) warns about at length. Reads are the
hot path for a filesystem; writes are rare, and buffered writes are still far
faster than SPI because there is no per-byte command overhead.

`$9F8D-$9F8F` — keyboard diagnostic counters, beside the SD device rather than
part of it ([x816.sv](../x816.sv)): make codes that crossed into the core
(`$9F8D`), makes that reached the SMC key FIFO (`$9F8E`), keys dropped because
the FIFO was full (`$9F8F`). Free-running 8-bit, wrapping, cleared only by
reset — software reads them twice and subtracts, and the first counter that
falls short of what was typed names the stage that lost the keystroke. That
fills the `$9F8x` block, so the firmware write-protect enable can no longer go
here.

---

## 3. VERA VRAM — 128 KB, separate address space

Reachable only via `$9F20-$9F22` (address) + `$9F23`/`$9F24` (data). Not part of
the CPU's 16 MB. This is stock VERA v0.9: 131,072 bytes, a 17-bit byte address.

| Range | Size | Contents |
|---|---:|---|
| `$00000-$1F9BF` | 129,472 B | tilemaps, tile data, sprite data, bitmaps |
| `$1F9C0-$1F9FF` | 64 B | PSG registers |
| `$1FA00-$1FBFF` | 512 B | palette |
| `$1FC00-$1FFFF` | 1,024 B | sprite attributes |

The last three are **windows, not storage set aside**: a write in that range
updates both the register file and the VRAM underneath. That matters for
bitmaps — any framebuffer reaching `$1F9C0` repaints the palette with its own
pixels as it draws, and the picture simply comes up in the wrong colours, which
looks nothing like an address bug. The largest clear run is therefore
**129,472 bytes** (`$00000-$1F9BF`).

### What fits — and what the renderer can scan

**Two independent limits, and memory is only one of them.** A bitmap mode has
to fit in VRAM *and* be one the layer renderer can address to the last line.

The second limit is easy to miss.
[layer_renderer.v:191-197](../vera/fpga/source/graphics/layer_renderer.v#L191-L197)
computes the bitmap line address from `line_idx_mul5` (`line_idx × 5`) and
**truncates it differently per mode**:

| Depth / width | Line-address expression | Truncated to | Usable lines |
|---|---|:--:|---:|
| 8bpp / 640 | `{line_idx_mul5[9:0], 5'b0}` | 10 bits | **205** |
| 8bpp / 320 | `{line_idx_mul5[10:0], 4'b0}` | 11 bits | 410 |
| 4bpp / 640 | `{line_idx_mul5[10:0], 4'b0}` | 11 bits | 410 |
| 4bpp / 320, and all 2bpp / 1bpp | full `line_idx_mul5` | — | 512 |

Past the cap the address wraps and the top of the screen repeats. This is stock
VERA v0.9 behaviour, not something the X816 changed.

Putting both limits together, at 128 KB:

| Mode | Bytes | Fits VRAM | Renderer can scan it | Usable |
|---|---:|:--:|:--:|:--:|
| 640×480 8bpp | 307,200 | ❌ | ❌ (205 lines) | ❌ |
| 640×240 8bpp | 153,600 | ❌ | ❌ (205 lines) | ❌ |
| 640×480 4bpp | 153,600 | ❌ | ❌ (410 lines) | ❌ |
| 640×200 8bpp | 128,000 | ✅ (just) | ✅ | ⚠️ leaves 1,472 B |
| **320×240 8bpp** | **76,800** | **✅** | **✅** | **✅** |
| 640×240 4bpp | 76,800 | ✅ | ✅ | ✅ |
| 640×480 2bpp | 76,800 | ✅ | ✅ | ✅ |
| 320×240 4bpp | 38,400 | ✅ | ✅ | ✅ double-buffers |
| 640×480 1bpp | 38,400 | ✅ | ✅ | ✅ double-buffers |

**No 640×480 mode above 2bpp is reachable.** 4bpp fails twice over: 153,600
bytes against 131,072 of VRAM, and the renderer wraps at line 410 of 480. 8bpp
fails harder — it could never scan more than 205 lines even with 352 KB, which
is why the withdrawn 640×480 8bpp work needed the framebuffer *and* a renderer
that could reach it.

**320×240 8bpp is the practical bitmap mode.** 76,800 bytes leaves ~52 KB for
tiles and sprites, the renderer scans it with room to spare, and `blit816`
clears it in ~0.8 ms against ~38 ms through the CPU data port
([BLIT816.md](BLIT816.md)) — which is what makes it usable at 8 MHz at all.
Double-buffering it does not fit; page-flipping at 4bpp does.

### Why high resolution is VERA2's job — and VERA2 exists

**[VERA2.md](VERA2.md) is built**: a 640×480 linear framebuffer (4bpp and
8bpp, both measured to fit the fetch budget) scanned out of the `$E0:0000`
SDRAM window and composited over VERA, with a vsync-latched display base for
tear-free page flips.

VRAM itself cannot simply be grown back: the M10K is spent (§4), and a 352 KB
VERA shipped here until 2026-08-02 before being traded for program RAM (its
documents live in git history).

But **only part of a high-resolution mode actually needs to be VRAM.** Tilemap,
tile and sprite fetches are random-access at ~160 scattered accesses per line;
only a bitmap layer is sequential. That is why VERA's own hardware uses on-chip
SPRAM, and why the X16's VERA2 could be a line-prefetch streaming engine out of
SDRAM rather than a memory. **Anything random-access must stay in BRAM; a
sequentially-scanned framebuffer need not.** That asymmetry is the whole case
for VERA2, and it is stronger now than when it was first weighed: the CPU runs
from BRAM and no longer competes for SDRAM bandwidth.

---

## 4. Physical backing

### On-chip M10K — 553 blocks on the 5CSEBA6U23I7

| Consumer | Blocks |
|---|---:|
| `fast_ram` — banks `$01-$04` (256 KB) | 256 |
| VERA VRAM (128 KB) | 128 |
| `bank0_ram` (64 KB) | 64 |
| VERA2 line buffer + palette | 2 |
| `boot_rom` (256 B) | 1 |
| ascal, line buffers, palette, sprite RAM, FIFOs | 91 |
| **Total** | **542 / 553 (98%)** |
| **Free** | **11** |

**Block RAM is the binding constraint, and timing is not.** That distinction
matters for anything proposed next, so both numbers are here (build of
2026-08-03, stock VERA + `blit816` + VERA2):

| | |
|---|---|
| M10K | **542 / 553 (98%)** — 11 free |
| ALMs | 19,421 / 41,910 (46%) |
| Worst slack, any corner | **+0.087 ns** — framework PLL clocking, as before |
| Negative slack | **none** |

Every tight path belongs to the MiSTer framework's PLL/HDMI clocking, not to
X816 logic. The CPU (8 MHz), VERA (25 MHz) and SDRAM (100 MHz) domains all
close comfortably.

So: **anything new that wants block RAM has to take it from something already
here** — 13 blocks is nothing, and VERA2's line buffers are exactly that kind
of consumer. But there is ALM room (57% free) and real timing margin, so the
constraint on a new engine is memory and not speed.

Packing runs ~80%: VERA's arrays are nibble-wide (required for VERA FX's 4-bit
write enables) and M10K's ×4 mode uses 4 of 5 bits per word. Roughly 1 block
per KB.

For comparison the X16 core sits at **550/553 (99%)** — it had no BRAM left,
which is exactly why its VERA2 had to live in SDRAM. Dropping the 256 KB system
ROM and 40 KB LowRAM is what made headroom available here, and it has now been
spent: on program RAM, which every binary benefits from without being rebuilt.

### SDRAM

`sdram.v` is not plainly byte-addressed: `addr[23:0]` is a **word** address and
`addr[24]` selects the byte lane ([rtl/sdram.v:164-167](../rtl/sdram.v#L164-L167)).

| | Current mapping `{1'b0, cpu_a}` | Planned remap `{cpu_a[0], 1'b0, cpu_a[23:1]}` |
|---|---|---|
| Words claimed | 16 M (`$000000-$FFFFFF`) | 8 M (`$000000-$7FFFFF`) |
| Part consumed | **32 MB** — one word per CPU byte, high half wasted | **16 MB** — both lanes used |
| Free | 16 MB (all of lane 1) | 16 MB (words `$800000+`) |
| `dout16` usable for 16-bit fetch? | **no** — consecutive bytes are in different words | **yes** |

Either way a **32 MB or larger** MiSTer SDRAM module is required; 8 MB parts
cannot back a flat '816. Bank `$00`'s words are claimed but unused — that region
is served by BRAM.

The free 16 MB is where a pristine firmware image could sit for a SYSCTL-driven
"restore firmware on reset", since the CPU never addresses it.
