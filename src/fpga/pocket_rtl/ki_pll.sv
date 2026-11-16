// ki_pll: every clock of the Pocket build, from ONE PLL on clk_74a.
//
// The first port had two PLLs in cascade (74.25 -> 50 MHz here, then 50 MHz ->
// the core's clocks inside upstream's rtl/pll). Cascading costs jitter on the
// 100 MHz SDRAM clocks, puts the APF pixel clock and the core's pixel enable on
// unrelated phases, and makes Quartus see every core clock as a child of an
// APF clock - which is how the SDC ended up declaring the SDRAM pin clock
// asynchronous to its own controller. One PLL removes all three.
//
//   out  wire            freq        phase    purpose
//   0    clk_sys          50.00 MHz  0        CPU, bridge, video, I/O, DCS
//   1    clk_sdram_pin   100.00 MHz  6806 ps  leaves the chip as dram_clk
//   2    clk_sdram_ctl   100.00 MHz   556 ps  ki_sdram_burst's logic
//   3    clk_sdram_cap   100.00 MHz  1389 ps  captures dram_dq
//   4    clk_pix           6.25 MHz  0        APF pixel clock (clk_sys / 8)
//   5    clk_pix_90        6.25 MHz  40 ns    APF pixel clock, +90 degrees
//
// f_vco = 74.25 MHz * 400 / 33 = 900.000 MHz, all dividers integer:
//   50 = 900/18, 100 = 900/9, 6.25 = 900/144.
//
// PHASES. A counter starts (prst-1) VCO periods late plus ph_mux eighths of a
// VCO period: at 900 MHz that is 1111.1 ps and 138.9 ps. The three SDRAM
// phases are upstream's 6750 / 500 / 1500 ps (rtl/pll/pll_0002.v explains where
// those come from; a hardware run of the two-PLL build passed the SDRAM
// self-test with them) put on this grid:
//   pin - ctl = 6250 ps   (upstream 6250 ps, exact)
//   cap - pin = 4583 ps   (upstream 4750 ps)
// The capture phase is the one number here chosen from this build's own timing
// report rather than copied. With the SDRAM pin clock finally a related clock,
// the Timing Analyzer times dram_dq -> dq_cap. That is a pin to an I/O
// register, so the fitter cannot fix it; the phase is the only knob. Measured
// worst slack over the four corners (setup / hold):
//   1528 ps   +0.31 / -0.01
//   1667 ps   +0.31 / -0.07      (later is worse for hold)
//   1389 ps   +0.39 / +0.05      (in use)
// The whole eye is only ~0.3 ns wide against upstream's board numbers
// (6.0 ns max / 2.5 ns min input delay), so re-check both slacks whenever the
// pin clock phase or the SDRAM pin assignments change.
// The first port's clk_pix_90 was configured with prst = 1 and came out at 0
// degrees (the fitter report says so); it is 90 degrees here.
//
// The counters are given physically because the frequency strings alone let
// Quartus pick N = 66 and halve everything, as the first port found out.
// tools/check_fit.py verifies the fitter's PLL summary against this table after
// every build.
`default_nettype none

module ki_pll (
	input  wire refclk,          // clk_74a, 74.25 MHz
	input  wire rst,
	output wire clk_sys,
	output wire clk_sdram_pin,
	output wire clk_sdram_ctl,
	output wire clk_sdram_cap,
	output wire clk_pix,
	output wire clk_pix_90,
	output wire locked
);
	wire [5:0] outclk;

	assign clk_sys       = outclk[0];
	assign clk_sdram_pin = outclk[1];
	assign clk_sdram_ctl = outclk[2];
	assign clk_sdram_cap = outclk[3];
	assign clk_pix       = outclk[4];
	assign clk_pix_90    = outclk[5];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(6),
		.output_clock_frequency0("50.0 MHz"),   .phase_shift0("0 ps"),     .duty_cycle0(50),
		.output_clock_frequency1("100.0 MHz"),  .phase_shift1("6806 ps"),  .duty_cycle1(50),
		.output_clock_frequency2("100.0 MHz"),  .phase_shift2("556 ps"),   .duty_cycle2(50),
		.output_clock_frequency3("100.0 MHz"),  .phase_shift3("1389 ps"),  .duty_cycle3(50),
		.output_clock_frequency4("6.25 MHz"),   .phase_shift4("0 ps"),     .duty_cycle4(50),
		.output_clock_frequency5("6.25 MHz"),   .phase_shift5("40000 ps"), .duty_cycle5(50),
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(200), .m_cnt_lo_div(200),
		.n_cnt_hi_div(17),  .n_cnt_lo_div(16),
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("false"),
		.m_cnt_odd_div_duty_en("false"), .n_cnt_odd_div_duty_en("true"),
		// 0: /18, phase 0
		.c_cnt_hi_div0(9),  .c_cnt_lo_div0(9),  .c_cnt_prst0(1),  .c_cnt_ph_mux_prst0(0),
		.c_cnt_in_src0("ph_mux_clk"), .c_cnt_bypass_en0("false"), .c_cnt_odd_div_duty_en0("false"),
		// 1: /9, 6 VCO periods + 1/8 = 6805.6 ps
		.c_cnt_hi_div1(5),  .c_cnt_lo_div1(4),  .c_cnt_prst1(7),  .c_cnt_ph_mux_prst1(1),
		.c_cnt_in_src1("ph_mux_clk"), .c_cnt_bypass_en1("false"), .c_cnt_odd_div_duty_en1("true"),
		// 2: /9, 4/8 VCO period = 555.6 ps
		.c_cnt_hi_div2(5),  .c_cnt_lo_div2(4),  .c_cnt_prst2(1),  .c_cnt_ph_mux_prst2(4),
		.c_cnt_in_src2("ph_mux_clk"), .c_cnt_bypass_en2("false"), .c_cnt_odd_div_duty_en2("true"),
		// 3: /9, 1 VCO period + 2/8 = 1388.9 ps
		.c_cnt_hi_div3(5),  .c_cnt_lo_div3(4),  .c_cnt_prst3(2),  .c_cnt_ph_mux_prst3(2),
		.c_cnt_in_src3("ph_mux_clk"), .c_cnt_bypass_en3("false"), .c_cnt_odd_div_duty_en3("true"),
		// 4: /144, phase 0
		.c_cnt_hi_div4(72), .c_cnt_lo_div4(72), .c_cnt_prst4(1),  .c_cnt_ph_mux_prst4(0),
		.c_cnt_in_src4("ph_mux_clk"), .c_cnt_bypass_en4("false"), .c_cnt_odd_div_duty_en4("false"),
		// 5: /144, 36 VCO periods = 40.000 ns = 90 degrees
		.c_cnt_hi_div5(72), .c_cnt_lo_div5(72), .c_cnt_prst5(37), .c_cnt_ph_mux_prst5(0),
		.c_cnt_in_src5("ph_mux_clk"), .c_cnt_bypass_en5("false"), .c_cnt_odd_div_duty_en5("false"),
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_output_clk_frequency("900.0 MHz"),
		.mimic_fbclk_type("GCLK"),          // "NONE" is rejected by 25.1 for this PLL
		.pll_fbclk_mux_1("glb"),
		.pll_fbclk_mux_2("m_cnt"),
		.pll_m_cnt_in_src("ph_mux_clk"),
		.pll_slf_rst("true")
	) pll_i (
		.rst               (rst),
		.refclk            (refclk),
		.outclk            (outclk),
		.locked            (locked),
		.reconfig_to_pll   (64'd0),
		.reconfig_from_pll (),
		.fbclk             (1'b0),
		.fboutclk          ()
	);
endmodule

`default_nettype wire
