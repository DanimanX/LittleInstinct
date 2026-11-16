#!/bin/sh
# ADSP sound board bench: does the real DCS ROM make the DSP emit PCM?
#
# Needs Icarus Verilog 11+ on PATH (or set IVERILOG=/path/to/iverilog) and the
# packed DCS image beat file:
#
#   python3 tools/gen_dcs_rom_hex.py <kinst.rom> tests/sim/vectors/dcs_kinst.hex
#
# -DKI_DCS_SIMULATION is mandatory: without it the DCS RTL compiles its
# synthesis branch (altsyncram, no behavioral PM), which iverilog cannot use.
#
# usage: run_adsp.sh [vvp-plusargs...]
#   e.g. run_adsp.sh -lxt2     (keep a wave file at build/sim/tb_adsp.lxt2)
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
IV=${IVERILOG:-iverilog}
VV=${VVP:-vvp}
OUT=build/sim
mkdir -p "$OUT"

ROM=tests/sim/vectors/dcs_kinst.hex
if [ ! -f "$ROM" ]; then
	echo "missing $ROM" >&2
	echo "run: python3 tools/gen_dcs_rom_hex.py <kinst.rom> $ROM" >&2
	exit 2
fi

$IV -g2012 -Wall -DKI_DCS_SIMULATION -o "$OUT/tb_adsp.vvp" \
	tests/sim/adsp_rom_model.sv \
	tests/sim/tb_adsp.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_dcs_audio.sv \
	src/fpga/pocket_rtl/dcs/adsp2105_lean.sv \
	src/fpga/pocket_rtl/dcs/dcs_mem.sv

$VV "$OUT/tb_adsp.vvp" "$@"
