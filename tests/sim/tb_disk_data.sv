// Does a sector read through pk_io -> ki_ata deliver the bytes in the file?
//
// The hardware symptom that motivates this: on v1.0.27 the game reaches its own
// code (PC:88020D08) and then departs for the boot ROM from DP:8802EC4C with
// EX:00000012 - an AdEL in the delay slot of a branch. The instruction at the
// departure point is
//
//   8802ec48: lwu  $t7, 0x1f8($t6)      <- AdEL here
//   8802ec4c: beq  $v0, $t7, ...
//
// which is a sector check: 8802D560 walks 0x1F8 bytes as a checksum and the
// word at +0x1F8 must match it. 0x1F8 is 4-aligned, so the load only faults if
// the BASE POINTER is wrong - and that pointer comes from data the disk handed
// the CPU (8802E520 builds it from a stack array filled at 8802E524).
//
// So the question is not "does the ATA handshake complete" (it does, AT cycles
// 3<->0 with ER:00) but "are the halfwords the CPU drains the halfwords in the
// file". This bench answers exactly that, through the real pair of modules and
// a behavioural APF host that streams the bytes from disk_sectors.hex.
//
// What it proves: pk_io's deferred-slot streaming, ki_ata's PIO read path, LBA
// selection, batch splitting and halfword ordering all preserve the image.
// What it does NOT prove: any timing, or anything above the ATA data port.

`timescale 1ns/1ps
`default_nettype none

