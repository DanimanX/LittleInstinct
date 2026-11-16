# Timing constraints for the Pocket build.
#
# Every clock comes from ONE PLL (pocket_rtl/ki_pll.sv) on clk_74a:
#
#   counter[0]  clk_sys         50 MHz   0        CPU, bridge, video, I/O, DCS
#   counter[1]  clk_sdram_pin  100 MHz   6806 ps  -> dram_clk (KI_SDRAM_CLK)
#   counter[2]  clk_sdram_ctl  100 MHz    556 ps  ki_sdram_burst
#   counter[3]  clk_sdram_cap  100 MHz   1389 ps  captures dram_dq
#   counter[4]  clk_pix        6.25 MHz  0        APF pixel clock
#   counter[5]  clk_pix_90     6.25 MHz  40 ns    APF pixel clock + 90 degrees
#
# They are all RELATED, and nothing below says otherwise: the only clocks cut
# from them are the APF bridge's (clk_74a, clk_74b, bridge_spiclk), whose
# crossings go through a dual-clock FIFO or two-flop synchronisers in pk_io
# and core_bridge_cmd.
#
# The earlier two-PLL build declared the CPU clock and then the SDRAM pin clock
# asynchronous to the rest. That removed the SDRAM interface and the whole
# CPU <-> bridge boundary from timing analysis; the build "met timing" and
# failed the SDRAM self-test on hardware. Do not add clock groups inside the
# PLL to make a failing path go away.
#
# Clock names are written out in full. Do NOT factor the common prefix into a
# Tcl variable and use it inside {...}: braces suppress substitution, the
# collection comes back empty, and Quartus ignores the constraint with only a
# warning.

derive_pll_clocks
derive_clock_uncertainty

# ---- the SDRAM clock as it leaves the device --------------------------------
create_generated_clock -name KI_SDRAM_CLK \
  -source [get_pins -compatibility_mode {ic|iki|u_pll|pll_i|cyclonev_pll|counter[1].output_counter|divclk}] \
  [get_ports {dram_clk}]

# ---- the APF bridge is asynchronous to the core ------------------------------
set_clock_groups -asynchronous \
  -group [get_clocks {clk_74a clk_74b bridge_spiclk}] \
  -group [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[0].output_counter|divclk \
                      ic|iki|u_pll|pll_i|cyclonev_pll|counter[1].output_counter|divclk \
                      ic|iki|u_pll|pll_i|cyclonev_pll|counter[2].output_counter|divclk \
                      ic|iki|u_pll|pll_i|cyclonev_pll|counter[3].output_counter|divclk \
                      ic|iki|u_pll|pll_i|cyclonev_pll|counter[4].output_counter|divclk \
                      ic|iki|u_pll|pll_i|cyclonev_pll|counter[5].output_counter|divclk \
                      KI_SDRAM_CLK}]

# ---- asynchronous reset -------------------------------------------------------
set_false_path -from [get_keepers {*rst_sync[*]}]

# ---- SDRAM board timing -------------------------------------------------------
# Upstream's numbers: the Pocket's DRAM is a 512 Mbit x16 part at 100 MHz, as
# MiSTer's is.
set_input_delay  -clock KI_SDRAM_CLK -max 6.0 [get_ports {dram_dq[*]}]
set_input_delay  -clock KI_SDRAM_CLK -min 2.5 [get_ports {dram_dq[*]}]
set_output_delay -clock KI_SDRAM_CLK -max 1.5 \
  [get_ports {dram_a[*] dram_ba[*] dram_dq[*] dram_dqm[*] dram_cke dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -clock KI_SDRAM_CLK -min -0.8 \
  [get_ports {dram_a[*] dram_ba[*] dram_dq[*] dram_dqm[*] dram_cke dram_ras_n dram_cas_n dram_we_n}]

# ---- two-clock windows between the core and the SDRAM controller --------------
# clk_sys -> clk_sdram_ctl: the request is held for a whole clk_sys period.
set_multicycle_path -setup -end \
  -from [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
  -to   [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[2].output_counter|divclk}] 2
set_multicycle_path -hold -end \
  -from [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[0].output_counter|divclk}] \
  -to   [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[2].output_counter|divclk}] 1

# dram_dq is sampled on the capture clock edge after the one nearest the
# launching SDRAM clock edge (CAS latency accounting in ki_sdram_burst).
set_multicycle_path -setup -end \
  -rise_from [get_clocks {KI_SDRAM_CLK}] \
  -rise_to   [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[3].output_counter|divclk}] 2
set_multicycle_path -setup -end \
  -rise_from [get_clocks {KI_SDRAM_CLK}] \
  -rise_to   [get_clocks {ic|iki|u_pll|pll_i|cyclonev_pll|counter[2].output_counter|divclk}] 2

# ---- debug observability registers, sampled without a synchroniser ------------
set_false_path -to [get_keepers {*|debug_cpu_pc_meta[*]}]
set_false_path -to [get_keepers {*|debug_cpu_retired_meta[*]}]
set_false_path -to [get_keepers {*|debug_trace_frozen_meta}]
set_false_path -to [get_keepers {*|debug_trace_shadow[*]}]
set_false_path -to [get_keepers {*|debug_dep_valid_meta}]
set_false_path -to [get_keepers {*|debug_dep_pc_hold[*]}]
set_false_path -to [get_keepers {*|debug_dep_op_hold[*]}]
set_false_path -to [get_keepers {*|debug_dep_trig_hold[*]}]
set_false_path -to [get_keepers {*|debug_dep_cause_hold[*]}]
