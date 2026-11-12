// pk_io: the Analogue Pocket replacement for MiSTer's hps_io.
//
// The MiSTer shell gives the core a 46-bit HPS_BUS carrying ioctl downloads,
// OSD settings, pad input and a block device. The Pocket has none of that: it
// has the APF bridge, data slots and a pad controller. This module presents the
// same *core-facing* interface (ioctl_*, status, joystick, ps2_key, sd_*) so
// KillerInstinct.sv needs no other change, and fills it from the APF side.
//
// DATAPATH
//   clk_74a  : APF bridge writes for the ROM slot arrive here (32-bit words at
//              the slot's data.json address). bridge_endian_little = 1, so file
//              byte 4k is in bridge_wr_data[7:0].
//   clk      : clk_core (50 MHz). The core consumes ioctl_dout 16 bits at a
//              time, paced by ioctl_wait.
//   Crossing : a dual-clock FIFO of whole bridge words. Each entry yields two
//              ioctl words (low half then high half), which is the byte order
//              the core expects (upstream: ioctl_dout = {byte 2n, byte 2n+1}).
//
// WHAT IS AND IS NOT IMPLEMENTED
//   ROM slot      : full path. 4,718,592 bytes = 0x480000, exactly the size
//                   data.json declares, streamed as ioctl index 0x0001 (the
//                   boot ROM + DCS image the core's download FSM expects).
//   game selector : one word at index 0x0000, emitted before the image, taken
//                   from a register the APF could drive. KI1 = 0.
//   DIP switches  : one word at index 0x00FE, defaulting to 0xFFFF (all off).
//   disk image    : ATA sector reads via APF deferred data slot 2 (0x0180).
//                   Bridge writes to 0x4000_0000..0x4000_3FFF stream 16-bit
//                   sector words into ki_ata's sector_buffer via sd_buff_*.
//   OSD / status  : status is tied to 0 (no core settings yet), joystick and
//                   ps2_key come from the APF pad controller.
`default_nettype none

module pk_io #(
	// Exactly the ROM image size data.json declares.
	parameter integer ROM_BYTES    = 4718592,
	parameter [15:0]  DISK_SLOT_ID = 16'd2,
	parameter [31:0]  DISK_BRIDGE_BASE = 32'h4000_0000
) (
	// ---- APF side ----------------------------------------------------------
	input  wire        clk_74a,          // APF bridge clock
	input  wire        apf_reset_n,
	input  wire [31:0] bridge_addr,      // synchronous to clk_74a
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	// ---- APF deferred data slot (disk streaming) ---------------------------
	input  wire        dataslot_update,
	input  wire [15:0] dataslot_update_id,
	input  wire [31:0] dataslot_update_size,
	output reg         target_dataslot_read = 1'b0,
	output reg         target_dataslot_write = 1'b0,
	input  wire        target_dataslot_ack,
	input  wire        target_dataslot_done,
	input  wire  [2:0] target_dataslot_err,
	output wire [15:0] target_dataslot_id,
	output reg  [31:0] target_dataslot_slotoffset = 32'd0,
	output wire [31:0] target_dataslot_bridgeaddr,
	output reg  [31:0] target_dataslot_length = 32'd0,
	output reg  [31:0] disk_bridge_rd_data = 32'd0,

	// ---- pad / settings, from the APF pad controller -----------------------
	input  wire [31:0] pad_key,          // APF key bitmap, same layout as MiSTer
	input  wire [15:0] game_select,      // 0 = KI1, 1 = KI2
	input  wire [15:0] dip_switches_i,

	// ---- boot sequencing (ki_boot_ctrl) -----------------------------------
	// loader_reset is a one-shot POWER-ON reset, not a live PLL-lock gate:
	// once the first ROM byte has arrived the loader must survive a lock
	// glitch, because the host never sends the image a second time.
	input  wire        loader_reset,
	// Fallback: the boot supervisor timed out. Finish the stream, release
	// ioctl_download and let the bridge drain and the CPU run.
	input  wire        loader_abort,
	// APF Host Command 0x008F (data slot access all complete). The exact
	// byte count in the ROM slot is not part of the protocol contract; this
	// is the host saying "no more writes are coming".
	input  wire        loader_end,

	// ---- core-facing, as hps_io --------------------------------------------
	input  wire        clk,              // clk_core
	output reg  [127:0] status,
	output wire [31:0] debug_loader_info,
	output wire  [1:0] buttons,
	output wire        forced_scandoubler,
	output wire [31:0] joystick_0,
	output wire [31:0] joystick_1,
	output wire [10:0] ps2_key,

	output reg         ioctl_download,
	output reg         ioctl_wr,
	output reg  [15:0] ioctl_index,
	output reg  [26:0] ioctl_addr,
	output reg  [15:0] ioctl_dout,
	input  wire        ioctl_wait,

	input  wire [31:0] sd_lba,
	input  wire  [5:0] sd_blk_cnt,
	input  wire        sd_rd,
	input  wire        sd_wr,
	output reg         sd_ack = 1'b0,
	output reg  [12:0] sd_buff_addr = 13'd0,
	output reg  [15:0] sd_buff_dout = 16'd0,
	input  wire [15:0] sd_buff_din,
	output reg         sd_buff_wr = 1'b0,
	output reg         img_mounted = 1'b0,
	output wire        img_readonly,
	output reg  [63:0] img_size = 64'd131076608,

	output wire        overflow,           // sticky: a bridge write found the FIFO full
	output wire [31:0] debug_disk_info
);
	localparam integer ROM_WORDS = ROM_BYTES / 4;          // bridge words (4 bytes each)
	localparam [26:0]  ROM_BYTES_27 = ROM_BYTES[26:0];
	localparam [63:0]  DEFAULT_KI1_SIZE = 64'd131076608;
	localparam [63:0]  DEFAULT_KI2_SIZE = 64'd457673216;

	// ---------------------------------------------------------------- clk_74a
	// ROM slot writes: [0, ROM_BYTES).
	// Disk sector writes: [DISK_BRIDGE_BASE, DISK_BRIDGE_BASE + 16 KiB).
	wire        rom_win_hit  = (bridge_addr < {5'd0, ROM_BYTES_27});
	wire        disk_win_hit = (bridge_addr[31:14] == DISK_BRIDGE_BASE[31:14]);
	wire        fifo_wr      = bridge_wr && (rom_win_hit || disk_win_hit);
	wire [43:0] fifo_din     = {disk_win_hit, bridge_addr[12:2], bridge_wr_data};

	wire        fifo_full;
	reg         overflow_r = 1'b0;
	always @(posedge clk_74a) if (fifo_wr && fifo_full) overflow_r <= 1'b1;
	assign overflow = overflow_r;

	wire [43:0] fifo_dout;
	wire        fifo_empty;
	reg         fifo_rd = 1'b0;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(8192),
		.lpm_showahead("OFF"),
		.lpm_type("dcfifo"),
		.lpm_width(44),
		.lpm_widthu(13),
		.overflow_checking("ON"),
		.underflow_checking("OFF"),
		.use_eab("ON"),
		.wrsync_delaypipe(4),
		.rdsync_delaypipe(4)
	) fifo (
		.data(fifo_din), .wrclk(clk_74a), .wrreq(fifo_wr),
		.rdclk(clk), .rdreq(fifo_rd), .q(fifo_dout),
		.rdempty(fifo_empty), .wrfull(fifo_full),
		.aclr(loader_reset), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// 512-byte sector write buffer (128 x 32-bit words) for ATA sector writes (0x0184)
	(* ramstyle = "M10K, no_rw_check" *)
	reg [31:0] wr_buf [0:127];
	always @(posedge clk_74a) begin
		disk_bridge_rd_data <= wr_buf[bridge_addr[8:2]];
	end

	// ---------------------------------------------------------------- clk domain
	// Emit, in order: game selector (index 0x0000, 1 word), DIPs (0x00FE, 1
	// word), then the image (index 0x0001) as it arrives. Once in S_DONE, the
	// same FIFO drains APF deferred data slot reads for the ATA hard disk.
	// Note: dcfifo has lpm_showahead("OFF") and fifo_rd is registered, so
	// S_RD and S_DISK_RD wait 1 clk cycle after asserting fifo_rd before
	// latching fifo_dout in S_LO / S_DISK_LO.
	localparam [3:0] S_SEL      = 4'd0,
	                 S_DIP      = 4'd1,
	                 S_WAIT     = 4'd2,
	                 S_RD       = 4'd3,
	                 S_LATCH    = 4'd4,
	                 S_LO       = 4'd5,
	                 S_HI       = 4'd6,
	                 S_POST     = 4'd7,
	                 S_DONE     = 4'd8,
	                 S_DISK_RD  = 4'd9,
	                 S_DISK_LO  = 4'd10,
	                 S_DISK_HI  = 4'd11,
	                 S_WR_WAIT0 = 4'd12,
	                 S_WR_LO    = 4'd13,
	                 S_WR_HI    = 4'd14;

	reg [3:0]  st = S_SEL;
	reg [43:0] held = 44'd0;
	reg [26:0] wr_addr = 27'd0;      // ioctl_addr for the image, in bytes

	// Disk mount & Target Command CDC
	reg        upd_tog_74a = 1'b0;
	reg [31:0] upd_size_74a = 32'd131076608;
	always @(posedge clk_74a) begin
		if (dataslot_update && (dataslot_update_id == DISK_SLOT_ID)) begin
			upd_size_74a <= dataslot_update_size;
			upd_tog_74a  <= ~upd_tog_74a;
		end
	end

	reg [2:0]  upd_sync = 3'd0;
	reg        disk_req_tog = 1'b0;
	reg        disk_is_write = 1'b0;
	reg [2:0]  disk_done_sync = 3'd0;
	reg [12:0] disk_words_rem = 13'd0;
	reg        disk_active = 1'b0;

	assign target_dataslot_id         = DISK_SLOT_ID;
	assign target_dataslot_bridgeaddr = DISK_BRIDGE_BASE;
	assign img_readonly               = 1'b0;

	// clk_74a side of Target Command (0x0180: Data slot read, 0x0184: Data slot write)
	reg [2:0]  req_sync_74a = 3'd0;
	reg [1:0]  wr_sync_74a  = 2'd0;
	reg        done_tog_74a = 1'b0;
	reg [1:0]  tcmd_st = 2'd0;
	reg [2:0]  tcmd_err = 3'd0;
	reg [23:0] tcmd_timeout = 24'd0;

	// APF interact.json action write (0xF0000000 = Reset Core)
	reg menu_reset_tog_74a = 1'b0;
	always @(posedge clk_74a) begin
		if (bridge_wr && (bridge_addr == 32'hF0000000)) begin
			menu_reset_tog_74a <= ~menu_reset_tog_74a;
		end
	end

	always @(posedge clk_74a) begin
		req_sync_74a <= {req_sync_74a[1:0], disk_req_tog};
		wr_sync_74a  <= {wr_sync_74a[0], disk_is_write};
		case (tcmd_st)
		2'd0: begin
			tcmd_timeout <= 24'd0;
			if (req_sync_74a[2] != done_tog_74a) begin
				target_dataslot_read  <= ~wr_sync_74a[1];
				target_dataslot_write <=  wr_sync_74a[1];
				tcmd_st               <= 2'd1;
			end
		end
		2'd1: begin
			tcmd_timeout <= tcmd_timeout + 24'd1;
			if (target_dataslot_ack || !target_dataslot_done || tcmd_timeout[22]) begin
				target_dataslot_read  <= 1'b0;
				target_dataslot_write <= 1'b0;
				tcmd_st               <= 2'd2;
			end
		end
		2'd2: begin
			tcmd_timeout <= tcmd_timeout + 24'd1;
			if (target_dataslot_done || tcmd_timeout[23]) begin
				tcmd_err     <= target_dataslot_err;
				done_tog_74a <= req_sync_74a[2];
				tcmd_st      <= 2'd0;
			end
		end
		default: tcmd_st <= 2'd0;
		endcase
	end

	// Watchdog for a deferred-slot read/write that never completes. It exists so
	// a stuck APF handshake cannot hang the loader forever - NOT as a deadline
	// for a legitimate transfer.
	//
	// The timeout was 2^23 clocks = 167.8 ms, and that was a bug. ki_ata marks a
	// bank VALID on the falling edge of sd_ack without checking how many words
	// actually arrived (ki_ata.sv: "if (fetch_busy && !sd_ack && sd_ack_d)"), so
	// a watchdog that fires EARLY hands the CPU a half-filled sector as if it
	// were complete. 167.8 ms is inside the range of a first deferred-slot read
	// from a microSD card, which includes FAT metadata lookups and can include
	// card wake-up. The failure is silent wrong data, which looks like the game
	// hanging mid-disk-read rather than like a timeout.
	//
	// 2^27 = 2.68 s is far beyond any card latency worth waiting for and still
	// bounds a genuine deadlock.
	localparam integer DISK_TIMEOUT_BIT = 27;
	reg [DISK_TIMEOUT_BIT:0] disk_watchdog = {DISK_TIMEOUT_BIT+1{1'b0}};
	reg        disk_timeout = 1'b0;

	// The APF's end-of-transfer marker is a level in clk_74a. It is latched
	// here and only acted on once the FIFO has stayed empty for a grace
	// window, so a bridge write still in flight cannot be cut off. The boot
	// ROM is required to be present (BOOT_BYTES_MIN) before the marker is
	// allowed to finish the stream; a short image is then reported, not
	// silently accepted.
	localparam [26:0] BOOT_BYTES_MIN = 27'h0080000;
	reg [1:0]  loader_end_sync    = 2'b00;
	reg        loader_end_latched = 1'b0;
	reg        loader_short       = 1'b0;
	reg        loader_aborted     = 1'b0;
	reg [15:0] end_grace          = 16'd0;

	always @(posedge clk) begin
		fifo_rd      <= 1'b0;
		ioctl_wr     <= 1'b0;
		ioctl_index  <= 16'h0001;
		ioctl_dout   <= 16'h0000;
		sd_buff_wr   <= 1'b0;
		img_mounted  <= 1'b0;

		upd_sync       <= {upd_sync[1:0], upd_tog_74a};
		disk_done_sync <= {disk_done_sync[1:0], done_tog_74a};

		if (upd_sync[2] != upd_sync[1]) begin
			if (upd_size_74a >= 32'd512)
				img_size <= {32'd0, upd_size_74a};
			else
				img_size <= game_select[0] ? DEFAULT_KI2_SIZE : DEFAULT_KI1_SIZE;
			img_mounted <= 1'b1;
		end

		if (loader_reset) begin
			st             <= S_SEL;
			ioctl_download <= 1'b0;
			ioctl_addr     <= 27'd0;
			wr_addr        <= 27'd0;
			status         <= 128'd0;
			sd_ack         <= 1'b0;
			disk_active    <= 1'b0;
			disk_is_write  <= 1'b0;
			img_size       <= game_select[0] ? DEFAULT_KI2_SIZE : DEFAULT_KI1_SIZE;
			img_mounted    <= 1'b0;
			loader_end_latched <= 1'b0;
			loader_short       <= 1'b0;
			loader_aborted     <= 1'b0;
			end_grace          <= 16'd0;
		end else if (core_menu_reset) begin
			// On menu soft-reset, DO NOT re-enter S_SEL or re-assert ioctl_download:
			// APF only streams the boot ROM once on initial core launch.
			// Re-entering S_SEL would stall pk_io in S_WAIT waiting on an empty FIFO.
			// Keep st unchanged (S_DONE) and cleanly clear any pending ATA activity.
			sd_ack         <= 1'b0;
			disk_active    <= 1'b0;
			disk_is_write  <= 1'b0;
		end else begin
			if (img_size < 64'd512) begin
				img_size <= game_select[0] ? DEFAULT_KI2_SIZE : DEFAULT_KI1_SIZE;
			end
			status <= 128'd0;

			// Latch the APF end marker. It is a level held by the host, so a
			// two-flop sync is enough; the latch removes any dependence on
			// when the marker happens to be sampled.
			loader_end_sync <= {loader_end_sync[0], loader_end};
			if (loader_end_sync[1])
				loader_end_latched <= 1'b1;

			if (disk_active)
				disk_watchdog <= disk_watchdog + 1'b1;
			else
				disk_watchdog <= {DISK_TIMEOUT_BIT+1{1'b0}};

			// Start an APF deferred slot read when ki_ata asserts sd_rd
			if (st == S_DONE && !disk_active && sd_rd) begin
				target_dataslot_slotoffset <= {sd_lba[22:0], 9'd0};
				target_dataslot_length     <= {17'd0, (sd_blk_cnt + 6'd1), 9'd0};
				disk_words_rem             <= ({7'd0, sd_blk_cnt} + 13'd1) << 8;
				sd_ack                     <= 1'b1;
				disk_active                <= 1'b1;
				disk_is_write              <= 1'b0;
				disk_req_tog               <= ~disk_req_tog;
			end else if (st == S_DONE && !disk_active && sd_wr) begin
				// Copy 512-byte sector from ki_ata's sector_buffer and write via APF 0x0184
				target_dataslot_slotoffset <= {sd_lba[22:0], 9'd0};
				target_dataslot_length     <= 32'd512;
				disk_words_rem             <= 13'd0;
				sd_ack                     <= 1'b1;
				disk_active                <= 1'b1;
				disk_is_write              <= 1'b1;
				sd_buff_addr               <= 13'd0;
				st                         <= S_WR_WAIT0;
			end

			if (loader_abort) begin
				// Fallback: the boot supervisor timed out waiting for the image.
				// Finish the stream and release ioctl_download so the bridge can
				// drain and boot_loaded can rise. The debug page reports the
				// abort, so a partial image is visible rather than silent.
				loader_aborted <= 1'b1;
				st             <= S_DONE;
				ioctl_download <= 1'b0;
				disk_active    <= 1'b0;
			end else case (st)
			// The selector and the DIPs are single words the core latches on
			// ioctl_wr with the matching index; emit them before the stream so
			// the download FSM sees them first, as on MiSTer.
			S_SEL: begin
				ioctl_index    <= 16'h0000;
				ioctl_addr     <= 27'd0;
				ioctl_dout     <= game_select;
				ioctl_wr       <= 1'b1;
				ioctl_download <= 1'b1;
				st             <= S_DIP;
			end
			S_DIP: begin
				ioctl_index <= 16'h00FE;
				ioctl_addr  <= 27'd0;
				ioctl_dout  <= dip_switches_i;
				ioctl_wr    <= 1'b1;
				st          <= S_WAIT;
			end
			S_WAIT: begin
				ioctl_index <= 16'h0001;
				if (!fifo_empty && !ioctl_wait) begin
					fifo_rd   <= 1'b1;
					st        <= S_RD;
					end_grace <= 16'd0;
				end else if (loader_end_latched && fifo_empty &&
				             (wr_addr >= BOOT_BYTES_MIN)) begin
					// The host says no more writes are coming and the FIFO has
					// been empty long enough that nothing can still be in flight.
					// Finish on the host's marker rather than on an exact byte
					// count, which is not part of the APF slot contract.
					if (end_grace == 16'hffff) begin
						if (wr_addr < ROM_BYTES_27)
							loader_short <= 1'b1;
						st <= S_DONE;
					end else begin
						end_grace <= end_grace + 16'd1;
					end
				end else begin
					end_grace <= 16'd0;
				end
			end
			S_RD: begin
				ioctl_index <= 16'h0001;
				st          <= S_LATCH;
			end
			S_LATCH: begin
				ioctl_index <= 16'h0001;
				held        <= fifo_dout;
				st          <= S_LO;
			end
			S_LO: begin
				ioctl_index <= 16'h0001;
				if (!ioctl_wait) begin
					ioctl_addr <= wr_addr;
					ioctl_dout <= held[15:0];
					ioctl_wr   <= 1'b1;
					st         <= S_HI;
				end
			end
			S_HI: begin
				ioctl_index <= 16'h0001;
				if (!ioctl_wait) begin
					ioctl_addr <= wr_addr + 27'd2;
					ioctl_dout <= held[31:16];
					ioctl_wr   <= 1'b1;
					wr_addr    <= wr_addr + 27'd4;
					st         <= S_POST;
				end
			end
			S_POST: begin
				ioctl_index <= 16'h0001;
				if (wr_addr >= ROM_BYTES_27)
					st <= S_DONE;
				else
					st <= S_WAIT;
			end
			S_DONE: begin
				// Release the download so the core leaves reset
				// (KillerInstinct.sv: core_reset = shell_reset | ioctl_download).
				ioctl_download <= 1'b0;
				if (!fifo_empty) begin
					fifo_rd <= 1'b1;
					st      <= S_DISK_RD;
				end else if (disk_active &&
				             ((disk_done_sync[2] == disk_req_tog) ||
				              disk_watchdog[DISK_TIMEOUT_BIT])) begin
					// Sticky: a timeout here means the APF stopped answering, and
					// ki_ata will have accepted a partial bank as complete. Surface
					// it on the debug page instead of letting it look like a game bug.
					if (disk_watchdog[DISK_TIMEOUT_BIT])
						disk_timeout <= 1'b1;
					sd_ack      <= 1'b0;
					disk_active <= 1'b0;
				end
			end
			S_DISK_RD: begin
				st <= S_DISK_LO;
			end
			S_DISK_LO: begin
				held         <= fifo_dout;
				sd_buff_addr <= {fifo_dout[42:32], 1'b0};
				sd_buff_dout <= fifo_dout[15:0];
				sd_buff_wr   <= fifo_dout[43];
				if (fifo_dout[43] && (disk_words_rem != 13'd0))
					disk_words_rem <= disk_words_rem - 13'd1;
				st           <= S_DISK_HI;
			end
			S_DISK_HI: begin
				sd_buff_addr <= {held[42:32], 1'b1};
				sd_buff_dout <= held[31:16];
				sd_buff_wr   <= held[43];
				if (held[43] && (disk_words_rem != 13'd0))
					disk_words_rem <= disk_words_rem - 13'd1;
				st           <= S_DONE;
			end
			S_WR_WAIT0: begin
				sd_buff_addr <= sd_buff_addr + 13'd1;
				st           <= S_WR_LO;
			end
			S_WR_LO: begin
				held[15:0] <= sd_buff_din;
				st         <= S_WR_HI;
			end
			S_WR_HI: begin
				wr_buf[sd_buff_addr[7:1]] <= {sd_buff_din, held[15:0]};
				if (sd_buff_addr[7:0] == 8'hFF) begin
					disk_req_tog <= ~disk_req_tog;
					st           <= S_DONE;
				end else begin
					sd_buff_addr <= sd_buff_addr + 13'd1;
					st           <= S_WR_WAIT0;
				end
			end
			default: st <= S_SEL;
			endcase
		end
	end

	// ---------------------------------------------------------------- pad/status/reset
	// The APF key bitmap is generated in the clk_74a domain. Synchronize it
	// before anything in clk_core samples it: the game inputs and the Start +
	// Select chord detector both read these bits, and a raw crossing can
	// produce a phantom press (or, worse, a phantom chord).
	reg [31:0] pad_key_meta = 32'd0;
	reg [31:0] pad_key_sync = 32'd0;
	always @(posedge clk) begin
		pad_key_meta <= pad_key;
		pad_key_sync <= pad_key_meta;
	end
	// Map APF cont1_key to MiSTer joystick_0 expected by Killer Instinct:
	//   Pocket (cont1_key):
	//     [0]  D-Pad Up
	//     [1]  D-Pad Down
	//     [2]  D-Pad Left
	//     [3]  D-Pad Right
	//     [4]  Button A (MK)
	//     [5]  Button B (QK)
	//     [6]  Button X (MP)
	//     [7]  Button Y (QP)
	//     [8]  Trigger L (FP)
	//     [9]  Trigger R (FK)
	//     [10] Trigger L2 (Service)
	//     [11] Trigger R2
	//     [14] Select (Coin 1)
	//     [15] Start (1P Start)
	//
	//   KI / MiSTer joystick_0:
	//     [0]  Right
	//     [1]  Left
	//     [2]  Down
	//     [3]  Up
	//     [4]  High Quick (QP)
	//     [5]  High Medium (MP)
	//     [6]  High Fierce (FP)
	//     [7]  Low Quick (QK)
	//     [8]  Low Medium (MK)
	//     [9]  Low Fierce (FK)
	//     [10] 1P Start
	//     [11] Coin 1
	//     [12] Service Mode
	assign joystick_0 = {
		16'd0,
		3'd0,
		pad_key_sync[10], // 12: Service Mode (L2)
		pad_key_sync[14], // 11: Coin 1 (Select)
		pad_key_sync[15], // 10: 1P Start (Start)
		pad_key_sync[9],  //  9: Low Fierce / FK (R)
		pad_key_sync[4],  //  8: Low Medium / MK (A)
		pad_key_sync[5],  //  7: Low Quick / QK (B)
		pad_key_sync[8],  //  6: High Fierce / FP (L)
		pad_key_sync[6],  //  5: High Medium / MP (X)
		pad_key_sync[7],  //  4: High Quick / QP (Y)
		pad_key_sync[0],  //  3: Up
		pad_key_sync[1],  //  2: Down
		pad_key_sync[2],  //  1: Left
		pad_key_sync[3]   //  0: Right
	};
	assign joystick_1         = 32'd0;
	assign ps2_key            = 11'd0;
	assign forced_scandoubler = 1'b0;

	// Reset stretcher for APF menu reset (action write to 0xF0000000)
	reg [2:0]  menu_reset_sync = 3'd0;
	reg [17:0] reset_extender  = 18'd0; // 50,000 cycles = 1ms at 50MHz
	always @(posedge clk) begin
		menu_reset_sync <= {menu_reset_sync[1:0], menu_reset_tog_74a};
		if (menu_reset_sync[2] != menu_reset_sync[1]) begin
			reset_extender <= 18'd50000;
		end else if (reset_extender != 18'd0) begin
			reset_extender <= reset_extender - 18'd1;
		end
	end
	wire core_menu_reset = (reset_extender != 18'd0);

	assign buttons = {core_menu_reset, ~apf_reset_n};   // [1] = reset, [0] = apf_reset

	// disk_timeout is the MSB so it lands on the first hex digit of the DK
	// field, which is the only part of this word the page displays (the row
	// shows bits 31:8). Its LSBs carried sd_lba[7:0], of which only seven bits
	// were ever visible.
	assign debug_disk_info = {
		disk_timeout,
		tcmd_st,
		tcmd_err,
		target_dataslot_done,
		target_dataslot_ack,
		disk_active,
		sd_rd,
		sd_ack,
		fifo_empty,
		fifo_full,
		disk_words_rem[11:0],
		sd_lba[6:0]
	};

	// Loader summary for the debug page. wr_addr counts bytes handed to the
	// core; the shift by one fits the 0x480000 maximum in 22 bits and leaves
	// room for the FSM state and the sticky flags.
	assign debug_loader_info = {
		st,
		wr_addr[22:1],
		fifo_empty,
		fifo_full,
		overflow_r,
		loader_end_latched,
		loader_short,
		loader_aborted
	};
endmodule

`default_nettype wire
