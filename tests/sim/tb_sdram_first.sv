// Does the FIRST request after init survive?
//
// The V182 hardware photo showed the very first SDRAM read of a session
// launched by ki_sdram_adapter into ki_sdram_x2 / ki_sdram_burst, and no word
// ever coming back - while the burst controller reported `ready` (idle). That
// is a request lost between the adapter's one-cycle `issue_read` pulse and the
// controller's edge-detected capture.
//
// This bench drives the real adapter + x2 + burst + sdram_model and pulses a
// single 16-word read at a configurable cycle after reset release, then
// requires request_done within a timeout. Sweep parameters are generics so one
// binary covers the whole space:
//
//   (all plusargs; this suite's vvp ignores -P)
//   +phase=    the clk2x offset from clk in ps (the Pocket's PLL gives 500)
//   +arrive=   clk cycles from the adapter reporting ready to the read pulse
//   STARTUP    ki_sdram_burst's STARTUP_CYCLES (12000 in the core)
//   REFRESH    ki_sdram_burst's REFRESH_PERIOD (730 in the core)
//   (both are compile-time parameters: the vvp here ignores -P, so they stay
//   at the core's own values and the runs are faithful)
//   +fast=     0 leaves fast_req_tog silent (the Pocket); 1 toggles it once
//              just after reset, i.e. a stale direct-port request at startup
//
// Exit code: 0 = every arrival completed, 1 = at least one dropped.
`timescale 1ns/1ps
`default_nettype none

