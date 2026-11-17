// Can the Pocket memory path serve the CPU's OWN miss sequence back to back?
//
// The CPU's requests here are not invented: they are the ones the real boot ROM
// issues on its first D-cache misses, read out of a GHDL run of the boot ROM on
// ki_cpu_core (tests/sim/tb_cpu_boot.vhd):
//
//   0x00000000  32-byte line fill   (lw zero,0(v0)   at 0xBFC003FC, v0=0x80000000)
//   0x00002000  32-byte line fill   (lw zero,0x2000  at 0xBFC00400 - the address
//                                    the hardware froze on)
//   0x00000020 / 0x00002020         the next loop iteration
//
// Every one is a 16-word read (cpu_req64=1, cpu_size=4), 32-byte aligned, and
// low RAM, so it goes through ki_memory_bridge -> ki_sdram_adapter ->
// ki_sdram_x2 -> ki_sdram_burst -> sdram_model exactly as on the board.
//
// It answers one question per request: does cpu_done arrive, and how many
// clocks after the request was accepted. A request that never completes prints
// the bridge's state, sdram_ready and the controller's handshake.
`timescale 1ns/1ps
`default_nettype none
`define KI_FB_OFFCHIP 1

module tb_cpu_line_fills;
	parameter integer RD_LAT = 3;

	reg clk50 = 0, clk100 = 0;
	reg loader_reset = 1;
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0;

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

	pk_io loader (
		.clk_74a(clk50), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
		.dataslot_update(1'b0), .dataslot_update_id(16'd0), .dataslot_update_size(32'd0),
		.target_dataslot_read(tdr), .target_dataslot_write(tdw),
		.target_dataslot_ack(1'b0), .target_dataslot_done(1'b0), .target_dataslot_err(3'd0),
		.target_dataslot_id(tid), .target_dataslot_slotoffset(tso),
		.target_dataslot_bridgeaddr(tba), .target_dataslot_length(tlen),
		.disk_bridge_rd_data(dbrd),
		.pad_key(32'd0), .game_select(16'd0), .dip_switches_i(16'hffff),
		.loader_reset(loader_reset), .loader_abort(1'b0), .loader_end(1'b0),
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

	wire boot_loaded, sdram_ready;
	wire [24:0] s_addr; wire [255:0] s_wdata; wire [31:0] s_be; wire [4:0] s_burst;
	wire s_rd, s_we;
	wire [31:0] s_rdata; wire [1:0] s_rbe; wire s_dvalid, s_done;
	wire [31:0] ctl_addr; wire [255:0] ctl_din; wire [31:0] ctl_be;
	wire [4:0] ctl_burst; wire ctl_rd, ctl_we; wire [15:0] ctl_dout;
	wire ctl_dvalid, ctl_ready;
	wire [15:0] DQ; wire [12:0] A; wire [1:0] BA, DQM;
	wire CKE, nRAS, nCAS, nWE, nCS;
	wire [7:0] adapter_status;
`ifdef V181_COUNTS
	// The two link counter words, bridge and adapter side.
	wire [31:0] bridge_counts;
	wire [31:0] adapter_counts;
