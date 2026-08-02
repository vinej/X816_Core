# The switchable 256 KB — fast program RAM, or VERA's extra VRAM

A plan, not a description: nothing here is built. Written 2026-08-02, after
`BANKBNCH.BIN` measured what executing from SDRAM actually costs.

---

## 1. What is being built

One 256 KB block of BRAM, instantiated **always**, wired to one of two owners
by a mode bit:

| mode | the 256 KB belongs to | VERA | banks `$01-$04` | for |
|---|---|---|---|---|
| **FAST** (default) | the CPU | 128 KB, stock | **BRAM** | everything, normally |
| **VIDEO** | VERA | **384 KB** — 32 KB *more* than today | SDRAM | 640×480 8bpp and the VERA816 extensions |

**FAST is the default.** The machine is a fast-CPU machine that can be put into
a high-resolution graphics mode, not the other way round. In FAST a program
gets **256 KB of 4.5×-speed code space plus 13 MB of SDRAM** for data; in
VIDEO it is today's machine with a little more VRAM.

That choice has a consequence worth stating plainly: **out of the box,
`SCANOUT.BIN`, `SCANFULL.BIN`, `SCAN4.BIN` and `REGWIN.BIN` will not run** —
they need 352 KB. §4.1 is about how a program asks for the mode it needs.

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

The block count must come from VERA's *actual* packing, not from dividing bits
by 10,240. `main_ram.v` says so itself: eight 4-bit arrays, M10K x4 mode 2048
deep, **44 blocks per array x 8 = 352 blocks for 352 KB**. Nibble granularity
is required for FX's 4-bit write enables and costs 20% packing efficiency —
"M10K x4 mode uses 4 of 5 bits" — which a generic bits/10240 estimate misses
entirely. At VERA's organisation the rule is simply **1 M10K block per KB**.

So VERA is 352 of the 507 blocks in use, and everything else — `bank0_ram`,
the MiSTer scaler, VERA's audio FIFO and line buffers — is the other 155.

| switchable block | VIDEO VRAM | VERA blocks | total | free |
|---:|---:|---:|---:|---:|
| 192 KB | 320 KB — *less than today* | 320 | 475 | 78 |
| **224 KB** | **352 KB — unchanged** | **352** | **507 — exactly today** | **46** |
| **256 KB** | 384 KB | 384 | 539 | **14** |

**224 KB is free.** It costs not one extra block, leaves VERA at exactly the
352 KB it has now, and still hands the CPU 224 KB of BRAM. Its one cost is that
224 KB is three and a half banks: either the CPU takes banks `$01-$03` and 32
KB idles, or the decode carries one extra term for a half-populated bank `$04`
(`bank 1..3`, or `bank==4 && !addr[15]`). Neither is hard, and a program simply
sees fast memory from `$01:0000` up to `$04:7FFF` and SDRAM above it.

**256 KB costs 32 blocks and leaves 14 free — 97% occupancy.** That is where
placement and timing closure start pushing back, and the fitter is the only
authority. It buys four clean banks, 32 KB more fast RAM, and 384 KB of VRAM in
VIDEO mode.

**192 KB is rejected**: it would cut VIDEO-mode VRAM below what the machine has
today, which is a regression rather than an option.

In VIDEO mode VERA gets the whole block. An earlier draft of this document
wired only part of it to keep VRAM at exactly 352 KB and left the remainder
idle; that was wrong twice over — it wasted real memory for no gain, and 352 KB
is the *less* tidy number. 384 KB is `$00000-$5FFFF`, exactly six 64 KB banks,
against 352 KB's `$00000-$57FFF`. The existing 19-bit VRAM addressing already
spans it (2^19 = 512 KB).

Software written for 352 KB is unaffected — there is simply more above it. What
does need attention: `VERA816.md` documents 352 KB throughout and must be
amended, and two existing limits should be re-checked against a larger space
rather than assumed — the sprite-attribute reach (`AUDIT.md` M-1, which caps
sprite fetches at the first 128 KB) and where the REGWIN register windows sit.

**The block must keep VERA's nibble organisation** — eight 4-bit lanes, 32-bit
words — because in VIDEO mode it is part of VRAM and FX needs 4-bit write
enables. The CPU side then addresses a byte as two nibbles of a word, with
`addr[1:0]` picking the lane. A byte-organised block would pack ~20% better
(205 blocks for 256 KB instead of 256) but could not serve VERA at all.

**And it must be INSTANTIATED, not inferred — this was measured, not assumed.**
The first version described the arrays behaviourally the way `main_ram.v` does
and Quartus refused outright:

> Error (276003): Cannot convert all sets of registers into RAM megafunctions
> ... the resulting number of registers ... exceeds the number of registers in
> the device

