// ki_pocket_top: the Killer Instinct core on an Analogue Pocket.
//
// This instantiates the real core -- R4600, memory bridge, DCS audio, ATA, video
// timing -- through `emu` in ki_core_pocket.sv, which is upstream
// KillerInstinct.sv with one change: the MiSTer HPS shell (hps_io) is replaced
// by pk_io, driven from the APF bridge.
//
// What this file provides, and what it does not:
//
//   clocks   50 MHz core (from ki_pll), 6.25 MHz APF pixel clock. The core's own
//            PLL runs from that 50 MHz reference and produces CLK_VIDEO = clk_core
//            = 50 MHz, so CE_PIXEL = 50/8 = 6.25 MHz: exactly the APF pixel rate,
//            and the video capture needs no rate adapter.
//   ROM      data slot 1 -> pk_io -> ioctl stream -> boot ROM + DCS image.
//   memory   the core's SDR SDRAM pins go to the Pocket's 64 MB dram_* bus:
//            same protocol, and ki_sdram_burst already speaks it.
//   video    320x240 RGB555 at 6.25 MHz into the APF DDR converters.
//   audio    DCS mono 31.25 kHz into sound_i2s (48 kHz I2S).
//   disk     NOT connected. img_size = 0, so the core reports no hard disk.
//   DCS ROM  NOT backed. The core streams the 4 MiB sound ROM from DDR3 on
//            MiSTer; the Pocket has no DDR3. Here the DDR port answers 0xFF
//            immediately, so the stream cannot hang but the audio program is
//            invalid. This is the largest remaining piece of work.
`default_nettype none

module ki_pocket_top (
	input  wire        clk_74a,
	input  wire        apf_reset_n,

	// APF bridge (the ROM slot and deferred disk sector reads arrive here)
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	// APF deferred data slot (ATA hard disk emulation)
	input  wire        dataslot_update,
	input  wire [15:0] dataslot_update_id,
	input  wire [31:0] dataslot_update_size,
	output wire        target_dataslot_read,
	input  wire        target_dataslot_ack,
	input  wire        target_dataslot_done,
	input  wire  [2:0] target_dataslot_err,
	output wire [15:0] target_dataslot_id,
	output wire [31:0] target_dataslot_slotoffset,
	output wire [31:0] target_dataslot_bridgeaddr,
	output wire [31:0] target_dataslot_length,

	// APF pad
	input  wire [31:0] pad_key,

	// APF video, into apf_top's DDR converters
	output wire [23:0] video_rgb,
	output wire        video_rgb_clock,
	output wire        video_rgb_clock_90,
	output wire        video_de,
	output wire        video_skip,
	output wire        video_vs,
	output wire        video_hs,

	// APF audio (I2S)
	output wire        audio_mclk,
	output wire        audio_lrck,
	output wire        audio_dac,

	// Pocket DRAM: the core's SDR SDRAM pins
	output wire [12:0] dram_a,
	output wire  [1:0] dram_ba,
	inout  wire [15:0] dram_dq,
	output wire  [1:0] dram_dqm,
	output wire        dram_clk,
	output wire        dram_cke,
	output wire        dram_ras_n,
	output wire        dram_cas_n,
	output wire        dram_we_n,

	// status
	output wire        boot_done,
	output wire        loader_overflow,
	output wire        pll_locked_o
);
	// ---------------------------------------------------------------- clocks
	wire clk_core, clk_mem, clk_pix, clk_pix_90, pll_locked;

	ki_pll u_pll (
		.refclk     (clk_74a),
		.rst        (1'b0),
		.clk_core   (clk_core),      // 50 MHz = emu's CLK_50M
		.clk_mem    (clk_mem),       // 100 MHz (unused here; the core makes its own)
		.clk_pix    (clk_pix),       // 6.25 MHz APF pixel clock
		.clk_pix_90 (clk_pix_90),
		.locked     (pll_locked)
	);
	assign pll_locked_o = pll_locked;

	// ---------------------------------------------------------------- reset
	reg [3:0] rst_sync = 4'd0;
	always @(posedge clk_core) rst_sync <= {rst_sync[2:0], (apf_reset_n & pll_locked)};
	wire core_reset_n = rst_sync[3];
	assign boot_done  = core_reset_n;

	// ---------------------------------------------------------------- core
	wire        CLK_VIDEO, CE_PIXEL;
	wire [12:0] VIDEO_ARX, VIDEO_ARY;
	wire  [7:0] VGA_R, VGA_G, VGA_B;
	wire        VGA_HS, VGA_VS, VGA_DE, VGA_F1, VGA_SCALER, VGA_DISABLE;
	wire  [1:0] VGA_SL;
	wire        HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT;
	wire        LED_U;
	wire  [1:0] LED_POWER, LED_DISK, BUTTONS;
	wire [15:0] AUDIO_L, AUDIO_R;
	wire        AUDIO_S;
	wire  [1:0] AUDIO_MIX;
	wire        DDRAM_CLK;
	wire        DDRAM_BUSY, DDRAM_DOUT_READY;
	wire [63:0] DDRAM_DOUT, DDRAM_DIN;
	wire [28:0] DDRAM_ADDR;
	wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
	wire        DDRAM_RD, DDRAM_WE;
	wire        SD_SCK, SD_MOSI, SD_CS;
	wire        UART_RTS, UART_TXD, UART_DTR;
	wire  [6:0] USER_OUT;
	wire  [3:0] adc_bus;
	wire        dram_cs_n;

	emu u_core (
		.CLK_50M          (clk_core),
		.RESET            (~core_reset_n),

		.clk_74a                    (clk_74a),
		.bridge_addr                (bridge_addr),
		.bridge_wr                  (bridge_wr),
		.bridge_wr_data             (bridge_wr_data),
		.dataslot_update            (dataslot_update),
		.dataslot_update_id         (dataslot_update_id),
		.dataslot_update_size       (dataslot_update_size),
		.target_dataslot_read       (target_dataslot_read),
		.target_dataslot_ack        (target_dataslot_ack),
		.target_dataslot_done       (target_dataslot_done),
		.target_dataslot_err        (target_dataslot_err),
		.target_dataslot_id         (target_dataslot_id),
		.target_dataslot_slotoffset (target_dataslot_slotoffset),
		.target_dataslot_bridgeaddr (target_dataslot_bridgeaddr),
		.target_dataslot_length     (target_dataslot_length),
		.pad_key                    (pad_key),
		.loader_overflow            (loader_overflow),

		.CLK_VIDEO        (CLK_VIDEO),
		.CE_PIXEL         (CE_PIXEL),
		.VIDEO_ARX        (VIDEO_ARX),
		.VIDEO_ARY        (VIDEO_ARY),
		.VGA_R            (VGA_R),
		.VGA_G            (VGA_G),
		.VGA_B            (VGA_B),
		.VGA_HS           (VGA_HS),
		.VGA_VS           (VGA_VS),
		.VGA_DE           (VGA_DE),
		.VGA_F1           (VGA_F1),
		.VGA_SL           (VGA_SL),
		.VGA_SCALER       (VGA_SCALER),
		.VGA_DISABLE      (VGA_DISABLE),

		.HDMI_WIDTH       (12'd0),
		.HDMI_HEIGHT      (12'd0),
		.HDMI_FREEZE      (HDMI_FREEZE),
		.HDMI_BLACKOUT    (HDMI_BLACKOUT),
		.HDMI_BOB_DEINT   (HDMI_BOB_DEINT),

		.LFB_FMT          (6'd0),
		.LFB_BASE         (32'd0),
		.LFB_WIDTH        (12'd0),
		.LFB_HEIGHT       (12'd0),
		.LFB_STRIDE       (14'd0),

		.LED_USER         (LED_U),
		.LED_POWER        (LED_POWER),
		.LED_DISK         (LED_DISK),
		.BUTTONS          (BUTTONS),

		.CLK_AUDIO        (clk_core),
		.AUDIO_L          (AUDIO_L),
		.AUDIO_R          (AUDIO_R),
		.AUDIO_S          (AUDIO_S),
		.AUDIO_MIX        (AUDIO_MIX),

		.ADC_BUS          (adc_bus),

		.SD_SCK           (SD_SCK),
		.SD_MOSI          (SD_MOSI),
		.SD_MISO          (1'b1),
		.SD_CS            (SD_CS),
		.SD_CD            (1'b1),

		// No DDR3 on the Pocket. Answer every beat immediately with 0xFF so the
		// DCS ROM stream cannot hang; the program it receives is invalid.
		.DDRAM_CLK        (DDRAM_CLK),
		.DDRAM_BUSY       (1'b0),
		.DDRAM_BURSTCNT   (DDRAM_BURSTCNT),
		.DDRAM_ADDR       (DDRAM_ADDR),
		.DDRAM_DOUT       (64'hFFFF_FFFF_FFFF_FFFF),
		.DDRAM_DOUT_READY (1'b1),
		.DDRAM_RD         (DDRAM_RD),
		.DDRAM_DIN        (DDRAM_DIN),
		.DDRAM_BE         (DDRAM_BE),
		.DDRAM_WE         (DDRAM_WE),

		// The core's SDR SDRAM pins are the Pocket's DRAM bus.
		.SDRAM_CLK        (dram_clk),
		.SDRAM_CKE        (dram_cke),
		.SDRAM_A          (dram_a),
		.SDRAM_BA         (dram_ba),
		.SDRAM_DQ         (dram_dq),
		.SDRAM_DQML       (dram_dqm[0]),
		.SDRAM_DQMH       (dram_dqm[1]),
		.SDRAM_nCS        (dram_cs_n),
		.SDRAM_nCAS       (dram_cas_n),
		.SDRAM_nRAS       (dram_ras_n),
		.SDRAM_nWE        (dram_we_n),

		.UART_CTS         (1'b1),
		.UART_RTS         (UART_RTS),
		.UART_RXD         (1'b1),
		.UART_TXD         (UART_TXD),
		.UART_DTR         (UART_DTR),
		.UART_DSR         (1'b1),
		.USER_IN          (7'h7f),
		.USER_OUT         (USER_OUT),
		.OSD_STATUS       (1'b0)
	);

	assign adc_bus   = 4'bzzzz;
	// apf_top does not expose dram_ncs. Hold chip select asserted; the core's
	// controller drives CKE and the command lines.
	assign dram_cs_n = 1'b0;

	// ---------------------------------------------------------------- video to APF
	// CE_PIXEL is 6.25 MHz (CLK_VIDEO / 8) and clk_pix is 6.25 MHz from the same
	// PLL, so one register stage is enough: hold the pixel on clk_core at the
	// CE_PIXEL edge and let apf_top sample it 160 ns later.
	reg  [23:0] v_rgb = 24'd0;
	reg         v_de  = 1'b0;
	reg         v_hs  = 1'b0;
	reg         v_vs  = 1'b0;
	always @(posedge clk_core) begin
		if (CE_PIXEL) begin
			v_rgb <= {VGA_R, VGA_G, VGA_B};
			v_de  <= VGA_DE;
			v_hs  <= VGA_HS;
			v_vs  <= VGA_VS;
		end
	end

	assign video_rgb          = v_rgb;
	assign video_rgb_clock    = clk_pix;
	assign video_rgb_clock_90 = clk_pix_90;
	assign video_de           = v_de;
	assign video_skip         = 1'b0;
	assign video_hs           = v_hs;
	assign video_vs           = v_vs;

	// ---------------------------------------------------------------- audio
	// The core emits mono 16-bit at 31.25 kHz; sound_i2s resamples to the
	// Pocket's 48 kHz I2S through its dual-clock FIFO.
	sound_i2s #(
		.CHANNEL_WIDTH (16),
		.SIGNED_INPUT  (1)
	) isound (
		.clk_74a    (clk_74a),
		.clk_audio  (clk_core),
		.audio_l    ($signed(AUDIO_L)),
		.audio_r    ($signed(AUDIO_R)),
		.audio_mclk (audio_mclk),
		.audio_lrck (audio_lrck),
		.audio_dac  (audio_dac)
	);

	// Keep every otherwise-unobserved core output referenced so nothing that
	// matters is optimised away, as the measurement harness learned to do.
	wire unused = ^{CLK_VIDEO, VIDEO_ARX, VIDEO_ARY, VGA_F1, VGA_SCALER,
	                VGA_DISABLE, VGA_SL, HDMI_FREEZE, HDMI_BLACKOUT,
	                HDMI_BOB_DEINT, LED_U, LED_POWER, LED_DISK, BUTTONS,
	                AUDIO_S, AUDIO_MIX, DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR,
	                DDRAM_RD, DDRAM_DIN, DDRAM_BE, DDRAM_WE, SD_SCK, SD_MOSI,
	                SD_CS, UART_RTS, UART_TXD, UART_DTR, USER_OUT};
endmodule

`default_nettype wire