`endif

	reg         cpu_req = 0, cpu_rnw = 0, cpu_req64 = 0;
	reg  [31:0] cpu_addr = 0;
	reg   [2:0] cpu_size = 3'd4;
	reg   [7:0] cpu_wmask = 8'hff;
	reg  [63:0] cpu_wdata = 64'd0;
	wire [63:0] cpu_rdata;
	wire        cpu_done, cpu_grant, cpu_cdr;
	wire [63:0] cpu_cdata;

	integer cyc = 0;
	always @(posedge clk50) cyc = cyc + 1;

	// ---- concurrent traffic, the way the board runs it -------------------
	// ki_framebuffer holds memory_request until memory_done, four words at a
	// time, once per scanline. STIM_VID=0 disables it.
	parameter integer STIM_VID = 1;
	parameter integer STIM_DCS = 1;
	parameter integer VID_GAP  = 40;    // cycles between scanout requests
	// Aggressive mode: both requesters re-arm as fast as the bridge lets them,
	// which removes nearly every idle cycle the CPU could slip into. 0 =
	// the polite traffic that measured ~28 cycles of interference.
	parameter integer AGG      = 1;
	parameter integer AGGRESSIVE_GAP = 0;

	reg         v_req = 0;
	reg  [27:0] v_addr = 0;
	wire        v_done, v_dvalid;
	wire [63:0] v_data;
	reg         d_req = 0, d_ready;
	reg  [18:0] d_addr = 0;
	wire [63:0] d_data;

	integer v_ok = 0, d_ok = 0, v_hi = 0, v_iss = 0;
	always @(posedge clk50) begin
		if (v_req) v_hi = v_hi + 1;
	end
	always @(posedge clk50) begin
		if (bridge.state == bridge.VID_ISSUE) v_iss = v_iss + 1;
		if (bridge.state == bridge.VID_WAIT)  v_iss = v_iss + 100000;
	end

	// AGG=2: the pathological client. video_request is held high and never
	// withdrawn, and video_done is never waited for - so the bridge's video
	// branch is eligible again on the very cycle after every completion and
	// there is no idle cycle for anything else to use. This is the shape of a
	// requester whose flow control is broken, and it is the ONLY way to starve
	// a client that is merely lower priority: every well-behaved requester
	// leaves at least its own completion cycle free.
	initial begin
		if (STIM_VID && AGG == 2) begin
			v_addr <= 28'h3_0000;
			v_req  <= 1'b1;
			forever begin
				@(posedge clk50);
				v_addr <= 28'h3_0000 + ((cyc % 64) * 32);
				if (v_done === 1'b1) v_ok = v_ok + 1;
			end
		end
	end

	initial begin
		if (STIM_VID && AGG != 2) begin
			forever begin
				repeat (VID_GAP) @(posedge clk50);
				v_addr <= 28'h3_0000 + ((cyc % 64) * 32);
				v_req  <= 1'b1;
				wait (v_done === 1'b1);
				@(posedge clk50);
				// AGG mode: re-raise on the very next cycle. The bridge
				// needs one cycle with the request low to re-arm
				// (video_done / dcs_rom_request_seen_level), so a 1-cycle
				// drop is the most aggressive a well-behaved client can be.
				if (!AGG) repeat (AGGRESSIVE_GAP) @(posedge clk50);
				v_req  <= 1'b0;
				v_ok    = v_ok + 1;
			end
		end
	end

	// The DCS port: request held until ready pulses, as ki_dcs_audio does.
	initial begin
		if (STIM_DCS) begin
			forever begin
				repeat (17) @(posedge clk50);
				d_addr <= d_addr + 19'd4;
				d_req  <= 1'b1;
				wait (d_ready === 1'b1);
				@(posedge clk50);
				d_req  <= 1'b0;
				d_ok    = d_ok + 1;
				// AGG: one cycle low, then straight back up. This is the
				// shape the hardware's sound board produces when the DSP is
				// fetching its program in a tight loop.
				repeat (AGG ? 1 : 16) @(posedge clk50);
			end
		end
	end


	integer n_bv = 0, n_done_p = 0, cyc_bv = -1, cyc_done = -1;
	always @(posedge clk50) begin
		if (s_dvalid) begin n_bv = n_bv + 1; cyc_bv = cyc; end
		if (s_done)   begin n_done_p = n_done_p + 1; cyc_done = cyc; end
	end

	integer beats = 0;
	integer t_grant = -1;
	integer t_beat  = 0;
	integer t_accept = 0;
	always @(posedge clk50) begin
		if (cpu_cdr) begin beats = beats + 1; t_beat = cyc; end
		if (cpu_grant && t_grant < 0) t_grant = cyc;
	end
	always @(posedge clk50) if (cpu_req) t_accept = cyc;

	ki_memory_bridge bridge (
		.clk(clk50), .ddr_clk(clk50), .reset(1'b0),
		.cpu_request(cpu_req), .cpu_hold(1'b0), .cpu_rnw(cpu_rnw),
		.cpu_address(cpu_addr), .cpu_req64(cpu_req64), .cpu_size(cpu_size),
		.cpu_write_mask(cpu_wmask), .cpu_data_write(cpu_wdata),
		.cpu_line_write(1'b0), .cpu_line_data(256'd0), .cpu_line_bytes(32'd0),
		.cpu_line_ra(1'b0), .cpu_data_read(cpu_rdata), .cpu_done(cpu_done),
		.cpu_grant(cpu_grant), .cpu_cache_data(cpu_cdata),
		.cpu_cache_data_ready(cpu_cdr), .fast_ok(),
		.io_request(), .io_write(), .io_address(), .io_write_data(), .io_byte_enable(),
		.io_read_data(32'hffff_ffff), .io_done(1'b0),
		// Loader port tied off: pk_io leaves ioctl_download high when no image
		// is ever mounted, and the bridge's IDLE gates BOTH the video and the
		// DCS branches on !ioctl_download - which silently disabled the
		// concurrency this bench exists to test. The CPU port is not gated.
		.ioctl_download(1'b0), .ioctl_wr(1'b0), .ioctl_index(16'd0),
		.ioctl_addr(27'd0), .ioctl_dout(16'd0), .ioctl_wait(),
		.boot_loaded(boot_loaded),
		.video_request(v_req), .video_address(v_addr), .video_words(3'd4),
		.video_data(v_data), .video_data_valid(v_dvalid), .video_done(v_done),
		.dcs_rom_request(d_req), .dcs_rom_address(d_addr), .dcs_rom_ready(d_ready),
		.dcs_rom_data(d_data),
		.sdram_address(s_addr), .sdram_write_data(s_wdata), .sdram_byte_enable(s_be),
		.sdram_burst(s_burst), .sdram_read(s_rd), .sdram_write(s_we),
		.sdram_read_data(s_rdata), .sdram_read_be(s_rbe),
		.sdram_data_valid(s_dvalid), .sdram_done(s_done), .sdram_ready(sdram_ready),
		.ddram_busy(1'b0), .ddram_burstcnt(), .ddram_addr(), .ddram_dout(64'd0),
		.ddram_dout_ready(1'b1), .ddram_rd(), .ddram_din(), .ddram_be(), .ddram_we(),
		.fb_read_accept(), .fb_write_accept(), .perf_frame(1'b0),
		.perf_cpu_outstanding(), .perf_cpu_burst(),
		.debug_write_count(), .debug_low_write_count(), .debug_main_write_count(),
		.debug_download_info()
`ifdef V181_COUNTS
		, .debug_sdram_counts(bridge_counts)