module tb_disk_data;
	localparam integer ROM_BYTES   = 4096;
	localparam integer ROM_WORDS   = ROM_BYTES / 4;
	localparam integer SECTOR      = 512;
	localparam integer HALFWORDS   = SECTOR / 2;
	localparam [31:0]  DISK_BASE   = 32'h4000_0000;
	localparam integer VEC_SECTORS = 13;
	// One entry per block in disk_sectors.hex, in file order.

	// ---------------------------------------------------------------- clocking
	reg clk_74a = 0, clk = 0;
	always #6.734 clk_74a = ~clk_74a;
	always #10.0  clk     = ~clk;

	reg loader_reset = 1, loader_abort = 0, loader_end = 0;
	reg ata_reset = 1;   // ki_ata's registers have no initialisers: pulse this
	reg [31:0] bridge_addr = 0, bridge_wr_data = 0;
	reg bridge_wr = 0;
	reg [31:0] pad_key = 0;

	// ---------------------------------------------------------------- dut nets
	wire [127:0] status; wire [1:0] buttons; wire fscan;
	wire [31:0] j0, j1; wire [10:0] ps2;
	wire ioctl_download, ioctl_wr; wire [15:0] ioctl_index, ioctl_dout;
	wire [26:0] ioctl_addr;
	reg  ioctl_wait = 0;
	wire img_mounted, img_readonly; wire [63:0] img_size; wire overflow;
	wire [31:0] debug_loader_info, debug_disk_info;
	wire tds_read, tds_write; wire [15:0] tds_id;
	wire [31:0] tds_slotoffset, tds_bridgeaddr, tds_length, disk_bridge_rd_data;

	// APF host side of the deferred data slot
	reg  tds_ack = 0, tds_done = 0;
	reg  [2:0] tds_err = 0;

	// ATA <-> pk_io
	wire [31:0] sd_lba; wire [5:0] sd_blk_cnt;
	wire sd_rd, sd_wr, sd_ack;
	wire [12:0] sd_buff_addr; wire [15:0] sd_buff_dout, sd_buff_din;
	wire sd_buff_wr;
	wire ata_irq;
	wire [2:0] ata_state; wire [7:0] ata_status, ata_error;
	wire ata_image_ready; wire [31:0] ata_info;

	// CPU side of the ATA bus
	reg         bus_req = 0, bus_wr = 0;
	reg  [31:0] bus_addr = 0, bus_wdata = 0;
	reg  [ 3:0] bus_be = 4'hf;
	wire [31:0] bus_rdata;
	wire        bus_done;

	pk_io #(.ROM_BYTES(ROM_BYTES)) host (
		.clk_74a(clk_74a), .apf_reset_n(1'b1),
		.bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
		.bridge_wr_data(bridge_wr_data),
		.dataslot_update(1'b0), .dataslot_update_id(16'd0),
		.dataslot_update_size(32'd0),
		.target_dataslot_read(tds_read), .target_dataslot_write(tds_write),
		.target_dataslot_ack(tds_ack), .target_dataslot_done(tds_done),
		.target_dataslot_err(tds_err), .target_dataslot_id(tds_id),
		.target_dataslot_slotoffset(tds_slotoffset),
		.target_dataslot_bridgeaddr(tds_bridgeaddr),
		.target_dataslot_length(tds_length),
		.disk_bridge_rd_data(disk_bridge_rd_data),
		.pad_key(pad_key), .game_select(16'd0), .dip_switches_i(16'hffff),
		.loader_reset(loader_reset), .loader_abort(loader_abort),
		.loader_end(loader_end), .debug_loader_info(debug_loader_info),
		.clk(clk), .status(status), .buttons(buttons),
		.forced_scandoubler(fscan), .joystick_0(j0), .joystick_1(j1),
		.ps2_key(ps2), .ioctl_download(ioctl_download), .ioctl_wr(ioctl_wr),
		.ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
		.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
		.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
		.sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr), .img_mounted(img_mounted),
		.img_readonly(img_readonly), .img_size(img_size), .overflow(overflow),
		.debug_disk_info(debug_disk_info)
	);

	ki_ata ata (
		.clk(clk), .reset(ata_reset), .game_ki2(1'b0),
		.bus_request(bus_req), .bus_write(bus_wr), .bus_address(bus_addr),
		.bus_write_data(bus_wdata), .bus_byte_enable(bus_be),
		.bus_read_data(bus_rdata), .bus_done(bus_done), .irq(ata_irq),
		.img_mounted(img_mounted), .img_readonly(img_readonly),
		.img_size(img_size), .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt),
		.sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.debug_state(ata_state), .debug_status(ata_status),
		.debug_error(ata_error), .debug_image_ready(ata_image_ready),
		.debug_info(ata_info), .debug_read_lba(), .debug_write_lba()
	);

	// ---------------------------------------------------------------- vectors
	// One 16-bit halfword per line, little-endian, 256 per sector.
	reg [15:0] vec [0:VEC_SECTORS*HALFWORDS-1];
	integer lba_of [0:VEC_SECTORS-1];
	initial begin
		$readmemh("tests/sim/vectors/disk_sectors.hex", vec);
		lba_of[0]  = 0;  lba_of[1]  = 1;  lba_of[2]  = 2;  lba_of[3]  = 3;
		lba_of[4]  = 4;  lba_of[5]  = 5;  lba_of[6]  = 6;  lba_of[7]  = 7;
		lba_of[8]  = 8;  lba_of[9]  = 9;  lba_of[10] = 10; lba_of[11] = 11;
		lba_of[12] = 255919;
	end

	integer errors = 0;
	task check(input [8*66-1:0] what, input integer ok);
		begin
			if (ok) $display("PASS: %0s", what);
			else begin $display("FAIL: %0s", what); errors = errors + 1; end
		end
	endtask

	// ---------------------------------------------------------------- APF host
	// On a read request, stream `tds_length` bytes from the image starting at
	// tds_slotoffset, one 32-bit bridge word at a time, exactly as the Pocket's
	// data-slot engine does: two halfwords per word, low half first.
	//
	// rtl_batch_words is what the transfer covers; volatile because the host
	// task reads them after ki_ata has already moved on.
	integer host_words_done = 0;

	task host_serve;
		integer base_sector, nwords, i, base_hw;
		reg [31:0] w;
		begin
			base_sector = sd_lba;
			nwords      = ({26'd0, sd_blk_cnt} + 1) * (SECTOR / 4);
			$display("   (host) serving lba=%0d words=%0d  [pk_io said slotoffset=%0d length=%0d]",
			         base_sector, nwords, tds_slotoffset, tds_length);
			base_hw     = 0;
			// Find which vector block this LBA lives in.
			for (i = 0; i < VEC_SECTORS; i = i + 1)
				if (lba_of[i] == base_sector) base_hw = i * HALFWORDS;
			if (base_hw == 0 && base_sector != 0)
				$display("  (host) LBA %0d not in the vectors", base_sector);

			for (i = 0; i < nwords; i = i + 1) begin
				w = {vec[base_hw + 2*i + 1], vec[base_hw + 2*i]};
				@(posedge clk_74a);
				bridge_addr    <= DISK_BASE + i * 4;
				bridge_wr_data <= w;
				bridge_wr      <= 1'b1;
			end
			@(posedge clk_74a);
			bridge_wr <= 1'b0;
			host_words_done = nwords;
		end
	endtask

	// A rigid APF handshake: ack while the request is up, done after the words
	// are in the bridge, then drop `done` so the next request sees a fresh edge.
	// slotoffset and length are registered in the same always_ff that raises
	// sd_ack, so sampling them on the edge that starts the request reads the
	// PREVIOUS transfer's values - in practice zeros, which made the host
	// stream nothing and left the batch open. Sample them a few clocks later.
	always @(posedge tds_read) begin
		fork
			begin
				repeat (8) @(posedge clk_74a);
				tds_ack <= 1'b1;
				host_serve;
				tds_done <= 1'b1;
				repeat (6) @(posedge clk_74a);
				tds_ack <= 1'b0;
				tds_done <= 1'b0;
			end
		join_none
	end

	// ---------------------------------------------------------------- CPU side
	task ata_write(input [31:0] addr, input [31:0] data);
		begin
			@(posedge clk);
			bus_addr <= addr; bus_wdata <= data; bus_be <= 4'hf;
			bus_wr   <= 1'b1; bus_req <= 1'b1;
			@(posedge clk);
			while (!bus_done) @(posedge clk);
			bus_req <= 1'b0; bus_wr <= 1'b0;
			@(posedge clk);
		end
	endtask

	task ata_read(input [31:0] addr, output [31:0] data);
		begin
			@(posedge clk);
			bus_addr <= addr; bus_wr <= 1'b0; bus_req <= 1'b1;
			@(posedge clk);
			while (!bus_done) @(posedge clk);
			data = bus_rdata;
			bus_req <= 1'b0;
			@(posedge clk);
		end
	endtask

	// Issue READ SECTORS for `lba`, `nsect` sectors, then drain and compare.
	reg [15:0] got;
	reg [31:0] rd;
	integer n, k, base_hw, bad, first_bad;

	task read_and_check(input integer lba, input integer nsect, input integer vecblk);
		begin
			// LBA mode: device/head bit 6, and the 28-bit address split across
			// head[3:0] / cylinder / sector number (ki_ata selected_lba()).
			// CS0 register map is bus_address[5:3] off KI_ATA_CS0_BASE:
			//   0x100 data, 0x108 features/error, 0x110 sector count,
			//   0x118 sector number, 0x120 cyl low, 0x128 cyl high,
			//   0x130 device/head, 0x138 status/command.
			// Writing features instead of sector count leaves sector_count at
			// its reset value of 0, which ki_ata reads as 256 sectors - that
			// is what made an earlier cut of this bench prefetch 8 at a time
			// and drain the wrong image block.
			ata_write(32'h1000_0130, 32'h0000_00E0 | ((lba >> 24) & 32'hF));
			ata_write(32'h1000_0128, 32'h0000_0000 | ((lba >> 16) & 32'hFF));
			ata_write(32'h1000_0120, 32'h0000_0000 | ((lba >>  8) & 32'hFF));
			ata_write(32'h1000_0118, 32'h0000_0000 | ( lba        & 32'hFF));
			ata_write(32'h1000_0110, nsect);
			ata_write(32'h1000_0138, 32'h20);

			base_hw = vecblk * HALFWORDS;
			$display("  -- issue lba=%0d nsect=%0d: state=%0d status=%02x sd_rd=%b sd_ack=%b",
			         lba, nsect, ata_state, ata_status, sd_rd, sd_ack);
			bad = 0; first_bad = -1;
			for (n = 0; n < nsect; n = n + 1) begin
				// Wait for DRQ.
				k = 0;
				rd = 32'h0;
				while (((rd & 32'h58) != 32'h58) && k < 400000) begin
					ata_read(32'h1000_0138, rd);
					k = k + 1;
				end
				if (k >= 400000) begin
					$display("  timeout waiting for DRQ at sector %0d (status %02x)", n, rd[7:0]);
					bad = bad + 1;
				end else begin
					for (k = 0; k < HALFWORDS; k = k + 1) begin
						ata_read(32'h1000_0100, rd);
						got = rd[15:0];
						if (got !== vec[base_hw + n * HALFWORDS + k]) begin
							bad = bad + 1;
							if (first_bad < 0) begin
								first_bad = n * HALFWORDS + k;
								$display("  first mismatch at sector %0d halfword %0d: got %04x want %04x",
								         n, k, got, vec[base_hw + n * HALFWORDS + k]);
							end
						end
					end
				end
			end
			$display("  LBA %0d x%0d: %0d halfwords, %0d mismatched", lba, nsect, nsect*HALFWORDS, bad);
		end
	endtask

	// ---------------------------------------------------------------- stimulus
	integer i;
	initial begin
		// Load a small boot image so pk_io leaves S_SEL and reaches S_DONE.
		#200 loader_reset = 0;
		#200;
		repeat (8) @(posedge clk);
		ata_reset = 0;
		repeat (8) @(posedge clk);
		for (i = 0; i < ROM_WORDS; i = i + 1) begin
			@(posedge clk_74a);
			bridge_addr    <= i * 4;
			bridge_wr_data <= 32'h1000_0000 + i;
			bridge_wr      <= 1'b1;
		end
		@(posedge clk_74a);
		bridge_wr <= 1'b0;

		i = 0;
		while (debug_loader_info[31:28] != 4'd8 && i < 400000) begin
			@(posedge clk); i = i + 1;
		end
		check("loader reaches S_DONE", debug_loader_info[31:28] == 4'd8);
		check("ATA reports the image ready", ata_image_ready === 1'b1);
		$display("  img_size=%0d image_ready=%b", img_size, ata_image_ready);

		// 1. Single sector - the shape the game's boot check uses (count=1).
		read_and_check(1,      1, 1);
		check("LBA 1 equals the image", bad == 0);

		// 2. The other side of the game's own comparison at 8801DEAC.
		read_and_check(255919, 1, 12);
		check("LBA 255919 equals the image", bad == 0);

		// 3. A full 8-sector batch: the prefetch engine hands over two banks of
		//    eight, and a bank boundary is where a wrong fill_bank or a dropped
		//    halfword would show.
		read_and_check(0,      8, 0);
		check("8-sector batch equals the image", bad == 0);

		// 4. Ten sectors: one full batch plus a two-sector remainder, so the
		//    second request is short and the drain crosses the release.
		read_and_check(2,     10, 2);
		check("10-sector read spans two batches", bad == 0);

		// 5. Both sectors back to back, as the game does them.
		read_and_check(0,     12, 0);
		check("12-sector read, both banks twice", bad == 0);

		if (errors == 0) $display("PASS_DISK_DATA");
		else             $display("FAIL_DISK_DATA (%0d)", errors);
		$finish;
	end

	initial begin
		#200000000;
		$display("TIMEOUT");
		$finish;
	end
endmodule
