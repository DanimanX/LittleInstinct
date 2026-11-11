#!/bin/sh
# Regression benches for the Pocket loader, boot sequencer and input chord.
#
# Needs Icarus Verilog 11+ on PATH (or set IVERILOG=/path/to/iverilog).
# These benches use behavioural models for the Altera dcfifo and the SDRAM
# device; they verify the RTL handshakes, not silicon timing.
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
IV=${IVERILOG:-iverilog}
VV=${VVP:-vvp}
OUT=build/sim
mkdir -p "$OUT"

run() {
	name=$1; shift
	echo "== $name"
	$IV -g2012 -DKI_FB_OFFCHIP -o "$OUT/$name.vvp" "$@"
	$VV "$OUT/$name.vvp"
}

run tb_input_chord \
	tests/sim/tb_input_chord.sv src/fpga/pocket_rtl/ki_input_chord.sv

run tb_boot_ctrl \
	tests/sim/tb_boot_ctrl.sv src/fpga/pocket_rtl/ki_boot_ctrl.sv

run tb_pk_io_paths \
	tests/sim/dcfifo_model.sv tests/sim/tb_pk_io_paths.sv \
	src/fpga/pocket_rtl/pk_io.sv

run tb_loader_e2e \
	tests/sim/dcfifo_model.sv tests/sim/sdram_model.sv tests/sim/tb_loader_e2e.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_board_pkg.sv \
	src/fpga/pocket_rtl/pk_io.sv \
	src/fpga/pocket_rtl/ki_memory_bridge_pocket.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_sdram_adapter.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_sdram_x2.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_sdram_burst.sv \
	upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_fast_fill.sv
