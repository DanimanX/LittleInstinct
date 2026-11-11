`timescale 1ns/1ps
`default_nettype none
`define KI_FB_OFFCHIP 1



module tb_loader_e2e;
	localparam integer ROM_BYTES = 65536;
	localparam integer WORDS = ROM_BYTES / 4;

	reg clk_74a = 0, clk = 0, clk100 = 0;
	reg loader_reset = 1, loader_abort = 0, loader_end = 0;
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0;
	reg [31:0] pad_key = 0;

	wire [127:0] status; wire [1:0] buttons; wire forced_scandoubler;
	wire [31:0] joystick_0, joystick_1; wire [10:0] ps2_key;
	wire ioctl_download, ioctl_wr, ioctl_wait;
	wire [15:0] ioctl_index, ioctl_dout; wire [26:0] ioctl_addr;
	wire sd_ack; wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout, sd_buff_din;
	wire sd_buff_wr, img_mounted, img_readonly; wire [63:0] img_size;
	wire overflow; wire [31:0] debug_disk_info, debug_loader_info;
	wire target_dataslot_read, target_dataslot_write;
	wire [15:0] target_dataslot_id;
	wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
	wire [31:0] disk_bridge_rd_data;
	reg sd_rd = 0, sd_wr = 0; reg [31:0] sd_lba = 0; reg [5:0] sd_blk_cnt = 0;

	pk_io #(.ROM_BYTES(ROM_BYTES)) loader (
		.clk_74a(clk_74a), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
		.dataslot_update(1'b0), .dataslot_update_id(16'd0), .dataslot_update_size(32'd0),
		.target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
		.target_dataslot_ack(1'b0), .target_dataslot_done(1'b0), .target_dataslot_err(3'd0),
		.target_dataslot_id(target_dataslot_id), .target_dataslot_slotoffset(target_dataslot_slotoffset),
		.target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
		.target_dataslot_length(target_dataslot_length), .disk_bridge_rd_data(disk_bridge_rd_data),
		.pad_key(pad_key), .game_select(16'd0), .dip_switches_i(16'hffff),
		.loader_reset(loader_reset), .loader_abort(loader_abort), .loader_end(loader_end),
		.debug_loader_info(debug_loader_info),
		.clk(clk), .status(status), .buttons(buttons), .forced_scandoubler(forced_scandoubler),
		.joystick_0(joystick_0), .joystick_1(joystick_1), .ps2_key(ps2_key),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
		.sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr), .img_mounted(img_mounted),
		.img_readonly(img_readonly), .img_size(img_size), .overflow(overflow),
		.debug_disk_info(debug_disk_info)
	);

	// The bridge and the SDRAM path.
	wire boot_loaded, sdram_ready;
	wire [24:0] s_addr; wire [255:0] s_wdata; wire [31:0] s_be; wire [4:0] s_burst;
	wire s_rd, s_we;
	wire [31:0] s_rdata; wire [1:0] s_rbe; wire s_dvalid, s_done;
	wire [31:0] debug_download_info;
	wire [31:0] ctl_addr; wire [255:0] ctl_din; wire [31:0] ctl_be;
	wire [4:0] ctl_burst; wire ctl_rd, ctl_we; wire [15:0] ctl_dout;
	wire ctl_dvalid, ctl_ready;
	wire [15:0] DQ; wire [12:0] A; wire [1:0] BA, DQM;
	wire CKE, nRAS, nCAS, nWE, nCS;

	ki_memory_bridge bridge (
		.clk(clk), .ddr_clk(clk), .reset(1'b0),
		.cpu_request(1'b0), .cpu_hold(1'b0), .cpu_rnw(1'b0), .cpu_address(32'd0),
		.cpu_req64(1'b0), .cpu_size(3'd0), .cpu_write_mask(8'd0), .cpu_data_write(64'd0),
		.cpu_line_write(1'b0), .cpu_line_data(256'd0), .cpu_line_bytes(32'd0),
		.cpu_line_ra(1'b0), .cpu_data_read(), .cpu_done(), .cpu_grant(),
		.cpu_cache_data(), .cpu_cache_data_ready(), .fast_ok(),
		.io_request(), .io_write(), .io_address(), .io_write_data(), .io_byte_enable(),
		.io_read_data(32'hffff_ffff), .io_done(1'b0),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.boot_loaded(boot_loaded),
		.video_request(1'b0), .video_address(28'd0), .video_words(3'd0),
		.video_data(), .video_data_valid(), .video_done(),
		.dcs_rom_request(1'b0), .dcs_rom_address(19'd0), .dcs_rom_ready(),
		.dcs_rom_data(),
		.sdram_address(s_addr), .sdram_write_data(s_wdata), .sdram_byte_enable(s_be),
		.sdram_burst(s_burst), .sdram_read(s_rd), .sdram_write(s_we),
		.sdram_read_data(s_rdata), .sdram_read_be(s_rbe), .sdram_data_valid(s_dvalid),
		.sdram_done(s_done), .sdram_ready(sdram_ready),
		.ddram_busy(1'b0), .ddram_burstcnt(), .ddram_addr(), .ddram_dout(64'd0),
		.ddram_dout_ready(1'b1), .ddram_rd(), .ddram_din(), .ddram_be(), .ddram_we(),
		.fb_read_accept(), .fb_write_accept(), .perf_frame(1'b0),
		.perf_cpu_outstanding(), .perf_cpu_burst(),
		.debug_write_count(), .debug_low_write_count(), .debug_main_write_count(),
		.debug_download_info(debug_download_info)
	);

	ki_sdram_adapter adapter (
		.clk(clk), .clk2x(clk100), .reset(1'b0),
		.request_address(s_addr), .request_write_data(s_wdata), .request_byte_enable(s_be),
		.request_burst(s_burst), .request_read(s_rd), .request_write(s_we),
		.request_read_data(s_rdata), .request_read_be(s_rbe),
		.request_data_valid(s_dvalid), .request_done(s_done),
		.aux_address(25'd0), .aux_write_data(64'd0), .aux_byte_enable(8'd0),
		.aux_burst(5'd0), .aux_read(1'b0), .aux_write(1'b0),
		.aux_read_data(), .aux_read_be(), .aux_data_valid(), .aux_done(),
		.sdram_ready(sdram_ready),
		.fast_req_tog(1'b0), .fast_req_line(32'd0), .fast_window(), .fast_beat(),
		.fast_first(), .fast_qword(), .fast_done_tog(),
		.controller_address(ctl_addr), .controller_write_data(ctl_din),
		.controller_byte_enable(ctl_be), .controller_burst(ctl_burst),
		.controller_read(ctl_rd), .controller_write(ctl_we),
		.controller_read_data(ctl_dout), .controller_dout_valid(ctl_dvalid),
		.controller_ready(ctl_ready), .controller_fast_tog(), .controller_fast_addr(),
		.controller_fast_valid()
	);

	ki_sdram_burst #(
		.T_RP(4'd2), .T_RCD(4'd2), .T_RAS(5'd5), .T_RC(5'd7),
		.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
		.STARTUP_CYCLES(15'd12000), .REFRESH_PERIOD(13'd730)
	) ctl (
		.init(1'b0), .clk(clk100), .clk_cap(clk100),
		.SDRAM_DQ(DQ), .SDRAM_A(A), .SDRAM_DQML(DQM[0]), .SDRAM_DQMH(DQM[1]),
		.SDRAM_BA(BA), .SDRAM_nCS(nCS), .SDRAM_nWE(nWE), .SDRAM_nRAS(nRAS),
		.SDRAM_nCAS(nCAS), .SDRAM_CKE(CKE),
		.wtbt(ctl_be), .addr(ctl_addr), .burst(ctl_burst), .dout(ctl_dout),
		.dout_valid(ctl_dvalid), .din(ctl_din), .we(ctl_we), .rd(ctl_rd),
		.ready(ctl_ready), .fast_tog(1'b0), .fast_addr(23'd0), .fast_valid()
	);

	sdram_model chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	always #6.734 clk_74a = ~clk_74a;
	always #10.0 clk = ~clk;
	always #5.0  clk100 = ~clk100;

	integer i;
	integer accepted = 0;
	always @(posedge clk) if (ioctl_wr && ioctl_index == 16'h0001) accepted = accepted + 2;

	initial begin
		#100 loader_reset = 0;
		#200;
		for (i = 0; i < WORDS; i = i + 1) begin
			@(posedge clk_74a);
			bridge_addr <= i * 4;
			bridge_wr_data <= i;
			bridge_wr <= 1;
			@(posedge clk_74a);
			bridge_wr <= 0;
			repeat (12) @(posedge clk_74a);
		end
		repeat (200000) @(posedge clk);
		$display("accepted=%0d boot_loaded=%b download=%b sdram_ready=%b dl=%08x",
		         accepted, boot_loaded, ioctl_download, sdram_ready, debug_download_info);
		if (accepted == ROM_BYTES && boot_loaded && !ioctl_download)
			$display("PASS");
		else
			$display("FAIL");
		$finish;
	end
endmodule
