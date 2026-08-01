#!/usr/bin/env bash
# X816 RTL simulation runner -- ModelSim batch, structure ported from
# x16_mister/sim/run.sh.  Self-checking testbenches; verdicts are grep-able
# and a failed target exits nonzero.
#
#   ./run.sh boot     # boot ROM happy path: stage an image through the real
#                     # loader port, magic check, program runs (fast)
#   ./run.sh fw       # kernel-firmware path: image staged at $F0:0000
#                     # (boot2.rom), firmware magic branch + write-protect
#   ./run.sh noboot   # no image staged: colour-bands fallback + WAI park
#                     # (simulates ~1M cpu cycles -- takes a few minutes)
#   ./run.sh blit     # VERA816 blitter unit test (blit816 + vram_if + the
#                     # real 352 KB main_ram; fill/copy/wrap/contention)
#   ./run.sh all      # everything
#
# The DUT chain is the real RTL: p65c816_flat_wrap + bank0_ram + boot_rom
# (running the SHIPPED boot/boot.hex) + flat_sdram, with sdram_sim.v standing
# in for the SDRAM chip and vera_stub.sv for VERA.  See tb_boot.v's header.
set -e
MS=${MS:-/c/intelFPGA_lite/17.0/modelsim_ase/win32aloem}
CC65=${CC65:-/c/Emulator/cc65/bin}
export PATH="$MS:$CC65:$PATH"
cd "$(dirname "$0")"

# boot_rom.sv reads "boot/boot.hex" relative to the vsim cwd -- mirror the
# repo's committed image here so the sim always runs what the bitstream bakes.
mkdir -p boot
cp -f ../boot/boot.hex boot/boot.hex

echo "=== assemble bootprobe.s + fwprobe.s (ca65 65816) ==="
ca65 --cpu 65816 bootprobe.s -o bootprobe.o
ld65 -C ../boot/prog.cfg bootprobe.o -o bootprobe.rom
od -An -v -tx1 bootprobe.rom | tr -s ' ' '\n' | grep -v '^$' > bootprobe.hex
PROBE_LEN=$(wc -l < bootprobe.hex)
ca65 --cpu 65816 fwprobe.s -o fwprobe.o
ld65 -C fwprobe.cfg fwprobe.o -o fwprobe.rom
od -An -v -tx1 fwprobe.rom | tr -s ' ' '\n' | grep -v '^$' > fwprobe.hex
FWPROBE_LEN=$(wc -l < fwprobe.hex)
echo "bootprobe.hex: $PROBE_LEN bytes   fwprobe.hex: $FWPROBE_LEN bytes"

echo "=== compile P65C816 core + flat wrapper (VHDL-2008) ==="
if [ ! -d work ]; then vlib work >/dev/null 2>&1; fi
CORE=../rtl/cpu/65C816
vcom -quiet -2008 -work work \
  "$CORE/P65816_pkg.vhd" "$CORE/BCDAdder.vhd" "$CORE/AddSubBCD.vhd" "$CORE/ALU.vhd" \
  "$CORE/AddrGen.vhd" "$CORE/MCode.vhd" "$CORE/P65C816.vhd" "$CORE/p65c816_flat_wrap.vhd"

echo "=== compile RTL + sim models + testbenches ==="
vlog -quiet -sv ../rtl/bank0_ram.sv ../rtl/boot_rom.sv ../rtl/flat_sdram.sv \
     sdram_sim.v vera_stub.sv tb_boot.v
vlog -quiet -sv ../vera/fpga/source/main_ram.v ../vera/fpga/source/vram_if.v \
     ../vera/fpga/source/blit816.v tb_blit816.v

run_boot () {  # $1 = MODE, $2 = image hex, $3 = image length
  local out
  out=$(vsim -c -gMODE=$1 -gIMAGE_HEX="$2" -gIMAGE_LEN=$3 -do "run -all; quit -f" tb_boot 2>&1) || true
  echo "$out" | grep -E "\[TB\]|PASS|FAIL|TRAP|Error" || echo "$out" | tail -20
  echo "$out" | grep -q '\*\*\* PASS \*\*\*' || { echo "*** TARGET FAILED ***"; return 1; }
}

run_blit () {
  local out
  out=$(vsim -c -do "run -all; quit -f" tb_blit816 2>&1) || true
  echo "$out" | grep -E "\[TB\]|PASS|FAIL|MISMATCH|Error" || echo "$out" | tail -20
  echo "$out" | grep -q '\*\*\* PASS \*\*\*' || { echo "*** TARGET FAILED ***"; return 1; }
}

case "${1:-all}" in
  boot)   run_boot 1 bootprobe.hex $PROBE_LEN ;;
  fw)     run_boot 2 fwprobe.hex   $FWPROBE_LEN ;;
  noboot) run_boot 0 bootprobe.hex $PROBE_LEN ;;
  blit)   run_blit ;;
  all)    echo "----- boot (staged program) -----";    run_boot 1 bootprobe.hex $PROBE_LEN
          echo "----- fw (kernel firmware) -----";     run_boot 2 fwprobe.hex   $FWPROBE_LEN
          echo "----- blit (VRAM blitter) -----";      run_blit
          echo "----- noboot (bands fallback) -----";  run_boot 0 bootprobe.hex $PROBE_LEN ;;
  *)      echo "unknown target: $1 (boot | fw | noboot | blit | all)"; exit 1 ;;
esac
