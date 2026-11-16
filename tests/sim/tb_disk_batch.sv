// Regression for the ATA batch close condition in pk_io's S_DONE.
//
// ki_ata marks a WHOLE 8-sector bank valid on the falling edge of sd_ack and
// never counts the words that arrived:
//
//   if (fetch_busy && !sd_ack && sd_ack_d) begin
//     bank_valid[fill_bank] <= 1'b1;
//     bank_count[fill_bank] <= fetch_batch;      // the full batch, unverified
//
// So if pk_io lowers sd_ack before every halfword of the batch has landed, the
// CPU drains sectors that were never written and the game's own comparison of
// LBA 1 against LBA 255919 at 8801DEAC fails with "CHECK SUM SECTORS
// CORRUPTED". Two hardware sightings read disk_words_rem as 482 and 1056
// between transfers - 6.12 and 3.88 sectors of 8, cut mid-sector and at
// different points, which is a timing cut and not an accounting error.
//
// This bench emulates an APF deferred-slot read that reports `done` early: it
// streams part of an 8-sector batch and then completes the APF handshake. The
// close must NOT happen until the remaining halfwords arrive.

`timescale 1ns/1ps
`default_nettype none

module tb_disk_batch;
	// A small ROM so S_DONE is reached in a few microseconds. The exact byte
	// count in S_POST finishes the loader; the end-marker path is not used, so
	// BOOT_BYTES_MIN does not apply.
	localparam integer ROM_BYTES  = 4096;
	localparam integer ROM_WORDS   = ROM_BYTES / 4;
	localparam [31:0]  DISK_BASE   = 32'h4000_0000;
	localparam integer BATCH_WORDS = 1024;   // 8 sectors, 2 halfwords per word
	localparam integer SHORT_WORDS = 300;    // what the short transfer delivers

	reg clk_74a = 0, clk = 0, loader_reset = 1, loader_abort = 0, loader_end = 0;
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0;
	reg [31:0] pad_key = 0;
	wire [31:0] debug_loader_info;

	wire [127:0] status; wire [1:0] buttons; wire forced_scandoubler;
	wire [31:0] joystick_0, joystick_1; wire [10:0] ps2_key;
	wire ioctl_download, ioctl_wr; wire [15:0] ioctl_index, ioctl_dout; wire [26:0] ioctl_addr;
	reg ioctl_wait = 0;
	reg sd_rd = 0, sd_wr = 0; reg [31:0] sd_lba = 0; reg [5:0] sd_blk_cnt = 0;
	wire sd_ack; wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout;
	reg [15:0] sd_buff_din = 0; wire sd_buff_wr; wire img_mounted, img_readonly;
	wire [63:0] img_size; wire overflow; wire [31:0] debug_disk_info;
	wire target_dataslot_read, target_dataslot_write;
	reg  target_dataslot_ack = 0, target_dataslot_done = 0;
	wire [15:0] target_dataslot_id;
	wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
	wire [31:0] disk_bridge_rd_data;

	pk_io #(.ROM_BYTES(ROM_BYTES)) dut (
		.clk_74a(clk_74a), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
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
	always #10.0  clk     = ~clk;

	integer errors = 0;
	task check(input [8*72-1:0] what, input integer ok);
		begin
			if (ok) $display("PASS: %0s", what);
			else begin $display("FAIL: %0s", what); errors = errors + 1; end
		end
	endtask

	// One APF bridge write. The FIFO is 8192 deep and a batch is 1024 words, so
	// the whole batch fits and the drain can lag without overflowing.
	task send_bridge(input [31:0] addr, input [31:0] data);
		begin
			@(posedge clk_74a);
			bridge_addr    <= addr;
			bridge_wr_data <= data;
			bridge_wr      <= 1'b1;
			@(posedge clk_74a);
			bridge_wr      <= 1'b0;
		end
	endtask

	integer i;

	initial begin
		// ---- 1. load the (short) boot ROM so pk_io enters S_DONE ----------
		#200 loader_reset = 0;
		#200;
		for (i = 0; i < ROM_WORDS; i = i + 1)
			send_bridge(i * 4, 32'h1000_0000 + i);

		i = 0;
		while (debug_loader_info[31:28] != 4'd8 && i < 200000) begin
			@(posedge clk); i = i + 1;
		end
		check("loader reaches S_DONE", debug_loader_info[31:28] == 4'd8);

		// ---- 2. an 8-sector READ SECTORS --------------------------------
		@(posedge clk);
		sd_lba     <= 32'd1;
		sd_blk_cnt <= 6'd7;
		sd_rd      <= 1'b1;
		@(posedge clk);
		sd_rd <= 1'b0;

		// The APF command pulse: one clk_74a cycle with `done` low, which is
		// the normal shape (tcmd_st=1 exits on !done).
		@(posedge target_dataslot_read);
		repeat (4) @(posedge clk_74a);

		check("the read request opened a batch", sd_ack === 1'b1);
		check("the batch expects 2048 halfwords", dut.disk_words_rem == 13'd2048);

		// ---- 3. the short transfer: 300 of 1024 words, then `done` -------
		for (i = 0; i < SHORT_WORDS; i = i + 1)
			send_bridge(DISK_BASE + i * 4, 32'hA5A5_0000 + i);

		// Let the drain catch up first. This matters: while the FIFO still holds
		// words, S_DONE takes the fifo_rd branch and never reaches the close, so
		// the early-done race only shows up with an EMPTY FIFO - which is exactly
		// how it happens on hardware, between two bursts of the same transfer.
		i = 0;
		while (dut.fifo_empty !== 1'b1 && i < 200000) begin
			@(posedge clk); i = i + 1;
		end
		$display("fifo drained at words_rem=%0d", dut.disk_words_rem);

		target_dataslot_done <= 1'b1;
		repeat (4) @(posedge clk_74a);
		target_dataslot_ack  <= 1'b1;
		repeat (4) @(posedge clk_74a);
		target_dataslot_ack  <= 1'b0;
		repeat (60) @(posedge clk);
		target_dataslot_done <= 1'b0;

		$display("short batch: sd_ack=%b disk_active=%b words_rem=%0d fifo_empty=%b",
		         sd_ack, dut.disk_active, dut.disk_words_rem, dut.fifo_empty);

		// THE POINT OF THE BENCH. `done` arrived and the APF handshake is
		// complete, but 1448 halfwords of the batch were never delivered.
		// Closing here hands ki_ata a bank it will mark fully valid.
		check("sd_ack stays high while the batch is incomplete", sd_ack === 1'b1);
		check("the batch is still owned by the disk", dut.disk_active === 1'b1);
		check("no timeout was reported", dut.disk_timeout === 1'b0);

		// ---- 4. the rest of the batch arrives ----------------------------
		for (i = SHORT_WORDS; i < BATCH_WORDS; i = i + 1)
			send_bridge(DISK_BASE + i * 4, 32'h5A5A_0000 + i);

		i = 0;
		while (sd_ack === 1'b1 && i < 200000) begin
			@(posedge clk); i = i + 1;
		end
		$display("after the full batch: sd_ack=%b disk_active=%b words_rem=%0d",
		         sd_ack, dut.disk_active, dut.disk_words_rem);
		check("sd_ack falls once every halfword arrived", sd_ack === 1'b0);
		check("the batch is released", dut.disk_active === 1'b0);
		check("the batch closed on the count, not on the watchdog",
		      dut.disk_timeout === 1'b0);

		if (errors == 0) $display("PASS_DISK_BATCH");
		else             $display("FAIL_DISK_BATCH (%0d)", errors);
		$finish;
	end
endmodule
