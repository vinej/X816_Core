# VERA memory review — 352 KB BRAM vs the VERA2 SDRAM layer, and what gaming actually needs

> ## HISTORICAL — written when VRAM was 352 KB
>
> **This review analysed a configuration that no longer exists.** VERA went back
> to a stock 128 KB on 2026-08-02 ([VERA816.md](VERA816.md)), so every capacity
> claim below is about memory the core no longer has.
>
> **In particular §1.5 is now false.** It says the 352 KB re-partitions as two
> 640×480 4bpp framebuffers and that double-buffering that mode needs no RTL.
> At 128 KB **a single 640×480 4bpp framebuffer does not fit**: it is 153,600
> bytes against 131,072 of VRAM. Nor does 640×240 8bpp, which is the same
> 153,600. See [MEMORY_MAP.md](MEMORY_MAP.md) §3 for what does fit — the short
> answer is 320×240 8bpp.
>
> **What survived the review is its conclusion**, option D: the blitter was
> built, is green on hardware, and is the one part of this analysis still in the
> core ([BLIT816.md](BLIT816.md)). The fill-rate arithmetic in §4 also stands,
> and improved — fill rate is CPU-bound, so the 4.47× CPU is a 4.47× fill rate.
>
> Kept because the VERA2-versus-BRAM question is now live again, and this is the
> record of how it was reasoned about the first time.

Date: 2026-08-01. Question under review: was dropping VERA2 (the upstream
SDRAM bitmap layer) in favour of the 352 KB VERA816 BRAM widening the right
call — given that 640×480 4/8bpp software rendering may be too slow for
gaming — and should we give VERA more BRAM, keep VERA2 for high resolution,
or something in between?

Facts below come from the last fitter run (`output_files/X816.fit.summary`,
2026-07-31), [VERA816.md](VERA816.md), upstream `x16_mister/vera_2.md`, and a
measured fill loop from the new simulation suite.

---

## 1. Hard constraints first

### 1.1 There is no spare BRAM. That option is dead.

```
Total RAM Blocks : 507 / 553  (92%)     <- the binding constraint
Total block memory bits : 3,888,010 / 5,662,720  (69%)
```

VERA816.md §1's premise — "X816 has M10K to spare, 282/553" — described the
core *before* the widening. The widening itself consumed the spare: VRAM is
352 of those 507 blocks, and blocks (not bits) are the limit because FX's
nibble write-enables force ×4 M10K mode (4 of 5 bits used, VERA816.md §7).
46 free blocks ≈ **+40 KB VRAM absolute ceiling at 100% utilisation**, which
does not fit or close timing in practice. Realistic headroom is ~2–3 M10K for
small FIFOs/palettes — enough for a new engine's buffers, nowhere near enough
to matter for framebuffers. **"Give VERA more BRAM" is not available.**

### 1.2 The X816-specific fact that changes the VERA2 math

Upstream, VERA2's cost was mild: *"8bpp scanout uses roughly ¾ of the SDRAM
read bandwidth… HiRAM-heavy programs may run slightly slower"* (vera_2.md §8)
— because the upstream 65C02 ran from BRAM ROM/lowram and touched SDRAM
occasionally. **X816's CPU executes from that SDRAM.** Every opcode fetch
above bank 0 goes through `flat_sdram` (one 16-bit word per ~9-cycle access,
no bursts, ~11 M accesses/s total). An 8bpp 640×480 scanout needs ~9.2 M
word-reads/s during active display — **~83% of all access slots** — so a
straight port of VERA2 would stall the CPU to a fraction of its speed for
~80% of every frame. Upstream's "slightly slower" becomes X816's "first-order
CPU tax". Any X816 VERA2 port therefore needs a **page/burst read path added
to the SDRAM side** (amortising to ~2–3 cycles/word puts scanout back to
~20–25% of bandwidth) — that, not the register file, is the real engineering
cost. 4bpp halves all of this; it is the only depth an unmodified controller
could plausibly carry, and marginally.

### 1.3 Where the "too slow for gaming" actually lives

The bottleneck is the **CPU fill rate through a data port**, and it is the
same wall wherever the framebuffer lives (BRAM or SDRAM — both take one `sta`
per byte):

