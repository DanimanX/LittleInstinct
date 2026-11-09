// Isolated cost measurement for the DCS ADSP-2105 emulation.
// Same pattern as tools/measure/feas_top.sv: every output reaches a pin through
// one reduction so nothing is pruned, every input is driven from a counter.
module adsp_bench (
	input  wire clk,
	output wire led
);
	reg [31:0] ctr = 32'd0;
	always @(posedge clk) ctr <= ctr + 32'd1;

	wire        rom_req;
	wire [18:0] rom_addr;
	wire [15:0] host_status, host_resp;
	wire [13:0] ppc, wrap_pc, src_pc, src_addr;
	wire        valid, unimpl;
	wire [15:0] dac_s;
	wire        dac_ce;
	wire  [7:0] wrap_cnt, src_cnt, src_op, rom_unst, cmd_lost;
	wire [11:0] bank_delta;
	wire        cmd_read;

	adsp2105 u_adsp (
		.clk(clk), .rst(ctr[0]), .core_ce(1'b1),
		.host_rst(ctr[1]),
		.host_cmd_w(ctr[2]), .host_cmd_data(ctr[31:16]),
		.host_status_r(host_status), .host_response_r(host_resp),
		.host_resp_rd(ctr[3]),
		.rom_ddr_req(rom_req), .rom_ddr_addr(rom_addr),
		.rom_ddr_rdy(ctr[4]), .rom_ddr_q({8{ctr[7:0]}}),
		.dac_ce_in(ctr[5]),
		.o_ppc(ppc), .o_valid(valid), .o_unimpl(unimpl),
		.dac_sample(dac_s), .dac_ce(dac_ce),
		.dbg_wrap_pc(wrap_pc), .dbg_wrap_cnt(wrap_cnt),
		.dbg_src_pc(src_pc), .dbg_src_addr(src_addr),
		.dbg_src_cnt(src_cnt), .dbg_src_op(src_op),
		.dbg_rom_unstable_o(rom_unst), .dbg_rom_bankdelta_o(bank_delta),
		.dbg_cmd_lost(cmd_lost), .dbg_cmd_read(cmd_read)
	);

	assign led = ^{rom_req, rom_addr, host_status, host_resp, ppc, wrap_pc,
	               src_pc, src_addr, valid, unimpl, dac_s, dac_ce, wrap_cnt,
	               src_cnt, src_op, rom_unst, bank_delta, cmd_lost, cmd_read};
endmodule
