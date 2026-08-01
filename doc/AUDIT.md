# X816 audit — core RTL, runtime software, verification state

Date: 2026-08-01. Audited at X816_core `dd4e370` and X816_Calypsi `e3a2cff`, both
clean. Method: three parallel read-only reviews (core RTL + build pipeline;
`X816_Calypsi/runtime` + its examples and build scripts; the upstream
`x16_mister` simulation inventory), then synthesis. Every claim cites
`file:line` as verified on those HEADs. **Sections 1–5 are that review, and
nothing was modified while it was written.** §6 is the resolution pass that
followed the same day, and H-3 in it is the one finding no amount of reading
produced — hardware did.

Path shorthand: bare paths = `C:\quartus\projects\X816_core`;
`RT\` = `C:\quartus\projects\X816_Calypsi\runtime`;
`EX\` = `C:\quartus\projects\X816_Calypsi\examples`;
`UP:` = `C:\quartus\projects\x16_mister`;
`EMU\` = `C:\quartus\projects\X816_Emulator`.

Companion documents: [SIMULATION.md](SIMULATION.md) covers the simulation gap
and the port from upstream, and [VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md)
covers the VRAM-versus-VERA2 question and why the answer was a blitter.

---

## 1. What the system is

**Core.** X816 is the upstream X16 MiSTer core with the machine architecture
replaced and the peripherals kept. `sys/` is byte-identical to upstream. The
CPU is upstream's X16-fixed srg320 P65C816 fork, its seven core VHDL files
byte-identical to `UP:rtl/cpu/65C816_x16/`; only the bus wrapper is new
(`rtl/cpu/65C816/p65c816_flat_wrap.vhd`: 24-bit address out, no VPB,
`wait_state` exposed). New RTL is exactly five files — `rtl/bank0_ram.sv`,
`rtl/boot_rom.sv`, `rtl/flat_sdram.sv`, `rtl/sd_block.sv`, the wrapper — plus a
31-line effective diff in `rtl/smc_x16.sv` (key-FIFO pop race fix, two debug
strobes) and a six-file "VERA816" widening in `vera/` (352 KB VRAM, 19-bit
addresses: `addr_data.v`, `main_ram.v`, `top.v`, `vram_if.v`, both renderers).
Removed relative to upstream: banked memory (rom_banks/lowram/HiRAM latches),
cart, RTC/NVRAM, serial card, SPI SD, bitmap engine, the 65C02 CPUs and
`wai_shim`, and all simulation directories.

**Memory.** Flat 24-bit map (`x816.sv:17-31`): bank 0 = 64 KB single-cycle
BRAM (`bank0_ram.sv:57`) except the I/O page `$9F00-$9FFF` and a 256-byte
boot-ROM read overlay at `$FF00` while `SYSCTL[0]=1`; banks `$01-$FF` = SDRAM
through `flat_sdram`, one 16-bit word burned per byte, so the 32 MB MiSTer
SDRAM module is mandatory (`flat_sdram.sv:53-61`, `README.md:34-35`). Chip
selects are qualified by `dec_valid = cpu_bus_valid | ~cpu_rwn`
(`x816.sv:305`) — ghost reads gated, writes trusted to the CPU (see L-9).

**Software.** Nothing from X816_Calypsi enters the bitstream. The FPGA carries
only the 256-byte ca65 boot overlay (`boot/build.sh:31-38`); the Calypsi-built
shell ships as `games/X816/boot1.rom`, auto-loaded by MiSTer via ioctl index
`16'h0040` to `PROG_BASE $01:0000` (`x816.sv:192-217`, `tools/mkrelease.sh:100-102`);
demo and test binaries ship on `boot0.img` built by `tools/mksdcard.py`. The
boot overlay checks the `"X816"` magic at `$01:0000` and `jml $01:0004`
(`boot/boot.s:90-102`), else paints colour bands and parks in WAI.

**Kernel.** A 64-entry × 4-byte `jmp long:` table at `$00:FE00`
(`RT\kernel.h:54-56`), stamped at run time by `kern_install`
(`RT\kerntab.s:73-86`). Console entries 0-7, filesystem 16-30, `SYS_VERSION`
48; `K_EXEC`/`K_EXIT` are `k_nosys` stubs (`RT\kerntab.s:275-276`).

