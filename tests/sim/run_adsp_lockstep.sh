#!/bin/sh
# Prove pocket_rtl/dcs/adsp2105_lean.sv equal to upstream's adsp2105.sv, clock
# by clock. Run this after ANY edit to the lean DSP, before building.
#
#   tests/sim/run_adsp_lockstep.sh                 # three fuzz runs
#   tests/sim/run_adsp_lockstep.sh roms/kinst.rom  # + the real sound ROM
#
# Needs Icarus Verilog 12+ (IVERILOG / VVP override the binaries).
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
IV=${IVERILOG:-iverilog}
VV=${VVP:-vvp}
UP=upstream/Arcade-KillerInstinct_MiSTer/rtl/dcs
OUT=build/sim
mkdir -p "$OUT"

# The reference is upstream's file, renamed, with one declaration moved above
# its first use (Icarus insists; Quartus does not care).
sed -e 's/\r//' -e 's/^module adsp2105 /module adsp2105_ref /' \
    -e 's/^    reg \[23:0\] op;$//' \
    -e 's/^    wire cpu_ce = core_ce;$/    wire cpu_ce = core_ce; reg [23:0] op;/' \
    "$UP/adsp2105.sv" > "$OUT/adsp2105_ref.sv"

$IV -g2012 -DKI_DCS_SIMULATION -o "$OUT/adsp_lock.vvp" \
    tests/sim/tb_adsp_lockstep.sv "$OUT/adsp2105_ref.sv" \
    src/fpga/pocket_rtl/dcs/adsp2105_lean.sv "$UP/dcs_mem.sv"

fail=0
run() {
	echo "== $*"
	$VV -n "$OUT/adsp_lock.vvp" "$@" | tail -3 | tee "$OUT/last.log"
	grep -q '^PASS' "$OUT/last.log" || fail=1
}
run +fuzz=1 +cycles=3000000 +cmdgap=3000 +dacdiv=97
run +fuzz=2 +ce=1 +cycles=3000000 +cmdgap=500 +dacdiv=33
run +fuzz=3 +ce=2 +cycles=3000000 +cmdgap=2000 +dacdiv=200
if [ -n "${1:-}" ]; then
	# kinst.rom = 512 KiB boot ROM + 4 MiB DCS image
	tail -c +524289 "$1" > "$OUT/kinst_dcs.bin"
	run +rom="$OUT/kinst_dcs.bin" +cycles=3000000
fi
[ $fail -eq 0 ] && echo "ALL PASS" || { echo "LOCKSTEP FAILED"; exit 1; }
