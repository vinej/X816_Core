# The switchable 256 KB — fast program RAM, or VERA's extra VRAM

A plan, not a description: nothing here is built. Written 2026-08-02, after
`BANKBNCH.BIN` measured what executing from SDRAM actually costs.

---

## 1. What is being built

One 256 KB block of BRAM, instantiated **always**, wired to one of two owners
by a mode bit:

| mode | the 256 KB belongs to | VERA | banks `$01-$04` | for |
|---|---|---|---|---|
| **VIDEO** (default) | VERA | **352 KB**, exactly as today | SDRAM | high-resolution graphics |
| **FAST** | the CPU | 128 KB, stock | **BRAM** | everything compute-bound |

In FAST mode a program gets **256 KB of 4.5×-speed code space plus 13 MB of
SDRAM** for data. In VIDEO mode the machine is byte-for-byte what it is today.

**The whole point is that FAST mode needs no source changes.** Programs already
link to `$01:0000`; in FAST mode that address *is* BRAM. Every existing binary
gets the speedup by being loaded, not by being rewritten. That is the property
that makes this worth RTL work — a smaller window that programmers had to
opt into by hand-placing code would not be.

---

## 2. Why — the measurement, and two premises that moved

`doc/AUDIT.md` §6.2: **code executing from SDRAM runs 4.47× slower than the
same code from BRAM** — ~6 cycles per SDRAM access against 1. Measured on a
DE10-Nano by `BANKBNCH.BIN`, which runs one workload twice, in place in bank
`$01` and from a copy in bank `$00`, and prints the bank it really executed in
so the two cannot be confused.

That number moves two things `doc/VERA_MEMORY_REVIEW.md` §3 rested on, and §4
there records it:

* **"CPU-from-SDRAM contention"** was the first cost listed against porting
  VERA2. It is real, now quantified, and *removable* — give the CPU BRAM and
  it stops competing for SDRAM, which is exactly the condition VERA2's SDRAM
  framebuffer needs. The two changes dissolve each other's blocker.
* **"Fill rate is the bottleneck, not capacity"** still holds, and now cuts
  the other way: fill rate is one `sta` per pixel, a CPU-throughput limit, so
  a 4.5× CPU is a 4.5× fill rate.

The upstream position helps too: VERA2 with 1 MB of SDRAM is proven in
X16_MiSTer, so FAST mode does not mean giving up high resolution — it means
sourcing it from SDRAM instead of BRAM, which is where a 1 MB framebuffer
belongs anyway.

And VERA816's extensions are opt-in, so **128 KB VERA in FAST mode is stock
VERA**: software that does not use the new registers runs unchanged.

---

## 3. Does it fit?

From `output_files/X816.fit.rpt` at `X816_20260802`: **553 M10K blocks, 507
used (92%), 46 free.**

| | M10K |
|---|---:|
| VERA today, 352 KB | 282 |
| proposed: VERA base 128 KB | 103 |
| proposed: switchable block 256 KB | 205 |
| **proposed total** | **308** |

**+26 blocks → 533/553 (96%), 20 free.** It fits, and only just.

Two honest caveats. These counts assume near-perfect packing at whatever width
each memory is inferred with; VERA's `main_ram` may pack worse, and the fitter
is the only authority. And 96% is where placement and timing closure start to
fight back — §7 treats that as the main risk, not the arithmetic.

**In VIDEO mode only 224 KB of the 256 is used**, keeping VRAM at exactly 352
KB. The 32 KB idles. That is deliberate: 256 KB is four whole banks for the
CPU, which keeps the address decode trivial, and VERA staying at 352 KB means
**zero** software or documentation impact in the default mode. Extending VERA
to 384 KB instead was considered and rejected — VERA_MEMORY_REVIEW.md §2 found
more VRAM "buys nothing", and it would churn VERA816.md for a mode nobody
asked to change.

---

## 4. What switches, and what does not

Switched by the mode bit:

* the 256 KB block's owner
* the CPU's decode for banks `$01-$04` — BRAM in FAST, SDRAM in VIDEO
* VERA's reach above `$1FFFF`

**Not** switched, in either mode:

* bank `$00` — always BRAM, always the kernel's and the I/O page
* banks `$05-$EF` — always SDRAM; `MEM_ALLOC`'s arena at `$20:0000` is
  untouched, so the 13 MB heap is the same in both modes
* the firmware region `$F0-$FF` — always SDRAM, always write-protected
* the I/O page, the SD block device, the boot overlay

