#!/bin/sh
# Load-use bubble regression: builds tb_cpu_loaduse on the boot bench's
# libraries and sweeps gen_loaduse_rom.py's variants (nops x write-FIFO stores
# x line eviction x SDRAM deferral). Every line must say DONE.
#
#   GHDL=/path/to/ghdl tests/sim/run_cpu_loaduse.sh
set -eu
GHDL=${GHDL:-ghdl}
here=$(cd "$(dirname "$0")/../.." && pwd)
W=$here/build/sim/ghdl-boot
# The boot bench's script analyses the CPU chain into $W; reuse it.
STOP=1us GHDL=$GHDL "$here/tests/sim/run_boot.sh" >/dev/null 2>&1 || true
"$GHDL" -a --workdir="$W" -P"$W/mem" --std=08 "$here/tests/sim/tb_cpu_loaduse.vhd"
"$GHDL" -e --workdir="$W" -P"$W/mem" --std=08 tb_cpu_loaduse
OUT=$here/build/sim/loaduse; rm -rf "$OUT"; fails=0
for d in 0 8; do for e in 0 1; do for s in 0 1 2 3; do for n in 0 1 2 3; do
	dir=$OUT/$n$s$e$d; mkdir -p "$dir/roms"
	SEG=0xBFC0 python3 "$here/tests/sim/gen_loaduse_rom.py" "$dir/roms/kinst.rom" $n $s $e 6
	pc=$(cd "$dir" && "$GHDL" -r --workdir="$W" -P"$W/mem" --std=08 tb_cpu_loaduse \
		-gDEFER=$d -gPASS_RET=2147483647 -gRUN_CYCLES=90000 --stop-time=3ms \
		--ieee-asserts=disable 2>&1 | grep -o "END: .* pc=[0-9A-F]*" | grep -o "pc=[0-9A-F]*" || true)
	case "$pc" in pc=BFC0080?) r=DONE;; *) r="FAIL($pc)"; fails=$((fails+1));; esac
	echo "nops=$n stores=$s evict=$e defer=$d -> $r"
done; done; done; done
[ $fails -eq 0 ] && echo PASS_LOADUSE || { echo "FAIL_LOADUSE: $fails"; exit 1; }
