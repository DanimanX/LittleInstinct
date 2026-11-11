// Start + Select chord detector: window, no false positive on a lone press,
// no repeat while held.
`timescale 1ns/1ps
`default_nettype none

module tb_chord;
	reg clk = 0, reset = 1, start = 0, select = 0;
	wire pulse, both;
	integer pulses = 0;

	ki_input_chord #(.WINDOW_CYCLES(50), .WINDOW_BITS(8)) dut (
		.clk(clk), .reset(reset), .start_i(start), .select_i(select),
		.pulse(pulse), .both_held(both)
	);

	always #10 clk = ~clk;
	always @(posedge clk) if (pulse) pulses = pulses + 1;

	task expect_pulses(input integer n, input [255:0] msg);
		begin
			repeat (2) @(posedge clk);
			if (pulses != n) begin
				$display("FAIL %0s: pulses=%0d want=%0d", msg, pulses, n);
				$fatal(1);
			end
			$display("ok   %0s (pulses=%0d)", msg, pulses);
		end
	endtask

	initial begin
		repeat (5) @(posedge clk);
		reset = 0;
		repeat (5) @(posedge clk);

		// 1. Start alone: never a chord, even if held past the window.
		start = 1;
		repeat (100) @(posedge clk);
		start = 0;
		repeat (10) @(posedge clk);
		expect_pulses(0, "start alone");

		// 2. Start, then Select well inside the window: one pulse.
		start = 1;
		repeat (10) @(posedge clk);
		select = 1;
		repeat (5) @(posedge clk);
		expect_pulses(1, "sequential chord");
		// Holding the pair must not repeat.
		repeat (100) @(posedge clk);
		expect_pulses(1, "held pair does not repeat");
		start = 0; select = 0;
		repeat (10) @(posedge clk);

		// 3. Start, long pause, Select: two ordinary presses, no chord.
		start = 1;
		repeat (5) @(posedge clk);
		start = 0;
		repeat (100) @(posedge clk);   // window is 50 clocks
		select = 1;
		repeat (5) @(posedge clk);
		select = 0;
		repeat (10) @(posedge clk);
		expect_pulses(1, "presses outside window");

		// 4. Simultaneous: one pulse.
		start = 1; select = 1;
		repeat (5) @(posedge clk);
		expect_pulses(2, "simultaneous");
		start = 0; select = 0;
		repeat (10) @(posedge clk);

		// 5. And again after release.
		start = 1; select = 1;
		repeat (5) @(posedge clk);
		expect_pulses(3, "second chord");
		$display("PASS");
		$finish;
	end
endmodule
