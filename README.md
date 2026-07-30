# X816 — a flat 16 MB, native-mode 65C816 for MiSTer

A new machine, not a Commander X16. It runs the 65C816 in **native mode only**
(M=0, X=0) over a **flat 24-bit / 16 MB** address space, with no bank latches
and no paging windows.

It reuses the [Commander X16 MiSTer core](../x16_mister)'s peripherals — VERA,
YM2151, two 6522 VIAs, the SMC keyboard path — and the whole MiSTer framework.
It does **not** reuse the X16's architecture or software: the X16 ROM is 8-bit
65C02 code built around the bank latches, so none of it runs here.

## Memory map

```
$00:0000-$00:9EFF   RAM   64 KB bank-0 BRAM, single cycle
$00:9F00-$00:9FFF   I/O   (page layout identical to the X16)
$00:A000-$00:FEFF   RAM
$00:FF00-$00:FFFF   boot ROM overlay for reads while SYSCTL[0]=1; RAM beneath
$01:0000-$FF:FFFF   RAM   SDRAM, stalls the CPU per access
```

I/O page:

| Range | Device |
|---|---|
| `$9F00-$9F0F` | VIA #1 (SNES pads, I²C to SMC) |
| `$9F10-$9F1F` | VIA #2 (user port) |
| `$9F20-$9F3F` | VERA |
| `$9F40-$9F4F` | YM2151 |
| `$9F80-$9F8F` | SYSCTL — bit 0 boot overlay; reads also expose the CPU's E flag |

## Requirements

- DE10-Nano (`5CSEBA6U23I7`) with a **32 MB or larger** SDRAM module.
  8 MB parts cannot back a flat '816.
- Quartus 24.1std (Lite is fine).

## Build

```sh
quartus_sh --flow compile X816.qpf     # bitstream -> output_files/X816.rbf

sh boot/build.sh                       # boot.hex <- the bands demo (needs cc65)
sh boot/build.sh vramtest              # boot.hex <- the VERA816 conformance test
```

`boot/boot.hex` is committed, so the bitstream builds with no toolchain
installed.

Copy the result to `/media/fat/_Computer/` on the MiSTer SD card and **keep
MiSTer's `<Name>_<date>.rbf` naming convention** — e.g. `X816_20260730.rbf`.
A file that does not follow the pattern can misbehave in the launcher in ways
that look exactly like a broken bitstream (black screen, unresponsive board).
That cost an afternoon of RTL debugging here.

## What it does today

**Confirmed working on real hardware** (DE10-Nano) — both the bands bring-up
demo and the VERA816 conformance test, matching the emulator.

`sh boot/build.sh vramtest` builds a
bitstream carrying the conformance test from [doc/VERA816.md](doc/VERA816.md)
— green on pass, red on fail — and it comes up green on a DE10-Nano as well as
on the emulator. That proves the full 352 KB is addressable, the 19-bit path
works including bits 17 and 18, the unpopulated region reads zero without
aliasing, auto-increment wraps, and `VRAMCAP` reads 22.

Power-on runs the boot stub: enters native mode, sets up S/D/DBR, copies
itself into RAM and drops the ROM overlay, then brings VERA up in 320×240 8bpp
bitmap mode and paints horizontal colour bands. That is a font-free proof that
the CPU, native mode, the flat bus, the I/O decode and video all work.

That one result validates the PLL frequencies, native-mode entry, the boot
overlay's self-copy and its `SYSCTL` unmapping mid-instruction-stream, bank-0
BRAM, the VERA bus pipeline and the MiSTer video path — and, because this
bitstream carries the 352 KB VERA816 widening, that the widening did not break
stock VERA behaviour.

**SDRAM is confirmed on hardware too.** `sh boot/build.sh sdramtest` builds a
bitstream carrying [boot/sdramtest.s](boot/sdramtest.s), which walks the bank
address lines (A16-A23 across all 255 SDRAM banks), the mid and low address
lines, and the data lines — each failing in a distinct colour so the screen
names the fault class. It comes up green on a DE10-Nano.

That proves the whole flat 16 MB, and with it the three load-bearing
constraints in [rtl/flat_sdram.sv](rtl/flat_sdram.sv): the `ready` cone that
must not compare live address bits, the `| we` term the '816's global clock
enable depends on, and consume-clear read delivery.

Not yet exercised on hardware: the keyboard, audio, and the SD card.

## Running a program

Programs load at `PROG_BASE` = `$01:0000`, the first SDRAM bank. The boot stub
looks for the four-byte magic `X816` there and jumps to `$01:0004`; without it
the bands demo runs instead, so a core with nothing loaded still shows life.

Load with the OSD **Load Image** entry, or drop the image in the core's folder
as `boot1.rom` for auto-load at core start. The RTL adds `PROG_BASE` to the
file offset, so a program links at `$01:0004` and loads from offset 0 — no
padding.

```sh
cd boot
ca65 --cpu 65816 hello.s -o hello.o
ld65 -C prog.cfg hello.o -o hello.bin      # -> load this
```

**`boot/hello.s` is confirmed working on hardware and the emulator** — 80×60
VERA text mode at 640×480, with `putc`/`puts`/`cls`/`newline` and an 8×8 font
uploaded to VRAM. It runs in place from SDRAM, so every instruction fetch goes
through the CPU stall path.

Two things bite every program that runs outside bank `$00`, both learned the
hard way in `hello.s`:

* **Data access needs long addressing.** DBR stays `$00` so the I/O page at
  `$9Fxx` is reachable, which means a program's *own* data is not where plain
  absolute addressing looks. Use `f:label,x` and `[ptr],y`. This is what
  Calypsi's `__far24` handles for you.
* **Watch direct-page overlap.** A 3-byte long pointer at `$12` occupies
  `$12-$14`; putting a scratch byte at `$14` silently corrupts its bank.

## License

MIT — see [LICENSE](LICENSE). Third-party components (the MiSTer framework,
VERA, IKAOPM and the P65C816 core) remain under their own licenses, listed
there. Note that `sys/` is GPL-3.0, so a distributed bitstream or a copy of the
repository as a whole is subject to the GPL's terms.

## Documentation

[doc/TOOLCHAIN.md](doc/TOOLCHAIN.md) — Calypsi C: license terms, install,
the code/data model configuration that matches this machine's memory hierarchy,
and the board support package.

[doc/MEMORY_MAP.md](doc/MEMORY_MAP.md) — full map with sizes: the CPU's flat
16 MB, the I/O page, VERA's separate VRAM space, and the physical M10K/SDRAM
accounting behind both.

[doc/PORTING.md](doc/PORTING.md) — what was reused, the three architectural
pieces (24-bit wrapper, memory split, native-mode entry), what is deliberately
not wired yet, and the known performance ceiling with the two fixes for it.
