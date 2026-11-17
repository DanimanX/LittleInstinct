// The same clk -> clk2x multicycle race on the DIRECT FILL port.
//
// ki_fast_fill maps the CPU's request to a controller address and a toggle.
// Before V183 it passed req_tog straight to ki_sdram_burst while ctl_addr came
// from req_line combinatationally - so on the clk_ctl edge 0.5 ns after launch
// the toggle could be new while the ADDRESS was still the previous line's.
// The failure is silent: the right number of words comes back, from the WRONG
// line.
//
// `+skew=1` models the SDC contract (the mapped fields are one clk_ctl edge
// late), `+skew=0` the ideal case. Checked: the controller's fast port must
// capture the line we asked for.
`timescale 1ns/1ps
`default_nettype none

module tb_fast_skew;
	integer SKEW_V, N_V, DBG_V, PHASE_V;
	real phase_ns;
	reg clk50 = 0, clk100 = 0;
	always #10.0 clk50 = ~clk50;
	initial begin
		PHASE_V = 556; SKEW_V = 1; N_V = 3; DBG_V = 0;
		void'($value$plusargs("phase=%d", PHASE_V));
		void'($value$plusargs("skew=%d",  SKEW_V));
		void'($value$plusargs("n=%d",     N_V));
		void'($value$plusargs("dbg=%d",   DBG_V));
		phase_ns = PHASE_V / 1000.0;
		clk100 = 0;
		#(phase_ns + 10.0);
		forever #5.0 clk100 = ~clk100;
	end

	reg reset = 1;

	// The CPU side: a held line address and a toggle, exactly as cpu.vhd drives
	// them. Address is a byte address; bit 0 selects qword (4 words) vs the
	// whole 16-word line.
	reg  [31:0] req_line = 32'd0;
	reg         req_tog  = 1'b0;

	// SDC model: the mapped fields (storage address) are one clk_ctl edge late
	// - which is the same statement as multicycle setup 2 on clk -> clk_ctl.
	reg  [31:0] f_line = 32'd0;
	always @(posedge clk100) f_line <= req_line;
	wire [31:0] line_seen = (SKEW_V != 0) ? f_line : req_line;

	wire        ctl_tog, fast_valid;
	wire [24:0] ctl_addr;

	wire [7:0] fb_unused;
	ki_fast_fill fast (
		.clk(clk50), .clk_ctl(clk100),
		.req_tog(req_tog), .req_line(line_seen),
		.ctl_tog(ctl_tog), .ctl_addr(ctl_addr),
		.word(16'd0), .word_valid(1'b0),
		.window(), .beat(), .first(), .qword(), .done_tog()
	);

	wire [15:0] DQ; wire [12:0] A; wire [1:0] BA, DQM;
	wire CKE, nRAS, nCAS, nWE, nCS;
	wire [15:0] ctl_dout; wire ctl_dvalid, ctl_ready;

	ki_sdram_burst #(
		.T_RP(4'd2), .T_RCD(4'd2), .T_RAS(5'd5), .T_RC(5'd7),
		.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
		.STARTUP_CYCLES(15'd400), .REFRESH_PERIOD(13'd730)
	) ctl (
		.init(reset), .clk(clk100), .clk_cap(clk100),
		.SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQM[0]), .SDRAM_DQMH(DQM[1]),
		.SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
		.SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE),
		.wtbt(32'hffff_ffff), .addr(25'd0), .burst(5'd16), .dout(ctl_dout),
		.dout_valid(ctl_dvalid), .din(256'd0), .we(1'b0), .rd(1'b0),
		.ready(ctl_ready),
		.fast_tog(ctl_tog), .fast_addr(ctl_addr), .fast_valid(fast_valid)
	);

	sdram_model #(.READ_LATENCY(3)) chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	// What the controller's fast port captured, on its own fast_take edge.
	reg [24:0] cap = 25'd0;
	reg        cap_hit = 1'b0;
	reg        tog_d = 1'b0;
	always @(posedge clk100) begin
		tog_d <= ctl_tog;
		if (ctl_tog != tog_d) begin
			cap <= ctl.fast_addr;        // the address it will issue from
			cap_hit <= 1'b1;
			if (DBG_V != 0) $display("    fast capture: ctl_addr=%0d", ctl_addr);
		end
	end

	integer i, n = 0, errors = 0;
	reg [24:0] exp;

	initial begin
		reset = 1;
		repeat (4) @(posedge clk50);
		reset = 0;
		wait (ctl_ready === 1'b1);
		repeat (4) @(posedge clk50);

		for (i = 0; i < N_V; i = i + 1) begin
			// Every request is a qword read (bit 0 set) at a different line.
			@(posedge clk50);
			req_line <= (i + 1) * 32;
			req_tog  <= ~req_tog;
			cap_hit  <= 1'b0;
			exp       = (i + 1) * 32;
			repeat (400) @(posedge clk50);
			if (cap_hit !== 1'b1) begin
				$display("req%0d: the direct port never started", i);
				errors = errors + 1;
			end else if (cap !== exp[24:0]) begin
				$display("req%0d: WRONG LINE - asked for %0d, controller latched %0d",
				         i, exp, cap);
				errors = errors + 1;
			end
		end
		if (errors == 0) $display("PASS  skew=%0d", SKEW_V);
		else $display("FAIL  skew=%0d errors=%0d", SKEW_V, errors);
		$finish;
	end
endmodule
