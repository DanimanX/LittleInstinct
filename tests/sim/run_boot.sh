#!/bin/sh
# Boot-ROM bring-up bench: runs the real boot ROM image on the real CPU.
#
#   GHDL=/path/to/ghdl tests/sim/run_boot.sh
#
# Not part of run.sh: it is a diagnosis of the Pocket's first-boot hang
# (PC frozen at 0xBFC00400, error_stall set), not a pass/fail regression yet.
#
# The `mem` library gets its OWN workdir. GHDL names objects after the source
# file, so analysing functions.vhd / dpram_model.vhd / RamMLAB_model.vhd into
# two libraries in one directory leaves one object per unit name and the
# elaboration then cannot resolve mem.* - tests/sim/run_cpu.sh hits exactly
# that with GHDL 7.0 (undefined reference to mem__rammlab__RTI).
set -eu
GHDL=${GHDL:-ghdl}
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
OUT=${OUT:-build/sim/ghdl-boot}
rm -rf "$OUT"
mkdir -p "$OUT/mem"
cd "$OUT"

R=$here
CORE="$R/upstream/Arcade-KillerInstinct_MiSTer/rtl"

MEMFILES="
	$CORE/cpu/functions.vhd
	$CORE/cpu/export.vhd
	$R/tests/sim/RamMLAB_model.vhd
	$R/tests/sim/dpram_model.vhd
	$CORE/cpu/SyncFifoFallThroughMLAB.vhd
	$CORE/cpu/divider.vhd
	$CORE/cpu/cpu_cdc_fifo.vhd
	$CORE/cpu/cpu_TLB_instr.vhd
	$CORE/cpu/cpu_TLB_data.vhd
	$CORE/cpu/cpu_mul.vhd
	$CORE/cpu/cpu_cop0.vhd
"

for f in $MEMFILES; do
	"$GHDL" -a --work=mem --workdir=mem --std=08 "$f"
done
for f in $MEMFILES; do
	"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$f"
done

"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$CORE/cpu/cpu_instrcache.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$R/src/fpga/pocket_rtl/cpu/cpu_datacache.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$CORE/cpu/cpu_FPU_sqrt.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$CORE/cpu/cpu_FPU.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$R/src/fpga/pocket_rtl/cpu/cpu_pocket.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$CORE/ki_cpu_core.vhd"
"$GHDL" -a --workdir=. -P. -Pmem --std=08 "$R/tests/sim/tb_cpu_boot.vhd"
"$GHDL" -e --workdir=. -P. -Pmem --std=08 tb_cpu_boot
# Run from the repository root: the bench opens roms/kinst.rom by that path.
cd "$R"
exec "$OUT/tb_cpu_boot" \
	--stop-time=${STOP:-20ms} --ieee-asserts=disable \
	--wave="$OUT/wave_boot.ghw" "$@"
