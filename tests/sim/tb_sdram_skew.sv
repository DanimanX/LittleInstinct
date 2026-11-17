// Does a request survive the clk -> clk2x multicycle race?
//
// pocket_rtl/pocket_ki.sdc gives the clk_sys(counter 0) -> clk_sdram_ctl
// (counter 2) paths a multicycle of 2: they are only guaranteed at the SECOND
// clk2x edge after the clk edge that launched them. The first clk2x edge lands
// 0.556 ns after launch and samples each bit OLD or NEW depending on its route.
//
// Before V183, ki_sdram_x2 passed req_rd/req_we straight out to
// ki_sdram_burst (edge-detected there via old_rd) and to its own rd_d, and
// ki_fast_fill passed req_tog straight out. So on that first edge the strobe
// could be NEW while addr/burst were still OLD - and the two consumers could
// disagree with each other.
//
// This bench models that physically: the request FIELDS travel through a
// transport delay (`+skew=` ps), the STROBE through its own (`+strobe=` ps).
// A skew between ~600 ps and 9.9 ns puts the fields past the first clk2x edge
// and inside the second, which is exactly the window the SDC leaves open.
//
// It instantiates ki_sdram_x2 + ki_sdram_burst + the SDRAM model directly, so
// the adapter's own registers are replaced by bench registers - they are the
// same registers in the same clock domain, holding until the next launch, and
// that is the whole point: the fields are stable and only their ARRIVAL at x2
// is delayed.
//
// Checks, per request:
//   ADDRESS  the burst controller captured the address we asked for
//   TYPE     it ran the read we asked for, not a write (a strobe race between
//            rd and we is the nastiest form of this)
//   BEATS    every word came back, and x2 has none left owed
//
// Plusargs: +phase= (clk2x offset, ps), +skew= (field delay, ps),
//           +strobe= (strobe delay, ps), +burst= (words), +n= (requests),
//           +addrstep= (address delta between requests, in 16-bit words).
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_skew;
	integer PHASE_V, SKEW_V, STROBE_V, BURST_V, N_V, STEP_V, DBG_V;
	real    phase_ns, skew_ns, strobe_ns;

	reg clk50 = 0, clk100 = 0;
	always #10.0 clk50 = ~clk50;
	initial begin
		PHASE_V  = 556;
		SKEW_V   = 0;
		STROBE_V = 0;
		BURST_V  = 16;
		N_V      = 3;
		STEP_V   = 32;
		DBG_V    = 0;
		void'($value$plusargs("phase=%d",   PHASE_V));
		void'($value$plusargs("dbg=%d",     DBG_V));
		void'($value$plusargs("skew=%d",    SKEW_V));
		void'($value$plusargs("strobe=%d",  STROBE_V));
		void'($value$plusargs("burst=%d",   BURST_V));
		void'($value$plusargs("n=%d",       N_V));
		void'($value$plusargs("addrstep=%d", STEP_V));
		phase_ns  = PHASE_V / 1000.0;
		skew_ns   = SKEW_V / 1000.0;
		strobe_ns = STROBE_V / 1000.0;
		// Alignment matters. clk50 transitions on multiples of 10 ns, so its
		// POSEDGES are at 10, 30, 50 ... For clk2x's posedge to land
		// `phase` after a clk posedge it must be on the grid 10.556 + k*10,
		// which means the first toggle is at phase + 10 ns, not at phase.
		// (Getting this wrong puts the first clk2x edge 5.556 ns after the clk
		// edge instead of 0.556 and the whole race window disappears.)
		clk100 = 0;
		#(phase_ns + 10.0);
		forever #5.0 clk100 = ~clk100;
	end

	reg reset = 1;

	// ---------------------------------------------------- bench "adapter" side
	// These stand in for ki_sdram_adapter's issue_* registers: written on clk,
	// stable across the launch, and read by x2 on clk2x.
	reg  [24:0] a_addr = 25'd0;
	reg   [4:0] a_burst = 5'd1;
	reg         a_rd = 1'b0;
	reg         a_we = 1'b0;

	// THE MODEL. Modelled as the SDC CONTRACT, not as a delay number, because
	// the contract is the thing that is true: "multicycle setup 2" means the
	// destination is only GUARANTEED to see the launching edge's value at the
	// SECOND clk2x edge. So a field may be one clk2x edge late, and that is
	// exactly what `+skew=1` builds: the fields as seen by x2 are the clk2x
	// register of the clk-domain value - old on the first edge after launch,
	// new from the second on. `+skew=0` is the ideal zero-delay case.
	//
	// The STROBE is separately selectable (`+strobe=1`), because that is the
	// asymmetry that made the bug: before V183 the strobe went straight
	// through to ki_sdram_burst while the fields could still be old.
	reg  [24:0] f_addr  = 25'd0;
	reg   [4:0] f_burst = 5'd1;
	reg         f_rd    = 1'b0;
	reg         f_we    = 1'b0;

	always @(posedge clk100) begin
		f_addr  <= a_addr;
		f_burst <= a_burst;
		f_rd    <= a_rd;
		f_we    <= a_we;
	end

	wire [24:0] x2_addr  = (SKEW_V   != 0) ? f_addr  : a_addr;
	wire  [4:0] x2_burst = (SKEW_V   != 0) ? f_burst : a_burst;
	wire        x2_rd    = (STROBE_V != 0) ? f_rd    : a_rd;
	wire        x2_we    = (STROBE_V != 0) ? f_we    : a_we;

	wire [31:0] x2_dout;
	wire  [1:0] x2_be;
	wire        x2_valid, x2_ready;
	wire  [7:0] x2_status;

	wire [24:0] ctl_addr; wire [255:0] ctl_din; wire [31:0] ctl_be;
	wire  [4:0] ctl_burst; wire ctl_rd, ctl_we; wire [15:0] ctl_dout;
	wire ctl_dvalid, ctl_ready;

	ki_sdram_x2 pack (
		.clk(clk50), .clk2x(clk100), .init(reset),
		.req_addr(x2_addr), .req_din(256'd0), .req_wtbt(32'hffff_ffff),
		.req_burst(x2_burst), .req_rd(x2_rd), .req_we(x2_we),
		.req_dout(x2_dout), .req_dout_be(x2_be),
		.req_dout_valid(x2_valid), .req_ready(x2_ready),
		.ctl_addr(ctl_addr), .ctl_din(ctl_din), .ctl_wtbt(ctl_be),
		.ctl_burst(ctl_burst), .ctl_rd(ctl_rd), .ctl_we(ctl_we),
		.ctl_dout(ctl_dout), .ctl_dout_valid(ctl_dvalid),
		.ctl_ready(ctl_ready), .debug_status(x2_status)
	);

	wire [15:0] DQ; wire [12:0] A; wire [1:0] BA, DQM;
	wire CKE, nRAS, nCAS, nWE, nCS;

	ki_sdram_burst #(
		.T_RP(4'd2), .T_RCD(4'd2), .T_RAS(5'd5), .T_RC(5'd7),
		.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
		.STARTUP_CYCLES(15'd400), .REFRESH_PERIOD(13'd730)
	) ctl (
		.init(reset), .clk(clk100), .clk_cap(clk100),
		.SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQM[0]), .SDRAM_DQMH(DQM[1]),
		.SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
		.SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE),
		.wtbt(ctl_be), .addr(ctl_addr), .burst(ctl_burst), .dout(ctl_dout),
		.dout_valid(ctl_dvalid), .din(ctl_din), .we(ctl_we), .rd(ctl_rd),
		.ready(ctl_ready), .fast_tog(1'b0), .fast_addr(25'd0),
		.fast_valid()
	);

	sdram_model #(.READ_LATENCY(3)) chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	// ---------------------------------------------------------------- monitors
	// What the CONTROLLER actually captured, at its own new_rd/new_we edge.
	reg [24:0] cap_addr = 25'd0;
	reg        cap_we   = 1'b0;
	reg        cap_hit  = 1'b0;
	reg        cap_rd_d = 1'b0, cap_we_d = 1'b0;
	reg [24:0] exp_addr = 25'd0;

	integer beats = 0, cyc = 0;
	always @(posedge clk50) cyc = cyc + 1;
	always @(posedge clk50) if (x2_valid) beats = beats + 1;

	integer errors = 0;

	always @(posedge clk100) begin
		cap_rd_d <= ctl_rd;
		cap_we_d <= ctl_we;
		if ((ctl_rd && !cap_rd_d) || (ctl_we && !cap_we_d)) begin
			cap_addr <= ctl_addr;
			cap_we   <= ctl_we && !cap_we_d;
			cap_hit  <= 1'b1;
			if (DBG_V != 0)
				$display("    capture@%0t: ctl_addr=%0d ctl_burst=%0d we=%b (x2_addr=%0d x2_burst=%0d)",
				         $time, ctl_addr, ctl_burst, ctl_we, x2_addr, x2_burst);
		end
	end

	integer reqno = 0;
	integer t_issue = 0;
	integer i, dropped, risen;

	initial begin
		reset = 1;
		repeat (4) @(posedge clk50);
		reset = 0;
		wait (x2_ready === 1'b1);
		repeat (2) @(posedge clk50);

		for (reqno = 0; reqno < N_V; reqno = reqno + 1) begin
			// Launch: the adapter's registers all update on the SAME clk edge -
			// that simultaneity is the whole premise of the race. Only their
			// arrival at x2 differs, which is `skew` vs `strobe`.
			@(posedge clk50);
			a_addr  <= reqno * STEP_V;
			a_burst <= BURST_V[4:0];
			a_rd    <= 1'b1;
			exp_addr = reqno * STEP_V;
			cap_hit  = 1'b0;
			beats    = 0;
			t_issue  = cyc;
			@(posedge clk50);
			a_rd    <= 1'b0;

			// Was the request taken at all? `ready` must fall.
			dropped = 0;
			for (i = 0; i < 200; i = i + 1) begin
				@(posedge clk50);
				if (x2_ready !== 1'b1) begin dropped = 1; i = 200; end
			end
			// Then it must come back.
			risen = 0;
			for (i = 0; i < 3000; i = i + 1) begin
				@(posedge clk50);
				if (x2_ready === 1'b1) begin risen = 1; i = 3000; end
			end
			if (!dropped) begin
				$display("req%0d: NEVER STARTED - ready never fell; the request was LOST", reqno);
				errors = errors + 1;
			end else if (!risen) begin
				$display("req%0d: TIMEOUT - never completed; cap_hit=%b cap_addr=%0d beats=%0d wl=%0d",
				         reqno, cap_hit, cap_addr, beats, pack.words_left);
				errors = errors + 1;
			end else if (cap_hit !== 1'b1) begin
				$display("req%0d: NOTHING CAPTURED - the request never reached the controller", reqno);
				errors = errors + 1;
			end else begin
				if (cap_we !== 1'b0) begin
					$display("req%0d: WRONG TYPE - controller ran a WRITE, expected addr %0d, got %0d",
					         reqno, exp_addr, cap_addr);
					errors = errors + 1;
				end
				if (cap_addr !== exp_addr) begin
					$display("req%0d: WRONG ADDRESS - expected %0d, controller captured %0d",
					         reqno, exp_addr, cap_addr);
					errors = errors + 1;
				end
				// `beats` is x2_valid sampled on clk50 and is only printed: a
				// beat is held for two clk2x cycles, so an exact count needs the
				// same edge discipline the DUT uses. The authoritative accounting
				// is x2's own words_left below - it reaches 0 only if every word
				// of the burst came back.
				if (pack.words_left != 5'd0) begin
					$display("req%0d: x2 STILL OWES %0d words at ready", reqno, pack.words_left);
					errors = errors + 1;
				end
			end
		end

		if (errors == 0) $display("PASS  phase=%0d skew=%0d strobe=%0d burst=%0d n=%0d (beats seen %0d/req)",
		                          PHASE_V, SKEW_V, STROBE_V, BURST_V, N_V, beats);
		else $display("FAIL  phase=%0d skew=%0d strobe=%0d burst=%0d n=%0d errors=%0d",
		               PHASE_V, SKEW_V, STROBE_V, BURST_V, N_V, errors);
		$finish;
	end
endmodule
