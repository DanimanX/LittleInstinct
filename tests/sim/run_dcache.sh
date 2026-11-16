#!/bin/sh
# D-cache bench. Needs GHDL, because cpu_datacache is VHDL and GHDL cannot
# co-simulate the Verilog benches' language.
#
#   GHDL=/path/to/ghdl tests/sim/run_dcache.sh
#
# It is deliberately NOT part of run.sh: the store path does not yet pass (see
# tests/sim/README.md), and run.sh's contract is "every bench that runs, passes".
#
# dpram_model.vhd stands in for rtl/cpu/dpram.vhd, which wraps altsyncram and
# cannot be elaborated without Altera's megafunction library. The model is
# documented at the top of the file; read it before trusting a failure.
set -eu
GHDL=${GHDL:-ghdl}
here=$(cd "$(dirname "$0")/../.." && pwd)
cd "$here"
OUT=build/sim/ghdl
mkdir -p "$OUT"
cd "$OUT"

rm -rf work mem
mkdir -p mem

# pFunctions goes in BOTH libraries: dpram lives in mem and uses it, and
# cpu_datacache says "use work.pFunctions.all".
"$GHDL" -a --work=mem --workdir=. --std=08 "$here/upstream/Arcade-KillerInstinct_MiSTer/rtl/cpu/functions.vhd"
"$GHDL" -a --work=work --workdir=. --std=08 "$here/upstream/Arcade-KillerInstinct_MiSTer/rtl/cpu/functions.vhd"
"$GHDL" -a --work=mem --workdir=. --std=08 "$here/tests/sim/dpram_model.vhd"
"$GHDL" -a --work=work --workdir=. --std=08 "$here/tests/sim/dpram_model.vhd"
"$GHDL" -a --workdir=. --std=08 "$here/src/fpga/pocket_rtl/cpu/cpu_datacache.vhd"
"$GHDL" -a --workdir=. --std=08 "$here/tests/sim/tb_dcache.vhd"
"$GHDL" -e --workdir=. --std=08 tb_dcache
"$GHDL" -r --workdir=. --std=08 tb_dcache --stop-time=120us --ieee-asserts=disable-at-0
