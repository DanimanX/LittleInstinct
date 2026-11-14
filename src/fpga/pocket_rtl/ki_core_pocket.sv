// SPDX-License-Identifier: GPL-3.0-only
// Killer Instinct core, Pocket shell.
// Copied from upstream KillerInstinct.sv; the only change is that hps_io
// (the MiSTer HPS shell) is replaced by pk_io, which the APF bridge drives.
// Everything else -- PLL, CPU, DCS, ATA, bridge, video, audio -- is upstream.

// Comment this line out for a release build.
//`define KI_DEBUG_BUILD

module emu
(
	input         CLK_50M,
	input         RESET,

	// ---- Analogue Pocket side (this port's only change to the shell) ----
	input         clk_74a,
	input  [31:0] bridge_addr,
	input         bridge_wr,
	input  [31:0] bridge_wr_data,
	input         dataslot_update,
	input  [15:0] dataslot_update_id,
	input  [31:0] dataslot_update_size,
	output        target_dataslot_read,
	output        target_dataslot_write,
	input         target_dataslot_ack,
	input         target_dataslot_done,
	input   [2:0] target_dataslot_err,
	output [15:0] target_dataslot_id,
	output [31:0] target_dataslot_slotoffset,
	output [31:0] target_dataslot_bridgeaddr,
	output [31:0] target_dataslot_length,
	output [31:0] disk_bridge_rd_data,
	input  [31:0] pad_key,
	// APF Host Command 0x008F: all data slot accesses complete. This is the
	// host's end-of-stream marker for the ROM slot.
	input         apf_dataslot_complete,
	input         ref_pll_locked,
	output        core_pll_locked,
	output        core_sdram_ready,
	output        loader_overflow,
	inout  [45:0] HPS_BUS,

	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output  [1:0] VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

	input   [5:0] LFB_FMT,
	input  [31:0] LFB_BASE,
	input  [11:0] LFB_WIDTH,
	input  [11:0] LFB_HEIGHT,
	input  [13:0] LFB_STRIDE,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,
	input         OSD_STATUS
);

localparam CONF_STR = {
	"KillerInstinct;;",
	"S0,IMG,Mount HDD Image;",
	"-;",
	"P1,Video Settings;",
	"P1O1,Aspect Ratio,Original,Wide Screen;",
	"P1O2,Video Timing,Native,60Hz CRT;",
	"-;",
	"O8,OSD Pause,Off,On;",
	"-;",
	"DIP;",
	"-;",
`ifdef KI_DEBUG_BUILD
	"P2,Debug;",
	"P2O4,Video Output,Game,Debug;",
	"P2O56,Debug Page,Status,Trace,Perf,Prof;",
	"P2O7,Perf Peak,Run,Clear;",
	"P2O9C,Prof Fine Map,Auto,B0,B1,B2,B3,B4,B5,B6,B7;",
	"P2O3,FPS Overlay,Off,On;",
	"-;",
`endif
	"R0,Reset;",
	"J1,High Quick,High Medium,High Fierce,Low Quick,Low Medium,Low Fierce,Start,Coin,Service,Test,Pause;",
	"V,1.63"
};