`endif
`ifdef BRIDGE_HAS_WAIT_INFO
		, .debug_cpu_wait_info()
`endif
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
		.controller_fast_valid(), .debug_status(adapter_status)
`ifdef V181_COUNTS
		, .debug_counts(adapter_counts)
`endif
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

	sdram_model #(.READ_LATENCY(RD_LAT)) chip (
		.clk(clk100), .a(A), .ba(BA), .dq(DQ), .dqm(DQM), .cke(CKE),
		.ras_n(nRAS), .cas_n(nCAS), .we_n(nWE), .cs_n(nCS)
	);

	always #10.0 clk50  = ~clk50;
	always #5.0  clk100 = ~clk100;

	integer i, n_done, lat, worst_lat = 0, worst_grant = 0;
	// Fills this bench issues: the boot ROM's twelve.
	localparam integer NFILL = 12;
	reg [31:0] addrs [0:15];

	task automatic do_read(input [31:0] addr);
		begin
			// One cycle of request, exactly as the CPU's mailbox hands it over.
			@(posedge clk50);
			cpu_addr <= addr; cpu_rnw <= 1'b1; cpu_req64 <= 1'b1;
			cpu_size <= 3'd4; cpu_req <= 1'b1;
			@(posedge clk50);
			cpu_req <= 1'b0;
			beats = 0;
			lat = 0;
			t_grant = -1;
			t_beat = 0;
			n_bv = 0; cyc_bv = -1; cyc_done = -1;
			while (cpu_done !== 1'b1 && lat < 4000) begin
				@(posedge clk50);
				lat = lat + 1;
			end
			if (lat > worst_lat) worst_lat = lat;
			if (t_grant >= 0 && (t_grant - t_accept) > worst_grant)
				worst_grant = t_grant - t_accept;
			if (cpu_done === 1'b1) begin
				$display("  read %08h: done after %0d clk, %0d cache beats, grant at +%0d, last beat at +%0d, data=%016h",
				         addr, lat, beats, t_grant - t_accept, t_beat - t_accept, cpu_rdata);
				$display("      sdram_data_valid x%0d (last at +%0d), sdram_done at +%0d  => %s",
				         n_bv, cyc_bv - t_accept, cyc_done - t_accept,
				         (cyc_done == cyc_bv) ? "DONE CONCURRENT WITH LAST BEAT" : "done after last beat");
			end else begin
				$display("  read %08h: NO DONE after %0d clk  (ready=%b dvalid=%b done=%b burst=%0d addr=%0d)",
				         addr, lat, sdram_ready, s_dvalid, s_done, s_burst, s_addr);
				$display("  adapter_status=%02h ctl_ready=%b ctl_dvalid=%b", adapter_status,
				         ctl_ready, ctl_dvalid);
			end
			@(posedge clk50);
		end
	endtask

	initial begin
		// The pattern table: the boot ROM's own miss sequence.
		addrs[0]  = 32'h0000_0000;
		addrs[1]  = 32'h0000_2000;
		addrs[2]  = 32'h0000_0020;
		addrs[3]  = 32'h0000_2020;
		addrs[4]  = 32'h0000_0040;
		addrs[5]  = 32'h0000_2040;
		addrs[6]  = 32'h0000_0060;
		addrs[7]  = 32'h0000_2060;
		addrs[8]  = 32'h0000_0000;
		addrs[9]  = 32'h0000_2000;
		addrs[10] = 32'h0005_0000;
		addrs[11] = 32'h0000_1000;

		#100 loader_reset = 0;
		// Let the controller finish its 12000-cycle startup.
		repeat (20000) @(posedge clk50);
		$display("sdram_ready=%b boot_loaded=%b", sdram_ready, boot_loaded);

		for (i = 0; i < 12; i = i + 1) begin
			$display("[%0d] line fill", i);
			do_read(addrs[i]);
		end
		$display("concurrent: %0d scanout served, %0d DCS served, v_req high %0d clk, cycles in VID_ISSUE %0d",
		         v_ok, d_ok, v_hi, v_iss);
		$display("worst CPU fill latency: %0d clk, worst grant wait: %0d clk",
		         worst_lat, worst_grant);
		$display("bridge state at end = %0d (IDLE=0)", bridge.state);
`ifdef V181_COUNTS
		begin : link_check
			integer b_rd, b_beat, b_done, a_launch, a_beat, a_done, a_req;
			b_rd    = bridge_counts[31:24];
			b_beat  = bridge_counts[23:16];
			b_done  = bridge_counts[15:8];
			a_req   = adapter_counts[31:24];
			a_launch= adapter_counts[23:16];
			a_done  = adapter_counts[15:8];
			a_beat  = adapter_counts[7:0];
			$display("BQ (bridge) = %08h  reads=%0d beats=%0d dones=%0d done_owed=%b seen=%b ready=%b words_left=%0d",
			         bridge_counts, b_rd, b_beat, b_done,
			         bridge_counts[7], bridge_counts[6], bridge_counts[5],
			         bridge_counts[4:0]);
			$display("AD (adapter)= %08h  req_high=%0d launches=%0d dones=%0d beats=%0d",
			         adapter_counts, a_req, a_launch, a_done, a_beat);
			// The request path is 1:1 either way: every sdram_read the bridge
			// issues is one primary launch at the adapter, and every one of
			// those produces exactly one done. That holds with scanout and DCS
			// running too, because they use this same port.
			if (b_rd != a_launch) $display("MISMATCH: bridge issued %0d reads, adapter launched %0d", b_rd, a_launch);
			if (b_done != a_done) $display("MISMATCH: bridge saw %0d dones, adapter raised %0d", b_done, a_done);
			// The absolute figures below only hold with no other requester: a
			// scanout word is also a sdram_read here and also a beat at the
			// adapter, but it is not an 8-beat line fill.
			if (STIM_VID == 0 && STIM_DCS == 0) begin
			if (b_rd != NFILL)   $display("MISMATCH: %0d sdram_read for %0d fills", b_rd, NFILL);
			if (b_rd != a_launch) $display("MISMATCH: bridge issued %0d reads, adapter launched %0d", b_rd, a_launch);
			if (STIM_VID == 0 && STIM_DCS == 0 && b_beat != a_beat)
				$display("MISMATCH: bridge saw %0d beats, adapter sent %0d", b_beat, a_beat);
			if (b_done != a_done) $display("MISMATCH: bridge saw %0d dones, adapter raised %0d", b_done, a_done);
			if (b_beat != NFILL * 8) $display("MISMATCH: %0d beats for %0d fills (expected 8 each)", b_beat, NFILL);
			if (b_rd == NFILL && b_beat == a_beat && b_beat == NFILL * 8)
				$display("LINK CONSISTENT (reference): reads=%0d launches=%0d beats=%0d dones=%0d",
				         b_rd, a_launch, b_beat, b_done);
			end
		end
`endif
`ifdef BRIDGE_HAS_WAIT_INFO
		$display("debug_cpu_wait_info = %08h  {state=%0d, starve_win=%0d, max_age=%0d}",
		         bridge.debug_cpu_wait_info, bridge.debug_cpu_wait_info[31:27],
		         bridge.debug_cpu_wait_info[23:16], bridge.debug_cpu_wait_info[15:0]);
`endif
		$display("PASS: every request completed");
		$finish;
	end

	initial begin
		#10_000_000;
		$display("TIMEOUT");
		$finish;
	end
endmodule