| Fill method | Rate | 640×480 8bpp (300 KB) | 640×480 4bpp (150 KB) | 320×240 8bpp (75 KB) |
|---|---|---|---|---|
| Measured naive loop (boot.s bands, 11.3 cyc/px in sim) | 0.7 MB/s | 434 ms (2.3 fps) | 217 ms | 108 ms |
| Tight unrolled `sta` (~5 cyc/B) | 1.6 MB/s | 192 ms (5 fps) | 96 ms (10 fps) | 48 ms (21 fps) |
| **VERA FX cache writes** (4 B/`sta`, already shipped in this VERA) | ~5–6 MB/s | ~55 ms (18 fps) | ~27 ms (37 fps) | ~13 ms (75 fps) |
| **Hardware blit/fill in VRAM** (32-bit @ 25 MHz, §3 option D) | ~100 MB/s | **3.1 ms** | 1.6 ms | 0.8 ms |

Two conclusions: (a) moving the framebuffer to SDRAM does **not** make games
faster — VERA2's win is *capacity* (1 MB, save-under, room for double
buffers), and its blit is a copy engine, not a renderer; (b) the thing that
turns "too slow for gaming" into "60 fps" is a **blitter**, and a blitter
into BRAM VRAM is faster than anything SDRAM can offer, with zero CPU-stall
side effects.

### 1.4 What VERA2 actually was (so we compare the real thing)

From upstream `vera_2.md`: 640×480 only (no 320×240, no other rasters),
8bpp/4bpp, 1 MB SDRAM window addressed by a 20-bit pointer with signed
strides, readable DATA (GUI save-under), separate 256×RGB444 palette, and a
byte-wise SDRAM→SDRAM **copy** blit ($9F69–$9F6F, runs below scanout
priority). Composition: replaces VERA wholesale, or `passthru` lets VERA's
opaque pixels (sprites, mouse) ride on top — the `vera_opaque` hook is still
wired in `x816.sv:537`. Two gaps for gaming even upstream: **it always scans
from offset 0** (no display-base register → no true page flip; vera_2.md §8
lists double-buffering as future headroom), and the blit only copies (fills
use a log₂ seed-doubling trick). Internally the framebuffer is **planar
across the two SDRAM byte lanes** — on X816 that collides with the CPU's
lane-0-of-every-word mapping, so a port must either carve the top CPU banks
(e.g. $F8–$FF, 512 KB the flat map would give up) or adopt the lane remap
already sketched in `flat_sdram.sv`'s header (2 bytes/word for the CPU too —
a bigger change to a silicon-proven module).

### 1.5 What the 352 KB already buys that nobody is using yet

The populated VRAM is **exactly** 307,200 + 53,248 bytes. Those same bytes
re-partition as **two 640×480 4bpp framebuffers (2 × 153,600) + the full
53 KB tile/sprite region = 360,448 = the populated 352 KB to the byte**. With
`L0_BASEX`/`TILEBASE` repointed at vsync, **double-buffered 640×480 4bpp is
possible today with zero RTL**. Likewise 320×240 8bpp double-buffering
(2 × 75 KB) fits trivially. And the classic gaming path — two scrolling tile
layers + 128 sprites — is VERA's native strength and needs no framebuffer at
all. One thing does block the asset region: sprites cannot fetch above
128 KB (AUDIT.md M-1) — that fix is prerequisite to any of this.

---

## 2. Options, honestly priced

| | Gain | Cost | Verdict |
|---|---|---|---|
| **A. Status quo** (352 KB, software rendering) | 640×480 8bpp single-buffer; 4bpp double-buffer; tiles+sprites; FX-assisted fills to ~18–37 fps | none | Right foundation, wrong endgame for full-motion 8bpp |
| **B. More BRAM to VERA** | +40 KB theoretical | Unfittable at 92% blocks; buys nothing (gap to 8bpp double-buffer is 250 KB) | **Rejected — physically off the table** |
| **C. Port VERA2 (SDRAM, 1 MB)** | Capacity: 8bpp double-buffer + 400 KB scratch; save-under GUI idioms | Burst-read upgrade to the SDRAM path (the real work), lane-plan carve-out, DISPBASE + fill-blit additions it never had, $9F60 bank, emulator model + contract doc + conformance tests; CPU-stall risk managed but never zero | Defer until a concrete need (see §3); not a drop-in on X816 |
| **D. VRAM blitter** (new, small) | Fill+copy at ~100 MB/s into existing VRAM → 60 fps full-frame 4bpp double-buffered and fast-repaint 8bpp; no SDRAM contention, no CPU stall | ~1 new engine (≈ upstream `bitmap_engine.sv` size, 250 lines) + register bank + a 5th `vram_if` port or CPU-port arbitration; ~2–3 M10K for FIFOs (fits); sim TB first | **The high-leverage move** |

## 3. Recommendation

