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
| `$01:0000-$EF:FFFF` | 15,663,104 B ≈ 14.94 MB | SDRAM | built | user RAM |
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
| `$9F90-$9FFF` | 112 B | unmapped — open bus |

Unmapped reads return the last byte on the data bus (floating-bus emulation),
not `$00` — returning zero makes device-probing code false-positive.

**SYSCTL `$9F80`** — bit 0 boot ROM overlay enable (1 at reset, write 0 to drop
it); bit 1 reads the CPU's live E flag, so software can assert it is really in
native mode. `$9F81-$9F8F` free — the firmware write-protect enable goes here.

---

## 3. VERA VRAM — separate address space

Reachable only via `$9F20-$9F22` (address) + `$9F23`/`$9F24` (data). Not part of
the CPU's 16 MB.

### As built — 128 KB, 17-bit address

| Range | Size | Contents |
|---|---:|---|
| `$00000-$1FFFF` | 131,072 B = 128 KB | tilemaps, tile data, sprite data, small bitmaps |

This is VERA v0.9 as shipped. It **cannot** do 640×480 8bpp: that needs 300 KB,
and [layer_renderer.v:197](../vera/fpga/source/graphics/layer_renderer.v#L197)
truncates the 8bpp/640-wide line address to 10 bits, wrapping after ~204 lines.

### Planned — 352 KB, 19-bit address

| Range | Size | Contents |
|---|---:|---|
| `$00000-$4AFFF` | 307,200 B = 300 KB | 640×480 8bpp framebuffer (layer 0) |
| `$4B000-$57FFF` | 53,248 B = 52 KB | tilemaps, tile data, sprite data |
| **populated** | **360,448 B = 352 KB** | |
| `$58000-$7FFFF` | 163,840 B | unpopulated (19-bit space is 512 KB) |

**The 52 KB is not a free choice.** Tilemap, tile and sprite fetches are
random-access at ~160 scattered accesses per line; only the bitmap layer is
sequential. That is why VERA's own hardware uses on-chip SPRAM
([main_ram.v:110](../vera/fpga/source/main_ram.v#L110), the `SP256K` blocks) and
why the X16's VERA2 had to be a line-prefetch streaming engine rather than a
memory. Anything random-access must stay in BRAM.

---

## 4. Physical backing

### On-chip M10K — 553 blocks on the 5CSEBA6U23I7

| Consumer | As built | With 352 KB VRAM |
|---|---:|---:|
| VERA VRAM | 128 | 352 |
| `bank0_ram` (64 KB) | 64 | 64 |
| `boot_rom` (256 B) | 1 | 1 |
| ascal, line buffers, palette, sprite RAM, FIFOs | 89 | 89 |
| **Total** | **282 / 553 (51%)** | **506 / 553 (91%)** |
| Free | 271 | 47 |

Packing runs ~80%: VERA's arrays are nibble-wide (required for VERA FX's 4-bit
write enables) and M10K's ×4 mode uses 4 of 5 bits per word. Roughly 1 block
per KB.

For comparison the X16 core sits at **550/553 (99%)** — it had no BRAM left,
which is exactly why VERA2 had to live in SDRAM. Dropping the 256 KB system ROM
and 40 KB LowRAM is what makes native 352 KB VRAM affordable here.

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
