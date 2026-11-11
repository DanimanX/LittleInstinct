// Boot supervisor: one-shot loader reset, watchdog, abort, ready.
`timescale 1ns/1ps
`default_nettype none

module tb_boot;
	reg clk = 0, pll_locked = 0, boot_loaded = 0, sdram_ready = 0, bist_done = 1, loader_busy = 1;
	wire loader_reset, loader_abort, boot_ready;
	wire [2:0] state;
	wire timed_out;

	ki_boot_ctrl #(.TIMEOUT_CYCLES(100)) dut (
		.clk(clk), .pll_locked(pll_locked), .boot_loaded(boot_loaded),
		.sdram_ready(sdram_ready), .bist_done(bist_done), .loader_busy(loader_busy),
		.loader_reset(loader_reset), .loader_abort(loader_abort), .boot_ready(boot_ready),
		.state(state), .timed_out(timed_out), .elapsed()
	);

	always #10 clk = ~clk;

	initial begin
		repeat (3) @(posedge clk);
		if (!loader_reset) $fatal(1, "loader_reset should be high before lock");
		pll_locked = 1;
		repeat (3) @(posedge clk);
		if (loader_reset) $fatal(1, "loader_reset should clear after lock");
		$display("ok   loader reset is a one-shot");

		// A later lock glitch must NOT re-assert the loader reset.
		pll_locked = 0;
		repeat (2) @(posedge clk);
		if (loader_reset) $fatal(1, "loader_reset re-asserted on a late unlock");
		pll_locked = 1;
		repeat (2) @(posedge clk);
		$display("ok   lock glitch does not reset the loader");

		sdram_ready = 1;
		repeat (120) @(posedge clk);
		if (!timed_out || !loader_abort)
			$fatal(1, "timeout/abort did not assert (state=%0d)", state);
		$display("ok   watchdog times out and requests an abort");

		loader_busy = 0;
		repeat (3) @(posedge clk);
		if (loader_abort) $fatal(1, "abort should release once the loader stops");
		$display("ok   abort releases when the loader stops");

		boot_loaded = 1;
		repeat (3) @(posedge clk);
		if (!boot_ready || state != 3)
			$fatal(1, "boot_ready did not assert after boot_loaded (state=%0d)", state);
		$display("ok   boot_ready asserts when all terms are met");
		$display("PASS");
		$finish;
	end
endmodule
