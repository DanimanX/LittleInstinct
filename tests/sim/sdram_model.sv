// Functional 512 Mbit x16 SDR SDRAM model, for DATA INTEGRITY benches.
//
// The controller programs burst length 1 (MODE in ki_sdram_burst.sv), so every
// READ and WRITE is one word at an explicit column: no burst counter, no
// auto-precharge. This implements exactly that - ACTIVE latches a row, READ
// returns one word after a configurable delay, WRITE stores one word,
// PRECHARGE closes rows.
//
// READ_LATENCY IS CALIBRATED, NOT DERIVED. The controller's own comment says
// "the word for a READ issued from cas_pipe lands three clocks after
// cas_pipe[0]", through a command register plus dq_cap and dq_stg. Deriving
// that by hand produced three wrong versions of this model, so the delay is a
// parameter swept from the command line: the value at which a written pattern
// reads back unchanged is the alignment.
//
// TWO MISTAKES THIS FILE ALREADY MADE, recorded so they are not repeated:
//   1. It returned z on every read, so no bench could ever have caught a
//      read-path fault.
//   2. The return pipeline was clocked on the rising edge, i.e. the model
//      updated in the same instant the controller sampled, and the shift was
//      later duplicated onto both edges so it advanced twice per clock. Both
//      are bench races, not design faults. The pipeline below is a single
//      shift on the FALLING edge: a word loaded for delay N is driven N-1
//      clocks later and is stable across every rising edge in between.
`timescale 1ns/1ps
`default_nettype none
module sdram_model #(
	parameter integer ROW_BITS     = 13,
	parameter integer COL_BITS     = 10,
	parameter integer MEM_WORDS    = 1 << 20,
	// Clocks from a READ being seen by the device to the word reaching the pin.
	parameter integer READ_LATENCY = 2,
	parameter integer SH_DEPTH     = 20
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
	reg [15:0] mem [0:MEM_WORDS-1];

	wire [2:0] cmd = {ras_n, cas_n, we_n};
	localparam [2:0] CMD_ACTIVE = 3'b011,
	                 CMD_READ   = 3'b101,
	                 CMD_WRITE  = 3'b100,
	                 CMD_PRECHG = 3'b010;

	wire [15:0] dq_in = dq;      // write data, sampled while WRITE is seen

	reg [ROW_BITS-1:0] open_row [0:3];
	integer addr;
	always @(*) addr = ((open_row[ba] * (1 << COL_BITS)) + a[COL_BITS-1:0]) % MEM_WORDS;

	// ---- command side: rising edge, exactly when the device sees the command
	always @(posedge clk) begin
		if (cke && !cs_n) begin
			case (cmd)
				CMD_ACTIVE: open_row[ba] <= a[ROW_BITS-1:0];

				CMD_WRITE: begin
					if (!dqm[0]) mem[addr][7:0]  <= dq_in[7:0];
					if (!dqm[1]) mem[addr][15:8] <= dq_in[15:8];
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

	// ---- return pipeline: falling edge, so data never changes on a sampling edge
	// One slot per clock of latency. Several reads may be in flight at once -
	// the controller pipelines consecutive burst-length-1 READs - and each
	// occupies its own slot, so they do not overwrite one another. A single
	// "one read outstanding" register could not represent that, and dropped a
	// word wherever the request pattern changed.
	reg [15:0] sh_d [0:SH_DEPTH-1];
	reg [SH_DEPTH-1:0] sh_v = {SH_DEPTH{1'b0}};
	integer k;

	always @(negedge clk) begin
		// Shift toward index 0 first, then load the newest read at its delay.
		sh_v <= {1'b0, sh_v[SH_DEPTH-1:1]};
		for (k = 0; k < SH_DEPTH-1; k = k + 1)
			sh_d[k] <= sh_d[k+1];

		if (cke && !cs_n && cmd == CMD_READ) begin
			sh_d[READ_LATENCY-1] <= mem[addr];
			sh_v[READ_LATENCY-1] <= 1'b1;
		end
	end

	assign dq = sh_v[0] ? sh_d[0] : 16'hzzzz;

	integer i;
	initial begin
		for (i = 0; i < 4; i = i + 1) open_row[i] = 13'h1fff;
		for (i = 0; i < MEM_WORDS; i = i + 1) mem[i] = 16'h0000;
	end
endmodule

`default_nettype wire