It fell back to flip-flops — 262,144 of them for a 32 KB probe against a device
with about 84,000 — and died in 28 seconds. `main_ram.v` gets away with
inference because it is **single port**; this is true dual port on **two
different clocks** with both ports writing, which Quartus's templates do not
cover. `switch_ram.sv` now instantiates eight `altsyncram` megafunctions in
`BIDIR_DUAL_PORT` mode directly. Eight and not one because `altsyncram`'s byte
enables are 8-bit granular and FX needs 4-bit.

The probe caught this for the price of a 28-second failed compile, before any
of the six muxes were written. That is what step 4 is for.

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

**CHANGING MODE REQUIRES A FULL COLD BOOT** — not a CPU reset. Nothing about
the machine's state carries across: memory contents are undefined, VERA, the
SD block device and the SMC all re-initialise from scratch.

That is a deliberate constraint and it buys more than it costs. A warm reset
would leave the question of what is still live when the memory map changes
underneath it — an SD DMA mid-transfer would write into whichever memory now
answers, which is a card-corrupting bug with no diagnostic. A cold boot has
none of that: there is nothing in flight because there is nothing at all.

### 4.1 How the mode is chosen — the OSD, and only the OSD

The cold-boot rule settles this, by removing the alternatives. Nothing the
guest writes can survive to be read after a cold boot, so the mode cannot be a
SYSCTL bit the software sets, and it cannot be a flag in an image header that
`run` acts on by parking a request and resetting. There is nowhere to park it.

What does persist across a cold boot is **MiSTer's own core configuration**,
stored on the SD card and applied by the HPS when the core starts. So:

* the mode is an **OSD option** in `CONF_STR` — a `status` bit off `HPS_BUS`,
  the same mechanism every other MiSTer core option uses, and marked so that
  changing it resets the core
* the guest gets a **read-only** bit in the SYSCTL page so software can *see*
  which mode it is in
* the kernel **prints the mode at boot**, so it is never a mystery
* a program that needs VIDEO **checks the bit and refuses with a clear
  message** — "this needs VIDEO mode; set it in the OSD" — rather than
  running against 128 KB of VRAM and drawing garbage

`run SCANOUT.BIN` in FAST mode therefore prints an instruction instead of
working, and that is the honest outcome. A machine that silently half-worked
would be worse, and the alternative that made it automatic is not available at
any price once the switch is a cold boot.

This also **removes a whole class of RTL risk**: with no runtime switching,
there is no mid-access hazard to design against and no need to prove the mux
is safe while the CPU is mid-cycle. The mode bit is constant for the life of a
boot.

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
   address the right memory and that VERA cannot see the block in FAST mode.
   The mode is constant for a whole boot (§4.1), so there is no mid-access
   switching to test — the testbench elaborates each mode separately. `sim/run.sh
   switch`, with a negative control that mis-wires one mode and must be
   caught, the same discipline `tb_ms_timer` follows.
3. **The emulator, including the SDRAM cost model.** Two parts, and the second
   matters more than it looks: the emulator currently models a uniform
   single-cycle machine, which `BANKBNCH` showed is an *exact* model of BRAM
   and optimistic by 4.5× for SDRAM. Add ~6 cycles per bank-`$01+` access and
   emulator timings become predictive instead of blind — without it, every
   future optimisation has the same hole that hid the MVN stub result.
4. **RTL integration** — the six muxes in `x816.sv`. One Quartus round.
5. **OSD, boot and kernel** — the `CONF_STR` option and its reset flag; the
   read-only SYSCTL bit; the kernel printing the mode at boot; and the
   VERA816 tests checking the bit and refusing with a message instead of
   drawing garbage.
6. **Linker maps and docs** — a FAST-mode map, `MEMORY_MAP.md`, `VERA816.md`
   amended from 352 KB to 384 KB with the sprite-reach and REGWIN re-check, and a
   conformance test that proves a program really executed from BRAM. `BANKBNCH`
   already has the mechanism: it reports the bank it ran in, and the same trick
   proves the mode took effect.

VERA2 is **phase 2** — after this is built and stable, not alongside it.
`VERA_MEMORY_REVIEW.md` §2 still prices the rest of it honestly: burst reads on
the SDRAM side, the byte-lane carve-out, `DISPBASE`, the `$9F60` bank, an
emulator model, conformance tests.

**And phase 2 is what makes VIDEO mode obsolete.** VERA2 puts a 1 MB
framebuffer in SDRAM, so with FAST mode holding the CPU's code in BRAM you get
a fast CPU *and* high resolution at the same time — the trade this whole
document is about disappears. VIDEO mode then survives only as compatibility
for whatever 352 KB VERA816 software exists by then. That is the argument for
making FAST the default now rather than later: it is the mode the machine ends
up in permanently.

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
* **The default flip is user-visible, and the switch is manual.** Someone
  flashing the core gets stock 128 KB VERA, and the high-resolution demos need
  an OSD change and a cold boot — there is no way to make `run` do it for them
  (§4.1). The kernel printing the mode, the demos refusing with a clear
  message, and the card's help text are the whole mitigation, so all three
  have to be right or this reads as a regression rather than a choice.
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
