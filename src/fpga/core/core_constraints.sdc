# Killer Instinct Pocket: core-side timing constraints.
#
# Loaded by apf/apf_constraints.sdc (APF's, unmodified) after it creates the
# 74.25 MHz clocks and derives the PLL clocks.

# The 74.25 MHz bridge domain and everything the core makes from it are
# asynchronous to each other in the sense that matters for setup analysis of
# the crossings we wrote by hand (two-flop synchronisers only).
set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a clk_74b}]

# Video out is the pixel clock; apf_top samples it with the DDR converters.
# Nothing to constrain beyond the clock itself, which derive_pll_clocks makes.
