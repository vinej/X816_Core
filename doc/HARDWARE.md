# X816 — real-hardware feasibility study

*2026-08-04. The question: a simple standalone board — HDMI out, USB
keyboard/mouse/joystick, a real 14 MHz 65C816, a FAT SD card. What is
feasible?*

**Verdict: feasible, with strong prior art.** The Commander X16 itself is a
real 65C02 next to an FPGA video chip; the Foenix machines run a real 65816
at 14 MHz next to an FPGA chipset. Nothing in the X816 design fights this —
the CPU is already a discrete module behind a plain bus, and every service
the MiSTer framework provides has a known standalone replacement. The work
is real (a board, an FPGA port off the Cyclone V, an MCU firmware) but no
step requires an invention. The two highest risks are listed in §7 and both
are testable for ~$100 before any standalone board exists (§8).

---

## 1. What the machine actually is

Three layers, which the port must keep or replace:

| Layer | Today (MiSTer) | Standalone |
|---|---|---|
| CPU | P65C816 soft core in fabric | **real W65C816S-14** |
| Chipset | VERA, VERA2, IKAOPM, 2×VIA, SMC, SD block, ms timer, SYSCTL, memory system — all portable RTL | same RTL, smaller FPGA |
| Services | **HPS/Linux**: USB HID, SD card + image mounting, firmware/program loading, OSD, HDMI via ADV7513 + scaler | MCU + FPGA replacements (§4) |

The chipset layer is the easy part: it is vendor-neutral SystemVerilog that
this project already simulates off-hardware (`sim/run.sh`). The services
layer is where the actual porting work lives, because the HPS quietly does
five jobs.

## 2. The real chip — what changes vs the soft core

The W65C816S is in production (WDC; PLCC-44/QFP-44/DIP-40, ~$10–15).
Datasheet ratings: **14 MHz requires 5 V**; at 3.3 V the guaranteed number
is ~8 MHz. Many parts run 14 at 3.3 V in practice (the Foenix line ships
at 14.318 MHz), but that is silicon margin, not spec. Decide by test in
phase 0 (§8); the in-spec design is a 5 V CPU island with level shifters —
74AHCT245 up (TTL thresholds accept 3.3 V, drive 5 V), 74LVC245 down
(5 V-tolerant inputs). About six transceivers.

Four real-chip behaviours the soft core never showed us:

1. **The bank byte is multiplexed onto D0–7 during PHI2-low.** A
   transparent latch (74AHC573, LE = PHI2) recovers A16–23. Classic
   circuit, but its timing is part of the 14 MHz budget.
2. **VDA/VPA must qualify every chip select.** The real 816 emits internal
   cycles whose address bus is garbage; a decode that ignores VDA|VPA will
   ghost-trigger I/O. The soft core has no such cycles, so *no decode in
   x816.sv is currently qualified* — on real hardware every `cs` gains an
   `& (VDA | VPA)` term. This is the largest RTL delta and it is mechanical.
3. **RDY is bidirectional** (WAI pulls it low). Drive it open-drain with a
   pull-up. All of today's stall discipline maps directly: `cpu_rdy` becomes
   the RDY pin; every VERA/SDRAM/SD stall works the same way.
4. **TURBO becomes a PHI2 divider mux, not a clock-enable.** The FPGA
   generates PHI2, so 8-vs-14 is a glitch-free divider switch in fabric.
   The chip is fully static, so nothing objects. `cpu_pace.sv` retires; the
   SYSCTL/OSD semantics stay.

**Bus timing at 14 MHz closes, mediated by the FPGA.** PHI2 = 71.4 ns. The
CPU never talks to a memory chip directly: address/data go to the FPGA
(≈5 ns through shifters), the FPGA (100+ MHz internally, as today) serves
the access and returns read data before the tDSR deadline. This keeps the
entire existing memory architecture — decode, boot overlay, write
protection, stalls — as the same RTL with a new front end, and removes any
raw CPU-to-SRAM timing race from the board design.

## 3. Memory — simpler than what we have

The BRAM-vs-SDRAM split exists because fabric BRAM was the only zero-wait
memory. Standalone, one **10 ns async SRAM** (512K×8, ~$6, single chip)
gives banks `$00–$07` zero-wait — more fast memory than today's 320 KB —
and one **16 MB SDRAM** (~$4) backs the rest with RDY stalls exactly like
`flat_sdram` today. VERA2's bitmap fetch arbitration carries over unchanged
because the FPGA still owns the SDRAM. The memory map, the contract, and
every measured software number survive intact.

## 4. Replacing the HPS, job by job

