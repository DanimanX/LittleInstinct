# Timing constraints for the Pocket build.
#
# Adapted from upstream KillerInstinct.sdc, which was written for MiSTer's
# hierarchy (emu|pll|...) and its SDRAM_* ports. Here the core sits at
# ic|iki|u_core and its SDR SDRAM pins leave the device as dram_*.
#
# The reasoning in upstream's file applies unchanged and is not repeated; what
# matters is which constraints are load-bearing:
#
#   * clk_cpu (PLL out 1, 100 MHz) and clk_core (out 0, 50 MHz) are RELATED at a
#     2:1 ratio on purpose. The CPU-to-bridge crossing runs unsynchronised under
#     SYNC_CROSSING and MUST be timed. Do not make them asynchronous.
#   * clk_cpu is asynchronous to the SDRAM pin clock (out 3); declare that, or
#     every unrelated path across them is timed as if it had to meet 10 ns.
#   * clk_core -> clk_sdram_ctl (out 4) is a 2-clock window (upstream line 116).
#   * the SDRAM capture clock (out 5) gets 2 clocks from KI_SDRAM_CLK.

derive_pll_clocks
derive_clock_uncertainty

# Clock names are written out in full. Do NOT factor the common prefix into a
# Tcl variable and use it inside {...}: braces suppress substitution, the
# collections come back empty, and Quartus ignores the constraint with only a
# warning (this cost a build cycle - the slack did not move a thousandth).

# ---- CPU asynchronous to the SDRAM pin clock ---------------------------------
set_clock_groups -asynchronous \
  -group [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]

# ---- the SDRAM clock as it leaves the device --------------------------------
create_generated_clock -name KI_SDRAM_CLK \
  -source [get_pins -compatibility_mode {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  [get_ports {dram_clk}]

set_clock_groups -asynchronous \
  -group [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {KI_SDRAM_CLK}]

# ---- SDRAM board timing -----------------------------------------------------
# Same numbers upstream uses: the Pocket's DRAM part is a 512 Mbit x16 like
# MiSTer's, at the same 100 MHz.
set_input_delay  -clock KI_SDRAM_CLK -max 6.0 [get_ports {dram_dq[*]}]
set_input_delay  -clock KI_SDRAM_CLK -min 2.5 [get_ports {dram_dq[*]}]
set_output_delay -clock KI_SDRAM_CLK -max 1.5 \
  [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_cke dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock KI_SDRAM_CLK -min -0.8 \
  [get_ports {dram_a[*] dram_ba[*] dram_dqm[*] dram_cke dram_ras_n dram_cas_n dram_we_n}]

# ---- the CPU's fast-fill port into the SDRAM controller --------------------
# ki_sdram_burst's header says these inputs "come from the CPU's clock and have
# two controller clocks to settle". On MiSTer that needed no constraint of its
# own because Quartus MERGES clk_cpu (out 1) and clk_ddr (out 2), which are
# configured identically, so the general[0]->general[4] multicycle below covered
# it. Here they do not merge: out 0 is 50 MHz and out 1 is 100 MHz, so the
# fast_line_r / fast_tog path is a genuine clk_cpu -> clk_sdram_ctl crossing and
# must be given its own window or it fails by ~9 ns (measured).
set_multicycle_path -setup -end \
  -from [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold -end \
  -from [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 1

# ---- two-clock windows between the core and the SDRAM controller ------------
set_multicycle_path -setup -end \
  -from [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -hold -end \
  -from [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 1

set_multicycle_path -setup -end \
  -rise_from [get_clocks {KI_SDRAM_CLK}] \
  -rise_to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[5].gpll~PLL_OUTPUT_COUNTER|divclk}] 2
set_multicycle_path -setup -end \
  -rise_from [get_clocks {KI_SDRAM_CLK}] \
  -rise_to   [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk}] 2

# ---- debug observability registers, crossed without a synchroniser ----------
set_false_path -to [get_keepers {*|debug_cpu_pc_meta[*]}]
set_false_path -to [get_keepers {*|debug_cpu_retired_meta[*]}]
set_false_path -to [get_keepers {*|debug_trace_frozen_meta}]
set_false_path -to [get_keepers {*|debug_trace_shadow[*]}]
