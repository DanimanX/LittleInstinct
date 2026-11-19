`timescale 1ns/1ps
`default_nettype none


module tb_pk_io_paths;
	reg clk_74a = 0, clk = 0, loader_reset = 1, loader_abort = 0, loader_end = 0;
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0, bridge_rd = 0;
	reg target_dataslot_ack = 0, target_dataslot_done = 0;
	reg [31:0] pad_key = 0;
	wire [31:0] debug_loader_info;

	wire [127:0] status; wire [1:0] buttons; wire forced_scandoubler;
	wire [31:0] joystick_0, joystick_1; wire [10:0] ps2_key;
	wire ioctl_download, ioctl_wr; wire [15:0] ioctl_index, ioctl_dout; wire [26:0] ioctl_addr;
	reg ioctl_wait = 0;
	reg sd_rd = 0, sd_wr = 0; reg [31:0] sd_lba = 0; reg [5:0] sd_blk_cnt = 0;
	wire sd_ack; wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout;
	wire [15:0] sd_buff_din; wire sd_buff_wr; wire img_mounted, img_readonly;
	wire [63:0] img_size; wire overflow; wire [31:0] debug_disk_info;
	wire target_dataslot_read, target_dataslot_write;
	wire [15:0] target_dataslot_id;
	wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
	wire [31:0] disk_bridge_rd_data;

	pk_io #(.ROM_BYTES(4718592)) dut (
		.clk_74a(clk_74a), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
		.bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
		.dataslot_update(1'b0), .dataslot_update_id(16'd0), .dataslot_update_size(32'd0),
		.target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
		.target_dataslot_ack(target_dataslot_ack), .target_dataslot_done(target_dataslot_done),
		.target_dataslot_err(3'd0),
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

	always #6.734 clk_74a = ~clk_74a;
	always #10.0  clk = ~clk;

	integer bytes_out = 0;
	always @(posedge clk) if (ioctl_wr && ioctl_index == 16'h0001) bytes_out = bytes_out + 2;

	task send_word(input integer idx);
		begin
			@(posedge clk_74a);
			bridge_addr <= idx * 4;
			bridge_wr_data <= {idx[15:0], 16'hA500} ^ {16'h0, idx[15:0]};
			bridge_wr <= 1;
			@(posedge clk_74a);
			bridge_wr <= 0;
			repeat (12) @(posedge clk_74a);
		end
	endtask

	// ---- ATA sector buffer model (ki_ata's 512-byte sector_buffer) ----------
	// Registered address, UNREGISTERED output on clk: sd_buff_din is
	// mem[addr registered at the previous posedge clk].
	reg [15:0] sector_mem [0:255];
	reg [12:0] sb_addr_r = 13'd0;
	wire [15:0] sb_din = sector_mem[sb_addr_r];
	assign sd_buff_din = sb_din;
	always @(posedge clk) sb_addr_r <= sd_buff_addr;

	integer i;
	integer failures = 0;
	reg [31:0] sector_rd [0:127];
	reg [31:0] rd_word;
	integer stall;

	task check_word(input integer k);
		reg [31:0] exp;
		reg [15:0] h_lo, h_hi;
		begin
			h_lo = 16'hA000 + 2*k;
			h_hi = 16'hA000 + 2*k + 1;
			exp  = {h_hi, h_lo};
			if (sector_rd[k] !== exp) begin
				failures = failures + 1;
				if (failures == 1)
					$display("FAIL_PK_IO_WRITE word %0d got %08x expected %08x",
					         k, sector_rd[k], exp);
			end
		end
	endtask

	// APF host read burst for a 0x0184 command: bridge_rd pulses for one
	// clk_74a cycle while bridge_addr points at word k; the address is then
	// advanced (burst) and disk_bridge_rd_data is sampled two clk_74a cycles
	// after the pulse.
	task burst_read;
		begin
			@(posedge clk_74a);
			for (i = 0; i < 128; i = i + 1) begin
				@(negedge clk_74a);
				bridge_addr = target_dataslot_bridgeaddr + 4*i;
				bridge_rd   = 1'b1;
				@(negedge clk_74a);
				bridge_rd   = 1'b0;
				bridge_addr = target_dataslot_bridgeaddr + 4*(i+1);
				@(negedge clk_74a);
				rd_word      = disk_bridge_rd_data;
				sector_rd[i] = rd_word;
			end
			@(negedge clk_74a);
			bridge_addr = 0;
		end
	endtask

	// ---- Scenario 3: ATA sector write (APF 0x0184) --------------------------
	// Runs in a separate process: the loader scenarios below reset the core.
	initial begin : wr_flow
		#200 loader_reset = 0;
		for (i = 0; i < 256; i = i + 1) sector_mem[i] = 16'hA000 + i;
		// The loader scenarios in the other initial block drive loader_reset
		// again shortly after the ROM stream, so this scenario runs on its own
		// timescale: wait for S_DONE, then issue sd_wr on the first clk edge
		// that samples st == S_DONE (pk_io only honours sd_wr there).
		@(posedge clk);
		while (dut.st != 4'd8) @(posedge clk);   // st == S_DONE

		sd_lba = 32'h0001_2345;
		sd_wr  = 1'b1;
		repeat (3) @(posedge clk);
		sd_wr  = 1'b0;

		// pk_io copies 256 halfwords from the modelled sector buffer (S_WR_WAIT0
		// .. S_WR_HI, ~11 clk per word), then raises the APF 0x0184 request
		// (disk_req_tog at S_WR_HI word 127). The host acknowledges it in
		// tcmd_st 2'd1; emulate that here.
		stall = 0;
		while (!target_dataslot_write) begin
			@(posedge clk_74a);
			stall = stall + 1;
			if (stall > 200000) begin
				$display("FAIL_PK_IO_WRITE request never raised");
				failures = failures + 1;
				disable wr_flow;
			end
		end
		// Host ack: one clk_74a cycle while the request is up.
		@(posedge clk_74a);
		target_dataslot_ack <= 1'b1;
		@(posedge clk_74a);
		target_dataslot_ack <= 1'b0;
		while (target_dataslot_write) @(posedge clk_74a);   // pk_io drops it
		if (target_dataslot_length !== 32'd512) begin
			$display("FAIL_PK_IO_WRITE bad length %0d", target_dataslot_length);
			failures = failures + 1;
		end
		if (target_dataslot_slotoffset !== 32'h2468_A00) begin
			$display("FAIL_PK_IO_WRITE bad slotoffset %08x", target_dataslot_slotoffset);
			failures = failures + 1;
		end

		burst_read;
		// done is a LEVEL: pulse it high, let pk_io close the transfer, then
		// drop it again so the next command is not closed by the same level.
		@(posedge clk_74a);
		target_dataslot_done <= 1'b1;
		repeat (10) @(posedge clk_74a);
		while (debug_disk_info[28] === 1'b1) @(posedge clk_74a);   // disk_active low
		target_dataslot_done <= 1'b0;
		repeat (10) @(posedge clk_74a);

		// The whole transfer must have closed cleanly: no timeout, no stuck
		// sd_ack, back in S_DONE.
		if (debug_disk_info[28] !== 1'b0 || debug_disk_info[29] !== 1'b0 ||
		    debug_disk_info[31] !== 1'b0 || dut.st !== 4'd8) begin
			$display("FAIL_PK_IO_WRITE handshake did not close (disk_active=%b sd_ack=%b timeout=%b st=%0d)",
			         debug_disk_info[28], debug_disk_info[29], debug_disk_info[31], dut.st);
			failures = failures + 1;
		end

		for (i = 0; i < 128; i = i + 1) check_word(i);
		if (failures == 0)
			$display("PASS_PK_IO_WRITE");
		$finish;
	end

	initial begin
		// Scenario 1: boot ROM only, then the APF end marker.
		#200 loader_reset = 0;
		#200;
		for (i = 0; i < (27'h80000 / 4); i = i + 1) send_word(i);
		repeat (100) @(posedge clk);
		$display("before end: bytes=%0d download=%b info=%08x", bytes_out, ioctl_download, debug_loader_info);
		loader_end = 1;
		repeat (200000) @(posedge clk);
		$display("after end:  bytes=%0d download=%b info=%08x", bytes_out, ioctl_download, debug_loader_info);
		if (bytes_out == 27'h80000 && !ioctl_download && debug_loader_info[1])
			$display("PASS_END_MARKER");
		else
			$display("FAIL_END_MARKER");

		// Scenario 2: abort in the middle of the stream.
		loader_reset = 1;
		loader_end = 0;
		repeat (10) @(posedge clk);
		loader_reset = 0;
		bytes_out = 0;
		repeat (20) @(posedge clk_74a);
		for (i = 0; i < 64; i = i + 1) send_word(i);
		repeat (100) @(posedge clk);
		loader_abort = 1;
		repeat (100) @(posedge clk);
		loader_abort = 0;
		$display("after abort: bytes=%0d download=%b info=%08x", bytes_out, ioctl_download, debug_loader_info);
		if (!ioctl_download && debug_loader_info[0])
			$display("PASS_ABORT");
		else
			$display("FAIL_ABORT");
		$finish;
	end
endmodule