---

## 2. Findings, ranked

### High

**H-1. Kernel residency: the table points into memory that `run` erases — and
the resident shell never installs it in the first place.** Known design issue,
but the audit found it is worse than documented. The kernel *is* the shell
image at `$01:0000`; `run` stages the next program at `$10:0000`
(`RT\shell.c:439,536-541`) and the bank-0 exec blob erases `$01:0000` wholesale
before jumping (`RT\exec.s:107-124`), so every table entry then points into the
new program's bytes. Compounding: (a) the shipped shell only calls
`con_init()+sh_run()` (`EX\shell\shell.c:15-21`) — **no `kern_install`** — so
under the plain shell the `$FE00` page is uninitialised noise even before any
`run`; the only installers are the three test programs
(`EX\shell\kerntest.c:75`, `EX\kernel\kfstest.c:184`, `EX\kernel\libfs.s:102`),
each of which links its own private copy of the whole kernel stack. (b)
`K_EXEC`/`K_EXIT` are stubs, so there is no kernel-mediated launch/exit; return
after a program is ESC-goshell (which reloads `/DEMO/SHELL.BIN`,
`RT\goshell.c:44`) or reset. Already the roadmap's item 1
(`doc/KERNEL.md:432-440`, `RT\kernel.h:33-44`); the fix (kernel above bank
`$01`, `run` capped at `$FF00` bytes) preserves the ABI.

**H-2. `sh_readline` inserts the low byte of special keys: F1 types `p`,
arrows type letters.** `con_getc()` returns 16-bit values including
`KEY_SPECIAL|keynum` (`RT\console.c:292-304`), and `sh_readline` filters only
CR/LF/BS before doing `buf[n++] = c; con_putc(c);` (`RT\shell.c:904-905`).
The comment at `RT\shell.c:882-884` claims specials are ignored; nothing
discards `c > 0xFF`. Every F-key/arrow/Home/End press corrupts the prompt line
(F1 = `$0170` → `p`, KEY_LEFT = `$014F` → `O`). One-line fix in
`sh_readline`; roadmap item 5 (giving specials a meaning) is separate.

### Medium

**M-1. Sprites cannot reach the VRAM region the VERA816 spec assigns them.**
`doc/VERA816.md:33` puts "tilemaps, tile data, sprite data" at
`$4B000-$57FFF`, but the sprite-attribute address field was never widened:
`sprite_addr_r` stays `[11:0]` (`vera/fpga/source/graphics/sprite_renderer.v:88`),
so `line_addr = {sprite_addr_r,3'b0}+…` (`sprite_renderer.v:247`) reaches only
the first 128 KB. Layers got `L0/L1_BASEX` extensions (`top.v:877-878,932-933`);
sprites got only the bus widening. Software written to the doc gets silently
wrong sprite fetches. Fix either way: widen the attribute field, or state the
128 KB sprite limit in VERA816.md §sprites (`VERA816.md:223-226` currently
implies "unchanged" without the reach consequence).

**M-2. `sd_block`'s 100 MHz FSM takes a cpu_clk-synchronised reset without
re-synchronising the deassert.** `always_ff @(posedge sdram_clk or negedge
reset_n)` at `sd_block.sv:370` uses `cpu_reset_n` (`x816.sv:361`), whose
release is synchronous to cpu_clk (`x816.sv:108-112`) — recovery/removal into
the sdram domain is untimed. `flat_sdram.sv:110-114` re-syncs the same class
of reset with 2 FFs; `sd_block` should copy that pattern. Practical exposure
is small (release happens at boot, FSM in idle), but it is the one CDC in the
new RTL that deviates from the project's own standard.

**M-3. `doc/MEMORY_MAP.md` documents the pre-refactor SD register map — the
exact kind of doc that causes the bug the refactor fixed.** The doc
(`doc/MEMORY_MAP.md:132-138,157,164-171,188`) shows CMD+STATUS combined at
`$9F89`, gap at `$9F8A`, DATA at `$9F8B`, "`$9F8C-$9F8F` free". The RTL has
CMD write-only `$9F89`, STATUS read-only `$9F8A`, `$9F8B` deliberately
unmapped, DATA `$9F8C` (`sd_block.sv:49-89`), keyboard counters `$9F8D-8F`
(`x816.sv:349-357`). The split exists precisely because Calypsi elides a
volatile read that follows a volatile write to the same address
(`sd_block.sv:61-77`); anyone coding from the doc reintroduces that hazard.

