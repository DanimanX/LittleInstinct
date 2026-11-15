#!/bin/sh
# CPU-level bench: runs a real MIPS program on ki_cpu_core through GHDL.
#
#   GHDL=/path/to/ghdl tests/sim/run_cpu.sh
#
# Not part of run.sh: it does not pass yet (see tests/sim/README.md).
#
# The CPU is VHDL and pulls in the whole core - caches, TLB, COP0, divider,
# multiplier - so this compiles the lot. RamMLAB_model.vhd and dpram_model.vhd
# stand in for the Altera megafunction wrappers, and pFunctions has to go into
# BOTH libraries because dpram lives in mem and cpu_datacache says
# "use work.pFunctions.all".
set -eu
GHDL=${GHDL:-ghdl}
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
OUT=build/sim/ghdl-cpu
mkdir -p "$OUT"
cd "$OUT"
rm -rf work mem
mkdir -p mem

R=$here
CORE="$R/upstream/Arcade-KillerInstinct_MiSTer/rtl"

for lib in mem work; do
	for f in \
		"$CORE/cpu/functions.vhd" \
		"$CORE/cpu/export.vhd" \
		"$R/tests/sim/RamMLAB_model.vhd" \
		"$R/tests/sim/dpram_model.vhd" \
		"$CORE/cpu/SyncFifoFallThroughMLAB.vhd" \
		"$CORE/cpu/divider.vhd" \
		"$CORE/cpu/cpu_cdc_fifo.vhd" \
		"$CORE/cpu/cpu_TLB_instr.vhd" \
		"$CORE/cpu/cpu_TLB_data.vhd" \
		"$CORE/cpu/cpu_mul.vhd" \
		"$CORE/cpu/cpu_cop0.vhd" ; do
		"$GHDL" -a --work=$lib --workdir=. --std=08 "$f"
	done
done

"$GHDL" -a --workdir=. --std=08 "$CORE/cpu/cpu_instrcache.vhd"
"$GHDL" -a --workdir=. --std=08 "$R/src/fpga/pocket_rtl/cpu/cpu_datacache.vhd"
"$GHDL" -a --workdir=. --std=08 "$R/src/fpga/pocket_rtl/cpu/cpu_FPU_stub.vhd"
"$GHDL" -a --workdir=. --std=08 "$R/src/fpga/pocket_rtl/cpu/cpu_pocket.vhd"
"$GHDL" -a --workdir=. --std=08 "$CORE/ki_cpu_core.vhd"
"$GHDL" -a --workdir=. --std=08 "$R/tests/sim/tb_cpu_mem.vhd"
"$GHDL" -e --workdir=. --std=08 tb_cpu_mem
"$GHDL" -r --workdir=. --std=08 tb_cpu_mem --stop-time=200us --ieee-asserts=disable-at-0
