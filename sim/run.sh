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
#   ./run.sh lint     # elaborate VERA's top and FAIL on any port/connection
#                     # width mismatch (see the target for why this exists)
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

# ---------------------------------------------------------------------------
# lint -- port/connection width agreement across the whole VERA tree.
#
# WHY THIS IS A TARGET AND NOT A STYLE CHECK. When VRAM grew to 352 KB every
# renderer's bus_addr and every vram_if port went 15 -> 17 bits, but the three
# WIRES joining them in top.v stayed at 15. Verilog truncates silently, so
# layer 0, layer 1 and sprites could only ever fetch from the first 128 KB --
# for weeks, through a "passing" conformance suite, because every test that
# checked the widening used the CPU data port (a different, genuinely 19-bit
# path) and the one test that would have caught it was never implemented.
#
# It took a screen on real hardware to find. The simulator names it in six
# lines and costs seconds, so it runs as a test now.
# ---------------------------------------------------------------------------
run_lint () {
  local vf out n
  vf=$(cd .. && grep -oE "vera/fpga/source/[a-zA-Z0-9_/]+\.v" files.qip | sort -u | sed 's|^|../|' | tr '\n' ' ')
  rm -rf lintwork
  vlib lintwork >/dev/null 2>&1
  out=$(vlog -quiet -work lintwork $vf ../vera/fpga/source/addr_data.v \
                                       ../vera/fpga/source/mult_accum.v 2>&1)
  if echo "$out" | grep -q "^\*\* Error"; then
    echo "$out" | grep "^\*\* Error" | head
    echo "*** FAIL: the VERA tree does not compile ***"
    return 1
  fi
  out=$(vsim -c -lib lintwork top -do "quit -f" 2>&1)
  # `|| true` on both: grep exits 1 when it finds nothing, which is the GOOD
  # outcome here, and this script runs under `set -e`.
  n=$(echo "$out" | grep -c "PCDPC" || true)
  echo "$out" | grep "PCDPC" | sed 's/^# \*\* Warning: //' || true
  if [ "$n" -ne 0 ]; then
    echo "*** FAIL: $n port/connection width mismatch(es) -- silent truncation ***"
    return 1
  fi
  echo "[TB] VERA tree elaborates with no port/connection width mismatch"
  echo "*** PASS ***"
}

case "${1:-all}" in
  boot)   run_boot 1 bootprobe.hex $PROBE_LEN ;;
  fw)     run_boot 2 fwprobe.hex   $FWPROBE_LEN ;;
  noboot) run_boot 0 bootprobe.hex $PROBE_LEN ;;
  blit)   run_blit ;;
  lint)   run_lint ;;
  all)    echo "----- lint (VERA port widths) -----";  run_lint
          echo "----- boot (staged program) -----";    run_boot 1 bootprobe.hex $PROBE_LEN
          echo "----- fw (kernel firmware) -----";     run_boot 2 fwprobe.hex   $FWPROBE_LEN
          echo "----- blit (VRAM blitter) -----";      run_blit
          echo "----- noboot (bands fallback) -----";  run_boot 0 bootprobe.hex $PROBE_LEN ;;
  *)      echo "unknown target: $1 (boot | fw | noboot | blit | lint | all)"; exit 1 ;;
esac
