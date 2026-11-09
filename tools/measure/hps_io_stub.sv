// hps_io_stub: stands in for MiSTer's hps_io in fit measurements only.
//
// A Pocket has no HPS. What the core needs from hps_io is a data-slot loader:
// ioctl_download / ioctl_wr / ioctl_index / ioctl_addr / ioctl_dout running
// through the file, plus status, pad and disk-image signals. This module drives
// all of those from free-running counters, so every consumer in the core -
// the ROM-download FSM in ki_memory_bridge, the boot cache, the DCS ROM path,
// the game selector, the DIP latch - stays alive and is counted.
//
// Replacing hps_io with this is deliberate, not a shortcut. Leaving hps_io in
// and tying HPS_BUS to 'z' was measured to collapse hps_io's outputs to
// constants, which pruned the entire ROM-download path out of ki_memory_bridge
// and understated the core. Counting hps_io itself would instead count MiSTer's
// HPS protocol, which the Pocket replaces with the APF bridge. This stub is the
// middle: the loader's behaviour, none of either shell's transport.
`default_nettype none

module hps_io #(
	parameter CONF_STR = "",
	parameter CONF_STR_BRAM = 0,
	parameter PS2DIV = 0,
	parameter WIDE = 0,
	parameter VDNUM = 1,
	parameter BLKSZ = 2,
	parameter PS2WE = 0,
	parameter STRLEN = 0,
	parameter F12KEYMOD = 0
) (
	input  wire        clk_sys,
	inout  wire [45:0] HPS_BUS,
	output wire [63:0] EXT_BUS,
	output wire  [1:0] buttons,
	output wire        forced_scandoubler,
	output wire [31:0] joystick_0,
	output wire [31:0] joystick_1,
	output wire [10:0] ps2_key,
	input  wire [15:0] joystick_0_rumble,
	input  wire [15:0] joystick_1_rumble,
	output wire [127:0] status,
	input  wire [127:0] status_in,
	input  wire         status_set,
	input  wire  [15:0] status_menumask,
	input  wire         video_rotated,
	input  wire         new_vmode,
	output wire         ioctl_download,
	output wire         ioctl_wr,
	output wire  [15:0] ioctl_index,
	output wire  [26:0] ioctl_addr,
	output wire  [15:0] ioctl_dout,
	input  wire         ioctl_upload_req,
	input  wire   [7:0] ioctl_upload_index,
	input  wire  [15:0] ioctl_din,
	output wire         ioctl_wait,
	// Directions are the real hps_io's: the block-device *requests* come from
	// the core (inputs here), the *responses* come from the host (outputs here).
	input  wire  [31:0] sd_lba         [VDNUM],
	input  wire   [5:0] sd_blk_cnt     [VDNUM],
	// VDNUM = 1 and WIDE = 1 are the only configurations this stub supports;
	// the core instantiates hps_io with exactly those. Widths are literal for
	// that reason (Quartus rejects a [VDNUM-1:0] range for VDNUM = 1).
	input  wire         sd_rd,
	input  wire         sd_wr,
	output wire         sd_ack,
	output wire  [12:0] sd_buff_addr,
	output wire  [15:0] sd_buff_dout,
	input  wire  [15:0] sd_buff_din  [1],
	output wire         sd_buff_wr,
	output wire         img_mounted,
	output wire         img_readonly,
	output wire  [63:0] img_size
);
	// Keeps the request/response inputs referenced (they are the core's outputs,
	// so this is what keeps the ATA block-device path in the netlist).
	wire unused_sd_requests;

	// A loader that walks the whole 4.5 MiB ROM image once, then a DIP/game
	// selector write. The counters are free-running so nothing folds away.
	reg  [26:0] addr = 27'd0;
	reg  [15:0] dout = 16'd0;
	reg         wr   = 1'b0;

	always @(posedge clk_sys) begin
		addr <= addr + 27'd1;
		dout <= dout + 16'd1;
		wr   <= addr[3:0] == 4'hf;
	end

	// The download must FINISH. KillerInstinct.sv:320 is
	//   core_reset = shell_reset | ioctl_download | img_reset
	// so a stub that holds ioctl_download high holds the R4600 in reset
	// forever: every CPU register becomes constant and Quartus deletes the
	// whole CPU. (Measured: with download stuck at 1 the core reported 8,712
	// ALMs and 2 DSP instead of 17,xxx and 20 - the CPU and its multiplier
	// were gone.) Here the loader walks the 4.5 MiB image once and releases.
	localparam LOADER_WORDS = 27'h24_0000;   // 0x480000 bytes / 2
	assign ioctl_download = (addr < LOADER_WORDS);
	assign ioctl_wr       = wr;
	assign ioctl_index    = (addr < 27'd2) ? 16'h0000 : 16'h0001;
	assign ioctl_addr     = addr;
	assign ioctl_dout     = dout;
	assign ioctl_wait     = 1'b0;

	// pad, status and disk: plausible non-constant values so their consumers
	// survive; the values themselves are irrelevant to a resource measurement.
	reg  [31:0] pad = 32'd0;
	always @(posedge clk_sys) pad <= pad + 32'd1;

	assign status             = status_in;
	assign buttons            = pad[1:0];
	assign forced_scandoubler = pad[2];
	assign joystick_0         = pad;
	assign joystick_1         = pad ^ 32'h5a5a5a5a;
	assign ps2_key            = pad[10:0];
	assign EXT_BUS            = {32'd0, pad};

	assign sd_ack        = pad[6];
	assign sd_buff_addr  = pad[12:0];
	assign sd_buff_dout  = dout;
	assign sd_buff_wr    = pad[5];
	assign img_mounted   = pad[7];
	assign img_readonly  = 1'b0;
	assign img_size      = {37'd0, addr};
	assign unused_sd_requests = ^{sd_lba[0], sd_blk_cnt[0], sd_buff_din[0], sd_rd, sd_wr};

	// HPS_BUS is the MiSTer transport; this stub has none.
	assign HPS_BUS = 46'hzzzzzzzzzzzz;
endmodule

`default_nettype wire