1. **Do not grow VRAM (B), do not port VERA2 now (C).** The fitter closes B;
   for C, X816-specific costs (CPU-from-SDRAM contention, lane conflict, and
   VERA2's own missing page-flip) mean it is a project, not a port — and its
   headline gain (capacity) is not today's bottleneck (fill rate is).
2. **Software first, zero RTL:** adopt FX cache-write fills and the
   `L0_BASEX` page-flip convention; ship 320×240 8bpp and 640×480 4bpp
   double-buffered demos. This alone reaches "playable" for most 2D gaming,
   alongside tiles/sprites which were always the real game path.
   Prerequisite: the sprite-reach fix (AUDIT.md M-1), batched with the next
   Quartus round.
3. **Then add the VRAM blitter (D)** as the gaming enabler: fill + copy +
   (later) VRAM→VRAM with stride for software sprites. Borrow VERA2's proven
   register contract ($9F69–$9F6F shape: SRC=pointer, DST, LEN, CTRL/busy) so
   software idioms and even save-under carry over, but aimed at VRAM.
   Sim-first per SIMULATION.md conventions — the testbench is small and the
   upstream `tb_blit` shows the shape.
4. **Reopen C only on a concrete trigger:** a title/toolkit that needs
   double-buffered 640×480 **8bpp**, >352 KB of live pixel assets, or a GUI
   whose save-under exceeds VRAM scratch. If triggered, the port spec must
   include: burst reads on the SDRAM side, a DISPBASE register (real page
   flip), a fill mode on the blit, the lane carve-out decision, an emulator
   implementation, and a VERA2-816 contract doc with conformance tests — and
   it lands with the upstream sim TBs ported (tb_fb/tb_bmpregs/tb_bmpio/
   tb_blit/tb_bitmap).
5. **Doc updates now:** amend VERA816.md §1 (the "282/553 spare" premise is
   stale — post-widening the core sits at 507/553) and soften §10 from
   "VERA2 should be dropped" to "deferred behind the D-then-C ladder above",
   pointing here.

The one-line answer: **the 352 KB decision holds — capacity was never the
gaming bottleneck, fill rate is; fix fill rate with FX now and a small VRAM
blitter next, and keep VERA2 as a well-specified deferred option** for the
day 8bpp double-buffering or >352 KB of pixels becomes a real requirement.

---

## 4. Amendment, 2026-08-02 — both premises of §3 have moved

§3 said "reopen C only on a concrete trigger" and listed triggers of one kind:
a title needing double-buffered 640x480 8bpp, >352 KB of live assets, a GUI
whose save-under exceeds VRAM. None of those has happened. Something else did,
and it undercuts §3's *reasoning* rather than meeting its conditions.

**Measured on hardware (AUDIT.md §6.2): code executing from SDRAM runs 4.47x
slower than the same code from BRAM.** ~6 cycles per SDRAM access against 1.

That touches both premises this section rests on:

1. **"CPU-from-SDRAM contention" (§1.2) was the first cost listed against C.**
   It is real and now quantified — but it is also *removable*. Give the CPU's
   code BRAM and it stops competing for SDRAM at all, which is precisely the
   condition a VERA2 SDRAM framebuffer needs. The two changes each dissolve
   the other's blocker: C needs the CPU out of SDRAM, and getting the CPU out
   of SDRAM needs BRAM that only C can free. §1.2 assessed them separately
   because at the time moving the CPU was not on the table.

2. **"Capacity is not today's bottleneck, fill rate is" (§1.3) still holds —
   and now cuts the other way.** Fill rate is one `sta` per pixel, a CPU
   throughput limit. A 4.5x CPU is a 4.5x fill rate. The conclusion that
   moving the framebuffer to SDRAM does not make games faster remains correct;
   what changed is that *making the CPU faster* does, and the same BRAM
   reallocation delivers both.

**What does NOT change.** The other costs §2 priced against C are untouched:
burst reads on the SDRAM side (still "the real work"), the byte-lane carve-out,
the missing `DISPBASE` page flip, the `$9F60` bank, an emulator model, a
contract doc and conformance tests. C is still a project, not a port.

**One correction to §1.2's arithmetic.** It estimated SDRAM at "one 16-bit word
per ~9-cycle access". Measured, it is ~6 CPU cycles per access. The direction
of the argument is unchanged; the tax is a third smaller than assumed.

**And a methodology note that applies to everything above.** The emulator
matched hardware BRAM to within 1% (188 ms against 190) and understated SDRAM
by 4.5x. Every fps and fill-rate figure in §1 derived from emulator timings is
therefore optimistic for code running in bank `$01`. That does not overturn the
§1 conclusions -- they compare like with like -- but any *absolute* number in
this document should be read as a bank-`$00` figure.
