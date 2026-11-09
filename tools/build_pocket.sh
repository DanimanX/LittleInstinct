#!/bin/sh
# Build the Analogue Pocket bitstream for Killer Instinct.
#
# Needs Quartus Prime with Cyclone V support (25.1 Lite is what this was
# verified with). Output: src/fpga/output_files/pocket_ki.rbf
#
#   tools/build_pocket.sh            # full compile + fit + assemble
#   tools/build_pocket.sh --fit-only # stop after the fitter (faster iteration)
set -eu

QUARTUS_BIN=${QUARTUS_BIN:-/opt/intelFPGA/25.1/quartus/bin}
if [ -d "$QUARTUS_BIN" ]; then
    PATH="$QUARTUS_BIN:$PATH"
    export PATH
fi
command -v quartus_sh >/dev/null 2>&1 || {
    echo "quartus_sh not found. Set QUARTUS_BIN or put Quartus on PATH." >&2
    exit 1
}

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/src/fpga"

if [ "${1:-}" = "--fit-only" ]; then
    quartus_sh --flow compile pocket_ki -c pocket_ki 2>&1 | tail -5
else
    quartus_sh --flow compile pocket_ki 2>&1 | tail -5
fi

echo
echo "---- fit summary ----"
sed -n '1,14p' output_files/pocket_ki.fit.summary