**The mode is chosen at boot and requires a reset**, because switching
invalidates whatever the block held. It is not a live toggle and should not
pretend to be.

---

## 5. The six paths that need a mux

Every route that can reach banks `$01-$04` has to know which memory answers.
`bank0_ram` already does all six for bank `$00`, so each is a known pattern
rather than new ground:

1. **CPU decode** — `flat_cs` currently claims all of `$01-$FF`
2. **`cpu_di` read mux**
3. **the write path**
4. **the HPS loader** — it drops program images at `PROG_BASE $01:0000`, which
   in FAST mode is BRAM
5. **SD DMA** — `sd_block` writes to arbitrary 24-bit addresses
6. **the stall network** — BRAM is single-cycle and SDRAM is not, so `cpu_rdy`
   must stop being asserted for bank `$01-$04` accesses in FAST mode

Item 6 is the one to be careful with: it is on the critical path and it is
also what delivers the speedup.

---

## 6. Order of work

Sim before silicon, contract before code — the rules this tree already runs
under.

1. **Contract first.** The mode bit in the SYSCTL page, the FAST-mode bank
   range, and the block size, into `tools/contract.py`. Every consumer —
   RTL, boot ROM, emulator, linker maps — takes them from there, and
   `--selftest` proves the checks can fail.
2. **`rtl/switch_ram.sv` + a testbench, no Quartus round.** Prove both modes
   address the right memory, that the mode bit does nothing while the CPU is
   mid-access, and that VERA cannot see the block in FAST mode. `sim/run.sh
   switch`, with a negative control that mis-wires one mode and must be
   caught — the same discipline `tb_ms_timer` follows.
3. **The emulator, including the SDRAM cost model.** Two parts, and the second
   matters more than it looks: the emulator currently models a uniform
   single-cycle machine, which `BANKBNCH` showed is an *exact* model of BRAM
   and optimistic by 4.5× for SDRAM. Add ~6 cycles per bank-`$01+` access and
   emulator timings become predictive instead of blind — without it, every
   future optimisation has the same hole that hid the MVN stub result.
4. **RTL integration** — the six muxes in `x816.sv`. One Quartus round.
5. **Boot and kernel** — who chooses the mode (OSD, SYSCTL at boot, or a
   kernel decision), and the reset that follows.
6. **Linker maps and docs** — a FAST-mode map, `MEMORY_MAP.md`, and a
   conformance test that proves a program really executed from BRAM. `BANKBNCH`
   already has the mechanism: it reports the bank it ran in, and the same trick
   proves the mode took effect.

VERA2 is **not** in this plan. It becomes worth reopening once FAST mode
exists and capacity is the limit again; `VERA_MEMORY_REVIEW.md` §2 still prices
the rest of it honestly — burst reads on the SDRAM side, the byte-lane
carve-out, `DISPBASE`, the `$9F60` bank, an emulator model, conformance tests.

---

## 7. Risks, in the order they are likely to bite

* **96% M10K.** The arithmetic fits with 20 blocks spare; the fitter may not.
  If it does not, the fallback is a 192 KB block (banks `$01-$03`, ~154
  blocks, +? on today) — still three banks, still no source changes.
* **Timing closure** on the widened read mux and the changed stall network, at
  96% occupancy.
* **Two memory maps to test.** Some conformance surface doubles, and every
  result now has to say which mode produced it. The card's help text and every
  `run-*.sh` verdict should name the mode.
* **A program that assumes SDRAM timing.** Nothing in the tree does today, but
  anything hand-tuned against SDRAM stalls would change behaviour.
* **The 32 KB idle in VIDEO mode** is real waste. It buys a clean four-bank
  decode; if blocks turn out to be the binding constraint, this is the first
  thing to reconsider.

---

## 8. What would make this unnecessary

Worth stating so it is checked rather than assumed. `$00:A000-$00:FDFF` is
23.5 KB of bank `$00` already free in the program map, and `x816_exec_init`
and `bankbench.s` both already run code there. If a linker section put a
program's *hot* code in that window and the measured gain on real workloads
were most of the 4.5×, the RTL work would buy convenience rather than speed.

The reason to expect otherwise is §1: 23.5 KB needs the programmer to choose
what goes in it, and 256 KB at `$01:0000` needs nobody to choose anything. But
the cheap experiment exists, costs no Quartus round, and should be run before
step 4 commits silicon.
