// Behavioural stand-in for Altera's dcfifo with show-ahead OFF.
// q updates on the read clock edge where rdreq is sampled; the reader sees it
// on the following clock, which is the contract pk_io is written against.
`timescale 1ns/1ps
`default_nettype none
module dcfifo #(
	parameter integer lpm_numwords = 8192,
	parameter integer lpm_width = 44,
	parameter integer lpm_widthu = 13,
	parameter lpm_showahead = "OFF",
	parameter integer lpm_type = 0,
	parameter integer overflow_checking = 0,
	parameter integer underflow_checking = 0,
	parameter integer use_eab = 0,
	parameter integer wrsync_delaypipe = 0,
	parameter integer rdsync_delaypipe = 0,
	parameter intended_device_family = ""
) (
	input  wire [lpm_width-1:0] data,
	input  wire                 wrclk,
	input  wire                 wrreq,
	input  wire                 rdclk,
	input  wire                 rdreq,
	output reg  [lpm_width-1:0] q,
	output wire                 rdempty,
	output wire                 wrfull,
	input  wire                 aclr,
	output wire                 eccstatus,
	output wire                 rdfull,
	output wire [lpm_widthu-1:0] rdusedw,
	output wire                 wrempty,
	output wire [lpm_widthu-1:0] wrusedw
);
	reg [lpm_width-1:0] mem [0:lpm_numwords-1];
	integer wptr = 0, rptr = 0;
	integer count = 0;
	assign rdempty = (count == 0);
	assign wrfull  = (count == lpm_numwords);
	assign rdusedw = count;
	assign wrusedw = count;
	assign rdfull  = 1'b0;
	assign wrempty = (count == 0);
	assign eccstatus = 1'b0;
	always @(posedge wrclk) if (wrreq) begin
		mem[wptr] <= data; wptr <= (wptr + 1) % lpm_numwords; count <= count + 1;
	end
	always @(posedge rdclk) if (rdreq) begin
		q <= mem[rptr]; rptr <= (rptr + 1) % lpm_numwords; count <= count - 1;
	end
endmodule
`default_nettype wire
