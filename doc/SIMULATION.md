# RTL simulation for X816 — what upstream has, and the port

Date: 2026-08-01. Companion to [AUDIT.md](AUDIT.md) §4: today an RTL change in
X816_core is provable only by a Quartus compile plus a hardware round trip.
Upstream `x16_mister` closes that gap with a ModelSim suite that was its proof
standard for every RTL change; this document maps that suite and defines the
port. Paths: `UP:` = `C:\quartus\projects\x16_mister`.

## 1. The upstream suite, in brief

Everything is **ModelSim Intel FPGA Starter Edition 10.5b, batch mode** — no
waveforms, no GUI. Two bash scripts (`UP:sim/run.sh`, 357 lines, 25 targets;
`UP:sim816/run.sh`) compile exact file lists with `vlog`/`vcom` and run
`vsim -c -do "run -all; quit -f"`, grepping self-checking `$display` tags
(`PASS`/`FAIL`/`[TBC]`/error counters). Test programs are assembled with cc65
(`ca65 → ld65 → od → .hex → $readmemh`). Tool paths are hardcoded and valid on
this machine: ModelSim at `/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem`,
cc65 at `/c/Emulator/cc65/bin` (`UP:sim/run.sh:12-13`).

Two design rules make the suite work, and the port keeps both:

1. **No testbench compiles the whole top or `hps_io`.** Each TB replicates the
   top level's decode/glue verbatim around real RTL modules, and models the
   HPS side by hand (fill sequences, held `sd_ack`, `b_wr` pipeline timing —
   `UP:sim/tb_cpu_hps.v:45-49`).
2. **Self-checking or it doesn't count**: opcode-fetch ring buffers, crash
   traps on rogue fetches, an SDRAM shadow-mirror comparing every delivered
   read (`UP:sim/tb_fullboot.v:168-191`), heartbeats, hard timeouts.

What it proved historically (the workflow this port buys): the I2S
frame-alignment bug, the dropped `sta abs,x` write that motivated the SDRAM
write FIFO, the '816 IRQ-storm and splash-freeze root causes, the SD relaunch
wedge and its `vsd_hold` fix, mj65c02 qualification — each validated in sim
before hardware (`UP:sim/README.md`, `UP:x16.sv:382-387,438-439`).

Also present upstream and **not** worth porting: `pll_sim*` (unused IP
collateral; every TB makes its own clocks), the empty NativeLink report,
`run_emulator*.bat` (software emulator, X816 has its own), and the X16-only
TBs (rom banking, cart, RTC/NVRAM, SPI SD, bitmap engine — hardware X816
deleted).

## 2. Why the port is cheap

- **The CPU is already covered.** `UP:sim816/` is a standalone P65C816 suite
  (IRQ storms under RDY stalls, native-mode trampolines), and X816's seven CPU
  core files are byte-identical to the ones it tests — only the bus wrapper
  differs. It ports with a path change.
- **The SDRAM model matches.** `UP:sim/sdram_sim.v` models `rtl/sdram.v`,
  which X816 inherits unchanged; `flat_sdram.sv` documents inheriting exactly
  the invariants `UP:sim/tb_wfifo.v` tests (`flat_sdram.sv:21-38`).
- **The program pipeline matches.** `boot/build.sh` already produces
  `boot.hex` with the identical ca65→od pipeline the sim consumes.
- **The peripherals are byte-identical** (VERA tree pre-widening, IKAOPM,
  VIAs, ps2_to_smc_bridge, i2c), so `tb_verafx`/`tb_pcm`/`tb_ym`/`tb_periph`
  port nearly as-is where still relevant.

The genuinely new work is one testbench: `sd_block.sv` replaced the X16's SPI
SD with an LBA/DMA device on hps_io's virtual disk, so its HPS block protocol
TB must be written new — with `UP:sim/tb_cpu_hps.v` and `UP:sim/sd_card_sim.sv`
as the reference for faithful HPS-side timing (held `sd_ack`, `b_wr` +2-cycle
pipeline).

## 3. Port map

| Upstream asset | Action | Notes |
|---|---|---|
| `sim816/run.sh`, `tb_stall.v`, `tb_native.v`, `irq*.s/.cfg` | **copy, repoint** | CPU dir is `rtl/cpu/65C816` here (upstream: `65C816_x16`) |
| `sim/run.sh` skeleton (tools, vlib/vcom/vlog, `vsim -c`+grep, `-g` sweeps) | **copy structure** | new target set for X816 |
| `sim/sdram_sim.v` | **copy as-is** | models the inherited `rtl/sdram.v` |
| `sim/vera_stub.sv` | **copy as-is** | `$9F20-3F` decode identical; fast-boot sims |
| `sim/tb_fullboot.v` | **adapt** → `tb_kernel` (Phase 4) | flat decode replica, 24-bit bus, boot overlay + loaded image instead of 256 KB ROM; keep heartbeat/fetch-ring/shadow-mirror/timeout/`key` tasks verbatim |
| `sim/tb_wfifo.v` | **adapt** | flat_sdram unit test — same invariants |
| `sim/tb_smccombo.v`, `tb_i2cboot.v` | **adapt** | expected bytes become key position numbers per X816's `smc_x16.sv` |
| `sim/tb_periph.v` | **adapt** | drop rtc_x16 section (no RTC) |
| `sim/tb_verafx.v`, `tb_pcm.v`, `tb_ym.v` | **copy later** | full-VERA compile list at `UP:sim/run.sh:271-288`; VERA816 conformance goes here |
| `sim/tb_wai.v` | **adapt** | CPU816 branch only (no wai_shim) |
| HPS block timing model (`tb_cpu_hps.v`, `sd_card_sim.sv`) | **reference** for the new `tb_sd` | |
| rom_banks/lowram/cart/nvram/rtc/bitmap/SPI-SD TBs, r65c02/mj65c02 libs, wai_shim | **skip** | X816 deleted the hardware |

