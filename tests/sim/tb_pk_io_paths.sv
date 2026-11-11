`timescale 1ns/1ps
`default_nettype none


module tb_pk_io_paths;
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
	wire [15:0] target_dataslot_id;
	wire [31:0] target_dataslot_slotoffset, target_dataslot_bridgeaddr, target_dataslot_length;
	wire [31:0] disk_bridge_rd_data;

	pk_io #(.ROM_BYTES(4718592)) dut (
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

	integer i;
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