| HPS job | Replacement | Effort |
|---|---|---|
| USB keyboard + mouse | **RP2040 as the SMC**: USB host (TinyUSB/PIO-USB) on one side, the SMC's I²C protocol to VIA #1 on the other. The X16 ecosystem already has RP2040 keyboard adapters; `smc_x16.sv` keeps working, `ps2_to_smc_bridge` retires (the MCU feeds keys directly, already in SMC key-position numbers). | MCU firmware, moderate |
| USB joysticks | Same MCU, mapped to the SNES-pad shift registers VIA #1 already reads (optionally real SNES ports too — two connectors and pull-ups). | small |
| SD card + FAT | FPGA SPI master — `spi_sd_master100.sv` is already in-tree unwired (PORTING.md §next-steps). `sd_block.sv` keeps its register interface; only its backend changes from HPS virtual disk to SPI. **FAT is already software**: the kernel's `K_FS_*` implements FAT32 over the block device, `tools/mksdcard.py` builds the cards. | contained |
| Firmware/program load | SPI flash → small FSM DMAs the firmware image into SDRAM at reset with the CPU held — the same "CPU held while memory fills" sequence the HPS performs today. Programs then load from SD via the existing kernel/shell (`K_EXEC`). The 256-byte boot overlay is unchanged. | small FSM |
| OSD / menu | Gone. Its two surviving functions move: turbo → SYSCTL + a DIP/button; program selection → the shell from SD. | zero (by deletion) |
| HDMI | VERA is 640×480@60 at 25.0 MHz pixel clock — one fixed mode. Direct TMDS from FPGA pins (DVI-mode) is proven at this rate on hobbyist boards (ULX3S class); monitors accept the 25.0-vs-25.175 MHz deviation (~59.5 Hz). Audio-in-HDMI is extra work (data islands); phase it — line-out DAC (PCM5102, $2) first. | known cores |
| Scaler | Not needed — fixed native mode. | zero |

## 5. FPGA sizing

The chipset without CPU, framework, and scaler is modest logic but real
BRAM: VERA needs its **128 KB VRAM** plus line buffers and palette in
fabric (bank-0/fast-RAM BRAM all moves off-chip, §3).

| Candidate | BRAM | Fit | Note |
|---|---|---|---|
| iCE40UP5K (X16's VERA chip) | 128 KB SPRAM | video only | would mean a two-FPGA board; loses VERA2 |
| ECP5 LFE5U-25 | ~126 KB | **no** | VRAM alone consumes it |
| **ECP5 LFE5U-45/85** | ~243 / ~468 KB | **yes** | ~$25–40; open toolchain (Yosys/nextpnr) or Diamond |
| Artix-7 / Cyclone 10 LP | varies | 45-class parts fit | vendor toolchains |

ECP5-85 is the comfortable pick: VRAM + IKAOPM + VERA2 line stores + margin,
one FPGA, one design. The RTL port off Quartus touches inference-sensitive
spots (`fast_ram`'s 32-bit byte-enable trick — which mostly *disappears*
off-chip anyway, negedge BRAM reads, M10K-specific assumptions) — days of
work with the sim suite as the referee, not weeks.

## 6. What is preserved untouched

The entire software stack: kernel, shell, durexForth, the contract
(`tools/contract.py` and every generated header), the memory map, the I/O
page, all measured performance numbers (8 MHz paced mode included, via the
PHI2 divider). This is the payoff of the contract discipline — the software
cannot tell it moved except by running faster in the fast banks.

## 7. The two real risks

1. **Real-816 bus discipline at 14 MHz.** Bank latch timing, VDA/VPA
   qualification, RDY open-drain, level-shifter delays — each individually
   textbook, but their sum is exactly the kind of thing STA never sees
   (the 16 MHz turbo attempt passed STA clean and crashed the board;
   assume the same class of surprise here).
2. **5 V question.** If 14 MHz@3.3 V holds on the actual parts bought, the
   board simplifies substantially (no shifter bank, single rail). If not,
   the 5 V island design is the fallback and is fully in-spec.

Both are answered by phase 0 for about $100.

## 8. Phased plan

**Phase 0 — real CPU on the existing MiSTer core (~$100, one PCB).**
A DE10-Nano "hat" on the free GPIO header: W65C816S + bank latch + level
shifters (~34 signals fits the 36-pin header). Replace `p65c816_flat_wrap`
with a pin-driver module; *everything else* — HPS USB, SD, HDMI, loading,
the entire chipset — stays untouched. This one board answers: does a real
816 run this machine at 14 MHz, is 3.3 V viable, is the VDA/VPA decode
right. It is also simply a real-chip X816, usable daily.

**Phase 1 — standalone board.** ECP5-85 + W65C816S + 512 KB SRAM + 16 MB
SDRAM + RP2040 (USB host + SMC + RTC) + SPI flash + SD slot + HDMI + DAC.
Four-layer board, BOM ≈ $80–120, small-run cost realistically $150–250 per
board. Firmware: RP2040 HID/SMC (moderate), boot FSM (small), SPI-SD
backend (small), ECP5 RTL port (days). This is a months-of-evenings
project, not weeks — but phase 0 will have retired both §7 risks first.

**Explicitly not recommended:** skipping phase 0. Every hard unknown lives
on the CPU-to-FPGA boundary, and phase 0 tests that boundary against a
chipset already proven on hardware, so a failure there has one suspect.
