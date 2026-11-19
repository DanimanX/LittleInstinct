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
	localparam integer VEC_SECTORS = 29;   // 13 file blocks + the latent ones
	// 'Overtaken read': the host holds the answer to the batch for LBA 5 back
	// by this many clk_74a cycles (as a real APF round trip would). Override
	// with -P tb_disk_data.HOST_DELAY_CYCLES=N / HOST_WORD_GAP=N / CLK_NS=N.
	parameter integer  HOST_DELAY_CYCLES = 2000;
	parameter integer  HOST_WORD_GAP     = 0;
	// clk period in ns. 100 is the 100 ns this bench always used; 40 is the
	// runner-up ratio the overtaken-read scenario was probed at (see its note).
	parameter real     CLK_NS           = 40.0;

	// ---------------------------------------------------------------- clocking
	reg clk_74a = 0, clk = 0;
	always #6.734 clk_74a = ~clk_74a;
	always #(CLK_NS/2.0) clk = ~clk;

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
	wire ata_sd_rd, sd_wr, sd_ack;
	// The bench may drive sd_rd itself to stand in for pk_io's S_DONE latch
	// (it samples the level, not ki_ata's one-cycle pulse).
	reg  sd_rd_drv = 1'b0;
	wire sd_rd = sd_rd_drv ? 1'b1 : ata_sd_rd;
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
		.sd_rd(ata_sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
		.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
		.debug_state(ata_state), .debug_status(ata_status),
		.debug_error(ata_error), .debug_image_ready(ata_image_ready),
		.debug_info(ata_info), .debug_read_lba(), .debug_write_lba()
	);

	// ---------------------------------------------------------------- vectors
	// One 16-bit halfword per line, little-endian, 256 per sector.
	//
	// The image file on disk carries four blocks (0, 1, 2, 255919); the extra
	// LBAs the overtaken-read scenario needs are not in it. Synthesise them
	// deterministically here rather than shipping more image content, and check
	// disjointly: every LBA this bench compares must differ from the two LBAs
	// the late batch carries, or a stale write would compare equal and the
	// scenario would pass for the wrong reason.
	reg vectors_ready = 1'b0;
	integer errors = 0;
	// Exactly as many words as disk_sectors.hex holds: $readmemh stops at the
	// end of the file and leaves the remainder X, so an oversized array is a
	// silent source of x's in every comparison that reaches past the file.
	localparam integer FILE_BLOCKS = 4;
	reg [15:0] filev [0:FILE_BLOCKS*HALFWORDS-1];
	// The tasks below are NOT automatic, so this table lives in their scope.
	reg [15:0] vec   [0:VEC_SECTORS*HALFWORDS-1];
	integer lba_of [0:VEC_SECTORS-1];
	integer vi, wi;
	function [15:0] synth(input integer lba, input integer idx);
		synth = 16'h1000 ^ (lba[15:0] << 4) ^ idx[15:0];
	endfunction
	initial begin
		$readmemh("tests/sim/vectors/disk_sectors.hex", filev);
		lba_of[0]  = 0;  lba_of[1]  = 1;  lba_of[2]  = 2;  lba_of[3]  = 3;
		lba_of[4]  = 4;  lba_of[5]  = 5;  lba_of[6]  = 6;  lba_of[7]  = 7;
		lba_of[8]  = 8;  lba_of[9]  = 9;  lba_of[10] = 10; lba_of[11] = 11;
		lba_of[12] = 255919;
		// LBAs the older scenarios drain from the second half of a batch.
		lba_of[13] = 10; lba_of[14] = 8; lba_of[15] = 9;
		// The overtaken-read batches: A = the late, superseded command's sectors,
		// B = the ones the CPU must actually receive.
		for (vi = 0; vi < 7; vi = vi + 1) lba_of[16 + vi] = 5 + vi;   // A batch
		for (vi = 0; vi < 7; vi = vi + 1) lba_of[23 + vi] = 12 + vi;  // B batch
		for (vi = 0; vi < VEC_SECTORS; vi = vi + 1)
			for (wi = 0; wi < HALFWORDS; wi = wi + 1)
				vec[vi*HALFWORDS + wi] = (vi < FILE_BLOCKS) ? filev[vi*HALFWORDS + wi]
				                                   : synth(lba_of[vi], wi);
		// Fail loudly rather than comparing against x's: the image blocks must
		// have loaded, and the synthetic LBAs must be reached.
		for (vi = 0; vi < VEC_SECTORS; vi = vi + 1)
			if (^vec[vi*HALFWORDS] === 1'bx) begin
				$display("  (bench) vector block %0d (lba %0d) is x", vi, lba_of[vi]);
				errors = errors + 1;
			end
		vectors_ready = 1'b1;
	end

	integer scn_err;
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
	// Host requests arrive as a queue, not a rendezvous: a request made while
	// the host is still busy is answered only after the one in flight.
	integer host_busy_req = 0;
	integer host_reqs     = 0;
	integer host_delay    = 0;   // extra clk_74a cycles before this answer
	// Extra clk_74a cycles between bridge words, and a hold that keeps the host
	// off the bridge until the scenario has seen its request go out. Both are
	// module variables named apart from the task arguments on purpose: iverilog
	// resolved same-named task arguments to these, silently.
	integer word_gap_m = 0;   // gap in use (0 restores the old straight-through host)
	integer word_hold  = 0;

	task host_serve;
		integer base_sector, nwords, i, base_hw, t0;
		reg [31:0] w;
		begin
			if (host_delay > 0) repeat (host_delay) @(posedge clk_74a);
			while (word_hold != 0) @(posedge clk_74a);
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

			// word_gap_m: extra clk_74a cycles between bridge words, so the
			// overtaken-read scenario can probe a host that streams slower than
			// pk_io's drain; 0 is the straight-through host the older cases use.
			t0 = $time;
			for (i = 0; i < nwords; i = i + 1) begin
				w = {vec[base_hw + 2*i + 1], vec[base_hw + 2*i]};
				repeat (word_gap_m) @(posedge clk_74a);
				@(posedge clk_74a);
				bridge_addr    <= DISK_BASE + i * 4;
				bridge_wr_data <= w;
				bridge_wr      <= 1'b1;
			end
			@(posedge clk_74a);
			bridge_wr <= 1'b0;
			host_words_done = nwords;
			$display("   (host) lba=%0d streamed %0d words in %.1f us; at the last word: FIFO %0d, disk_words_rem %0d, ack %b, active %b, state %0d",
			         base_sector, nwords, ($time - t0) / 1000.0, host.fifo.rdusedw,
			         host.disk_words_rem, sd_ack, host.disk_active, host.st);
		end
	endtask

	// A rigid APF handshake: ack while the request is up, done after the words
	// are in the bridge, then drop `done` so the next request sees a fresh edge.
	// slotoffset and length are registered in the same always_ff that raises
	// sd_ack, so sampling them on the edge that starts the request reads the
	// PREVIOUS transfer's values - in practice zeros, which made the host
	// stream nothing and left the batch open. Sample them a few clocks later.
	always @(posedge tds_read) begin
		host_reqs = host_reqs + 1;
		if (host_busy_req) begin
			$display("  (host) request at t=%0t queued behind the one in flight (sd_lba=%0d)",
			         $time, sd_lba);
		end else fork
			begin
				host_busy_req = 1;
				repeat (8) @(posedge clk_74a);
				tds_ack <= 1'b1;
				host_serve;
				tds_done <= 1'b1;
				repeat (6) @(posedge clk_74a);
				tds_ack <= 1'b0;
				tds_done <= 1'b0;
				host_busy_req = 0;
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


	// ------------------------------------------- overtaken read (LBA A -> B)
	// ki_ata's fetch_orphan flag exists for this shape: the Pocket's APF round
	// trip is ~45 ms against a CPU that issues its next READ as soon as the
	// previous one is drained, so a batch can be OVERTAKEN - the host still owes
	// the core the sectors of a command the driver has already replaced. If
	// those stale halfwords land in the new command's bank, the CPU reads another
	// LBA's sectors (KI's record copy at LBA 12 never checksums and the game
	// loops).
	//
	// The host really holds A: it is off the bridge until A has gone out, then
	// answers A (with A's image) only after B's command byte. The CPU then drains
	// B and every halfword is compared against LBAs lba_b .. lba_b+blk_b.
	task overtaken_read(input integer lba_a, input integer blk_a,
	                    input integer lba_b, input integer blk_b,
	                    input integer delay_cyc, input integer word_gap);
		integer r, vecblk, got_hw, want_hw, nsect, s_i, k, n, ncmp;
		reg [31:0] rd;

		begin
			vecblk = 0;
			for (r = 0; r < VEC_SECTORS; r = r + 1)
				if (lba_of[r] == lba_b) vecblk = r;
			nsect = blk_b + 1;

			$display("  -- overtaken read: A=lba%0d x%0d, then B=lba%0d x%0d, host delay %0d, word gap %0d clk_74a",
			         lba_a, nsect, lba_b, nsect, delay_cyc, word_gap);
			host_reqs  = 0;
			host_delay = 0;      // A is not delayed by time at first...
			word_gap_m = word_gap;

			// A: LBA registers, then READ SECTORS.
			ata_write(32'h1000_0130, 32'h0000_00E0 | ((lba_a >> 24) & 32'hF));
			ata_write(32'h1000_0128, 32'h0000_0000 | ((lba_a >> 16) & 32'hFF));
			ata_write(32'h1000_0120, 32'h0000_0000 | ((lba_a >>  8) & 32'hFF));
			ata_write(32'h1000_0118, 32'h0000_0000 | ( lba_a        & 32'hFF));
			ata_write(32'h1000_0110, nsect);
			ata_write(32'h1000_0138, 32'h20);

			// ... but held off the bridge until the fetch engine has really put
			// A on the wire, so the late answer is A's.
			word_hold = 1;
			n = 0;
			while (!(sd_rd === 1'b1 && sd_ack === 1'b0) && n < 20000) begin
				@(posedge clk); n = n + 1;
			end
			word_hold = 0;
			$display("    A on the wire: sd_rd=%b state=%0d sd_ack=%b t=%0t",
			         sd_rd, ata_state, sd_ack, $time);
			// pk_io's S_DONE is level-sensitive, so the batch need not be latched
			// on the cycle ki_ata pulses sd_rd: hold sd_rd for the bench only
			// until the host has taken A, then hand the pin back to ki_ata (which
			// is sitting in sd_ack waiting for exactly that answer).
			if (host_reqs == 0) begin
				@(posedge clk);
				sd_rd_drv = 1'b1;
				n = 0;
				while (host_reqs == 0 && n < 20000) begin
					@(posedge clk); n = n + 1;
				end
				@(posedge clk);
				sd_rd_drv = 1'b0;
			end
			check("the overtaken batch was requested from the host", host_reqs == 1);
			$display("    A held: sd_rd=%b sd_ack=%b reqs=%0d t=%0t", sd_rd, sd_ack, host_reqs, $time);

			// B overtakes A, exactly as the driver does it: rewrite the LBA and
			// count registers, then issue command 0x20 again. From here the host
			// delay is armed, so A's answer and then B's are late by `delay_cyc`.
			host_delay = delay_cyc;
			ata_write(32'h1000_0130, 32'h0000_00E0 | ((lba_b >> 24) & 32'hF));
			ata_write(32'h1000_0128, 32'h0000_0000 | ((lba_b >> 16) & 32'hFF));
			ata_write(32'h1000_0120, 32'h0000_0000 | ((lba_b >>  8) & 32'hFF));
			ata_write(32'h1000_0118, 32'h0000_0000 | ( lba_b        & 32'hFF));
			ata_write(32'h1000_0110, nsect);
			ata_write(32'h1000_0138, 32'h20);

			// The host now answers A (its bytes are A's image) and then B.
			n = 0;
			while (host_reqs < 2 && n < 400000) begin
				@(posedge clk); n = n + 1;
			end
			check("the new command was also requested from the host", host_reqs == 2);

			n = 0;
			rd = 32'h0;
			while (((rd & 32'h58) != 32'h58) && n < 400000) begin
				ata_read(32'h1000_0138, rd);
				n = n + 1;
			end
			$display("    DRQ after the host answered: t=%0t status=%02x reqs=%0d",
			         $time, rd[7:0], host_reqs);

			// Drain the whole of B and compare every halfword against LBAs
			// lba_b .. lba_b+blk_b.
			scn_err = 0;
			ncmp    = 0;
			for (s_i = 0; s_i < nsect; s_i = s_i + 1) begin
				n = 0;
				rd = 32'h0;
				while (((rd & 32'h58) != 32'h58) && n < 400000) begin
					ata_read(32'h1000_0138, rd);
					n = n + 1;
				end
				if (n >= 400000) begin
					scn_err = scn_err + 1;
					if (scn_err == 1)
						$display("  first mismatch: sector %0d index - got no DRQ expected data",
						         s_i);
				end else begin
					for (k = 0; k < HALFWORDS; k = k + 1) begin
						ata_read(32'h1000_0100, rd);
						got_hw  = rd[15:0];
						want_hw = vec[(vecblk + s_i) * HALFWORDS + k];
						ncmp    = ncmp + 1;
						if (got_hw !== want_hw) begin
							scn_err = scn_err + 1;
							if (scn_err == 1)
								$display("  first mismatch: sector %0d index %0d got %04x expected %04x",
								         s_i, k, got_hw, want_hw);
						end
					end
				end
			end
			$display("    drained %0d halfwords of lba%0d..%0d, %0d mismatched",
			         ncmp, lba_b, lba_b + blk_b, scn_err);
			check("every halfword of B equals the image",
			      scn_err == 0 && ncmp == nsect * HALFWORDS);
		end
	endtask

	// ---------------------------------------------------------------- stimulus	// ---------------------------------------------------------------- stimulus	// ---------------------------------------------------------------- stimulus
	integer i;
	initial begin
		wait (vectors_ready === 1'b1);
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

		scn_err = 0;
		if (!loader_abort) begin
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

		// 6. The overtaken read: a batch the host answers only after the next
		//    command has superseded it. The drain must carry B's sectors and
		//    nothing of A's.
		overtaken_read(5, 6, 12, 6, HOST_DELAY_CYCLES, HOST_WORD_GAP);
		check("overtaken read: drain is B's image, not A's", scn_err == 0);
		$display("%0s", (scn_err == 0) ? "PASS_OVERTAKEN_READ" : "FAIL_OVERTAKEN_READ");
		end else begin
			$display("  (loader aborted: overtaken-read scenario skipped)");
		end

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
