#!/bin/sh
# Measure how the Killer Instinct core fits the Analogue Pocket's Cyclone V.
#
# This builds the UPSTREAM core on the Pocket's device with each proposed
# re-engineering change switched on or off, and prints the fit summary for each.
# It never touches upstream/ or src/fpga/: it assembles a throwaway tree under
# build/measure/ from copies, applies the patches there, and compiles.
#
#   tools/measure/measure_fit.sh baseline        # upstream, untouched
#   tools/measure/measure_fit.sh fb-off          # framebuffer off chip
#   tools/measure/measure_fit.sh fb-off-no-fpu   # + R4600 FPU stubbed
#   tools/measure/measure_fit.sh all             # all of the above
#
# Single-block benchmark (docs/ADSP_ATTACK.md):
#   tools/measure/measure_fit.sh adsp            # isolated DCS ADSP-2105
#
# Each variant takes 6-10 minutes. Results and the per-entity tables are left in
# build/measure/<variant>/ for inspection; docs/REENGINEERING.md quotes them.
#
# Prerequisites: Quartus Prime with Cyclone V (25.1 Lite verified).
set -eu

QUARTUS_BIN=${QUARTUS_BIN:-/opt/intelFPGA/25.1/quartus/bin}
[ -d "$QUARTUS_BIN" ] && PATH="$QUARTUS_BIN:$PATH"
export PATH
command -v quartus_sh >/dev/null 2>&1 || {
    echo "quartus_sh not found; set QUARTUS_BIN or put Quartus on PATH" >&2; exit 1; }

root=$(cd "$(dirname "$0")/../.." && pwd)
src="$root/upstream/Arcade-KillerInstinct_MiSTer"
stub="$root/tools/measure/cpu_FPU_stub.vhd"
[ -d "$src/rtl" ] || { echo "upstream RTL missing at $src" >&2; exit 1; }

# ---------------------------------------------------------------- tree setup
prepare() {  # $1 = variant name
    v="$root/build/measure/$1"
    rm -rf "$v"
    mkdir -p "$v/sys"
    cp -r "$src/rtl" "$v/rtl"
    cp "$src/KillerInstinct.sv" "$v/"
    # hps_io is replaced by the loader stub (see feas_top.sv and hps_io_stub.sv):
    # the real one gets optimised away with HPS_BUS unconnected, taking the
    # core's ROM-download path with it.
    cp "$root/tools/measure/hps_io_stub.sv" "$v/sys/"
    cp "$src/files.qip" "$v/" 2>/dev/null || : > "$v/files.qip"

    # feas_top.sv instantiates the upstream `emu` with the MiSTer board IO tied
    # to real pins through one reduction, so the fitter cannot delete blocks
    # whose results are unobserved. Leaving outputs dangling was measured
    # silently discarding the CPU, framebuffer and ATA controller and reporting
    # a 13,145 ALM "fit" that was not one.
    cp "$root/tools/measure/feas_top.sv" "$v/"

    # File list: upstream files.qip minus the DCS qip (re-added below, it must
    # come after the dcs sources are on the path) plus hps_io, the DCS memory
    # files and the core PLL.
    # Drop the DCS qip (re-added after the dcs sources are on the path) and the
    # SDC (its clock names refer to the MiSTer PLL and board, which this harness
    # does not instantiate; the design is measured, not timed).
    grep -v -e 'rtl/dcs/dcs.qip' -e 'SDC_FILE' "$v/files.qip" > "$v/files.list" || :
    {
        echo 'set_global_assignment -name FAMILY "Cyclone V"'
        echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
        echo 'set_global_assignment -name TOP_LEVEL_ENTITY feas_top'
        echo 'set_global_assignment -name VHDL_INPUT_VERSION VHDL_2008'
        echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
        echo 'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"'
        echo 'set_global_assignment -name VERILOG_MACRO "MISTER_DISABLE_ALSA=1"'
        echo 'set_global_assignment -name VERILOG_MACRO "MISTER_DOWNSCALE_NN=1"'
        cat "$v/files.list"
        echo 'set_global_assignment -name SYSTEMVERILOG_FILE sys/hps_io_stub.sv'
        echo 'set_global_assignment -name QIP_FILE rtl/dcs/dcs.qip'
        echo 'set_global_assignment -name QIP_FILE rtl/pll.qip'
        echo 'set_global_assignment -name SYSTEMVERILOG_FILE feas_top.sv'
    } > "$v/feas.qsf"
    rm -f "$v/files.list"
}

