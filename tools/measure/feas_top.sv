// Feasibility wrapper v2: every emu output reaches a real pin (via one reduction),
// every emu input is driven, so nothing can be optimised away. Measures the
// upstream core's true fabric/RAM cost against the Pocket's 5CEBA4F23C8.
module feas_top (
	input  wire CLK_50M,
	input  wire RESET,
	output wire LED_USER,
	output wire SDRAM_CLK,
	output wire SDRAM_CKE,
	output wire [12:0] SDRAM_A,
	output wire [1:0]  SDRAM_BA,
	inout  wire [15:0] SDRAM_DQ,
	output wire SDRAM_DQML,
	output wire SDRAM_DQMH,
	output wire SDRAM_nCS,
	output wire SDRAM_nCAS,
	output wire SDRAM_nRAS,
	output wire SDRAM_nWE,
	output wire DDRAM_CLK,
	output wire [28:0] DDRAM_ADDR,
	output wire [7:0]  DDRAM_BURSTCNT,
	output wire [63:0] DDRAM_DIN,
	output wire [7:0]  DDRAM_BE,
	output wire        DDRAM_RD,
	output wire        DDRAM_WE
);
	// HPS_BUS is the MiSTer transport and this harness has none. It matters:
	// with HPS_BUS tied to 'z' and the real hps_io instantiated, hps_io's
	// outputs collapse to constants, ioctl_download never asserts, and Quartus
	// prunes the ROM-download path out of ki_memory_bridge - which understated
	// the core by a whole subsystem (measured: hps_io and every ioctl_* signal
	// absent from the fit netlist). The measurement harness therefore swaps the
	// real hps_io for tools/measure/hps_io_stub.sv, which drives the whole
	// loader interface from counters, so every consumer stays alive and counted.
	wire [45:0] HPS_BUS;
	wire        CLK_VIDEO, CE_PIXEL;
	wire [12:0] VIDEO_ARX, VIDEO_ARY;
	wire  [7:0] VGA_R, VGA_G, VGA_B;
	wire        VGA_HS, VGA_VS, VGA_DE, VGA_F1, VGA_SCALER, VGA_DISABLE;
	wire  [1:0] VGA_SL;
	wire        HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT;
	wire        LED_U, LED_D;
	wire  [1:0] LED_POWER, LED_DISK, BUTTONS;
	wire [15:0] AUDIO_L, AUDIO_R;
	wire        AUDIO_S;
	wire  [1:0] AUDIO_MIX;
	wire        DDRAM_BUSY, DDRAM_DOUT_READY;
	wire [63:0] DDRAM_DOUT;
	wire        SD_SCK, SD_MOSI, SD_CS;
	wire        UART_RTS, UART_TXD, UART_DTR;
	wire  [6:0] USER_OUT;

	wire reduce;
	wire [3:0] adc_bus;

	emu u_emu (
		.CLK_50M(CLK_50M), .RESET(RESET), .HPS_BUS(HPS_BUS),
		.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
		.VIDEO_ARX(VIDEO_ARX), .VIDEO_ARY(VIDEO_ARY),
		.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
		.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE), .VGA_F1(VGA_F1),
		.VGA_SL(VGA_SL), .VGA_SCALER(VGA_SCALER), .VGA_DISABLE(VGA_DISABLE),
		.HDMI_WIDTH(12'd0), .HDMI_HEIGHT(12'd0),
		.HDMI_FREEZE(HDMI_FREEZE), .HDMI_BLACKOUT(HDMI_BLACKOUT), .HDMI_BOB_DEINT(HDMI_BOB_DEINT),
		.LFB_FMT(6'd0), .LFB_BASE(32'd0), .LFB_WIDTH(12'd0), .LFB_HEIGHT(12'd0), .LFB_STRIDE(14'd0),
		.LED_USER(LED_U), .LED_POWER(LED_POWER), .LED_DISK(LED_DISK), .BUTTONS(BUTTONS),
		.CLK_AUDIO(CLK_50M),
		.AUDIO_L(AUDIO_L), .AUDIO_R(AUDIO_R), .AUDIO_S(AUDIO_S), .AUDIO_MIX(AUDIO_MIX),
		.DDRAM_CLK(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_nCS(SDRAM_nCS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nWE(SDRAM_nWE),
		.SD_SCK(SD_SCK), .SD_MOSI(SD_MOSI), .SD_MISO(1'b1), .SD_CS(SD_CS), .SD_CD(1'b1),
		.UART_CTS(1'b1), .UART_RTS(UART_RTS), .UART_RXD(1'b1), .UART_TXD(UART_TXD),
		.UART_DTR(UART_DTR), .UART_DSR(1'b1), .USER_IN(7'h7f), .USER_OUT(USER_OUT),
		.OSD_STATUS(1'b0),
		.ADC_BUS(adc_bus)
	);

	// every otherwise-unobserved emu output contributes to one pin
	assign reduce = ^{CLK_VIDEO, CE_PIXEL, VIDEO_ARX, VIDEO_ARY, VGA_R, VGA_G, VGA_B,
	                  VGA_HS, VGA_VS, VGA_DE, VGA_F1, VGA_SCALER, VGA_DISABLE, VGA_SL,
	                  HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT, LED_D, LED_POWER, LED_DISK,
	                  BUTTONS, AUDIO_L, AUDIO_R, AUDIO_S, AUDIO_MIX, SD_SCK, SD_MOSI, SD_CS,
	                  UART_RTS, UART_TXD, UART_DTR, USER_OUT};
	assign LED_USER = LED_U ^ reduce;

	// tie the block-device responses so the DDR path is not X
	assign DDRAM_BUSY       = 1'b1;
	assign DDRAM_DOUT       = 64'd0;
	assign DDRAM_DOUT_READY = 1'b0;
	assign HPS_BUS          = 46'hzzzzzzzzzzzz;
	assign adc_bus          = 4'bzzzz;
endmodule
