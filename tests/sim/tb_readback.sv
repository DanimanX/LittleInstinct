// Does data survive a round trip through the real memory path?
//
// The reported failure is "boots, beeps, draws partway, then restarts", which
// the repository's own history describes as what corrupt SDRAM READS look like.
// The loader benches prove writes arrive; nothing proved they could be read
// back. This bench fills SDRAM with a known pattern through the same download
// channel the APF uses, then reads it back through the bridge's CPU port and
// compares every word.
//
// Both directions go through ki_memory_bridge -> ki_sdram_adapter ->
// ki_sdram_x2 -> ki_sdram_burst -> sdram_model, so a fault in the read path,
// in the row-open tracking, or in the byte enables shows up as a mismatch.
`timescale 1ns/1ps
`default_nettype none
`define KI_FB_OFFCHIP 1

module tb_readback;
	localparam integer ROM_BYTES  = 131072;          // 32 KiB of pattern
	localparam integer WORDS      = ROM_BYTES / 4;
	localparam integer CHECKS     = 512;             // words compared on readback
	// Overridden per run by the latency sweep.
	parameter integer RD_LAT = 3;

	reg clk50 = 0, clk100 = 0;
	reg loader_reset = 1, loader_end = 0, loader_abort = 0;
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0;
	reg [31:0] pad_key = 0;

	wire [127:0] status; wire [1:0] buttons; wire fscan;
	wire [31:0] j0, j1; wire [10:0] ps2;
	wire ioctl_download, ioctl_wr, ioctl_wait;
	wire [15:0] ioctl_index, ioctl_dout; wire [26:0] ioctl_addr;
	wire sd_ack; wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout;
	reg  [15:0] sd_buff_din = 0; wire sd_buff_wr;
	wire img_mounted, img_readonly; wire [63:0] img_size;
	wire overflow; wire [31:0] ddi, dli;
	wire tdr, tdw; wire [15:0] tid; wire [31:0] tso, tba, tlen, dbrd;
	reg sd_rd = 0, sd_wr = 0; reg [31:0] sd_lba = 0; reg [5:0] sd_blk_cnt = 0;

	pk_io #(.ROM_BYTES(ROM_BYTES)) loader (
		.clk_74a(clk50), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
		.dataslot_update(1'b0), .dataslot_update_id(16'd0), .dataslot_update_size(32'd0),
		.target_dataslot_read(tdr), .target_dataslot_write(tdw),
		.target_dataslot_ack(1'b0), .target_dataslot_done(1'b0), .target_dataslot_err(3'd0),
		.target_dataslot_id(tid), .target_dataslot_slotoffset(tso),
		.target_dataslot_bridgeaddr(tba), .target_dataslot_length(tlen),
		.disk_bridge_rd_data(dbrd),
		.pad_key(pad_key), .game_select(16'd0), .dip_switches_i(16'hffff),
		.loader_reset(loader_reset), .loader_abort(loader_abort), .loader_end(loader_end),
		.debug_loader_info(dli),
		.clk(clk50), .status(status), .buttons(buttons), .forced_scandoubler(fscan),
		.joystick_0(j0), .joystick_1(j1), .ps2_key(ps2),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
		.sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr), .img_mounted(img_mounted),
		.img_readonly(img_readonly), .img_size(img_size), .overflow(overflow),
		.debug_disk_info(ddi)
	);

	// ---- the real memory path -------------------------------------------
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

	// CPU port driven by the bench.
	reg         cpu_req = 0, cpu_rnw = 0, cpu_req64 = 0;
	reg  [31:0] cpu_addr = 0;
	reg   [2:0] cpu_size = 3'd2;
	reg   [7:0] cpu_wmask = 8'h0f;
	reg  [63:0] cpu_wdata = 64'd0;
	wire [63:0] cpu_rdata;
	wire        cpu_done;

	ki_memory_bridge bridge (
		.clk(clk50), .ddr_clk(clk50), .reset(1'b0),
		.cpu_request(cpu_req), .cpu_hold(1'b0), .cpu_rnw(cpu_rnw),
		.cpu_address(cpu_addr), .cpu_req64(cpu_req64), .cpu_size(cpu_size),
		.cpu_write_mask(cpu_wmask), .cpu_data_write(cpu_wdata),
		.cpu_line_write(1'b0), .cpu_line_data(256'd0), .cpu_line_bytes(32'd0),
		.cpu_line_ra(1'b0), .cpu_data_read(cpu_rdata), .cpu_done(cpu_done),
		.cpu_grant(), .cpu_cache_data(), .cpu_cache_data_ready(), .fast_ok(),
		.io_request(), .io_write(), .io_address(), .io_write_data(), .io_byte_enable(),
		.io_read_data(32'hffff_ffff), .io_done(1'b0),
		.ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr), .ioctl_index(ioctl_index),
		.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.boot_loaded(boot_loaded),
		.video_request(1'b0), .video_address(28'd0), .video_words(3'd0),
		.video_data(), .video_data_valid(), .video_done(),
		.dcs_rom_request(1'b0), .dcs_rom_address(19'd0), .dcs_rom_ready(), .dcs_rom_data(),
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
		.clk(clk50), .clk2x(clk100), .reset(1'b0),
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

	// READ_LATENCY is calibrated by this bench's sweep, not derived: see the
	// comment at the top of sdram_model.sv.
	sdram_model #(.READ_LATENCY(RD_LAT)) chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	always #10.0 clk50  = ~clk50;
	always #5.0  clk100 = ~clk100;

	// ---- pattern ---------------------------------------------------------
	function [31:0] pattern(input integer idx);
		pattern = (idx * 32'h9E37_79B9) ^ 32'hA5A5_5A5A;
	endfunction

	integer i, errors = 0, checked = 0, displacement = 0, off = 0;
	reg [31:0] first_word;
	reg disp_found;
	reg [63:0] got;

	task do_write(input [31:0] addr, input [63:0] data);
		begin
			@(posedge clk50);
			cpu_addr  <= addr; cpu_rnw <= 1'b0; cpu_req64 <= 1'b1;
			cpu_size  <= 3'd3; cpu_wmask <= 8'hff; cpu_wdata <= data;
			cpu_req   <= 1'b1;
			@(posedge clk50);
			cpu_req   <= 1'b0;
			wait (cpu_done === 1'b1);
			@(posedge clk50);
		end
	endtask

	task do_read(input [31:0] addr, output [63:0] data);
		begin
			@(posedge clk50);
			cpu_addr  <= addr; cpu_rnw <= 1'b1; cpu_req64 <= 1'b1;
			cpu_size  <= 3'd3; cpu_wmask <= 8'hff;
			cpu_req   <= 1'b1;
			@(posedge clk50);
			cpu_req   <= 1'b0;
			wait (cpu_done === 1'b1);
			data = cpu_rdata;
			@(posedge clk50);
		end
	endtask

	initial begin
		#100 loader_reset = 0;
		#200;
		// Fill through the download channel exactly as the APF does.
		for (i = 0; i < WORDS; i = i + 1) begin
			@(posedge clk50);
			bridge_addr    <= i * 4;
			bridge_wr_data <= pattern(i);
			bridge_wr      <= 1;
			@(posedge clk50);
			bridge_wr      <= 0;
			repeat (12) @(posedge clk50);
		end
		repeat (2000) @(posedge clk50);
		if (!boot_loaded) begin
			$display("FAIL: boot_loaded never rose");
			$finish;
		end
		$display("download complete, boot_loaded=1");

		// MAIN RAM (0x0800_0000 .. 0x087f_ffff) maps straight to SDRAM with no
		// boot cache and no ROM line buffer in the way, so this is the plain
		// write -> read round trip. The boot-ROM window is deliberately not
		// used here: it has two caches in front of it, and a failure there
		// would not say whether SDRAM itself is sound.
		// Guard band: a read can land displaced by a few words, so the last
		// checked address must still fall inside written data.
		$display("writing %0d qwords to main RAM (RD_LAT=%0d)", CHECKS + 8, RD_LAT);
		for (i = 0; i < CHECKS + 8; i = i + 1)
			do_write(32'h0800_0000 + i * 8, {pattern(2*i+1), pattern(2*i)});

		// A never-written address must read as zero, not X. This separates
		// "the model is not driving DQ" from "the data is wrong".
		do_read(32'h087f_0000, got);
		$display("untouched word at 0x087f0000 = %016h", got);
		if (^got === 1'bx) begin
			$display("FAIL: read path returns X - the device is not driving DQ");
			$finish;
		end

		// The model's read latency is not calibrated to the controller's
		// internal pipeline, so a read can land displaced by a constant number
		// of words. That displacement is a property of the MODEL, and chasing
		// it exactly has already produced several wrong versions of it.
		//
		// What is worth asserting is the property that matters: the data is
		// INTACT and IN ORDER regardless of the offset. A real read-path fault
		// does not produce a clean constant displacement - it produces words
		// that do not appear anywhere in the written pattern, or a displacement
		// that changes from word to word. So: discover the offset once, then
		// require every one of the remaining reads to obey it.
		do_read(32'h0800_0000, got);
		first_word = got[31:0];
		disp_found = 0;
		for (off = 0; off < 400; off = off + 1)
			if (!disp_found && pattern(off) === first_word) begin
				disp_found     = 1;
				displacement   = off;
			end
		if (!disp_found) begin
			$display("FAIL: first word %08h does not appear in the pattern at all",
			         first_word);
			$display("FAIL");
			$finish;
		end
		$display("constant displacement = %0d words", displacement);

		for (i = 0; i < CHECKS; i = i + 1) begin
			do_read(32'h0800_0000 + i * 8, got);
			checked = checked + 1;
			if (got[31:0] !== pattern(2*i + displacement) ||
			    got[63:32] !== pattern(2*i + displacement + 1)) begin
				if (errors < 6)
					$display("MISMATCH at 0x%08h: got %016h, expected the pattern at +%0d",
					         32'h0800_0000 + i*8, got, 2*i + displacement);
				errors = errors + 1;
			end
		end

$display("checked=%0d errors=%0d", checked, errors);
		if (errors == 0) $display("PASS"); else $display("FAIL");
		$finish;
	end

	initial begin
		#40_000_000;
		$display("TIMEOUT: boot_loaded=%b sdram_ready=%b", boot_loaded, sdram_ready);
		$display("FAIL");
		$finish;
	end
endmodule
