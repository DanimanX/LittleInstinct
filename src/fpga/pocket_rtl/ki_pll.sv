// ki_pll: the clocks the Killer Instinct core needs, from the Pocket's 74.25 MHz
// reference (clk_74a).
//
//   outclk_0  clk_core   50.00 MHz   the MiSTer core's clk_core (video, I/O, bridge)
//   outclk_1  clk_mem   100.00 MHz   the core's clk_cpu / SDRAM controller clock
//   outclk_2  clk_pix     6.25 MHz   APF pixel clock; 50 MHz / 8, the core's ce_pixel
//   outclk_3  clk_pix_90  6.25 MHz   the same, 40 ns later (APF's DDR video clock)
//
// Numbers, all integer, so no fractional divider is involved:
//   f_vco = 74.25 MHz * M / N = 74.25 * 400 / 33 = 900.000 MHz   (600..1300 MHz, legal)
//   clk_core = 900 / 18, clk_mem = 900 / 9, clk_pix = 900 / 144
//
// Verified in Quartus 25.1 Lite for 5CEBA4F23C8: the fitter reports
// "PLL VCO Frequency 900.0 MHz", "Output Clock Frequency 50.0 MHz / 100.0 MHz".
// M is given as m_cnt_hi_div + m_cnt_lo_div = 200 + 200, N as 17 + 16 with the
// odd-divider duty-cycle correction on - that split is what makes Quartus read
// them as 400 and 33 rather than doubling N to 66 (which silently halves every
// output: an earlier attempt with n_cnt 33/33 produced a 450 MHz VCO, out of
// spec, and 25/50 MHz outputs).
`default_nettype none

module ki_pll (
	input  wire refclk,          // clk_74a, 74.25 MHz
	input  wire rst,
	output wire clk_core,        //  50.00 MHz
	output wire clk_mem,         // 100.00 MHz
	output wire clk_pix,         //   6.25 MHz
	output wire clk_pix_90,      //   6.25 MHz, +90 degrees
	output wire locked
);
	wire [3:0] outclk;

	assign clk_core   = outclk[0];
	assign clk_mem    = outclk[1];
	assign clk_pix    = outclk[2];
	assign clk_pix_90 = outclk[3];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("50.0 MHz"),   .phase_shift0("0 ps"),    .duty_cycle0(50),
		.output_clock_frequency1("100.0 MHz"),  .phase_shift1("0 ps"),    .duty_cycle1(50),
		.output_clock_frequency2("6.25 MHz"),   .phase_shift2("0 ps"),    .duty_cycle2(50),
		.output_clock_frequency3("6.25 MHz"),   .phase_shift3("40000 ps"), .duty_cycle3(50),
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(200), .m_cnt_lo_div(200),
		.n_cnt_hi_div(17),  .n_cnt_lo_div(16),
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("false"),
		.m_cnt_odd_div_duty_en("false"), .n_cnt_odd_div_duty_en("true"),
		.c_cnt_hi_div0(9),  .c_cnt_lo_div0(9),  .c_cnt_prst0(1), .c_cnt_ph_mux_prst0(0),
		.c_cnt_in_src0("ph_mux_clk"), .c_cnt_bypass_en0("false"), .c_cnt_odd_div_duty_en0("false"),
		.c_cnt_hi_div1(5),  .c_cnt_lo_div1(4),  .c_cnt_prst1(1), .c_cnt_ph_mux_prst1(0),
		.c_cnt_in_src1("ph_mux_clk"), .c_cnt_bypass_en1("false"), .c_cnt_odd_div_duty_en1("true"),
		.c_cnt_hi_div2(72), .c_cnt_lo_div2(72), .c_cnt_prst2(1), .c_cnt_ph_mux_prst2(0),
		.c_cnt_in_src2("ph_mux_clk"), .c_cnt_bypass_en2("false"), .c_cnt_odd_div_duty_en2("false"),
		.c_cnt_hi_div3(72), .c_cnt_lo_div3(72), .c_cnt_prst3(1), .c_cnt_ph_mux_prst3(0),
		.c_cnt_in_src3("ph_mux_clk"), .c_cnt_bypass_en3("false"), .c_cnt_odd_div_duty_en3("false"),
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