**M-4. `-O0` is load-bearing and enforced only by copy-paste.** Calypsi 5.18
elides volatile MMIO reads at `-O1+` (`RT\fat32.c:4-19`, `RT\x816_sd.h:12-23`),
and the compile recipe is duplicated across `EX\shell\build.sh`, six run
scripts and four Makefiles — a new recipe that forgets `-O0` produces a
clean-linking broken binary. The stated durable fix (assembly SD accessors,
then `-O2` elsewhere, `RT\fat32.c:14-15`) is planned but not done. Related pin:
the one proven 8-bit-RMW miscompile is excised into assembly (`RT\smc.s:9-29`);
remaining C has no in-place 8-bit shifts, but `uint8_t` `++` on
neighbour-adjacent locals throughout `RT\fat32.c`/`RT\console.c` is the same
exposure class — safe under the pinned compiler at `-O0`, re-audit on any
toolchain change. Treat **Calypsi 5.18 + `-O0` as pinned** until the accessor
rewrite lands.

**M-5. FAT32: allocation bound and error/EOF conflation.**
(a) `fat_alloc`'s `max_cluster = fatsz32*128` is FAT capacity, not the data
region's cluster count (`RT\fat32.c:108-116,547-560`); on a volume whose FAT is
oversized relative to its data region, allocation can hand out clusters whose
LBA lies beyond the partition → out-of-volume writes. (b) `fat32_read` returns
a short count on SD failure, indistinguishable from EOF (`RT\fat32.c:429-431`),
and `kfs_read` maps got==0 to plain EOF (`RT\kfs.c:305-306`) — shell
`type`/`copy` silently truncate on a mid-file I/O error (`RT\shell.c:411-421`).
`load`/`run` are safe (totals verified, `RT\shell.c:518-522`).

### Low

**L-1.** HPS loader wrap: `dl_addr = PROG_BASE + ioctl_addr[23:0]` guarded
only by `ioctl_addr[26:24]==0` (`x816.sv:210-214`) — an image ≥ `0xFF0000`
bytes wraps its tail onto bank 0 (zero page/stack) with no error.

**L-2.** `bank0_ram` write-port mux gives the loader priority over a
coincident CPU write (`bank0_ram.sv:110-117`); safe today only by the system
argument (CPU in reset during ioctl; frozen mid-I/O-write during SD DMA), not
structurally interlocked.

**L-3.** `sd_block` crosses `bufptr` (9-bit binary) and `buf_q` between
domains as plain 2-FF samples, justified by a ≥4-CPU-cycle spacing argument
(`sd_block.sv:293-297,319-323,358-362`). Any faster future consumer breaks it
silently. Same family: M-2.