module tb_sdram_first;
	parameter integer STARTUP  = 12000;
	parameter integer REFRESH  = 730;
	parameter integer BURST    = 16;
	parameter integer CHUNK    = 2;      // 16-bit words per beat at the adapter
	// 0: pulse ARRIVE clk cycles after the adapter reports ready (the state the
	//    core is in - the bridge only issues once sdram_ready).
	// n: pulse n clk cycles after reset release, i.e. DURING init, which tests
	//    the adapter's level capture of a one-cycle pulse.
	parameter real    T_RP     = 2.0;
	parameter real    T_RCD    = 2.0;
	parameter integer RD_LAT   = 3;

	// The knobs are plusargs, not parameters: this suite's vvp ignores -P, so a
	// parameter sweep would silently run the same case N times.
	integer ARRIVE_V, EARLY_V, FAST_V, PHASE_V, REINIT_V;
	real    phase_ns;

	reg clk50 = 0, clk100 = 0;
	always #10.0 clk50 = ~clk50;
	initial begin
		PHASE_V  = 500;
		ARRIVE_V = 3;
		EARLY_V  = 0;
		FAST_V   = 0;
		REINIT_V = 0;
		void'($value$plusargs("phase=%d",  PHASE_V));
		void'($value$plusargs("reinit=%d", REINIT_V));
		void'($value$plusargs("arrive=%d", ARRIVE_V));
		void'($value$plusargs("early=%d",  EARLY_V));
		void'($value$plusargs("fast=%d",   FAST_V));
		phase_ns = PHASE_V / 1000.0;
		// clk50's POSEDGES are at 10, 30, 50 ns (it toggles every 10 ns), so
		// for clk2x's posedge to sit `phase` after a clk posedge its first
		// toggle must be at phase + 10 ns. Without the +10 the first clk2x
		// edge is 5.556 ns after the clk edge, not 0.556.
		clk100 = 0;
		#(phase_ns + 10.0);
		forever #5.0 clk100 = ~clk100;
	end

	reg reset = 1;

	// Adapter primary port, driven by this bench.
	reg         req_rd = 0;
	reg  [24:0] req_addr = 25'd0;
	reg   [4:0] req_burst = 5'd16;
	wire [31:0] req_dout;
	wire  [1:0] req_be;
	wire        req_valid, req_done, packed_ready;

	wire [15:0] DQ; wire [12:0] A; wire [1:0] BA, DQM;
	wire CKE, nRAS, nCAS, nWE, nCS;

	wire [24:0] ctl_addr; wire [255:0] ctl_din; wire [31:0] ctl_be;
	wire  [4:0] ctl_burst; wire ctl_rd, ctl_we; wire [15:0] ctl_dout;
	wire ctl_dvalid, ctl_ready;
	wire [15:0] adapter_status;
	reg  fast_tog_r;
	wire [31:0] adapter_counts;

	ki_sdram_adapter adapter (
		.clk(clk50), .clk2x(clk100), .reset(reset),
		.request_address(req_addr),
		.request_write_data(256'd0), .request_byte_enable(32'd0),
		.request_burst(req_burst),
		.request_read(req_rd), .request_write(1'b0),
		.request_read_data(req_dout), .request_read_be(req_be),
		.request_data_valid(req_valid), .request_done(req_done),
		.aux_address(25'd0), .aux_write_data(64'd0), .aux_byte_enable(8'd0),
		.aux_burst(5'd0), .aux_read(1'b0), .aux_write(1'b0),
		.aux_read_data(), .aux_read_be(), .aux_data_valid(), .aux_done(),
		.sdram_ready(packed_ready),
		.fast_req_tog(fast_tog_r), .fast_req_line(32'd0),
		.fast_window(), .fast_beat(), .fast_first(), .fast_qword(),
		.fast_done_tog(),
		.controller_address(ctl_addr), .controller_write_data(ctl_din),
		.controller_byte_enable(ctl_be), .controller_burst(ctl_burst),
		.controller_read(ctl_rd), .controller_write(ctl_we),
		.controller_read_data(ctl_dout), .controller_dout_valid(ctl_dvalid),
		.controller_ready(ctl_ready), .controller_fast_tog(),
		.controller_fast_addr(), .controller_fast_valid(),
		.debug_status(adapter_status), .debug_counts(adapter_counts)
	);

	ki_sdram_burst #(
		.T_RP(T_RP), .T_RCD(T_RCD), .T_RAS(5'd5), .T_RC(5'd7),
		.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
		.STARTUP_CYCLES(STARTUP), .REFRESH_PERIOD(REFRESH)
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

	sdram_model #(.READ_LATENCY(RD_LAT)) chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	// FAST_V: 0 leaves the direct port silent (the Pocket's CPU never toggles
	// it); 1 toggles it once just after reset, which is what a CPU that comes
	// out of reset with a stale request would do.
	initial begin
		fast_tog_r = 1'b0;
		if (FAST_V != 0) begin
			repeat (20) @(posedge clk50);
			fast_tog_r = 1'b1;
		end
	end

	integer beats = 0, cyc = 0;
	always @(posedge clk50) cyc = cyc + 1;
	always @(posedge clk50) if (req_valid) beats = beats + 1;

	integer t_issue = -1, t_done = -1;
	initial begin
		reset = 1;
		repeat (4) @(posedge clk50);
		reset = 0;
		if (EARLY_V != 0) begin
			repeat (EARLY_V) @(posedge clk50);
		end else begin
			wait (packed_ready === 1'b1);
			repeat (ARRIVE_V) @(posedge clk50);
		end
		// One clk-wide read pulse, exactly as the bridge's sdram_read is.
		req_addr  <= 25'd0;
		req_burst <= BURST;
		req_rd    <= 1'b1;
		t_issue    = cyc;
		@(posedge clk50);
		req_rd    <= 1'b0;

		// +reinit=N: re-assert reset N clk cycles after the pulse, for 3 cycles.
		// In the core, `init` is ~sdram_postlock_pipe[7], cleared by a low on
		// pll_locked - so a PLL lock dropout after traffic re-runs the whole
		// startup sequence. This asks what happens to an outstanding request
		// when it does.
		if (REINIT_V != 0) begin
			repeat (REINIT_V) @(posedge clk50);
			reset = 1;
			repeat (3) @(posedge clk50);
			reset = 0;
		end

		fork : wait_done
			begin
				wait (req_done === 1'b1);
				t_done = cyc;
			end
			begin
				// An early pulse lands before init finishes, so the wait has to
				// span the rest of STARTUP as well as a transaction.
				repeat (STARTUP + 3000) @(posedge clk50);
				t_done = -1;
			end
		join_any
		disable wait_done;

		if (t_done < 0) begin
			$display("FAIL phase=%0.0fps arrive=%0d early=%0d startup=%0d refresh=%0d fast=%b : no done; beats=%0d ctl.ready=%b ctl.pending=%b ctl.state=%0d x2.wl=%0d open=%b",
			         PHASE_V, ARRIVE_V, EARLY_V, STARTUP, REFRESH, FAST_V, beats,
			         ctl_ready, ctl.pending, ctl.state, adapter.pack.words_left,
			         ctl.open_valid);
			$display("FAIL");
		end else begin
			$display("ok   phase=%0.0fps arrive=%0d early=%0d : done after %0d clk, %0d beats, wl=%0d",
			         PHASE_V, ARRIVE_V, EARLY_V, t_done - t_issue, beats,
			         adapter.pack.words_left);
			$display("PASS");
		end
		$finish;
	end
endmodule
