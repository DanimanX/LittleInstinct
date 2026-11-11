// Minimal SDRAM device model for the loader bench. Writes are fire-and-forget
// in this model; the bench checks command liveness and the controller's done,
// not read data.
`timescale 1ns/1ps
`default_nettype none
module sdram_model (
	input wire clk, input wire [12:0] a, input wire [1:0] ba,
	inout wire [15:0] dq, input wire [1:0] dqm, input wire cke,
	input wire ras_n, input wire cas_n, input wire we_n, input wire cs_n
);
	assign dq = 16'hzzzz;
endmodule
`default_nettype wire
