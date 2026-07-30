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
rm -rf db incremental_db               # see the warning below -- do not skip
quartus_sh --flow compile X816.qpf     # bitstream -> output_files/X816.rbf

sh boot/build.sh                       # boot.hex <- the bands demo (needs cc65)
sh boot/build.sh vramtest              # boot.hex <- the VERA816 conformance test
```

`boot/boot.hex` is committed, so the bitstream builds with no toolchain
installed.

### Always clean before compiling

**Quartus's incremental flow is not trustworthy in this project.** It has
produced a wrong bitstream twice, in two different ways, and neither reported
an error:

* After changing `boot/boot.hex`, Quartus took a *"MIF/HEX Update"* fast path
  that regenerated the `.rbf` **without the new contents** — reporting success
  in about a minute and emitting a byte-identical file. A conformance-test
  build came out as the previous demo.
* After an RTL change, an incremental full compile reported 0 errors and a
  clean fit, but produced a bitstream that **did not work on hardware**.
  *(Cause not yet isolated — it is either the incremental flow or the RTL
  change itself. A clean rebuild of the same source is the experiment that
  separates them.)*

So: `rm -rf db incremental_db` before every compile that matters, and **verify
the output actually changed** before flashing it:

```sh
md5sum output_files/X816.rbf            # compare against the previous build
```

A five-minute rebuild is cheaper than debugging a bitstream that isn't the one
you think you are running.

## What it does today

**Confirmed working on real hardware** (DE10-Nano, 2026-07-30), and matching
the emulator pixel for pixel.

Power-on runs the boot stub: enters native mode, sets up S/D/DBR, copies
itself into RAM and drops the ROM overlay, then brings VERA up in 320×240 8bpp
bitmap mode and paints horizontal colour bands. That is a font-free proof that
the CPU, native mode, the flat bus, the I/O decode and video all work.

That one result validates the PLL frequencies, native-mode entry, the boot
overlay's self-copy and its `SYSCTL` unmapping mid-instruction-stream, bank-0
BRAM, the VERA bus pipeline and the MiSTer video path — and, because this
bitstream carries the 352 KB VERA816 widening, that the widening did not break
stock VERA behaviour.

**VERA816 is also confirmed on hardware.** `sh boot/build.sh vramtest` builds a
bitstream carrying the conformance test from [doc/VERA816.md](doc/VERA816.md)
— green on pass, red on fail — and it comes up green on a DE10-Nano as well as
on the emulator. That proves the full 352 KB is addressable, the 19-bit path
works including bits 17 and 18, the unpopulated region reads zero without
aliasing, auto-increment wraps, and `VRAMCAP` reads 22.

Not yet exercised on hardware: **SDRAM** — the boot stub runs entirely in bank
`$00`, which is BRAM, so 15.9 MB of the 16 MB address space has never served a
CPU access on silicon — along with the keyboard and audio.

Loading a program: OSD **Load Image** (or `boot1.rom` in the core's folder).
The file's byte offset is its flat address, so an image linked for `$01:0000`
should be padded or linked accordingly.

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