patch_fb_off() {   # framebuffer out of block RAM
    f="$root/build/measure/$1/rtl/ki_memory_bridge.sv"
    python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """  localparam integer FB_BUFFER_WORDS = 19200;
  localparam integer FB_WORDS = 38400;"""
new = """`ifdef KI_FB_OFFCHIP
  localparam integer FB_BUFFER_WORDS = 320;
  localparam integer FB_WORDS = 640;
`else
  localparam integer FB_BUFFER_WORDS = 19200;
  localparam integer FB_WORDS = 38400;
`endif"""
assert old in s, "framebuffer params not found"
s = s.replace(old, new)
inst = """  ki_fb_ram #(.WORDS(FB_WORDS)) fb_ram (
    .clock(clk),
    .cpu_address(fb_addr),
    .cpu_data(fb_wdata),
    .cpu_byteena(fb_wbe),
    .cpu_wren(fb_we),
    .cpu_q(fb_q),
    .vid_address(fb_vaddr),
    .vid_q(fb_vq)
  );
"""
wrapped = """`ifdef KI_FB_BYPASS
  // Measurement: framebuffer resident off chip, no on-chip storage.
  assign fb_q  = 64'd0;
  assign fb_vq = 64'd0;
`else
""" + inst + "`endif\n"
assert inst in s, "framebuffer instance not found verbatim"
s = s.replace(inst, wrapped)
open(p, 'w').write(s)
print("  patched: framebuffer params + instance behind ifdefs")
PY
    printf '%s\n' 'set_global_assignment -name VERILOG_MACRO "KI_FB_OFFCHIP=1"' \
                  'set_global_assignment -name VERILOG_MACRO "KI_FB_BYPASS=1"' >> "$root/build/measure/$1/feas.qsf"
}

patch_no_fpu() {   # R4600 floating-point unit stubbed
    v="$root/build/measure/$1"
    cp "$stub" "$v/rtl/cpu/cpu_FPU_stub.vhd"
    python3 - "$v/rtl/cpu/cpu.vhd" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "icpu_FPU : entity work.cpu_FPU"
assert old in s, "cpu_FPU instantiation not found"
s = s.replace(old, "icpu_FPU : entity work.cpu_FPU_stub", 1)
open(p, 'w').write(s)
print("  patched: cpu_FPU -> cpu_FPU_stub")
PY
    echo 'set_global_assignment -name VHDL_FILE rtl/cpu/cpu_FPU_stub.vhd' >> "$v/feas.qsf"
}

# ---------------------------------------------------------------- one variant
# PREPARE_ONLY=1 stops after assembling and patching, to inspect the tree
# without spending 6-10 minutes per variant on a compile.
run() { [ "${PREPARE_ONLY:-0}" = 1 ] && { echo "  prepared (PREPARE_ONLY=1)"; return 0; }
        _run "$@"; }
_run() {  # $1 = variant name
    v="$root/build/measure/$1"
    echo
    echo "=== $1 ==============================================="
    ( cd "$v" && quartus_sh --flow compile feas > "build_$1.log" 2>&1 ) || true
    if [ -f "$v/feas.fit.summary" ]; then
        grep -E 'Fitter Status|Logic utilization \(in ALMs\)|Total registers|Total block memory bits|Total DSP' \
             "$v/feas.fit.summary" || true
        # The report tables are ;-delimited and padded; take the second field.
        echo "  LABs:      $(grep -E 'Total LABs' "$v/feas.fit.rpt" | head -1 | awk -F';' '{print $2}')"
        echo "  M10K:      $(grep -E 'M10K blocks' "$v/feas.fit.rpt" | head -1 | awk -F';' '{print $2}')"
    else
        echo "  no fit summary; see $v/build_$1.log"
    fi
}

