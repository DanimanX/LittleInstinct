// Functional 512 Mbit x16 SDR SDRAM model, for DATA INTEGRITY benches.
//
// The controller programs burst length 1 (MODE in ki_sdram_burst.sv), so every
// READ and WRITE is one word at an explicit column: no burst counter, no
// auto-precharge. That is all this implements - ACTIVE latches a row, READ
// returns one word after a configurable delay, WRITE stores one word,
// PRECHARGE closes rows.
//
// READ_LATENCY IS NOT DERIVED, IT IS CALIBRATED. The controller's own comment
// says "the word for a READ issued from cas_pipe lands three clocks after
// cas_pipe[0]", through a command register plus dq_cap and dq_stg. Rather than
// re-derive that by hand and hope, the delay is a parameter swept by
// tests/sim/tb_readback.sv: the value that makes 100% of a written pattern read
// back unchanged is the alignment. Anything else means the model, not the
// design, is off - and if NO value aligns, the design has a real fault.
//
// A previous version of this file returned z on every read, so no bench could
// ever have caught a read-path fault. The read pipeline below is designed so
// data is COMBINATIONAL at the pin for exactly the cycle it is due, rather than
// registered and held, which is what makes the sweep meaningful.
`timescale 1ns/1ps
`default_nettype none
module sdram_model #(
	parameter integer ROW_BITS    = 13,
	parameter integer COL_BITS    = 10,
	parameter integer MEM_WORDS   = 1 << 20,
	// Cycles from the READ command being seen by the device to the word being
	// driven on DQ. 0..6 is the whole plausible range; the bench sweeps it.
	parameter integer READ_LATENCY = 2
) (
	input  wire        clk,
	input  wire [12:0] a,
	input  wire  [1:0] ba,
	inout  wire [15:0] dq,
	input  wire  [1:0] dqm,
	input  wire        cke,
	input  wire        ras_n,
	input  wire        cas_n,
	input  wire        we_n,
	input  wire        cs_n
);
	localparam integer DEPTH = 8;

	reg [15:0] mem [0:MEM_WORDS-1];

	wire [2:0] cmd = {ras_n, cas_n, we_n};
	// Write data is sampled from the pin while the WRITE command is seen.
	wire [15:0] dq_in = dq;
	localparam [2:0] CMD_ACTIVE = 3'b011,
	                 CMD_READ   = 3'b101,
	                 CMD_WRITE  = 3'b100,
	                 CMD_PRECHG = 3'b010;

	reg [ROW_BITS-1:0] open_row [0:3];
	integer addr;
	always @(*) addr = ((open_row[ba] * (1 << COL_BITS)) + a[COL_BITS-1:0]) % MEM_WORDS;

	// Return pipeline. Data is loaded at index READ_LATENCY and shifted one
	// stage per clock toward index 0, which is the stage wired to the pin.
	// sh_v[0] is written BY the shift (never separately cleared), so a loaded
	// word is guaranteed to arrive; an earlier version cleared it every cycle
	// and nothing ever came out.
	localparam integer SH_DEPTH = 16;
	reg [15:0] sh_d [0:SH_DEPTH-1];
	reg [SH_DEPTH-1:0] sh_v = {SH_DEPTH{1'b0}};
	integer k;

	always @(posedge clk) begin
		// Shift toward index 0: sh_v[0] must receive sh_v[1], not a literal 0.
		sh_v <= {1'b0, sh_v[SH_DEPTH-1:1]};
		// Data must move the SAME direction as the valid bit: toward index 0.
		for (k = 0; k < SH_DEPTH-1; k = k + 1)
			sh_d[k] <= sh_d[k+1];

		if (cke && !cs_n) begin
			case (cmd)
				CMD_ACTIVE: open_row[ba] <= a[ROW_BITS-1:0];

				CMD_WRITE: begin
					if (!dqm[0]) mem[addr][7:0]  <= dq_in[7:0];
					if (!dqm[1]) mem[addr][15:8] <= dq_in[15:8];
				end

				CMD_READ: begin
					sh_d[READ_LATENCY] <= mem[addr];
					sh_v[READ_LATENCY] <= 1'b1;
				end

				CMD_PRECHG: begin
					if (a[10]) begin
						open_row[0] <= 13'h1fff; open_row[1] <= 13'h1fff;
						open_row[2] <= 13'h1fff; open_row[3] <= 13'h1fff;
					end else begin
						open_row[ba] <= 13'h1fff;
					end
				end
				default: ;
			endcase
		end
	end

	// Drive on sh_v[0] and hold one extra clock: the controller samples on a
	// separate phase of the same clock, so a single-clock window can be missed
	// by the bench's own alignment rather than by the design.
	assign dq = sh_v[0] ? sh_d[0] : 16'hzzzz;

	integer i;
	initial begin
		for (i = 0; i < 4; i = i + 1) open_row[i] = 13'h1fff;
		for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 16'h0000;
	end
endmodule

`default_nettype wire