wire [1:0] buttons;
wire [127:0] status;
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [10:0] ps2_key;
wire forced_scandoubler;
wire ioctl_download;
wire ioctl_wr;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire [15:0] ioctl_dout;
wire ioctl_wait;
wire img_mounted;
wire img_readonly;
wire [63:0] img_size;
wire hdd_image_present = (img_size >= 64'd512);
wire startup_osd_button;
wire [31:0] sd_lba;
wire [5:0] sd_blk_cnt;
wire sd_rd;
wire sd_wr;
wire sd_ack;
wire [12:0] sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din;
wire sd_buff_wr;

// Every clock in the core, and what each one is FOR. None of these names
// carries a frequency.
//
//   wire              PLL out   freq     phase   purpose
//   clk_core          0         50 MHz   0       video, I/O, bridge, debug
//   clk_cpu           1         50 MHz   250 ps  the MIPS core. Same rate as
//                                                clk_core but NOT phase
//                                                aligned, so the crossing is
//                                                an asynchronous CDC and runs
//                                                through synchronisers
//                                                (SYNC_CROSSING = 0); see
//                                                pocket_ki.sdc.
//   clk_ddr           2         100 MHz  0       DDRAM_CLK and the bridge's
//                                                DDR side
//   clk_sdram_pin     3         100 MHz  6750ps  leaves the chip as SDRAM_CLK
//   clk_sdram_ctl     4         100 MHz  500ps   ki_sdram_burst's logic
//   clk_sdram_cap     5         100 MHz  1500ps  captures SDRAM_DQ in the
//                                                device's data eye
//
// clk_cpu and clk_ddr are configured identically, so Quartus MERGES them onto
// one network - general[2] does not appear in the STA clock list at all. They
// are kept as two wires because they have two unrelated jobs, and because the
// merge is the fitter's decision to make, not this file's.
//
// Inside the CPU, clk_cpu arrives as clk93 and clk_core as clk1x. Those names
// come from the N64 core this CPU is derived from (93.75 and 62.5 MHz) and are
// wrong here - but the `_93` and `_1x` SUFFIXES on ~28 signals below them are
// a domain tag that CDC code depends on, so renaming the clocks without
// renaming every suffix would be worse than leaving both. This table is the
// mapping.
//
// The SDRAM phases above cannot be derived from nominal timing;
// rtl/pll/pll_0002.v records why.
wire clk_core;
wire clk_cpu;
wire clk_ddr;
wire clk_sdram_pin;
wire clk_sdram_ctl;
wire clk_sdram_cap;
wire pll_locked;

// Keep this instance name aligned with sys/sys_top.sdc's core clock group.
pll pll
(
	.refclk(CLK_50M),
	.rst(~ref_pll_locked),
	.outclk_0(clk_core),
	.outclk_1(clk_cpu),
	.outclk_2(clk_ddr),
	.outclk_3(clk_sdram_pin),
	.outclk_4(clk_sdram_ctl),
	.outclk_5(clk_sdram_cap),
	.locked(pll_locked)
);

assign core_pll_locked  = pll_locked;
assign core_sdram_ready = sdram_ready;

// Analogue Pocket: the APF bridge feeds the same core-facing ioctl_* bus that
// MiSTer's hps_io drove. See pocket_rtl/pk_io.sv.
//
// Boot sequencing. These wires are declared before pk_io because the loader
// consumes the supervisor's outputs; the status inputs are driven by the
// bridge and self test further down.
wire boot_loaded;
wire sdram_ready;
wire bist_busy;
wire bist_done;
wire loader_reset;
wire loader_abort;
wire [2:0] boot_state;
wire boot_timed_out;
wire boot_ready;
wire [31:0] debug_loader_info;
wire [31:0] debug_download_info;

ki_boot_ctrl boot_ctrl (
	.clk         (clk_core),
	.pll_locked  (pll_locked),
	.boot_loaded (boot_loaded),
	.sdram_ready (sdram_ready),
	.bist_done   (bist_done),
	.loader_busy (ioctl_download),
	.loader_reset(loader_reset),
	.loader_abort(loader_abort),
	.boot_ready  (boot_ready),
	.state       (boot_state),
	.timed_out   (boot_timed_out),
	.elapsed     ()
);

wire [31:0] debug_disk_info;
pk_io #(.ROM_BYTES(4718592)) pk_io
(
	.clk_74a                    (clk_74a),
	.apf_reset_n                (pll_locked),
	.bridge_addr                (bridge_addr),
	.bridge_wr                  (bridge_wr),
	.bridge_wr_data             (bridge_wr_data),
	.dataslot_update            (dataslot_update),
	.dataslot_update_id         (dataslot_update_id),
	.dataslot_update_size       (dataslot_update_size),
	.target_dataslot_read       (target_dataslot_read),
	.target_dataslot_write      (target_dataslot_write),
	.target_dataslot_ack        (target_dataslot_ack),
	.target_dataslot_done       (target_dataslot_done),
	.target_dataslot_err        (target_dataslot_err),
	.target_dataslot_id         (target_dataslot_id),
	.target_dataslot_slotoffset (target_dataslot_slotoffset),
	.target_dataslot_bridgeaddr (target_dataslot_bridgeaddr),
	.target_dataslot_length     (target_dataslot_length),
	.disk_bridge_rd_data        (disk_bridge_rd_data),
	.pad_key                    (pad_key),
	.game_select                (16'h0000),      // KI1; KI2 sets bit 0 via interact.json later
	.dip_switches_i             (16'hffff),
	.loader_reset               (loader_reset),
	.loader_abort               (loader_abort),
	.loader_end                 (apf_dataslot_complete),
	.debug_loader_info          (debug_loader_info),
	.clk                        (clk_core),
	.status                     (status),
	.buttons                    (buttons),
	.forced_scandoubler         (forced_scandoubler),
	.joystick_0                 (joystick_0),
	.joystick_1                 (joystick_1),
	.ps2_key                    (ps2_key),
	.ioctl_download             (ioctl_download),
	.ioctl_wr                   (ioctl_wr),
	.ioctl_index                (ioctl_index),
	.ioctl_addr                 (ioctl_addr),
	.ioctl_dout                 (ioctl_dout),
	.ioctl_wait                 (ioctl_wait),
	.sd_lba                     (sd_lba),
	.sd_blk_cnt                 (sd_blk_cnt),
	.sd_rd                      (sd_rd),
	.sd_wr                      (sd_wr),
	.sd_ack                     (sd_ack),
	.sd_buff_addr               (sd_buff_addr),
	.sd_buff_dout               (sd_buff_dout),
	.sd_buff_din                (sd_buff_din),
	.sd_buff_wr                 (sd_buff_wr),
	.img_mounted                (img_mounted),
	.img_readonly               (img_readonly),
	.img_size                   (img_size),
	.overflow                   (loader_overflow),
	.debug_disk_info            (debug_disk_info)
);

ki_startup_osd_button startup_osd_button_inst
(
	.clk_i(clk_core),
	.reset_i(~pll_locked | RESET),
	.rom_download_i(ioctl_download),
	.rom_index_i(ioctl_index),
	.image_present_i(hdd_image_present),
	.osd_button_o(startup_osd_button)
);

reg game_ki2 = 1'b0;
reg [15:0] dip_switches = 16'hffff;

always @(posedge clk_core) begin
	if(ioctl_wr && (ioctl_index == 16'h0000) && (ioctl_addr < 27'd2)) begin
		game_ki2 <= ioctl_dout[0];
	end
	if(ioctl_wr && (ioctl_index == 16'h00fe) && (ioctl_addr < 27'd2)) begin
		dip_switches <= ioctl_dout;
	end
end

wire shell_reset = RESET | buttons[1] | status[0] | ~pll_locked;

// Analogue Pocket: the disk image is configured at launch by APF, not mounted
// mid-game via an OSD menu like on MiSTer. Triggering an asynchronous reset
// when dataslot_update arrives interrupts the MIPS CPU mid-stride during its
// boot self-test, corrupting the SDRAM memory pipeline and freezing on scanline 0.
wire img_reset = 1'b0;

wire core_reset = shell_reset | ioctl_download | img_reset;

// The CPU is released by the boot sequencer, not by a chain of terms written
// out here. boot_ready is boot_loaded & sdram_ready & bist_done.
wire cpu_reset = core_reset | ~boot_ready;


// Is clk_sdram_ctl actually toggling? The adapter's sdram_ready cannot rise
// without it, so "SD:0" has two very different causes: a controller that is
// still counting, or an output the PLL/fitter did not produce. A free-running
// divider in the SDRAM clock domain and a toggle synchronizer answer that
// without another clock crossing protocol. BF bit 0 is the sticky result.
reg  [7:0] sdram_clk_div  = 8'd0;
reg        sdram_clk_tog  = 1'b0;
always @(posedge clk_sdram_ctl) begin
	sdram_clk_div <= sdram_clk_div + 8'd1;
	if (sdram_clk_div == 8'hff)
		sdram_clk_tog <= ~sdram_clk_tog;
end

reg [2:0] sdram_clk_sync = 3'd0;
reg       sdram_clk_seen = 1'b0;
always @(posedge clk_core) begin
	sdram_clk_sync <= {sdram_clk_sync[1:0], sdram_clk_tog};
	if (sdram_clk_sync[2] != sdram_clk_sync[1])
		sdram_clk_seen <= 1'b1;
	if (shell_reset)
		sdram_clk_seen <= 1'b0;
end
wire [9:0] h_count;
wire [9:0] v_count;

wire vblank;
wire frame_start;
wire [31:0] video_vblank_count;
wire video_vblank_seen;
wire [9:0] video_max_v_count;

// ---------------------------------------------------------------------------
// Video timing selection.
//
// Native Killer Instinct timing, matching the original board, is
// 50 MHz / 8 = 6.25 MHz with 406 clocks/line and 261 lines/frame:
//
//     H = 6.25 MHz / 406       = 15.394 kHz
//     V = 6.25 MHz / 406 / 261 = 58.981 Hz
//
// 15.394 kHz is low enough that some NTSC consumer televisions will not lock
// to it reliably. status[2] therefore selects an alternate 320x240 timing
// which keeps the ORIGINAL 6.25 MHz pixel cadence but changes only blanking:
//
//     398 clocks/line, 262 lines/frame
//     H = 15.704 kHz
//     V = 59.937 Hz
//
// This is deliberately a timing-compatibility mode rather than a scaler.
// The framebuffer remains 320x240 and no pixels are duplicated or dropped.
// Because vblank is generated by this timing, game speed/IRQ cadence rises by
// about 1.62% in CRT mode. Native remains the default and exact board mode.
wire crt_60hz = status[2];

wire        native_ce_pixel;
wire [9:0]  native_h_count;
wire [9:0]  native_v_count;
wire        native_de;
wire        native_hs;
wire        native_vs;
wire        native_vblank;
wire        native_frame_start;
wire [31:0] native_vblank_count;
wire        native_vblank_seen;
wire [9:0]  native_max_v_count;

// Keep the original generator running in both modes. Its CE_PIXEL is only
// the 1-in-8 pixel strobe, so it is safe to use as the common 6.25 MHz pixel
// enable for the alternate counters below.
ki_video_timing #(.CLOCK_DIVIDE(8)) video_timing
(
	.clk(clk_core),
	.reset(shell_reset),
	.ce_pixel(native_ce_pixel),
	.h_count(native_h_count),
	.v_count(native_v_count),
	.display_enable(native_de),
	.hsync_n(native_hs),
	.vsync_n(native_vs),
	.vblank(native_vblank),
	.frame_start(native_frame_start),
	.vblank_count(native_vblank_count),
	.vblank_seen(native_vblank_seen),
	.max_v_count(native_max_v_count)
);

// NTSC-consumer-CRT-friendly 240p timing. Active video is kept at the same
// 0..319 / 0..239 coordinates expected by ki_framebuffer and debug_screen.
// Horizontal: 320 active + 16 front + 32 sync + 30 back = 398.
// Vertical:   240 active +  3 front +  3 sync + 16 back = 262.
localparam int CRT_H_ACTIVE = 320;
localparam int CRT_H_FP     = 16;
localparam int CRT_H_SYNC   = 32;
localparam int CRT_H_TOTAL  = 398;
localparam int CRT_V_ACTIVE = 240;
localparam int CRT_V_FP     = 3;
localparam int CRT_V_SYNC   = 3;
localparam int CRT_V_TOTAL  = 262;

reg [9:0] crt_h_count = 10'd0;
reg [9:0] crt_v_count = 10'd0;
reg [31:0] crt_vblank_count = 32'd0;
reg crt_vblank_seen = 1'b0;
reg crt_frame_start = 1'b0;

always @(posedge clk_core) begin
	crt_frame_start <= 1'b0;

	if(core_reset) begin
		crt_h_count <= 10'd0;
		crt_v_count <= 10'd0;
		crt_vblank_count <= 32'd0;
		crt_vblank_seen <= 1'b0;
	end
	else if(native_ce_pixel) begin
		if(crt_h_count == CRT_H_TOTAL-1) begin
			crt_h_count <= 10'd0;

			if(crt_v_count == CRT_V_TOTAL-1) begin
				crt_v_count <= 10'd0;
				crt_frame_start <= 1'b1;
			end
			else begin
				crt_v_count <= crt_v_count + 1'b1;

				// Count the transition into vertical blank once per frame.
				if(crt_v_count == CRT_V_ACTIVE-1) begin
					crt_vblank_count <= crt_vblank_count + 1'b1;
					crt_vblank_seen <= 1'b1;
				end
			end
		end
		else begin
			crt_h_count <= crt_h_count + 1'b1;
		end
	end
end

wire crt_de = (crt_h_count < CRT_H_ACTIVE) &&
              (crt_v_count < CRT_V_ACTIVE);
wire crt_hs = ~((crt_h_count >= CRT_H_ACTIVE + CRT_H_FP) &&
                (crt_h_count <  CRT_H_ACTIVE + CRT_H_FP + CRT_H_SYNC));
wire crt_vs = ~((crt_v_count >= CRT_V_ACTIVE + CRT_V_FP) &&
                (crt_v_count <  CRT_V_ACTIVE + CRT_V_FP + CRT_V_SYNC));
wire crt_vblank = (crt_v_count >= CRT_V_ACTIVE);

assign CE_PIXEL = native_ce_pixel;
assign h_count = crt_60hz ? crt_h_count : native_h_count;
assign v_count = crt_60hz ? crt_v_count : native_v_count;
assign VGA_DE = crt_60hz ? crt_de : native_de;
assign VGA_HS = crt_60hz ? crt_hs : native_hs;
assign VGA_VS = crt_60hz ? crt_vs : native_vs;
assign vblank = crt_60hz ? crt_vblank : native_vblank;
assign frame_start = crt_60hz ? crt_frame_start : native_frame_start;
assign video_vblank_count = crt_60hz ? crt_vblank_count : native_vblank_count;
assign video_vblank_seen = crt_60hz ? crt_vblank_seen : native_vblank_seen;
assign video_max_v_count = crt_60hz ? CRT_V_TOTAL-1 : native_max_v_count;

// Board input bits:
//
//   0 High Quick   1 High Medium   2 High Fierce
//   3 Low Quick    4 Low Medium    5 Low Fierce
//   6 Up   7 Down   8 Left   9 Right
//  10 Start (1P on the P1 port, 2P on the P2 port)
//  11 Coin  (Coin 1 / Coin 2)
//  12 Service Mode on P1, TILT on P2
//  13 Coin 3 on P1, Service 1 on P2
//  14 Coin 4 on P1, Banknote 1 on P2
//
// MiSTer joystick bits are right/left/down/up in 3:0, then the CONF_STR J1
// order from bit 4: High Quick, High Medium, High Fierce, Low Quick,
// Low Medium, Low Fierce, Start, Coin, Service, Test, Pause.
//
// Merge the arcade keyboard controls with the matching MiSTer joystick bits
// before translating them to the board's active-low ports.
wire [12:0] keyboard_p1;
wire [12:0] keyboard_p2;
wire        keyboard_pause;

ki_keyboard keyboard
(
	.clk_i(clk_core),
	.ps2_key_i(ps2_key),
	.p1_o(keyboard_p1),
	.p2_o(keyboard_p2),
	.pause_o(keyboard_pause)
);

wire [12:0] controls_p1 = joystick_0[12:0] | keyboard_p1;
wire [12:0] controls_p2 = joystick_1[12:0] | keyboard_p2;

// Active low throughout: the board reads a released control as 1.
wire [31:0] input_p1 = {
	16'hffff,          // 31:16 unused
	3'b111,            // 15:13 Coin 4, Coin 3 inactive
	~controls_p1[12],  //    12 Service Mode
	~controls_p1[11],  //    11 Coin 1
	~controls_p1[10],  //    10 1P Start
	~controls_p1[0],   //     9 Right
	~controls_p1[1],   //     8 Left
	~controls_p1[2],   //     7 Down
	~controls_p1[3],   //     6 Up
	~controls_p1[9],   //     5 Low Fierce
	~controls_p1[8],   //     4 Low Medium
	~controls_p1[7],   //     3 Low Quick
	~controls_p1[6],   //     2 High Fierce
	~controls_p1[5],   //     1 High Medium
	~controls_p1[4]    //     0 High Quick
};
// P2 differs above bit 11: bit 12 is TILT, not Service Mode. Player 2's
// Service goes to bit 13, Service 1, which is the genuine service input on
// this port, and Tilt is left inactive because nothing should assert it.
wire [31:0] input_p2 = {
	16'hffff,          // 31:16 unused
	2'b11,             // 15:14 Banknote 1 inactive
	~controls_p2[12],  //    13 Service 1
	1'b1,              //    12 Tilt - never asserted
	~controls_p2[11],  //    11 Coin 2
	~controls_p2[10],  //    10 2P Start
	~controls_p2[0],   //     9 Right
	~controls_p2[1],   //     8 Left
	~controls_p2[2],   //     7 Down
	~controls_p2[3],   //     6 Up
	~controls_p2[9],   //     5 Low Fierce
	~controls_p2[8],   //     4 Low Medium
	~controls_p2[7],   //     3 Low Quick
	~controls_p2[6],   //     2 High Fierce
	~controls_p2[5],   //     1 High Medium
	~controls_p2[4]    //     0 High Quick
};

// The test switch is DSW bit 15 (mask 00008000), active low like the rest, so
// pressing the CONF_STR Test button on either pad clears it.
wire test_pressed = joystick_0[13] | joystick_1[13];
wire [15:0] dip_switches_live =
	dip_switches & {~test_pressed, 15'h7fff};

// Pause: the game stands still while the OSD is open with OSD Pause on, and
// from one press of P or a pad's Pause button to the next. The memory bridge
// starts no CPU request, so the CPU stops at its next miss or I/O access;
// Count stops with it, so the game's own frame timing sees no time pass; and
// the sound board stops in step. Scanout carries on, so the frame the game
// last flipped to stays on screen. ki_pause decides when.
wire core_pause;

ki_pause pause_control
(
	.clk(clk_core),
	.reset(cpu_reset),
	.osd_open(OSD_STATUS),
	.osd_pause(status[8]),
	.button(1'b0),
	.pause(core_pause)
);

wire [31:0] io_read_data;
wire io_done;
wire [31:0] board_io_read_data;
wire board_io_done;
wire [31:0] ata_read_data;
wire ata_done;
wire ata_irq;
wire io_request;
wire io_write;
wire [31:0] io_address;
wire [31:0] io_write_data;
wire [3:0] io_byte_enable;
wire [1:0] cpu_irq;
wire cpu_mem_request;
wire cpu_mem_rnw;
wire [31:0] cpu_mem_address;
wire cpu_mem_req64;
wire [2:0] cpu_mem_size;
wire [7:0] cpu_mem_write_mask;
wire [63:0] cpu_mem_data_write;
wire        cpu_mem_line_write;
wire [255:0] cpu_mem_line_data;
wire  [31:0] cpu_mem_line_bytes;
wire        cpu_mem_line_ra;
wire [63:0] cpu_mem_data_read;
wire cpu_mem_done;
wire cpu_mem_grant;
wire [63:0] cpu_cache_data;
wire cpu_cache_data_ready;
wire [5:0] cpu_errors;
wire [31:0] debug_cpu_pc;
wire [31:0] debug_cpu_retired;
wire [31:0] debug_cpu_irq_count;
wire [31:0] debug_cpu_t2_reload_count;
wire [31:0] debug_cop0_cause_live;
// ---------------------------------------------------------------------------
// The frozen pre-event execution trace, brought across from the CPU domain.
//
// This one is NOT a per-bit two-flop sync like every other field below, and
// deliberately so. Those carry live counters where a torn sample is merely a
// wrong digit for one frame; this carries 736 bits that must all describe the
// SAME instant, and independent bit synchronisers cannot promise that.
//
// What makes a single wide latch safe here is that the source stops changing.
// cpu.vhd freezes the whole capture on the first RAM -> boot ROM transition
// and never writes it again until reset. So: synchronise the one-bit frozen
// flag, wait for the clk93 side to have been static for a settling window,
// then take the payload once. After that the shadow is held, which also means
// the boot ROM's own execution after the restart cannot disturb what is on
// screen while it is being photographed.
//
// DEBUG_TRACE_SETTLE is counted in clk_core cycles at 50 MHz. Sixteen is
// ~320 ns against a 100 MHz source that went quiet at least two clk_core
// edges earlier, which is orders of magnitude more than the paths need.
localparam int DEBUG_TRACE_SETTLE = 16;
wire [895:0] debug_cpu_trace_bus;
wire debug_cpu_trace_frozen;
// State at the last eret before the trace froze. Held inside the CPU from the
// freeze onward, so these are stable by the time the video domain samples them
// - the same treatment the other frozen CPU counters get.
wire [31:0] debug_cpu_eret_epc;
wire [31:0] debug_cpu_eret_target;
wire [31:0] debug_cpu_eret_flags;
// DS/DP: how often the delay-slot suppression actually changed a recorded
// EPC, and the first EPC it changed. Live, because a freeze or a reset may
// fire no trace trigger at all.
wire [31:0] debug_cpu_ds_count;
wire [31:0] debug_cpu_ds_first;
reg  [31:0] debug_ds_count_meta = 32'd0, debug_ds_count_sync = 32'd0;
reg  [31:0] debug_ds_first_meta = 32'd0, debug_ds_first_sync = 32'd0;
// PCM FIFO health, reported as AU and AF. Already in clk_core, so no
// synchroniser is needed - ki_dcs_audio runs on the same clock the debug
// screen does.
wire [31:0] dcs_pcm_health;
wire [31:0] dcs_pcm_level;
reg  [31:0] debug_eret_epc_meta = 32'd0,      debug_eret_epc_sync = 32'd0;
reg  [31:0] debug_eret_target_meta = 32'd0,   debug_eret_target_sync = 32'd0;
reg  [31:0] debug_eret_flags_meta = 32'd0,    debug_eret_flags_sync = 32'd0;
reg debug_trace_frozen_meta = 1'b0;
reg debug_trace_frozen_sync = 1'b0;
reg [4:0] debug_trace_settle = 5'd0;
reg [895:0] debug_trace_shadow = 896'd0;
reg debug_trace_valid = 1'b0;
wire [31:0] debug_cpu_ret_count;
// COP0 Cause at the departure, captured in the CPU by the same statement that
// records DP/DO. This is the field that names WHY control left the program:
// ExcCode sits in bits 6:2 (0x4 AdEL, 0x5 AdES, 0x8 Sys, 0xA RI, 0x7/0xB/0xC/
// 0xD TLB, 0x0 Int). It has been captured since the departure capture went in
// but was wired to nothing, so the one value that separates "the game jumped"
// from "the game faulted" never reached the screen.
//
// Captured only on the 01 path (program -> boot ROM). On the 10 path it holds
// whatever the previous 01 departure left, which is why C: must be read too.
wire [31:0] debug_cpu_exc_cause;
reg [31:0] debug_cpu_ret_count_meta = 32'h0, debug_cpu_ret_count_sync = 32'h0;
// Departure capture from the CPU: the last PC executed in the decompressed
// program (the delay slot of the branch that left, when it left by one), the
// opcode one decode before it (that branch), and which of the two departure
// shapes it was. See the longer note at the capture block below, and
// cpu_pocket.vhd for the detector.
wire [31:0] debug_cpu_dep_pc;
wire        debug_cpu_dep_valid;
wire  [1:0] debug_cpu_dep_trigger;
wire [31:0] debug_cpu_prev_op;

// Crossing the capture into clk_core.
//
// These registers are held by the CPU from the departure until the next one, so
// the DATA is not what needs synchronising - only the news that it arrived. So
// the strobe is synchronised (two flops, rising-edge detected) and the payload
// is latched from the CPU-domain wires when the strobe lands. By then the
// payload has been still for at least two clk_core cycles, which is the
// standard "stable data, delayed strobe" crossing and costs one register per
// payload bit instead of two.
//
// The one assumption is that the CPU cannot depart twice inside that 40 ns
// window. It cannot: both departure shapes need many instructions between them,
// and the payload registers are only written at a decode that leaves the
// decompressed program. If that ever changed the symptom would be a mixed
// capture - PC from one departure, opcode from the next - not a frozen one.
//
// This matters for the fit: a full two-flop sync of the 64-bit payload pair cost
// 0.5 ns of clk_core slack for no extra correctness, in a design with one LAB of
// headroom.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg        debug_dep_valid_meta = 1'b0;
reg        debug_dep_valid_sync = 1'b0;
reg        debug_dep_valid_d    = 1'b0;
reg [31:0] debug_dep_pc_hold    = 32'd0;
reg [31:0] debug_dep_op_hold    = 32'd0;
reg  [1:0] debug_dep_trig_hold  = 2'd0;
reg  [7:0] debug_dep_cause_hold = 8'd0;

wire debug_dep_strobe = debug_dep_valid_sync & ~debug_dep_valid_d;

always @(posedge clk_core) begin
	debug_dep_valid_meta <= debug_cpu_dep_valid;
	debug_dep_valid_sync <= debug_dep_valid_meta;
	debug_dep_valid_d    <= debug_dep_valid_sync;

	if (shell_reset) begin
		debug_dep_pc_hold    <= 32'd0;
		debug_dep_op_hold    <= 32'd0;
		debug_dep_trig_hold  <= 2'd0;
		debug_dep_cause_hold <= 8'd0;
	end else if (debug_dep_strobe) begin
		debug_dep_pc_hold    <= debug_cpu_dep_pc;
		debug_dep_op_hold    <= debug_cpu_prev_op;
		debug_dep_trig_hold  <= debug_cpu_dep_trigger;
		debug_dep_cause_hold <= debug_cpu_exc_cause[7:0];
	end
end
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_pc_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_pc_sync = 32'h0000_0000;
// Per-game-frame stall census. ki_cpu_core latches these once per game frame
// and holds them for the whole of the next one, so they are already stable
// when this domain samples them - the two flops are for metastability, not
// coherence.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [223:0] debug_perf_bus_meta = 224'd0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [223:0] debug_perf_bus_sync = 224'd0;
wire [223:0] debug_perf_bus;
// Per-frame bridge census, counted in clk_core (50 MHz) - one count is two
// CPU cycles. Crossed into the CPU domain inside ki_cpu_core.
wire  [15:0] bridge_perf_out;
wire  [15:0] bridge_perf_burst;
// WHERE the frame's instructions retired, nine 16-bit fields of 256. Same
// per-bit sync as the other perf buses: latched once a frame in the CPU
// domain, so it has been still for thousands of cycles by the time the video
// domain samples it.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [335:0] debug_perf_prof_meta = 336'd0;
reg [2:0]   debug_prof_fine_meta = 3'd0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [335:0] debug_perf_prof_sync = 336'd0;
reg [2:0]   debug_prof_fine_sync = 3'd0;
wire [335:0] debug_perf_prof;
// Which coarse bucket F0..F7 cover. It travels with the prof bus because it
// is latched with it, so the two cannot disagree about which frame they show.
wire [2:0]  debug_prof_fine;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [223:0] debug_perf_worst_meta = 224'd0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [223:0] debug_perf_worst_sync = 224'd0;
wire [223:0] debug_perf_worst;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_retired_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_retired_sync = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_irq_count_meta = 32'h0000_0000;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [31:0] debug_cpu_irq_count_sync = 32'h0000_0000;
reg [31:0] debug_cpu_t2_reload_count_meta = 32'h0000_0000;
reg [31:0] debug_cpu_t2_reload_count_sync = 32'h0000_0000;
wire [2:0] debug_ata_state;
wire [7:0] debug_ata_status;
wire [7:0] debug_ata_error;
wire debug_ata_image_ready;
wire [31:0] debug_ata_info;

// Enable debug status overlay on Cyclone V 5CEBA4 to report live CPU PC, RET, ERR on Pocket screen.
localparam DEBUG_BUILD = 1;
localparam DEBUG_TRACE = 0;
reg [31:0] debug_ata_info_meta = 32'h0000_0000;
reg [31:0] debug_ata_info_sync = 32'h0000_0000;
// Interrupt decision set, crossed into clk_core.
//
// Until v1.0.25 this carried only {irq_sync, IP[7:0]} - the two things that
// say an interrupt is PENDING. It said nothing about whether the CPU was
// allowed to take one, so a run that showed IP[3:2] set and an accept count of
// zero could not be read: "no interrupt is enabled" and "the core will not
// accept one" produce the same screen. Those are opposite findings, and three
// builds (v1.0.21-v1.0.25) were spent looking at IRQs without the bits that
// separate them.
//
// irqTrigger in cpu_cop0.vhd is
//   SR.IE=1 && SR.EXL=0 && SR.ERL=0 && (SR.IM & Cause.IP) != 0
// so the missing half is IE, EXL and IM. Those are the bits added here,
// packed into 16 bits that map straight onto three screen digits.
//
//   probe[15:14] irq_sync (bit 1 ATA, bit 0 vblank, as driven into the CPU)
//   probe[13]    SR.IE
//   probe[12]    SR.EXL
//   probe[11:8]  SR.IM[3:0]  (bit 3 masks the ATA IRQ, bit 2 the vblank IRQ)
//   probe[7:0]   Cause.IP[7:0] (bit 3 ATA, bit 2 vblank)
reg [15:0] debug_cop0_probe_meta = 16'd0;
reg [15:0] debug_cop0_probe_sync = 16'd0;
wire [18:0] framebuffer_base;
wire framebuffer_memory_request;
wire [27:0] framebuffer_memory_address;
wire [2:0] framebuffer_memory_words;
wire [63:0] framebuffer_memory_data;
wire framebuffer_memory_data_valid;
wire framebuffer_memory_done;
wire fb_write_accept_pulse;
reg  fb_write_seen = 1'b0;

// Framebuffer liveness.
//
// The overlay used to auto-hide as soon as the CPU wrote its first framebuffer
// line, on the assumption that "it is drawing, so it is healthy". That is wrong
// exactly when it matters: a game that draws its POST and then hangs satisfies
// the assumption and hides the page that explains why. The Pocket has no OSD
// bit to fall back on (pk_io drives status to 0), so the Start+Select chord was
// the only route to the page - and a hung core gives no other sign.
//
// This counts FRAMES since the last accepted framebuffer write, not clocks. A
// 28-bit cycle counter cost more registers than the device had left (the fit
// failed by one LAB). Counting vblanks is both cheaper - six bits - and the
// more honest unit: a running game writes a line every frame, so "no writes
// for N frames" is the question worth asking. 2 s at ~59 Hz is 120 frames.
always @(posedge clk_core) begin
	if (core_reset)
		fb_write_seen <= 1'b0;
	else if (fb_write_accept_pulse && !cpu_reset)
		fb_write_seen <= 1'b1;
end
wire [7:0] framebuffer_red;
wire [7:0] framebuffer_green;
wire [7:0] framebuffer_blue;
wire [24:0] bridge_sdram_address;
wire [255:0] bridge_sdram_write_data;
wire [31:0] bridge_sdram_byte_enable;
wire [4:0] bridge_sdram_burst;
wire bridge_sdram_read;
wire bridge_sdram_write;
wire [31:0] bridge_sdram_read_data;
wire  [1:0] bridge_sdram_read_be;
wire bridge_sdram_data_valid;
wire bridge_sdram_done;
wire [24:0] controller_sdram_address;
wire [255:0] controller_sdram_write_data;
wire [31:0] controller_sdram_byte_enable;
wire [4:0] controller_sdram_burst;
wire controller_sdram_read;
wire controller_sdram_write;
wire [15:0] controller_sdram_read_data;
wire controller_sdram_dout_valid;
wire controller_sdram_ready;

// Physical SDRAM self test. Owns the SDRAM port until it completes, then hands
// it to the bridge for the rest of the session.
wire [24:0] bist_sdram_address;
wire [63:0] bist_sdram_write_data;
wire [7:0] bist_sdram_byte_enable;
wire [4:0] bist_sdram_burst;
wire bist_sdram_read;
wire bist_sdram_write;
wire bist_pass;
wire [15:0] bist_error_count;
wire [15:0] bist_first_bad_expected;
wire [15:0] bist_first_bad_actual;

// The BIST is a second requester on the adapter's auxiliary port, NOT a mux in
// front of the primary one. Steering the request lines by ownership discards
// whichever single-shot pulse is in flight when ownership changes, which
// would deadlock the ROM download.

wire [31:0] bist_sdram_read_data;
wire  [1:0] bist_sdram_read_be;
wire bist_sdram_data_valid;
wire bist_sdram_done;
wire sound_reset;
wire [31:0] sound_data;
wire sound_data_strobe;

// DCS audio board.
//
// host_reset is asserted while the core is in reset OR while the game holds
// the sound board reset low, so sound_reset is active-low here.
wire [15:0] dcs_host_status;
wire dcs_rom_request;
wire [18:0] dcs_rom_address;
wire dcs_rom_ready;
wire [63:0] dcs_rom_data;
wire signed [15:0] dcs_audio;
wire dcs_host_reset = core_reset | ~sound_reset;

reg debug_vblank_cpu_meta = 1'b0;
reg debug_vblank_cpu_sync = 1'b0;
reg debug_vblank_cpu_seen = 1'b0;
reg debug_cpu_reset_d = 1'b1;

// ---------------------------------------------------------------------------
// Departure capture: what replaced the first-reboot capture.
//
// The old block latched the CPU's PC and the reset-cause mask on the rising
// edge of cpu_reset. Two hardware reports (v1.0.12 and v1.0.13) read
// RP:00 V:0 from it: the capture never fired. That is a real finding, not a
// bug - nothing in cpu_reset's term list ever asserted after boot - but it
// leaves the original question unanswered, because a game can restart itself
// in SOFTWARE, with no reset at all, by jumping out of its decompressed
// program. That path leaves no trace in any reset counter and no evidence on
// any row of this screen.
//
// So what is captured now is the departure itself, inside the CPU, where the
// decode is visible (see cpu_pocket.vhd): the last PC executed in the
// decompressed program, the opcode one decode before it, and which of the two
// shapes it was - 01 = jumped into the boot ROM (an error or watchdog path),
// 10 = jumped straight back to 0x88000000 (a deliberate restart). It is armed
// by the departure, not by a reset, so it fires on exactly the case the reset
// capture could not see.
//
// This costs no new page and no new snapshot bits: the capture lands in the two
// fields this screen already had - DP on row 14 and DO on row 10 - and reuses
// the V and C columns of row 14 for validity and trigger. The synchroniser is
// declared up with the other CPU-domain crossings.
reg debug_ioctl_download_d = 1'b0;
// Reset provenance is retained across the resets it records:
//   (top digit)   always 0.
//   total_resets  rising edges of cpu_reset over the whole run.
//   late_resets   resets after the CPU has been continuously OUT of reset for
//                 2^24 core clocks, about a third of a second - far past any
//                 boot activity, so a nonzero value is a genuine mid-game
//                 reset and zero means the CPU reached BFC00000 on its own.
//   mask          cause terms, sampled only at late resets.
//
// These counters use only their initial value so reset provenance survives.
reg [3:0]  debug_rs_total = 4'd0;
reg [7:0]  debug_rs_count = 8'd0;
reg [7:0]  debug_rs_pulse_count = 8'd0;
reg [15:0] debug_rs_mask = 16'd0;
reg        debug_rs_armed = 1'b0;
reg [24:0] debug_rs_settle = 25'd0;
// Digits 2-3 are the debounced pulse count. A difference between the raw and
// debounced totals identifies a stuttering reset source.
wire [31:0] debug_reset_info =
    {4'd0, debug_rs_total, debug_rs_pulse_count, debug_rs_mask};
// The sticky mask ORs every late reset together, so one OSD reset by the
// operator contaminates it permanently and hides which term caused the FIRST
// one. This freezes the first SPONTANEOUS late reset's terms on their own.
//
// Spontaneous matters because the test procedure is: load the MRA, mount the
// image, then issue an OSD reset. That reset lands long after debug_rs_armed
// has set, so it is a "late" reset by every measure and it would otherwise be
// the one this field froze - the operator's own reset, reported as the answer.
// A pulse carrying status[0] or buttons[1] is the operator and is skipped.
//
// RESET is deliberately NOT treated as operator-initiated. The OSD reset drives
// status[0], not that pin, and an HPS asserting RESET on its own is a real
// candidate for what stops the game.
//
// Accumulated across the whole reset PULSE rather than sampled on its rising
// edge. If the cause is a PLL that has lost lock then clk_core is exactly the
// thing that cannot be trusted at that edge, and a level-sensitive OR over the
// pulse has many more chances to catch it than one clock edge does.
//
// The pulse is DEBOUNCED: it is over only once cpu_reset has been continuously
// low for 2^20 core clocks, about 21 ms. A term that stutters glitches for a
// cycle or so, while the events this has to separate - an operator reset at
// the start of a run and a failure minutes later - are seconds apart.
localparam int RS_GAP_BITS = 20;
reg [15:0] debug_rs_first_mask = 16'd0;
reg        debug_rs_first_done = 1'b0;
reg [15:0] debug_rs_pulse_mask = 16'd0;
reg        debug_rs_pulse_active = 1'b0;
reg [RS_GAP_BITS-1:0] debug_rs_gap = {RS_GAP_BITS{1'b0}};
reg [3:0]  debug_rs_spont_count = 4'd0;
// PLL lock, watched from the RAW 50 MHz reference instead of from a clock the
// PLL produces. If pll_locked is what drops, every counter in the clk_core
// domain is suspect at precisely the moment that matters; CLK_50M keeps
// running regardless. Never reset - it has to survive what it counts.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg debug_pll_lock_meta = 1'b0;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg debug_pll_lock_sync = 1'b0;
reg debug_pll_lock_d = 1'b0;
reg [7:0] debug_pll_unlock_count = 8'd0;

always @(posedge CLK_50M) begin
	debug_pll_lock_meta <= pll_locked;
	debug_pll_lock_sync <= debug_pll_lock_meta;
	debug_pll_lock_d    <= debug_pll_lock_sync;
	if(!debug_pll_lock_sync && debug_pll_lock_d &&
	   debug_pll_unlock_count != 8'hff)
		debug_pll_unlock_count <= debug_pll_unlock_count + 8'd1;
end

// The unlock count changes at most a handful of times in a run, so reading it
// through a plain two-flop sync can at worst show one stale digit for one
// frame. That is acceptable here and a handshake is not worth the logic.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [7:0] debug_pll_unlock_meta = 8'd0;
reg [7:0] debug_pll_unlock_sync = 8'd0;
reg [7:0] debug_ioctl_download_count = 8'h00;
wire [31:0] debug_reset_first =
    {debug_rs_first_mask, debug_pll_unlock_sync,
     debug_rs_spont_count, debug_ioctl_download_count[3:0]};
always @(posedge clk_core) begin
	debug_cpu_reset_d <= cpu_reset;
	debug_ioctl_download_d <= ioctl_download;
	// Every cpu_reset rise, over the whole run.
	if(cpu_reset && !debug_cpu_reset_d && debug_rs_total != 4'hf)
		debug_rs_total <= debug_rs_total + 1'b1;
	// Arm only after the CPU has been continuously out of reset long enough
	// that boot cannot still be in progress.
	if(cpu_reset) debug_rs_settle <= 25'd0;
	else if(!debug_rs_armed) begin
		if(debug_rs_settle == 25'h1ffffff) debug_rs_armed <= 1'b1;
		else debug_rs_settle <= debug_rs_settle + 1'b1;
	end
	debug_pll_unlock_meta <= debug_pll_unlock_count;
	debug_pll_unlock_sync <= debug_pll_unlock_meta;
	// Accumulate the terms of the late reset PULSE currently in progress, then
	// judge it once the pulse has been over for the debounce window. A pulse is
	// the operator's if status[0] or buttons[1] appeared anywhere in it;
	// anything else is spontaneous, gets counted, and the first one freezes RF.
	if(cpu_reset) begin
		debug_rs_gap <= {RS_GAP_BITS{1'b0}};
		if(debug_rs_armed) begin
			debug_rs_pulse_active  <= 1'b1;
			debug_rs_pulse_mask[0] <= debug_rs_pulse_mask[0] | shell_reset;
			debug_rs_pulse_mask[1] <= debug_rs_pulse_mask[1] | ioctl_download;
			debug_rs_pulse_mask[2] <= debug_rs_pulse_mask[2] | ~boot_loaded;
			debug_rs_pulse_mask[3] <= debug_rs_pulse_mask[3] | ~sdram_ready;
			debug_rs_pulse_mask[4] <= debug_rs_pulse_mask[4] | bist_busy;
			debug_rs_pulse_mask[6] <= debug_rs_pulse_mask[6] | ~pll_locked;
			debug_rs_pulse_mask[7] <= debug_rs_pulse_mask[7] | status[0];
			debug_rs_pulse_mask[8] <= debug_rs_pulse_mask[8] | RESET;
			debug_rs_pulse_mask[9] <= debug_rs_pulse_mask[9] | buttons[1];
		end
	end else begin
		if(debug_rs_gap != {RS_GAP_BITS{1'b1}})
			debug_rs_gap <= debug_rs_gap + 1'b1;
		else if(debug_rs_pulse_active) begin
			debug_rs_pulse_active <= 1'b0;
			debug_rs_pulse_mask   <= 16'd0;
			if(debug_rs_pulse_count != 8'hff)
				debug_rs_pulse_count <= debug_rs_pulse_count + 8'd1;
			if(!debug_rs_pulse_mask[7] && !debug_rs_pulse_mask[9]) begin
				if(debug_rs_spont_count != 4'hf)
					debug_rs_spont_count <= debug_rs_spont_count + 4'd1;
				if(!debug_rs_first_done) begin
					debug_rs_first_mask <= debug_rs_pulse_mask;
					debug_rs_first_done <= 1'b1;
				end
			end
		end
	end
	if(debug_rs_armed && cpu_reset && !debug_cpu_reset_d) begin
		if(debug_rs_count != 8'hff)
			debug_rs_count <= debug_rs_count + 1'b1;
		debug_rs_mask[0] <= debug_rs_mask[0] | shell_reset;
		debug_rs_mask[1] <= debug_rs_mask[1] | ioctl_download;
		debug_rs_mask[2] <= debug_rs_mask[2] | ~boot_loaded;
		debug_rs_mask[3] <= debug_rs_mask[3] | ~sdram_ready;
		debug_rs_mask[4] <= debug_rs_mask[4] | bist_busy;
		debug_rs_mask[6] <= debug_rs_mask[6] | ~pll_locked;
		debug_rs_mask[7] <= debug_rs_mask[7] | status[0];
		debug_rs_mask[8] <= debug_rs_mask[8] | RESET;
		debug_rs_mask[9] <= debug_rs_mask[9] | buttons[1];
	end
	if(ioctl_download && !debug_ioctl_download_d)
		debug_ioctl_download_count <= debug_ioctl_download_count + 1'b1;
end

// Mirror the CPU wrapper's vblank synchronizer for diagnostics. The sampled
// value is sticky so the 50 MHz debug page can report a pulse seen by CPU time.
always @(posedge clk_cpu) begin
	if(cpu_reset) begin
		debug_vblank_cpu_meta <= 1'b0;
		debug_vblank_cpu_sync <= 1'b0;
		debug_vblank_cpu_seen <= 1'b0;
	end else begin
		debug_vblank_cpu_meta <= vblank;
		debug_vblank_cpu_sync <= debug_vblank_cpu_meta;
		if(debug_vblank_cpu_sync)
			debug_vblank_cpu_seen <= 1'b1;
	end
end

always @(posedge clk_core) begin
	debug_cpu_pc_meta <= debug_cpu_pc;
	debug_cpu_pc_sync <= debug_cpu_pc_meta;
	debug_perf_bus_meta <= debug_perf_bus;
	debug_perf_bus_sync <= debug_perf_bus_meta;
	debug_perf_worst_meta <= debug_perf_worst;
	debug_perf_worst_sync <= debug_perf_worst_meta;
	debug_perf_prof_meta <= debug_perf_prof;
	debug_perf_prof_sync <= debug_perf_prof_meta;
	debug_prof_fine_meta <= debug_prof_fine;
	debug_prof_fine_sync <= debug_prof_fine_meta;
	debug_cpu_retired_meta <= debug_cpu_retired;
	debug_cpu_retired_sync <= debug_cpu_retired_meta;
	debug_cpu_irq_count_meta <= debug_cpu_irq_count;
	debug_cpu_irq_count_sync <= debug_cpu_irq_count_meta;
	debug_cpu_t2_reload_count_meta <= debug_cpu_t2_reload_count;
	debug_cpu_t2_reload_count_sync <= debug_cpu_t2_reload_count_meta;
	debug_cpu_ret_count_meta <= debug_cpu_ret_count;
	debug_cpu_ret_count_sync <= debug_cpu_ret_count_meta;
	debug_ata_info_meta <= debug_ata_info;
	debug_ata_info_sync <= debug_ata_info_meta;
	debug_cop0_probe_meta <=
		{debug_cop0_cause_live[31:30],  // irq_sync, substituted in ki_cpu_core
		 debug_cop0_cause_live[0],     // SR.IE
		 debug_cop0_cause_live[16],    // SR.EXL
		 debug_cop0_cause_live[27:24], // SR.IM[3:0]
		 debug_cop0_cause_live[15:8]}; // Cause.IP[7:0]
	debug_cop0_probe_sync <= debug_cop0_probe_meta;
	debug_ds_count_meta <= debug_cpu_ds_count;
	debug_ds_count_sync <= debug_ds_count_meta;
	debug_ds_first_meta <= debug_cpu_ds_first;
	debug_ds_first_sync <= debug_ds_first_meta;
	debug_eret_epc_meta <= debug_cpu_eret_epc;
	debug_eret_epc_sync <= debug_eret_epc_meta;
	debug_eret_target_meta <= debug_cpu_eret_target;
	debug_eret_target_sync <= debug_eret_target_meta;
	debug_eret_flags_meta <= debug_cpu_eret_flags;
	debug_eret_flags_sync <= debug_eret_flags_meta;
	if(shell_reset) begin
		debug_cpu_pc_meta <= 32'h0000_0000;
		debug_cpu_pc_sync <= 32'h0000_0000;
		debug_perf_bus_meta <= 192'd0;
		debug_perf_bus_sync <= 192'd0;
		debug_perf_prof_meta <= 336'd0;
		debug_perf_prof_sync <= 336'd0;
		debug_prof_fine_meta <= 3'd0;
		debug_prof_fine_sync <= 3'd0;
		debug_perf_worst_meta <= 192'd0;
		debug_perf_worst_sync <= 192'd0;
		debug_cpu_retired_meta <= 32'h0000_0000;
		debug_cpu_retired_sync <= 32'h0000_0000;
		debug_cpu_irq_count_meta <= 32'h0000_0000;
		debug_cpu_irq_count_sync <= 32'h0000_0000;
		debug_cpu_t2_reload_count_meta <= 32'h0000_0000;
		debug_cpu_t2_reload_count_sync <= 32'h0000_0000;
	end
end

assign io_read_data = ata_done ? ata_read_data : board_io_read_data;
assign io_done = board_io_done | ata_done;

// ki_ata drives bus_done combinationally from bus_request, so the command
// request itself is edge-detected to separate adjacent accesses.
wire ata_cmd_write = io_request && io_write &&
                     (io_address == 32'h1000_0138) && io_byte_enable[0];
reg        ata_cmd_write_d = 1'b0;

always @(posedge clk_core) begin
	if(core_reset)
		ata_cmd_write_d <= 1'b0;
	else
		ata_cmd_write_d <= ata_cmd_write;
end

// ---------------------------------------------------------------------------
// "THE GAME HAS RESTARTED", from the board side.
//
// The trace's own triggers are pc comparisons and can only catch a restart
// that goes where they are looking. This one does not care: INITIALIZE DEVICE
// PARAMETERS is issued by the disk-init routine, which is reached only from
// the game's startup path, so a later invocation means startup ran again.
//
// Held once asserted, so the CPU-domain synchronizer cannot miss it.
// Disk init issues 0x91 twice per startup, so the third invocation is the first
// one that can indicate a restart.
reg  [7:0] ata_init_count = 8'd0;
// The THIRD disk init. Startup issues exactly two in both games, so the
// third belongs to the restart. Counted rather than gated: the CPU's
// end-of-boot flag opens before the first handoff and cannot be used here.
wire ata_restart_seen = (ata_init_count >= 8'd3);

always @(posedge clk_core) begin
	if(core_reset) begin
		ata_init_count <= 8'd0;
	end else begin
		if(ata_cmd_write && !ata_cmd_write_d &&
		   io_write_data[7:0] == 8'h91 && ata_init_count != 8'hff)
			ata_init_count <= ata_init_count + 8'd1;
	end
end

// Changes level at every page flip - a change of framebuffer_base, the event
// ki_fps_overlay counts. ki_cpu_core's Perf census closes a game frame at each
// change.
reg        perf_flip = 1'b0;
reg [18:0] perf_flip_base = 19'd0;
always @(posedge clk_core) begin
	perf_flip_base <= framebuffer_base;
	if(!core_reset && framebuffer_base != perf_flip_base)
		perf_flip <= ~perf_flip;
end

// The data cache's direct fill path: from the CPU's clock to the SDRAM
// controller's second port and back through ki_fast_fill, inside the adapter.
wire        cpu_fast_ok;
wire        cpu_fast_req_tog;
wire [31:0] cpu_fast_req_line;
wire        cpu_fast_window;
wire        cpu_fast_beat;
wire        cpu_fast_first;
wire [63:0] cpu_fast_qword;
wire        cpu_fast_done_tog;
wire        controller_fast_tog;
wire [24:0] controller_fast_addr;
wire        controller_fast_valid;

ki_cpu_core #(
	.DEBUG_TRACE(DEBUG_TRACE),
	// clk_cpu and clk_core are both 50 MHz out of one PLL (see pll_0002.v), not
	// the 100:50 of the MiSTer build SYNC_CROSSING was written for. The
	// crossing must therefore go back through its two-flop synchronisers:
	// reading the other domain's raw register across a 250 ps offset lost
	// responses in the return FIFO, and the boot ROM's cache-flush lw at
	// 0xBFC00400 never saw its mem_done. That is the black screen.
	.SYNC_CROSSING(0),
	.DCACHE_FB_PARTIAL(0),
	.DCACHE_CWF_FB(0),
	.DCACHE_FILL_FIRST(0),
	.DCACHE_FILL_AT_MISS(0),
	.DCACHE_READ_AHEAD(0),
	.DCACHE_RA_ANSWER(0),
	.DCACHE_EARLY_RESTART(0),
	.DIRECT_FILL(0)
) cpu
(
	.clk1x(clk_core),
	.clk93(clk_cpu),
	.reset(cpu_reset),
	.irq(cpu_irq),
	.pause(core_pause),
	.mem_request(cpu_mem_request),
	.mem_rnw(cpu_mem_rnw),
	.mem_address(cpu_mem_address),
	.mem_req64(cpu_mem_req64),
	.mem_size(cpu_mem_size),
	.mem_writeMask(cpu_mem_write_mask),
	.mem_dataWrite(cpu_mem_data_write),
	.mem_line_write(cpu_mem_line_write),
	.mem_line_data(cpu_mem_line_data),
	.mem_line_bytes(cpu_mem_line_bytes),
	.mem_line_ra(cpu_mem_line_ra),
	.mem_dataRead(cpu_mem_data_read),
	.mem_done(cpu_mem_done),
	.cache_grant(cpu_mem_grant),
	.cache_data(cpu_cache_data),
	.cache_data_ready(cpu_cache_data_ready),
	.fast_ok(cpu_fast_ok),
	.fast_req_tog(cpu_fast_req_tog),
	.fast_req_line(cpu_fast_req_line),
	.fast_window(cpu_fast_window),
	.fast_beat(cpu_fast_beat),
	.fast_first(cpu_fast_first),
	.fast_qword(cpu_fast_qword),
	.fast_done_tog(cpu_fast_done_tog),
	.errors(cpu_errors),
	.debug_fetch_pc(debug_cpu_pc),
	.debug_retired(debug_cpu_retired),
	.perf_flip(perf_flip),
	.perf_clear(status[7]),
	.prof_fine_sel(status[12:9]),
	.perf_bridge_out(bridge_perf_out),
	.perf_bridge_burst(bridge_perf_burst),
	.debug_perf_bus(debug_perf_bus),
	.debug_perf_worst(debug_perf_worst),
	.debug_perf_prof(debug_perf_prof),
	.debug_prof_fine(debug_prof_fine),
	.debug_gpr_s1(),
	.debug_irq_count(debug_cpu_irq_count),
	.debug_t2_reload_count(debug_cpu_t2_reload_count),
	.debug_h1_op(debug_cpu_prev_op),
	.debug_dep_pc(debug_cpu_dep_pc),
	.debug_dep_valid(debug_cpu_dep_valid),
	.debug_dep_trigger(debug_cpu_dep_trigger),
	.debug_exc_cause(debug_cpu_exc_cause),
	.debug_cop0_cause_live(debug_cop0_cause_live),
	.debug_ret_count(debug_cpu_ret_count),
	.debug_trace_bus(debug_cpu_trace_bus),
	.debug_trace_frozen(debug_cpu_trace_frozen),
	.debug_trace_trigger(ata_restart_seen),
	.debug_ds_count(debug_cpu_ds_count),
	.debug_ds_first(debug_cpu_ds_first),
	.debug_eret_epc(debug_cpu_eret_epc),
	.debug_eret_target(debug_cpu_eret_target),
	.debug_eret_flags(debug_cpu_eret_flags),
	.debug_retire_pc(),
	.debug_retire_opcode()
);

generate if (DEBUG_TRACE) begin : g_trace_shadow
	// Latch the frozen trace once, on the clk_core side. See the declaration
	// comment for why this is a single wide capture instead of the usual per-bit
	// two-flop sync.
	always @(posedge clk_core) begin
		debug_trace_frozen_meta <= debug_cpu_trace_frozen;
		debug_trace_frozen_sync <= debug_trace_frozen_meta;

		if(shell_reset) begin
			debug_trace_frozen_meta <= 1'b0;
			debug_trace_frozen_sync <= 1'b0;
			debug_trace_settle <= 5'd0;
			debug_trace_valid <= 1'b0;
			debug_trace_shadow <= 896'd0;
		end else if(!debug_trace_valid) begin
			if(!debug_trace_frozen_sync) begin
				debug_trace_settle <= 5'd0;
			end else if(debug_trace_settle != DEBUG_TRACE_SETTLE[4:0]) begin
				debug_trace_settle <= debug_trace_settle + 5'd1;
			end else begin
				debug_trace_shadow <= debug_cpu_trace_bus;
				debug_trace_valid <= 1'b1;
			end
		end
	end
end else begin : g_no_trace_shadow
	// Nothing to latch: cpu.vhd drives the bus to zero when the trace is not
	// built, so the shadow and its settle counter would be 896 registers
	// holding a constant.
	always @(posedge clk_core) begin
		debug_trace_frozen_meta <= 1'b0;
		debug_trace_frozen_sync <= 1'b0;
		debug_trace_settle      <= 5'd0;
		debug_trace_valid       <= 1'b0;
		debug_trace_shadow      <= 896'd0;
	end
end endgenerate

ki_memory_bridge memory_bridge
(
	.clk(clk_core),
	.ddr_clk(clk_ddr),
	.reset(shell_reset),
	.cpu_request(cpu_mem_request),
	.cpu_hold(core_pause),
	.cpu_rnw(cpu_mem_rnw),
	.cpu_address(cpu_mem_address),
	.cpu_req64(cpu_mem_req64),
	.cpu_size(cpu_mem_size),
	.cpu_write_mask(cpu_mem_write_mask),
	.cpu_data_write(cpu_mem_data_write),
	.cpu_line_write(cpu_mem_line_write),
	.cpu_line_data(cpu_mem_line_data),
	.cpu_line_bytes(cpu_mem_line_bytes),
	.cpu_line_ra(cpu_mem_line_ra),
	.cpu_data_read(cpu_mem_data_read),
	.cpu_done(cpu_mem_done),
	.cpu_grant(cpu_mem_grant),
	.cpu_cache_data(cpu_cache_data),
	.cpu_cache_data_ready(cpu_cache_data_ready),
	.fast_ok(cpu_fast_ok),
	.io_request(io_request),
	.io_write(io_write),
	.io_address(io_address),
	.io_write_data(io_write_data),
	.io_byte_enable(io_byte_enable),
	.io_read_data(io_read_data),
	.io_done(io_done),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.boot_loaded(boot_loaded),
	.video_request(framebuffer_memory_request),
	.video_address(framebuffer_memory_address),
	.video_words(framebuffer_memory_words),
	.video_data(framebuffer_memory_data),
	.video_data_valid(framebuffer_memory_data_valid),
	.video_done(framebuffer_memory_done),
	.dcs_rom_request(dcs_rom_request),
	.dcs_rom_address(dcs_rom_address),
	.dcs_rom_ready(dcs_rom_ready),
	.dcs_rom_data(dcs_rom_data),
	.sdram_address(bridge_sdram_address),
	.sdram_write_data(bridge_sdram_write_data),
	.sdram_byte_enable(bridge_sdram_byte_enable),
	.sdram_burst(bridge_sdram_burst),
	.sdram_read(bridge_sdram_read),
	.sdram_write(bridge_sdram_write),
	.sdram_read_data(bridge_sdram_read_data),
	.sdram_read_be(bridge_sdram_read_be),
	.sdram_data_valid(bridge_sdram_data_valid),
	.sdram_done(bridge_sdram_done),
	.sdram_ready(sdram_ready),
	.ddram_busy(DDRAM_BUSY),
	.ddram_burstcnt(DDRAM_BURSTCNT),
	.ddram_addr(DDRAM_ADDR),
	.ddram_dout(DDRAM_DOUT),
	.ddram_dout_ready(DDRAM_DOUT_READY),
	.ddram_rd(DDRAM_RD),
	.ddram_din(DDRAM_DIN),
	.ddram_be(DDRAM_BE),
	.ddram_we(DDRAM_WE),
	.fb_read_accept(),
	.fb_write_accept(fb_write_accept_pulse),
	.perf_frame(frame_start),
	.perf_cpu_outstanding(bridge_perf_out),
	.perf_cpu_burst(bridge_perf_burst),
	.debug_write_count(),
	.debug_low_write_count(),
	.debug_main_write_count(),
	.debug_download_info(debug_download_info)
);

`ifdef KI_DEBUG_BUILD
// 256 words per pass. A short sweep finishes quickly and still exercises the
// READ-BACK path. Built only into the debug build, which shows its result.
ki_sdram_bist #(.WORDS(256)) sdram_bist
(
	.clk(clk_core),
	.reset(shell_reset),
	.sdram_ready(sdram_ready),
	.boot_loaded(boot_loaded),
	.request_address(bist_sdram_address),
	.request_write_data(bist_sdram_write_data),
	.request_byte_enable(bist_sdram_byte_enable),
	.request_burst(bist_sdram_burst),
	.request_read(bist_sdram_read),
	.request_write(bist_sdram_write),
	.request_read_data(bist_sdram_read_data),
	.request_read_be(bist_sdram_read_be),
	.request_data_valid(bist_sdram_data_valid),
	.request_done(bist_sdram_done),
	.rom_checksum(),
	.busy(bist_busy),
	.done(bist_done),
	.pass(bist_pass),
	.error_count(bist_error_count),
	.first_bad_address(),
	.first_bad_expected(bist_first_bad_expected),
	.first_bad_actual(bist_first_bad_actual)
);
`else
// No self test: the CPU starts as soon as the ROM is loaded and the SDRAM is
// ready, and the adapter's auxiliary port stays idle.
assign bist_busy = 1'b0;
assign bist_done = 1'b1;
assign bist_pass = 1'b1;
assign bist_error_count = 16'd0;
assign bist_first_bad_expected = 16'd0;
assign bist_first_bad_actual = 16'd0;
assign bist_sdram_address = 25'd0;
assign bist_sdram_write_data = 64'd0;
assign bist_sdram_byte_enable = 8'd0;
assign bist_sdram_burst = 5'd0;
assign bist_sdram_read = 1'b0;
assign bist_sdram_write = 1'b0;
`endif

wire [15:0] debug_adapter_status;
reg debug_packed_ready_seen = 1'b0;
always @(posedge clk_core) begin
	if (!pll_locked)
		debug_packed_ready_seen <= 1'b0;
	else if (debug_adapter_status[12])
		debug_packed_ready_seen <= 1'b1;
end

// Hold the SDRAM adapter (clk_core + clk_sdram_ctl) and burst controller
// (clk_sdram_ctl) in synchronous reset/init for 8 clk_core cycles (= 16
// clk_sdram_ctl cycles) after pll_locked asserts. Asynchronous clear ensures
// reset starts even before either PLL clock toggles cleanly, and holding init
// across post-lock clock edges prevents ki_sdram_x2/ki_sdram_burst from starting
// with un-reset state if pll_locked rises asynchronously or before clk2x starts.
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg [7:0] sdram_postlock_pipe = 8'd0;
always @(posedge clk_core or negedge pll_locked) begin
	if (!pll_locked)
		sdram_postlock_pipe <= 8'd0;
	else
		sdram_postlock_pipe <= {sdram_postlock_pipe[6:0], 1'b1};
end
wire sdram_init_reset = ~sdram_postlock_pipe[7];

// ki_sdram_x2 lives inside the adapter and packs the controller's 16-bit beats
// into the 32 bits clk_core expects. clk_sdram_ctl runs at twice clk_core, so
// a 32-bit beat comes out every clk_core cycle.
ki_sdram_adapter sdram_adapter
(
	.clk(clk_core),
	.clk2x(clk_sdram_ctl),
	.reset(sdram_init_reset),
	.request_address(bridge_sdram_address),
	.request_write_data(bridge_sdram_write_data),
	.request_byte_enable(bridge_sdram_byte_enable),
	.request_burst(bridge_sdram_burst),
	.request_read(bridge_sdram_read),
	.request_write(bridge_sdram_write),
	.request_read_data(bridge_sdram_read_data),
	.request_read_be(bridge_sdram_read_be),
	.request_data_valid(bridge_sdram_data_valid),
	.request_done(bridge_sdram_done),
	.aux_address(bist_sdram_address),
	.aux_write_data(bist_sdram_write_data),
	.aux_byte_enable(bist_sdram_byte_enable),
	.aux_burst(bist_sdram_burst),
	.aux_read(bist_sdram_read),
	.aux_write(bist_sdram_write),
	.aux_read_data(bist_sdram_read_data),
	.aux_read_be(bist_sdram_read_be),
	.aux_data_valid(bist_sdram_data_valid),
	.aux_done(bist_sdram_done),
	.sdram_ready(sdram_ready),
	.fast_req_tog(cpu_fast_req_tog),
	.fast_req_line(cpu_fast_req_line),
	.fast_window(cpu_fast_window),
	.fast_beat(cpu_fast_beat),
	.fast_first(cpu_fast_first),
	.fast_qword(cpu_fast_qword),
	.fast_done_tog(cpu_fast_done_tog),
	.controller_address(controller_sdram_address),
	.controller_write_data(controller_sdram_write_data),
	.controller_byte_enable(controller_sdram_byte_enable),
	.controller_burst(controller_sdram_burst),
	.controller_read(controller_sdram_read),
	.controller_write(controller_sdram_write),
	.controller_read_data(controller_sdram_read_data),
	.controller_dout_valid(controller_sdram_dout_valid),
	.controller_ready(controller_sdram_ready),
	.controller_fast_tog(controller_fast_tog),
	.controller_fast_addr(controller_fast_addr),
	.controller_fast_valid(controller_fast_valid),
	.debug_status(debug_adapter_status)
);

// The address decomposition uses col = addr[9:1], so 512 consecutive words
// share a row and a burst is a sequence of back-to-back column accesses.
// SDRAM contents are transient because the ROM download repopulates memory on
// every core load.
// 100 MHz floors: tRP 18->2, tRCD 18->2, tRAS 42->5, tRC 7, tRFC 66->7,
// tWR 15->2. CL2 is in spec for a -75 part at 100 MHz.
ki_sdram_burst #(
	.T_RP(4'd2), .T_RCD(4'd2), .T_RAS(5'd5), .T_RC(5'd7),
	.T_RFC(4'd7), .T_WR(4'd2), .CAS_LATENCY(3'd2),
	.STARTUP_CYCLES(15'd12000), .REFRESH_PERIOD(13'd730)
) sdram_controller
(
	.init(sdram_init_reset),
	.clk(clk_sdram_ctl), .clk_cap(clk_sdram_cap),
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.wtbt(controller_sdram_byte_enable),
	.addr(controller_sdram_address),
	.burst(controller_sdram_burst),
	.dout(controller_sdram_read_data),
	.dout_valid(controller_sdram_dout_valid),
	.din(controller_sdram_write_data),
	.we(controller_sdram_write),
	.rd(controller_sdram_read),
	.ready(controller_sdram_ready),
	.fast_tog(controller_fast_tog),
	.fast_addr(controller_fast_addr),
	.fast_valid(controller_fast_valid)
);

ki_framebuffer framebuffer
(
	.clk(clk_core),
	.reset(core_reset),
	.ce_pixel(CE_PIXEL),
	.h_count(h_count),
	.v_count(v_count),
	.framebuffer_base(framebuffer_base),
	.memory_request(framebuffer_memory_request),
	.memory_address(framebuffer_memory_address),
	.memory_words(framebuffer_memory_words),
	.memory_data(framebuffer_memory_data),
	.memory_data_valid(framebuffer_memory_data_valid),
	.memory_done(framebuffer_memory_done),
	.red(framebuffer_red),
	.green(framebuffer_green),
	.blue(framebuffer_blue),
	.pixel_valid()
);

ki_board_io board_io
(
	.clk(clk_core),
	.reset(core_reset),
	.game_ki2(game_ki2),
	.bus_request(io_request),
	.bus_write(io_write),
	.bus_address(io_address),
	.bus_write_data(io_write_data),
	.bus_byte_enable(io_byte_enable),
	.bus_read_data(board_io_read_data),
	.bus_done(board_io_done),
	.input_p1(input_p1),
	.input_p2(input_p2),
	// Bit 1 is the sound board's "ready" line back to the game, taken from the
	// DCS host status. The game polls it, so it has to reflect the real board.
	.input_volume({30'h3fff_ffff, dcs_host_status[11], 1'b1}),
	.input_dip({16'hffff, dip_switches_live}),
	.input_unused(32'hffff_ffff),
	.irq_vblank(vblank),
	.irq_ata(ata_irq),
	.cpu_irq(cpu_irq),
	.framebuffer_base(framebuffer_base),
	.sound_reset(sound_reset),
	.sound_data(sound_data),
	.sound_data_strobe(sound_data_strobe)
);

ki_dcs_audio dcs_audio_board
(
	.clk(clk_core),
	.rst(shell_reset),
	.pause(core_pause),
	.host_reset(dcs_host_reset),
	.host_cmd_wr(sound_data_strobe),
	.host_cmd_data(sound_data[15:0]),
	.host_status(dcs_host_status),
	.rom_req(dcs_rom_request),
	.rom_addr(dcs_rom_address),
	.rom_rdy(dcs_rom_ready),
	.rom_q(dcs_rom_data),
	.audio(dcs_audio),
	.dbg_valid(),
	.dbg_unimpl(),
	.dbg_pcm_push(),
	.dbg_pc(),
	.dbg_pcm_health(dcs_pcm_health),
	.dbg_pcm_level(dcs_pcm_level)
);

ki_ata ata
(
	.clk(clk_core),
	.reset(core_reset),
	.game_ki2(game_ki2),
	.bus_request(io_request),
	.bus_write(io_write),
	.bus_address(io_address),
	.bus_write_data(io_write_data),
	.bus_byte_enable(io_byte_enable),
	.bus_read_data(ata_read_data),
	.bus_done(ata_done),
	.irq(ata_irq),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_blk_cnt(sd_blk_cnt),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.debug_info(debug_ata_info),
	.debug_read_lba(),
	.debug_write_lba(),
	.debug_state(debug_ata_state),
	.debug_status(debug_ata_status),
	.debug_error(debug_ata_error),
	.debug_image_ready(debug_ata_image_ready)
);

// RC packs all three restart shapes into one row:
//
//   digits 0-1  executions of 0x88000000, the entry point. Boot is 1.
//   digits 2-3  ATA INITIALIZE DEVICE PARAMETERS commands. Boot is 1.
//   digits 4-7  RAM -> boot ROM transitions.
//
// The CPU exports {entry[15:0], transitions[15:0]}; only the low byte of the
// entry count can plausibly be non-zero, so bits 23:16 carry it.
wire [31:0] debug_restart_info =
    {debug_cpu_ret_count_sync[23:16], ata_init_count,
     debug_cpu_ret_count_sync[15:0]};

wire [7:0] debug_red;
wire [7:0] debug_green;
wire [7:0] debug_blue;

// Start + Select. The ids in input.json are id 10 = 1P Start, id 11 = Insert
// Coin (the Pocket's Select button), so those are the bits to watch. The old
// detector also watched bits 14/15 and 8/9, which are either unused or two
// kick buttons, and ANDed them in the live clock domain - both a false-positive
// and a metastability risk. ki_input_chord owns the whole function now.
wire dbg_chord_pulse;
wire dbg_chord_held;
ki_input_chord #(.WINDOW_CYCLES(12_500_000), .WINDOW_BITS(24)) dbg_chord (
	.clk      (clk_core),
	.reset    (shell_reset),
	.start_i  (joystick_0[10]),
	.select_i (joystick_0[11]),
	.pulse    (dbg_chord_pulse),
	.both_held(dbg_chord_held)
);

// Repurposed status-page fields, all of which were wired to constants before.
//   row 5  DS -> RX  bytes handed to the ROM loader
//   row 10 DP -> DO  the opcode that left the decompressed program
//   row 11 ET -> BF  boot flags
//   row 14 RP -> DP  where the decompressed program was left
// See ki_debug_screen.sv for the bit legends.
//
// Rows 10 and 14 used to carry the loader's download FSM (DL) and the reboot
// capture (RP/V/CA). Both answered questions that are now settled: the loader
// delivers the whole image (RX:00480000, BOOT:1 on every run since v1.0.10),
// and the reboot capture never fired because no reset term asserts after boot
// (V:0 across two hardware runs). The departure capture answers the question
// that is still open, so it takes those two rows.
reg controller_sdram_ready_ctl_seen = 1'b0;
always @(posedge clk_sdram_ctl) begin
	if (!pll_locked)
		controller_sdram_ready_ctl_seen <= 1'b0;
	else if (controller_sdram_ready)
		controller_sdram_ready_ctl_seen <= 1'b1;
end

reg controller_sdram_ready_core_seen = 1'b0;
always @(posedge clk_core) begin
	if (!pll_locked)
		controller_sdram_ready_core_seen <= 1'b0;
	else if (controller_sdram_ready)
		controller_sdram_ready_core_seen <= 1'b1;
end

wire [31:0] debug_loader_summary = {9'd0, debug_loader_info[27:6], 1'b0};
wire [31:0] debug_boot_summary = {
	debug_loader_info[31:28],         // bits 31:28 pk_io FSM state
	debug_download_info[31:28],       // bits 27:24 bridge state[4:1]
	boot_ready,                       // bit 23
	buttons[1],                       // bit 22
	RESET,                            // bit 21
	shell_reset,                      // bit 20
	core_reset,                       // bit 19
	controller_sdram_ready_ctl_seen,  // bit 18
	controller_sdram_ready_core_seen, // bit 17
	controller_sdram_ready,           // bit 16
	boot_state,                       // bits 15:13
	boot_timed_out,         // bit 12
	loader_abort,           // bit 11
	debug_loader_info[0],   // bit 10 aborted
	debug_loader_info[1],   // bit 9  short image
	debug_loader_info[2],   // bit 8  end marker seen
	loader_overflow,        // bit 7
	sdram_ready,            // bit 6
	boot_loaded,            // bit 5
	pll_locked,             // bit 4
	ioctl_download,         // bit 3
	dbg_chord_held,         // bit 2
	ref_pll_locked,         // bit 1
	sdram_clk_seen          // bit 0  clk_sdram_ctl has toggled
};

wire [6:0] fps_value;
wire fps_box_pixel;
wire fps_glyph_pixel;

generate if (DEBUG_BUILD) begin : g_overlays
	assign fps_box_pixel   = 1'b0;
	assign fps_glyph_pixel = 1'b0;

	ki_debug_screen debug_screen
	(
		.clk(clk_core),
		.frame_start(frame_start),
		.h_count(h_count),
		.v_count(v_count),
		.display_enable(VGA_DE),
		.cpu_reset(cpu_reset),
		.boot_loaded(boot_loaded),
		.pll_locked(pll_locked),
		.image_present((img_size >= 64'd512) | debug_ata_image_ready),
		.cpu_errors(cpu_errors),
		.cpu_pc(debug_cpu_pc_sync),
		.cpu_retired(debug_cpu_retired_sync),
		.cpu_irq_count(debug_cpu_irq_count_sync),
		.cpu_prev_op(debug_dep_valid_sync ? debug_dep_op_hold : {15'd0, debug_packed_ready_seen, debug_adapter_status}),
		.cpu_ret_prev(debug_boot_summary),
		.cpu_eret_flags({debug_ata_info_sync[31:21], ata_irq, cpu_irq[1], cpu_irq[0], sound_reset, dcs_host_reset, dcs_host_status}),
		.cpu_ret_count(debug_restart_info),
		.cpu_ret_pc(debug_loader_summary),
		.pcm_health(dcs_pcm_health),
		// {23 unused, departure valid, 6 unused, 2-bit trigger} - the page reads
		// bit 8 as V and bits 7:0 as C, so this shows V:1 and C:01 / C:10 once a
		// departure has been captured, and V:0 before that.
		.pcm_level({23'd0, debug_dep_valid_sync, 6'd0, debug_dep_trig_hold}),
		.cpu_response_status(32'd0),
		// Row 8 shows EX. With a departure captured (V:1) it is the 8-bit COP0
		// Cause of that departure; with no departure (V:0) it is the live
		// interrupt decision set, laid out in the same digit positions so the
		// two readings can be told apart by V alone:
		//
		//   V:1  EX:00000Cxx - the departure Cause; ExcCode in bits 6:2
		//                    (4 AdEL, 5 AdES, 8 Sys, A RI, 0 Int)
		//   V:0  EX:IEMM00PP - digit 0 = {irq_ata, irq_vblank, SR.IE, SR.EXL},
		//                    digit 1 = SR.IM[3:0], digits 4-5 = Cause.IP[7:0]
		//
		// "V:0 EX:EF000C00" reads: both IRQ lines asserted, interrupts ENABLED,
		// not in an exception, IRQs 3 and 2 unmasked and both pending - a real
		// fault, the CPU should have taken it. "V:0 EX:C0000C00" reads: same
		// pending bits with IE=0 and IM=0, i.e. the game has not enabled
		// interrupts yet and is polling, not waiting on an IRQ.
		.reset_info(debug_dep_valid_sync ? {24'd0, debug_dep_cause_hold} :
		            {debug_cop0_probe_sync[15:8], 8'd0,
		             debug_cop0_probe_sync[7:0], 8'd0}),
		.reset_first(debug_reset_first),
		.ata_info(debug_dep_valid_sync ? debug_dep_pc_hold : debug_ata_info_sync),
		.cpu_t2_reload_count(debug_cpu_t2_reload_count_sync),
		.video_max_v_count(video_max_v_count),
		.video_vblank_seen(video_vblank_seen),
		.cpu_vblank_seen(debug_vblank_cpu_seen),
		.vblank_count(video_vblank_count),
		.ata_state(debug_ata_state),
		.ata_status(debug_ata_status),
		.ata_error(debug_ata_error),
		.disk_debug_info(debug_disk_info),
		// Page 1 is the frozen pre-event trace. It is fed from the clk_core
		// shadow, not from the CPU domain directly, so what is on screen is a
		// coherent capture rather than a live sample of a 736-bit bus.
		.page(2'b00),
		.perf(224'd0),
		.perf_worst(224'd0),
		.perf_prof(336'd0),
		.prof_fine_base(3'd0),
		.trace_bus(896'd0),
		.trace_valid(1'b0),
		.bist_done(bist_done),
		.bist_pass(bist_pass),
		.bist_error_count(bist_error_count),
		.bist_first_bad_expected(bist_first_bad_expected),
		.bist_first_bad_actual(bist_first_bad_actual),
		.boot_state(boot_state),
		.sdram_ready(sdram_ready),
		.red(debug_red),
		.green(debug_green),
		.blue(debug_blue)
	);
end else begin : g_no_overlays
	// Release: nothing renders. The video mux below folds these constants
	// away, so neither overlay nor the registers feeding them are built.
	assign fps_box_pixel   = 1'b0;
	assign fps_glyph_pixel = 1'b0;
	assign debug_red       = 8'h00;
	assign debug_green     = 8'h00;
	assign debug_blue      = 8'h00;
end endgenerate

// Overlay mode is three-state: OVL_AUTO shows debug only before first frame
// write or on severe error; START+SELECT chord toggles it OFF if currently
// visible, or ON if currently hidden.
localparam [1:0] OVL_AUTO = 2'd0, OVL_ON = 2'd1, OVL_OFF = 2'd2;
reg [1:0] overlay_mode = OVL_AUTO;
always @(posedge clk_core) begin
	if (shell_reset)
		overlay_mode <= OVL_AUTO;
	else if (dbg_chord_pulse)
		overlay_mode <= show_debug ? OVL_OFF : OVL_ON;
end

wire show_debug = (overlay_mode == OVL_ON) ||
                  ((overlay_mode == OVL_AUTO) &&
                   ((!fb_write_seen) || (|cpu_errors) || status[4]));

reg [7:0] red;
reg [7:0] green;
reg [7:0] blue;
always @(*) begin
	red = 8'h00;
	green = 8'h00;
	blue = 8'h00;
	if(VGA_DE) begin
		// Game or Debug. Automatically shows KI DEBUG V160 (if enabled)
		// until the CPU begins drawing the boot screen into the framebuffer,
		// or whenever the user holds START + SELECT on the Pocket.
		// When debug overlay is disabled, mute video to clean solid black
		// until the CPU writes its first frame, preventing startup SDRAM snow.
		if(DEBUG_BUILD && show_debug) begin
			red   = debug_red;
			green = debug_green;
			blue  = debug_blue;
		end else begin
			red   = framebuffer_red;
			green = framebuffer_green;
			blue  = framebuffer_blue;
		end

		if(status[3] && fps_box_pixel) begin
			red = fps_glyph_pixel ? 8'hf0 : 8'h08;
			green = fps_glyph_pixel ? 8'hf0 : 8'h08;
			blue = fps_glyph_pixel ? 8'hf0 : 8'h08;
		end
	end
end

assign CLK_VIDEO = clk_core;
assign VGA_R = red;
assign VGA_G = green;
assign VGA_B = blue;
assign VIDEO_ARX = status[1] ? 13'd16 : 13'd4;
assign VIDEO_ARY = status[1] ? 13'd9 : 13'd3;
assign VGA_F1 = 1'b0;
assign VGA_SL = 2'b00;
assign VGA_SCALER = 1'b0;
assign VGA_DISABLE = 1'b0;
assign HDMI_FREEZE = 1'b0;
assign HDMI_BLACKOUT = 1'b0;
assign HDMI_BOB_DEINT = 1'b0;

assign LED_USER = ioctl_download | ~boot_loaded | (|cpu_errors) | boot_timed_out;
assign LED_POWER = 2'b00;
assign LED_DISK = {2{sd_rd | sd_wr}};
assign BUTTONS = {1'b0, startup_osd_button};
// DCS is a mono board, so both channels carry the same sample. AUDIO_S stays 1
// because dcs_audio is signed.
assign AUDIO_L = dcs_audio;
assign AUDIO_R = dcs_audio;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 2'b00;
assign ADC_BUS = 4'bzzzz;
assign {SD_SCK, SD_MOSI, SD_CS} = 3'bzzz;

assign DDRAM_CLK = clk_ddr;

assign SDRAM_CLK = clk_sdram_pin;

assign {UART_RTS, UART_TXD, UART_DTR} = 3'b000;
assign USER_OUT = 7'h7f;

`ifdef MISTER_FB
// The framebuffer is in on-chip block RAM, not DDR3, so use the FPGA scanout
// path rather than MiSTer's DDR3-only direct-framebuffer path.
assign FB_EN = 1'b0;
assign FB_FORMAT = 5'b11100;
assign FB_WIDTH = 12'd320;
assign FB_HEIGHT = 12'd240;
assign FB_BASE = 32'h3000_0000 + {13'd0, framebuffer_base};
assign FB_STRIDE = 14'd640;
assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
assign FB_PAL_CLK = CLK_50M;
assign FB_PAL_ADDR = 8'h00;
assign FB_PAL_DOUT = 24'h000000;
assign FB_PAL_WR = 1'b0;
`endif
`endif

endmodule

`undef KI_DEBUG_BUILD
