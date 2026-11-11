# Timing constraints for the Pocket build.
#
# Adapted from upstream KillerInstinct.sdc, which was written for MiSTer's
# hierarchy (emu|pll|...) and its SDRAM_* ports. Here the core sits at
# ic|iki|u_core and its SDR SDRAM pins leave the device as dram_*.
#
# The reasoning in upstream's file applies unchanged and is not repeated; what
# matters is which constraints are load-bearing:
#
#   * clk_core (PLL out 0, 50 MHz) and clk_cpu (out 1, ALSO 50 MHz) are two
#     outputs of one PLL that are NOT phase aligned - out 1 carries a 250 ps
#     offset. Quartus therefore pairs a clk_core launch edge with a clk_cpu
#     latch edge 0.25 ns later and gives every crossing ~12 ns of budget
#     instead of 20, which is how the CPU's response FIFO came to fail setup
#     by -6.5 ns. The crossing is an asynchronous CDC and is declared as one
#     below; the CPU runs it through its two-flop synchronisers
#     (SYNC_CROSSING = 0 in ki_core_pocket.sv). Do not "fix" the phase by
#     making these clocks related again.
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

# ---- CPU clock asynchronous to clk_core -------------------------------------
# Both are 50 MHz, but out 1 is phase-shifted 250 ps from out 0. Treating them
# as related asks for the data to land within that 250 ps window, which no
# register-to-register path can do; the CPU's return FIFO failed by -6.5 ns and
# the boot ROM hung on its first cached read. They cross through synchronisers,
# so they are separate asynchronous groups.
set_clock_groups -asynchronous \
  -group [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
  -group [get_clocks {ic|iki|u_core|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]

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
