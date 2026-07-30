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
sh boot/build.sh                       # rebuild boot/boot.hex (needs cc65)
```

`boot/boot.hex` is committed, so the bitstream builds with no toolchain
installed.

## What it does today

Power-on runs the boot stub: enters native mode, sets up S/D/DBR, copies
itself into RAM and drops the ROM overlay, then brings VERA up in 320×240 8bpp
bitmap mode and paints horizontal colour bands. That is a font-free proof that
the CPU, native mode, the flat bus, the I/O decode and video all work.

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