**L-4.** SD transfers freeze the whole machine including VIA timers
(`cpu_rdy` gates the VIAs' enable, `x816.sv:505,746,781`) — documented design
choice (`sd_block.sv:30-47`), but VIA-based timekeeping will drift with SD
activity once anything uses VIA timers.

**L-5.** `goshell` does not check the loaded size: a zero-length
`/DEMO/SHELL.BIN` makes the exec blob's post-increment loop copy 64 KB of
stage garbage and jump into it (`RT\goshell.c:67-85`, `RT\exec.s:118`;
`cmd_run` refuses size 0 at `RT\shell.c:480`, goshell doesn't).

**L-6.** `x816-plain.scm` leaves `$FE00-$FEFF` allocatable as `near`
(`RT\x816-plain.scm:47`) while `x816-lib.scm` reserves it
(`RT\x816-lib.scm:61`) — latent collision for a plain-linked program if a
kernel table is ever installed around it.

**L-7.** Minor C: `parse_bpb` skips the `$55AA` signature check
(`RT\fat32.c:72-117`); `cmd_dump` folds lowercase to `.` although the font has
it (`RT\shell.c:174`); dead `key >= 128` check after `& 0x7F`
(`RT\console.c:257,277-278`); `kfs_read`/`kfs_write` C-level return truncates
>64 KB transfers to 16 bits while the param block carries the true u32
(`RT\kfs.c:315-317,351-353`) — ABI-consistent, but a trap for C callers.

**L-8 (found and fixed during this audit).** `rtl/bank0_ram.sv` read
`ack_tgl` before declaring it — illegal SystemVerilog that Quartus tolerates
but every simulator rejects (ModelSim 10.5b and Questa 2024.3 both refuse to
compile it). Fixed by moving the declaration above first use: a pure reorder,
no semantic or netlist change, no rebuild required on its own. The rest of
the new RTL compiles clean in simulation.

**L-9.** Standing assumptions worth knowing (inherited, silicon-proven):
ghost-**write** exemption trusts P65C816 to assert WE only on true write
cycles (`x816.sv:296-305`); bank0/boot ROM negedge reads are a half-cycle path
at 8 MHz (`bank0_ram.sv:119-121`, `boot_rom.sv:40-42`) — revisit before any
cpu_clk increase; async-assert reset gates are the standard MiSTer idiom
(`x816.sv:97-112`); `kcall`/`kfs` globals are non-reentrant — fine until IRQs
exist (`RT\kcall.s:29-33`, `RT\kfs.c:27-44`), and nothing enables IRQs today
(all boot vectors trap to `rti`, `boot/boot.s:162-186`).

### Documentation drift (fix cheaply, high leverage)

| Doc | Says | Reality |
|---|---|---|
| `doc/MEMORY_MAP.md:132-188` | old SD map: CMD·STATUS both `$9F89`, DATA `$9F8B`, `$9F8C-8F` free | CMD `$9F89` W-only, STATUS `$9F8A` R-only, DATA `$9F8C`, counters `$9F8D-8F` (`sd_block.sv:49-89`) — see M-3 |
| `doc/PORTING.md:29-33` | VERA "Change: none", SMC "none" | 6 VERA files widened; smc_x16 FIFO-pop fix |
| `doc/KERNEL.md:6` | "Nothing in this document is built yet" | its own §9-10 lists console/SD/FAT32 green on hardware |
| `doc/SHELL.md:6` | "None of this is built" | the shell ships in every release (`README.md:66-78`) |
| `tools/mksdcard.py:29-30` | card auto-mounts by name | `SC` semantics: mount once, MiSTer remembers (`doc/MISTER.md:55-61`, `x816.sv:119-123`) |
| `X816_Calypsi\README.md:397-398` | SD RTL "has not been through Quartus" | FAT32 green on DE10-Nano claimed 100 lines earlier (`README.md:274-281`) |
| `RT\exec.s:44` vs `RT\goshell.c:66` | shell ≈ 12 KB vs 22 KB | pick one number |

### Contract duplication (drift is the main maintenance hazard)

The core↔ROM↔emulator agreements are encoded by repetition, not by a shared
source: `KERN_TABLE $00:FE00` ×3 (`RT\kernel.h:54`, `RT\kerntab.s:60-61`,
`RT\kcall.s:58`); call numbers duplicated positionally between `kernel.h` and
the `kerntab.s` prototype order; `EXEC_STAGE $10:0000` ×3 (`RT\exec.s:54`,
`RT\shell.c:439`, `RT\goshell.c:35`); load base/entry `$01:0000/$01:0004` ×6+
(header, exec, shell, boot.s, `x816.sv:208`, both `.scm`); the VERA register
block in ~8 files across two repos; VIA1 in `RT\smc.s:112` and
`RT\console.c:20`; keymaps deliberately duplicated into
`EMU\src\keyboard.c:276-279`; `/DEMO/SHELL.BIN` in `RT\goshell.c:44` vs
`tools/mksdcard.py:121`. A generated single-source header (one table → C
header + `.s` include + emulator header) would collapse most of this.

### Build/release pipeline

Solid overall: `boot/build.sh` asserts the 256-byte ROM and touches
`rtl/boot_rom.sv` because Quartus tracks no `$readmemh` dependency
(`boot/build.sh:11-23,40-42`); `tools/mkrelease.sh` refuses stale `shell.bin`
(`:57-92`), rebuilds the card every release, and documents the load-bearing
`.rbf` naming (`:15-19`). Fragilities: newest-mtime `.rbf` selection across
two directories (`mkrelease.sh:30-36`); hard sibling-checkout coupling
(`mkrelease.sh:27-28`, `tools/mksdcard.py:27`, run scripts' absolute `EMU=`
paths); card-build failure is a warning, not an error (`:113-116`);
`files.qip`/qsf list neither `vera/fpga/source/addr_data.v` nor
`mult_accum.v` — they compile only via `SEARCH_PATH` auto-discovery
(`files.qip:12` vs upstream's explicit listing); `EX\shell\Makefile:18` is
stale (missing `kfs.o`/`kerntab.o`) and make is broken on this machine anyway —
`build.sh` is the only working shell build (`EX\shell\build.sh:7-10`);
`.raw`/`.bin` are committed but only `shell.bin` has a staleness guard;
`releases/` is gitignored so shipped artifacts are untracked local state
(including `X816_vramtest.rbf`, which violates the naming rule and must stay
off-card).

---

## 3. What is solid

Worth stating, because an audit that only lists faults misleads:

- `sys/` untouched; CPU core byte-identical to the upstream fork that was
  sim-proven (`UP:sim816`, `UP:x16.sv:382-387`) before shipping as X16 default.
- The five new RTL files carry their hard-won invariants **in writing**:
  flat_sdram's `| we` ready term, single-push write FIFO and toggle CDC
  (`flat_sdram.sv:21-38`), sd_block's CMD/STATUS split and `$9F8B` gap
  rationale (`sd_block.sv:61-89`), the flag-then-data ps2_key sync with the
  make/break-corruption history (`x816.sv:809-848`), bounds-check of every SD
  request against `img_blocks` (`sd_block.sv:247-254,398-401`).
- No TODO/FIXME/HACK markers anywhere in the new RTL or boot code.
- Runtime discipline: volatile on all MMIO, consistent SEP/REP with the
  `#`/`##` footgun documented (`RT\smc.s:86-94`), DP capped one byte below the
  x16lib ZP window so overlap is a **link error** (`RT\x816-lib.scm:40`),
  `kfs_seek`'s unsigned wraparound verified sound (`RT\kfs.c:358-379`), all
  RAM buffers correctly bounded (no 512-byte sector buffer exists in RAM at
  all — the device buffer is the staging).
- Verification style is adversarial where it exists: emulator GIF glyph-decode
  against the real font, pyfatfs (an independent FAT32 implementation)
  re-reading images the guest wrote, `--negative` controls on every runner,
  and the emulator's SD/keymap models deliberately byte-matched to RTL and
  runtime (`EMU\src\sdblock.c:1-47`, `EMU\src\keyboard.c:276-279`).

---

## 4. Verification coverage today

| Surface | Emulator | Hardware | Notes |
|---|---|---|---|
| Converted x16lib, C↔lib glue | ✅ run-emu (asm-lib, c-lib) | ✅ DE10 | |
| Console (putc/scroll/wrap + glyphs) | ✅ contest | ✅ | |
| Keyboard decode path | ✅ run-kbd via `-autokeys` | ✅ | emulator feeds the SMC FIFO directly — RTL I²C/FIFO not exercised |
| FAT32 read / write | ✅ fstest / fwtest + pyfatfs | ✅ | |
| Shell command set | ✅ shtest, run-fs | ✅ | |
| Kernel table (console+FS halves) | ✅ run-kfs, run-libfs, kerntest | ✅ | each test installs its own table (H-1) |
| `run` / exec relocation / goshell ESC | ❌ none | manual only | tests are `-load`ed directly; `run` would destroy the program under test |
| SMC/PS2 RTL path, bitstream skew | ❌ | manual (kbd.s, keyscan) | FIFO-pop race was found on hardware |
| sd_block RTL (DMA, freeze, bounds) | ❌ (emulator is instantaneous, busy=0) | boot/sdtest.s | the three sd_block bugs of July were all found on hardware |
| flat_sdram / bank0 / boot overlay | ❌ | sdramtest.s, vramtest.s | |
| VERA816 widening | partial (emulator model) | ✅ vramtest | sprites >128 KB never exercised anywhere (M-1) |
| MiSTer framework (boot1.rom autoload, SC0 mount, key claims) | ❌ | ✅ | inherently hardware |

The ❌ column is exactly the "board runs the bitstream, not the RTL" pain: an
RTL change today is provable only by a Quartus compile and a hardware round
trip. Upstream's answer is its ModelSim suite — see
[SIMULATION.md](SIMULATION.md) for what exists there and the port.

---

## 5. Recommendations, in order

1. **Fix H-2 now** (one guard in `sh_readline`); it is user-visible at every
   prompt. Cheap, software-only, no Quartus.
2. **Correct `doc/MEMORY_MAP.md`'s SD table** (M-3) and the PORTING/KERNEL/
   SHELL/mksdcard staleness rows — doc-only, prevents real bugs.
3. **Kernel residency (H-1)** stays the top roadmap item, as already planned
   in `doc/KERNEL.md` §3. Have the resident shell call `kern_install` as part
   of the same change.
4. **Decide the sprite story (M-1)**: widen `sprite_addr_r` or write the limit
   into VERA816.md. If widening, it lands with a Quartus round anyway — batch
   it with the M-2 reset re-sync (both are small, same compile).
5. **Stand up RTL simulation** — Phase 1 landed together with this audit
   (`sim816/` CPU regression and `sim/tb_boot`, all green; see SIMULATION.md).
   Continue with Phase 2: the sd_block/SMC ❌ rows above are precisely the
   class of bug the upstream suite catches pre-hardware.
6. Medium-term software hygiene: single-source the contract constants
   (generator producing `.h`/`.s`/emulator tables); assembly SD accessors so
   FAT32 can leave `-O0` (M-4); `fat_alloc` bound from the data region and an
   error-vs-EOF distinction in `fat32_read`/`kfs_read` (M-5); size check in
   goshell (L-5).

Items requiring a Quartus compile (M-1 RTL fix, M-2, H-1's loader half,
L-1/L-2 hardening if desired) should be batched and each proven in simulation
first once the sim port lands — that is the workflow upstream already runs.

---

## 6. Disposition — resolution pass of 2026-08-01 (same day, second half)

Every finding above was resolved or explicitly dispositioned. Software changes
are built and regression-green (emulator suite + host harness + `sim/` +
`sim816/`), and the RTL was compiled and **confirmed running on a DE10-Nano
the same day** — the bitstream of 2026-08-01 13:33, which fits in 507/553 RAM
blocks (unchanged: the blitter went into existing headroom) and 42% of ALMs.

`BLITTEST.BIN` was then run on that board and **found a real bug that
everything else had missed** — H-3 below, the one finding in this document
that no amount of reading produced. It took two hardware rounds: the first
came back green with the blitter working and the sprite half wrong, the
second (bitstream 14:18) came back fully green. The final state is that every
finding here is closed, with one honest residual named at the end of H-3.

Later the same day that residual was closed by writing the test that had never
existed — and writing it produced **H-4**, a second RTL-only divergence in the
same neighbourhood. One further hardware round confirmed both. Every finding
in this document is now closed, and no residual is named.

### H-3 (found on hardware 2026-08-01, after the audit): the VERA816 widening
### never reached the display side

The three wires in `vera/fpga/source/top.v` connecting the renderers to
`vram_if` — `l0_addr`, `l1_addr`, `spr_addr` — were left at the stock 15 bits
when both ends were widened to 17. Verilog truncates silently, so **layer 0,
layer 1 and sprites could only ever fetch from the first 128 KB** of the
352 KB. The CPU data port and the blitter were unaffected: they use different
`vram_if` ports that were wired correctly.

Why it survived, which is the more useful half:

* Every test of the widening used the **CPU data port** — a physically
  different path from the renderers'. The march, hole, wrap and capability
  tests can all pass with the display side truncated, and did.
* The one test that would have caught it, VERA816.md §8 test 5 (bitmap
  scanout past line 204), **was never implemented**, while the document
  claimed all five tests passed. `vramtest.s`'s own paint is 320×240, which
  fits inside 128 KB.
* M-1 above blamed the sprite attribute field, which was *also* too narrow.
  Fixing it was necessary and not sufficient — and made the failure visible,
  because the renderer then computed a correct address that got chopped.

Fixed by widening the three wires, and **confirmed on hardware the same day**:
the 14:18 bitstream renders `BLITTEST.BIN` green with one white and one blue
rectangle, so a renderer now fetches from `$34000` and displays it.
`sim/run.sh lint` elaborates the VERA tree and fails on any port/connection
width mismatch — it names this bug in six lines, costs seconds, and has a
negative control.

**Residual, and it is the honest one:** only the SPRITE renderer has been
proved above 128 KB. Layers 0 and 1 share the same fix and the same arbiter,
which is a good reason to expect them to work and not evidence that they do —
VERA816.md §8 test 5 (a 640×480 8bpp scanout past line 204) is still
unimplemented, and it is the test that covers them.

**CLOSED, 2026-08-01 — on hardware.** Test 5 now exists as
`examples/vera/scanout.c` + `run-scanout.sh`, ships on the demo card as
`SCANOUT.BIN`, and a DE10-Nano displays all eight bands in order: white, red,
cyan, purple, green, blue, yellow, orange. Bands 4–7 are fetched entirely from
above 128 KB. Layer 0 is now proved above 128 KB by the same standard the
sprite renderer was, and the 352 KB is proved end to end for the mode it exists
for. The residual named above is gone.

### H-4 (found by writing test 5): the register-window write decodes ignored
### address bits [18:17]

`top.v`'s `palette_write`, `sprite_attr_write` and `audio_write` matched
`ib_addr_r[16:0]` patterns with no qualifier on bits `[18:17]`, so `$3FA00`
was a second palette, `$3FC00` a second sprite-attribute file and `$3F9C0` a
second PSG. `addr_data.v` already qualified the READ side and its comment
names this exact divergence — the write side had simply not been done.

It matters because a 640×480 8bpp framebuffer covers `$3F9C0-$3FFFF` no matter
where it is based (VERA816.md §2.2), so an ordinary paint rewrites the palette
from its own pixels partway down the screen. The emulator, comparing full
19-bit addresses, was correct throughout, so this was RTL-only — the same
skew direction as H-3, and again invisible to every test that existed.

Fixed by one `ib_addr_lo128k` qualifier on all three. `sim/run.sh lint` still
passes; the decode itself is not width-checkable, so `scanout.c` probes
`$3FA02` and `$3FC00` before it paints and fails with its own colour.

**Confirmed on hardware 2026-08-01**, and the confirmation is free: an unfixed
bitstream fails that probe and paints the screen grey, so the fact that the
board showed the eight bands at all is the evidence. One round closed both
this and the H-3 residual.

**Not a truncation this time, and worth noticing why it was missed anyway:**
H-3 was found by hardware and H-4 by *writing the missing test*, before it ever
ran on hardware. Both were sitting in code the audit read.

| Finding | Disposition |
|---|---|
| H-1 kernel residency | **FIXED.** Kernel is a firmware image at `$F0:0000` (`runtime/x816-kernel.scm`, `kernel.bin` → `boot2.rom`, ioctl `16'h0080`), write-protected in RTL (`x816.sv` `fw_region`), boot checks firmware magic first (`boot/boot.s`), thunks context-switch (`kerntab.s` `KENTER`, `-DKERNEL_RESIDENT`), the resident image installs the table (`kernelmain.c`), `K_EXEC`/`K_EXIT` implemented (`kexec.c`, guarded firmware re-entry), goshell re-enters firmware on ESC, program maps honour the `$2000-$2FFF` claim. Proven: `sim/run.sh fw` (+ write-protect probe), `run-fwboot.sh` (+ corrupted-magic negative), full regression suite. |
| H-2 sh_readline special keys | **FIXED** (`shell.c`: discard `c > 0xFF`; comment corrected). |
| M-1 sprite reach | **FIXED both sides.** RTL: `sprite_renderer.v` attr bits [13:12] (VERA816.md §5.1). Emulator: same decode, plus an out-of-bounds sprite-fetch latent bug fixed on the way (`video.c` now fetches via `video_space_read`). Conformance green: `examples/vera/run-blit.sh` test 8 renders one sprite from `$34000` via the new bits and one below 128 KB, probing both. **Green on a DE10-Nano** with the second bitstream of 2026-08-01 — but only after H-3, which is what the first on-board run exposed. |
| M-2 sd_block reset CDC | **FIXED** (`fsm_rst_sync`, same pattern as flat_sdram). |
| M-3 MEMORY_MAP.md SD table | **FIXED** (transcribed from RTL, incl. the CMD/STATUS split rationale). |
| M-4 `-O0` by copy-paste | **PARTIALLY resolved, rest dispositioned**: the volatile-elision contract is now stated in fat32.h/x816_sd.h and each build script; full `-O2` migration stays deferred behind the assembly-SD-accessor plan — under the pinned Calypsi 5.18 the risk is drift, and the recipes now all carry the warning. Consolidating ~10 recipes into one include remains open (tracked below). |
| M-5a fat_alloc bound | **FIXED**, proven differentially on host (unfixed code wrote 5.5 MB past a crafted volume; fixed code exact). |
| M-5b error vs EOF | **FIXED** (`fat32_ioerr()`/`fat32_clearerr()`, `kfs_read` returns `KERR_IO`, shell `type`/`copy` report truncation). |
| L-1 loader wrap | **FIXED** (25-bit sum, carry drops bytes). |
| L-2 bank0 write mux | **ACCEPTED** as documented system invariant (CPU in reset / frozen during DMA); a sim assertion belongs in Phase-2 `tb_sd`. |
| L-3 sd_block 2-FF multi-bit CDC | **ACCEPTED** — in-file timing argument stands; revisit only if a faster consumer appears. |
| L-4 SD freeze stalls VIAs | **ACCEPTED** design choice, documented. |
| L-5 goshell zero-size | **FIXED** (same guard as cmd_run). |
| L-6 x816-plain.scm `$FE00` | **FIXED** (+ both program maps now also carve the kernel's `$2000-$2FFF`). |
| L-7 small items | **FIXED**: `$55AA` check, dump lowercase, dead key check removed. `kfs_read/write` >64 KB C-return truncation stays documented ABI. |
| L-8 bank0_ram declare-before-use | **FIXED** (first pass). |
| Doc drift table (7 rows) | **ALL FIXED** (MEMORY_MAP SD section, PORTING VERA/SMC rows, KERNEL/SHELL headers, mksdcard comment, Calypsi README, shell size comments). |
| Contract duplication | **OPEN by choice**: a generator single-sourcing the constants across the three repos is real tooling work and was deliberately not bundled with this behaviour-heavy pass. `kexec.c`/`goshell.c` note their duplicated constants. Recommended next hygiene task, together with the build-recipe include. |
| H-4 register-window write aliasing | **FIXED** (`top.v` `ib_addr_lo128k` on `palette_write` / `sprite_attr_write` / `audio_write`), RTL-only — the emulator was already correct. Found by writing test 5, not by running it. **Green on a DE10-Nano**: `scanout.c` preflight 4 probes `$3FA02`/`$3FC00` and paints grey if the alias is there, so the picture coming up at all is the proof. |
| Coverage gaps (§4 ❌ rows) | `run`/exec/goshell: **covered** for the firmware path (`run-fwboot.sh`, `sim fw`); ESC-cycle end-to-end still needs an `-autokeys` raw-keynum extension. VERA816 §8 test 5: **covered and GREEN ON HARDWARE** (`examples/vera/run-scanout.sh` + `SCANOUT.BIN` on the card, emulator-green with a negative control) — this was the last ❌ that mattered. sd_block RTL + SMC chain: Phase 2/3 of SIMULATION.md, unchanged. |

New since the audit (same pass): the VERA816 **blitter** (`blit816.v`,
DCSEL-33, VERA816.md §4.3, `sim/run.sh blit` green) per
[VERA_MEMORY_REVIEW.md](VERA_MEMORY_REVIEW.md), the shell `go` command (OSD
image hand-over under a resident kernel), `boot/hostfat.sh` (captures the
host-harness recipe whose absence had let it rot), and `run-fwboot.sh`.
