// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// ki_boot_ctrl: the core's boot and reset sequencer.
//
// The game is held in reset until four independent things are true:
//
//   1. the core PLL is locked,
//   2. the SDRAM controller has finished its power-up sequence,
//   3. any built-in SDRAM self test has finished, and
//   4. the loader has finished writing the ROM image into SDRAM
//      (`boot_loaded`, raised by ki_memory_bridge only when its download
//      queue is empty and the last write has landed).
//
// Before this module those terms were spread between ki_core_pocket.sv,
// ki_pocket_top.sv and ki_memory_bridge.sv, and there was no timeout: if any
// one of them never became true the CPU stayed in reset forever with no
// indication beyond a frozen debug counter.
//
// Two things are separated here:
//
//   * loader_reset is a POWER-ON reset, not a live PLL-lock gate. If the core
//     PLL drops lock for a cycle after the ROM transfer has started, resetting
//     the loader to its start state would make it wait for a second copy of a
//     ROM the host will never send. The one-shot keeps the FSM and its FIFO
//     intact across a lock glitch.
//
//   * loader_abort is the fallback. If the loader is still busy after
//     TIMEOUT_CYCLES the host is not going to deliver the rest of the image;
//     telling the loader to finish lets the bridge drain, `boot_loaded` rise
//     and the CPU run (possibly on a partial image, which is visible on the
//     debug page) instead of hanging in reset forever.
//
// The module owns no video, input or CPU logic: it only reports state.
module ki_boot_ctrl #(
	// 8 s at 50 MHz. The ROM transfer measured on hardware is about 1.4 s at
	// the APF bridge's pace; eight seconds leaves room for a slow SD card
	// without turning a slow-but-valid load into a truncated image.
	parameter integer TIMEOUT_CYCLES = 400_000_000,
	// The bridge drains its download queue after ioctl_download drops. That
	// takes microseconds; 100 ms of no progress means the SDRAM write path,
	// not the host, is stuck.
	parameter integer DRAIN_TIMEOUT_CYCLES = 5_000_000
) (
	input  wire clk,
	input  wire pll_locked,

	// Status from the rest of the core.
	input  wire boot_loaded,     // ROM image fully written to SDRAM
	input  wire sdram_ready,     // controller out of its power-up sequence
	input  wire bist_done,       // self test finished (tied 1 in release)
	input  wire loader_busy,     // ioctl_download, i.e. loader still streaming

	output reg  loader_reset = 1'b1, // one-shot power-on reset for the loader
	output reg  loader_abort,    // finish the stream now (fallback)
	output reg  boot_ready,      // all four terms true

	output reg  [2:0] state,
	output reg        timed_out,
	output reg [31:0] elapsed
);
	localparam [2:0] S_WAIT_PLL   = 3'd0,
	                 S_WAIT_SDRAM = 3'd1,
	                 S_LOADING    = 3'd2,
	                 S_READY      = 3'd3,
	                 S_TIMEOUT    = 3'd4;

	localparam [31:0] TIMEOUT_MAX = TIMEOUT_CYCLES;
	localparam [31:0] DRAIN_MAX   = DRAIN_TIMEOUT_CYCLES;

	reg ever_locked = 1'b0;
	reg [31:0] watchdog = 32'd0;
	reg [31:0] drain_watchdog = 32'd0;
	reg abort_latched = 1'b0;

	wire ready_now = boot_loaded & sdram_ready & bist_done;

	always @(posedge clk) begin
		// Power-on loader reset. Asserted until the first PLL lock, then never
		// again: a later unlock is a fault to report, not a reason to make the
		// loader wait for a ROM that will not be sent twice.
		if (!pll_locked) begin
			if (!ever_locked)
				loader_reset <= 1'b1;
		end else begin
			ever_locked  <= 1'b1;
			loader_reset <= 1'b0;
		end

		if (!pll_locked) begin
			state         <= S_WAIT_PLL;
			watchdog      <= 32'd0;
			drain_watchdog<= 32'd0;
			elapsed       <= 32'd0;
			timed_out     <= 1'b0;
			abort_latched <= 1'b0;
			loader_abort  <= 1'b0;
			boot_ready    <= 1'b0;
		end else begin
			if (ready_now) begin
				state        <= S_READY;
				boot_ready   <= 1'b1;
				timed_out    <= 1'b0;
				loader_abort <= 1'b0;
			end else begin
				boot_ready <= 1'b0;

				if (!sdram_ready || !bist_done)
					state <= S_WAIT_SDRAM;
				else if (loader_busy)
					state <= S_LOADING;
				else
					state <= S_WAIT_SDRAM;

				// The watchdog runs only while the loader is actually busy and
				// the image is not complete. Counting from power-up would make
				// a slow host look like a broken loader.
				if (loader_busy && !boot_loaded) begin
					if (watchdog != TIMEOUT_MAX) begin
						watchdog <= watchdog + 32'd1;
						elapsed  <= elapsed + 32'd1;
					end else begin
						timed_out    <= 1'b1;
						loader_abort <= 1'b1;
						abort_latched <= 1'b1;
						state        <= S_TIMEOUT;
					end
				end else begin
					watchdog <= 32'd0;
				end

				// The host is done but the bridge has not raised
				// boot_loaded: its download queue is not draining. There is
				// nothing left to abort, but the page must say so.
				if (!loader_busy && !boot_loaded && sdram_ready && bist_done) begin
					if (drain_watchdog != DRAIN_MAX) begin
						drain_watchdog <= drain_watchdog + 32'd1;
					end else begin
						timed_out <= 1'b1;
						state     <= S_TIMEOUT;
					end
				end else begin
					drain_watchdog <= 32'd0;
				end

				// Keep abort up until the loader actually drops ioctl_download,
				// then release it. pk_io latches its own aborted flag.
				if (abort_latched && !loader_busy)
					loader_abort <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
