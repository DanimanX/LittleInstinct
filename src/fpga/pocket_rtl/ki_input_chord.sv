// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// ki_input_chord: a frame-rate independent two-button chord detector.
//
// The Pocket's Start and Select are separate small buttons; a human almost
// never closes them on the same 20 ns clock edge. The old detector ANDed the
// two live bits, so it only fired if the two presses happened to overlap in the
// single cycle the console sampled. That is not a combo detector, it is a
// coincidence detector.
//
// This one works in absolute time. The first button of the pair opens a window
// (WINDOW_CYCLES of clk); if the second arrives before it closes, a one-cycle
// `pulse` is emitted. Pressing either button alone therefore behaves exactly as
// before - not delayed, not swallowed, not replayed - and a chord still fires
// when the two presses are tens of milliseconds apart.
//
// Only rising edges are considered, and a chord is consumed once: both buttons
// must be released before another can fire, so holding them cannot repeat-toggle
// the overlay.
//
// Clocked by clk_core and counted in clk_core cycles, not video frames or
// CE_PIXEL ticks, so the window is identical in the native 59 Hz and the 60 Hz
// timing mode and does not depend on video timing being alive.
module ki_input_chord #(
	// 250 ms at 50 MHz. Long enough for a two-thumb press, short enough that a
	// deliberate Start, pause, Select is not read as a combo.
	parameter integer WINDOW_CYCLES = 12_500_000,
	parameter integer WINDOW_BITS   = 24
) (
	input  wire clk,
	input  wire reset,

	// Raw levels. They are synchronized here so the caller does not have to
	// remember to do it, and so a metastable edge cannot fake a chord.
	input  wire start_i,
	input  wire select_i,

	output reg  pulse,        // one clk_core cycle per completed chord
	output wire both_held     // both buttons down now (diagnostic / passthrough)
);
	// Two flops per input. The buttons are slow, so a plain two-flop
	// synchronizer is both sufficient and the least coupling.
	reg [1:0] start_sync  = 2'b00;
	reg [1:0] select_sync = 2'b00;
	wire start_down  = start_sync[1];
	wire select_down = select_sync[1];

	// Previous synchronized level, for a one-cycle rising-edge detect.
	reg start_d  = 1'b0;
	reg select_d = 1'b0;
	wire start_rise  = start_down  & ~start_d;
	wire select_rise = select_down & ~select_d;

	localparam [WINDOW_BITS-1:0] WINDOW_MAX = WINDOW_CYCLES;

	reg start_latched  = 1'b0;
	reg select_latched = 1'b0;
	reg armed          = 1'b1;
	reg [WINDOW_BITS-1:0] window = {WINDOW_BITS{1'b0}};

	// Chord on the rising edge of the second button while the first is latched
	// (or already down, which covers a truly simultaneous press).
	wire chord_now =
		(start_rise  & (select_down | select_latched)) |
		(select_rise & (start_down  | start_latched));

	assign both_held = start_down & select_down;

	always @(posedge clk) begin
		start_sync  <= {start_sync[0],  start_i};
		select_sync <= {select_sync[0], select_i};
		start_d     <= start_down;
		select_d    <= select_down;
		pulse <= 1'b0;

		if (reset) begin
			start_latched  <= 1'b0;
			select_latched <= 1'b0;
			armed          <= 1'b1;
			window         <= {WINDOW_BITS{1'b0}};
		end else begin
			if (armed && chord_now) begin
				// Consume the pair. Both buttons must be released before the
				// next chord, so holding them cannot toggle repeatedly.
				pulse          <= 1'b1;
				armed          <= 1'b0;
				start_latched  <= 1'b0;
				select_latched <= 1'b0;
				window         <= {WINDOW_BITS{1'b0}};
			end else if (armed && start_rise && !select_down && !select_latched) begin
				// First half of the chord: remember it and open the window.
				start_latched <= 1'b1;
				window        <= WINDOW_MAX;
			end else if (armed && select_rise && !start_down && !start_latched) begin
				select_latched <= 1'b1;
				window         <= WINDOW_MAX;
			end else if (window != {WINDOW_BITS{1'b0}}) begin
				window <= window - 1'b1;
			end else begin
				// Window expired: the lone press was an ordinary button. The
				// game already saw it, so there is nothing to undo.
				start_latched  <= 1'b0;
				select_latched <= 1'b0;
			end

			if (!start_down && !select_down)
				armed <= 1'b1;
		end
	end
endmodule

`default_nettype wire