# ---------------------------------------------------------------- ADSP block
adsp_prepare() {  # $1 = variant name
    v="$root/build/$1"
    rm -rf "$v"
    mkdir -p "$v"
    cp "$src/rtl/dcs/adsp2105.sv" "$src/rtl/dcs/dcs_mem.sv" "$v/"
    cp "$root/tools/measure/adsp_bench.sv" "$v/"
    {
        echo 'set_global_assignment -name FAMILY "Cyclone V"'
        echo 'set_global_assignment -name DEVICE 5CEBA4F23C8'
        echo 'set_global_assignment -name TOP_LEVEL_ENTITY adsp_bench'
        echo 'set_global_assignment -name SYSTEMVERILOG_FILE adsp_bench.sv'
        echo 'set_global_assignment -name SYSTEMVERILOG_FILE adsp2105.sv'
        echo 'set_global_assignment -name SYSTEMVERILOG_FILE dcs_mem.sv'
        echo 'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"'
        echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
    } > "$v/adsp.qsf"
    {
        echo 'QUARTUS_VERSION = "25.1"'
        echo 'DATE = "15:10:00  November 09, 2026"'
        echo 'PROJECT_REVISION = "adsp"'
    } > "$v/adsp.qpf"
}

patch_shift_subset() {  # narrow the ADSP shifter to the modes the DCS driver uses
    v="$root/build/measure/$1"
    python3 - "$v/rtl/dcs/adsp2105.sv" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "              4'h4, 4'h5: begin // ASHIFT (HI[,OR])"
assert marker in s, "shifter mode 4 not found"
i = s.index(marker)
j = s.index("            endcase", i)
s = s[:i] + (
    "              default: begin // SUBSET (docs/ADSP_SUBSET.md): ASHIFT/NORM/EXP/\n"
    "                // EXPADJ are never executed by the DCS driver, which uses only\n"
    "                // LSHIFT modes 0-3. Measured: -80 LABs.\n"
    "                res = 32'h0;\n"
    "              end\n") + s[j:]
open(p, 'w').write(s)
print("  patched: shifter narrowed to modes 0-3")
PY
}

patch_pf() {  # halve the DCS ROM prefetch cache (dcs_mem PF_LINES)
    v="$root/build/measure/$1"
    sed -i 's/parameter PF_LINES = 512/parameter PF_LINES = 256/' "$v/rtl/dcs/dcs_mem.sv"
    grep -q 'PF_LINES = 256' "$v/rtl/dcs/dcs_mem.sv" || {
        echo "  PATCH FAILED: PF_LINES" >&2; exit 1; }
    echo "  patched: dcs_mem PF_LINES 512 -> 256"
}

adsp_run() {  # $1 = variant name
    v="$root/build/$1"
    [ "${PREPARE_ONLY:-0}" = 1 ] && { echo "  prepared (PREPARE_ONLY=1)"; return 0; }
    echo
    echo "=== ADSP $1 =========================================="
    ( cd "$v" && quartus_sh --flow compile adsp > "build_$1.log" 2>&1 ) || true
    if [ -f "$v/adsp.fit.summary" ]; then
        grep -E 'Fitter Status|Logic utilization \(in ALMs\)|Total registers|Total block memory bits|Total DSP' \
             "$v/adsp.fit.summary" || true
    else
        echo "  no fit summary; see $v/build_$1.log"
    fi
}

case "${1:-}" in
adsp)           adsp_prepare adsp; adsp_run adsp ;;
fb-off-no-fpu-shrink) prepare fb-off-no-fpu-shrink
                patch_fb_off fb-off-no-fpu-shrink
                patch_no_fpu fb-off-no-fpu-shrink
                patch_shift_subset fb-off-no-fpu-shrink
                run fb-off-no-fpu-shrink ;;
fb-off-no-fpu-pf) prepare fb-off-no-fpu-pf; patch_fb_off fb-off-no-fpu-pf; patch_no_fpu fb-off-no-fpu-pf; patch_pf fb-off-no-fpu-pf; run fb-off-no-fpu-pf ;;
baseline)       prepare baseline;                                  run baseline ;;
fb-off)         prepare fb-off;        patch_fb_off fb-off;        run fb-off ;;
fb-off-no-fpu)  prepare fb-off-no-fpu; patch_fb_off fb-off-no-fpu; patch_no_fpu fb-off-no-fpu; run fb-off-no-fpu ;;
all)            prepare baseline;                                  run baseline
                prepare fb-off;        patch_fb_off fb-off;        run fb-off
                prepare fb-off-no-fpu; patch_fb_off fb-off-no-fpu; patch_no_fpu fb-off-no-fpu; run fb-off-no-fpu ;;
*)              sed -n '2,20p' "$0"; exit 2 ;;
esac