## 4. Phases

**Phase 1 — CPU regression + boot overlay.** Status: **done, green, in-repo**
— and extended the same day: `sim/run.sh fw` boots the kernel-firmware path
(image staged at `$F0:0000` through the loader port, firmware magic branch,
and an in-probe proof that the firmware **write-protect** drops CPU stores),
and `sim/run.sh blit` is the VERA816 blitter unit test (eight self-checking
cases against the real `vram_if` + 352 KB `main_ram`: fills, copies, the
doubling idiom, LEN=0, 50% renderer contention, wrap-through-hole).
- `sim816/` ported (targets `stall`, `nostall`, `nat`, `def`, `trace`, `all`):
  the P65C816 under LFSR RDY stalls and the native-mode IRQ path. Green here.
- `sim/` created with `tb_boot.v`: the real chain
  `p65c816_flat_wrap → x816.sv decode replica → bank0_ram + boot_rom(boot.hex)
  + flat_sdram + sdram_sim + vera_stub + SYSCTL`, running the shipped 256-byte
  boot ROM. Two targets: `boot` (image staged through the **real loader port**
  the HPS path uses, asserts the magic check passes and the program at
  `$01:0004` runs) and `noboot` (no image: asserts the VERA band-paint fallback
  and WAI park). Crash traps + timeout as upstream. Green here.
- Entry: `cd sim && ./run.sh boot` (see `sim/run.sh` header for all targets).

**Phase 2 — the memory and disk floor.** `tb_wfifo` adapted to `flat_sdram`
(write-FIFO fill/consume-clear/`| we` ready invariants under back-to-back CPU
writes); new `tb_sd` for `sd_block.sv`: HPS block model + DMA into bank 0 and
SDRAM, bounds refusals at `img_blocks`, buffer/DATA-window semantics, the
whole-machine freeze. Stimulus images already exist (`boot/fat32.img`,
`boot/sdtest.img`, `boot/mkfat32.py`). This phase covers the two audit rows
where every July bug was found on hardware.

**Phase 3 — the keyboard chain.** `tb_smccombo`/`tb_i2cboot` adapted:
`ps2_key` flag-then-data sync → `ps2_to_smc_bridge` → `smc_x16` I²C reads,
asserting position numbers (ESC=110, grave=1) and the FIFO-pop race fix
(20-keys-in/20-out — the exact July failure). The `$9F8D-8F` counters give the
TB its observability.

**Phase 4 — `tb_kernel`, the fullboot analog.** Boot overlay → loader stages
`shell.bin` (or a test kernel) at `$01:0000` → magic → shell banner into
vera_stub VRAM → inject keys through the real SMC path → assert the echoed
line. This is the missing regression for `run`/exec/goshell (AUDIT.md H-1
territory) once residency lands, and the pre-hardware gate for every future
RTL change.

**Phase 5 — VERA816 conformance.** `tb_verafx`/`tb_pcm` with the full VERA
compile; add the 19-bit/`BASEX` widening cases and a sprite-fetch-above-128KB
case (AUDIT.md M-1 — write the failing test first, then decide widen-vs-doc).

## 4b. Notes from the Phase-1 port (read before writing the next TB)

- **`rtl/bank0_ram.sv` needed a one-line legality fix to simulate at all**: it
  read `ack_tgl` before declaring it — illegal SystemVerilog that Quartus
  tolerates but both ModelSim 10.5b and Questa 2024.3 reject. The declaration
  was moved above first use (pure reorder, no semantic/netlist change). Any
  new RTL should be checked against `vlog` before it grows dependents.
- **The P65C816 emits address-0 sync cycles during its internal reset
  sequence**, before the `$FFFC` vector fetch. A fetch trap armed from reset
  fires on them; `tb_boot` arms its trap only after the first committed fetch
  from the boot page (with a 1000-cycle watchdog if that never happens).
- ModelSim ASE 10.5b handles the whole chain, including the VHDL-2008 CPU and
  the SystemVerilog RTL. Questa FSE 24.1 (`C:\intelFPGA_lite\24.1std\
  questa_fse\win64`) also works — override with `MS=` if 10.5b ever falls
  short.
- Measured runs (this machine): `sim816` all targets ≈ 2 min including the
  MCode.vhd compile; `sim/run.sh boot` seconds; `sim/run.sh noboot` ≈ 2 min
  (869k cpu cycles to the WAI park).

## 5. Conventions (kept from upstream)

- Batch only: `vsim -c`, grep-able verdict lines; a target's last line is
  `*** PASS ***` or `*** FAIL: reason ***`; nonzero exit on FAIL.
- TBs replicate `x816.sv` decode verbatim and say which lines they mirror —
  when the top changes, the TB diff is the review artifact.
- Every TB: hard timeout, fetch-trap on unmapped/rogue execution, heartbeat.
- Test programs via cc65 (`--cpu 65816`), same `od` hex pipeline as
  `boot/build.sh`; generated artifacts stay untracked (`sim/.gitignore`).
- Tool paths at the top of each `run.sh`, overridable by environment
  (`MS=`, `CC65=`), defaults matching this machine.
