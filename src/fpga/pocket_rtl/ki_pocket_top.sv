// ki_pocket_top: the Killer Instinct video path on the Analogue Pocket.
//
// MILESTONE 1 (this file): APF clocks, reset, the core's own video timing and
// framebuffer, and a test pattern in the framebuffer RAM. It builds an RBF that
// boots on the Pocket and shows a picture. It is NOT the game: the R4600, the
// DCS, the ATA disk and the memory bridge are not instantiated yet, because the
// memory plan they need is still open (see docs/FEASIBILITY.md).
//
// Everything here except the pattern writer and the scanout adapter is the
// upstream core's own RTL, unmodified: ki_video_timing, ki_framebuffer and
// ki_fb_ram are the same modules MiSTer runs.
//
// Clocks (ki_pll): clk_core 50 MHz, clk_mem 100 MHz, clk_pix 6.25 MHz,
// clk_pix_90 6.25 MHz shifted 90 degrees.
//
// Video: ki_video_timing is clocked AT the pixel clock with CLOCK_DIVIDE = 1,
// so ce_pixel is asserted every cycle. On MiSTer it runs on 50 MHz with
// CLOCK_DIVIDE = 8; the counters, and therefore the timing, are identical:
// 406 x 261 at 6.25 MHz = 15.39 kHz / 58.98 Hz, the native KI video.
`default_nettype none

module ki_pocket_top #(
	// 320x240 RGB555, two pages. ki_memory_bridge compacts them to 38400
	// 64-bit words; page 0 starts at low RAM 0x30000, page 1 at 0x58000.
	parameter logic [31:0] FB0_LOW = 32'h0003_0000,
	parameter logic [31:0] FB1_LOW = 32'h0005_8000
) (
	// clocks and reset from the APF side
	input  wire        clk_74a,
	input  wire        apf_reset_n,      // high = run

	// APF video, into apf_top's DDR converters
	output wire [23:0] video_rgb,
	output wire        video_rgb_clock,
	output wire        video_rgb_clock_90,
	output wire        video_de,
	output wire        video_skip,
	output wire        video_vs,
	output wire        video_hs,

	// APF audio (I2S), driven by sound_i2s in core_top
	output wire        clk_audio,
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// status back to core_top / core_bridge_cmd
	output wire        boot_done,
	output wire [15:0] status_word,
	output wire        pattern_done
);
	// ---------------------------------------------------------------- clocks
	wire clk_core, clk_mem, clk_pix, clk_pix_90, pll_locked;

	ki_pll u_pll (
		.refclk     (clk_74a),
		.rst        (1'b0),
		.clk_core   (clk_core),
		.clk_mem    (clk_mem),
		.clk_pix    (clk_pix),
		.clk_pix_90 (clk_pix_90),
		.locked     (pll_locked)
	);

	// ---------------------------------------------------------------- reset
	// PLL locked and the host running. Both are asynchronous to clk_pix; two
	// flops each, then a synchronous release.
	reg [2:0] rst_sync = 3'b000;
	always @(posedge clk_pix)
		rst_sync <= {rst_sync[1:0], (apf_reset_n & pll_locked)};
	wire core_reset = ~rst_sync[2];

	assign boot_done = rst_sync[2];

	// The video clock is the pixel clock: APF samples the DDR converters on it.
	assign video_rgb_clock    = clk_pix;
	assign video_rgb_clock_90 = clk_pix_90;

	// ---------------------------------------------------------------- video timing
	// Same module, same counters as MiSTer, run at the pixel clock.
	wire        ce_pixel;
	wire [9:0]  h_count, v_count;
	wire        native_de, native_hs_n, native_vs_n, native_vblank;

	ki_video_timing #(.CLOCK_DIVIDE(1)) u_timing (
		.clk            (clk_pix),
		.reset          (core_reset),
		.ce_pixel       (ce_pixel),
		.h_count        (h_count),
		.v_count        (v_count),
		.display_enable (native_de),
		.hsync_n        (native_hs_n),
		.vsync_n        (native_vs_n),
		.vblank         (native_vblank),
		.frame_start    (),
		.vblank_count   (),
		.vblank_seen    (),
		.max_v_count    ()
	);

	// ---------------------------------------------------------------- framebuffer
	wire        fb_req;
	wire [27:0] fb_addr;
	wire  [2:0] fb_words;
	wire [63:0] fb_data;
	wire        fb_data_valid;
	wire        fb_done;
	wire  [7:0] fb_red, fb_green, fb_blue;
	wire        fb_pixel_valid;

	ki_framebuffer u_fb (
		.clk               (clk_pix),
		.reset             (core_reset),
		.ce_pixel          (ce_pixel),
		.h_count           (h_count),
		.v_count           (v_count),
		.framebuffer_base  (FB0_LOW[18:0]),
		.memory_request    (fb_req),
		.memory_address    (fb_addr),
		.memory_words      (fb_words),
		.memory_data       (fb_data),
		.memory_data_valid (fb_data_valid),
		.memory_done       (fb_done),
		.red               (fb_red),
		.green             (fb_green),
		.blue              (fb_blue),
		.pixel_valid       (fb_pixel_valid)
	);

	// ---------------------------------------------------------------- framebuffer RAM
	// Port A: the pattern writer (and, later, the memory bridge's CPU path).
	// Port B: scanout.
	wire [15:0] fbram_cpu_q, fbram_vid_q;
	reg  [15:0] fbram_cpu_addr = 16'd0;
	reg  [63:0] fbram_cpu_data = 64'd0;
	reg   [7:0] fbram_cpu_be   = 8'h00;
	reg         fbram_cpu_we   = 1'b0;
	reg  [15:0] fbram_vid_addr = 16'd0;

	ki_fb_ram u_fbram (
		.clock       (clk_pix),
		.cpu_address (fbram_cpu_addr),
		.cpu_data    (fbram_cpu_data),
		.cpu_byteena (fbram_cpu_be),
		.cpu_wren    (fbram_cpu_we),
		.cpu_q       (fbram_cpu_q),
		.vid_address (fbram_vid_addr),
		.vid_q       (fbram_vid_q)
	);

	// ---------------------------------------------------------------- scanout adapter
	// ki_framebuffer asks for runs of qwords at a byte address; the RAM holds the
	// two framebuffer pages compacted. This is the same mapping as
	// ki_memory_bridge's fb_index(), for the two pages only.
	localparam integer FB_BUFFER_WORDS = 19200;

	function automatic [15:0] fb_index(input logic [27:0] byte_address);
		if (byte_address >= FB1_LOW[27:0])
			return FB_BUFFER_WORDS[15:0] + ((byte_address - FB1_LOW[27:0]) >> 3);
		return (byte_address - FB0_LOW[27:0]) >> 3;
	endfunction

	reg        scan_busy = 1'b0;
	reg  [2:0] scan_left = 3'd0;
	reg [63:0] scan_data = 64'd0;
	reg        scan_valid = 1'b0;
	reg        scan_done = 1'b0;

	assign fb_data       = scan_data;
	assign fb_data_valid = scan_valid;
	assign fb_done       = scan_done;

	always @(posedge clk_pix) begin
		scan_valid <= 1'b0;
		scan_done  <= 1'b0;
		if (core_reset) begin
			scan_busy  <= 1'b0;
			scan_left  <= 3'd0;
			fbram_vid_addr <= 16'd0;
		end else if (!scan_busy) begin
			if (fb_req) begin
				fbram_vid_addr <= fb_index(fb_addr);
				scan_left      <= fb_words - 3'd1;   // fb_words words in total
				scan_busy      <= 1'b1;
			end
		end else begin
			// one word per cycle; the RAM's registered address means vid_q is
			// the word for the address set last cycle
			scan_data  <= fbram_vid_q;
			scan_valid <= 1'b1;
			fbram_vid_addr <= fbram_vid_addr + 16'd1;
			if (scan_left == 3'd0) begin
				scan_done <= 1'b1;
				scan_busy <= 1'b0;
			end else begin
				scan_left <= scan_left - 3'd1;
			end
		end
	end

	// ---------------------------------------------------------------- test pattern
	// Eight vertical colour bars, written once into framebuffer page 0 through
	// port A. 19200 qwords of four RGB555 pixels each.
	reg  [14:0] w_count = 15'd0;      // qword index being written, 0 .. 19199
	reg         w_done  = 1'b0;
	reg         w_phase = 1'b0;

	function automatic [15:0] bar_colour(input logic [3:0] bar);
		case (bar)
			3'd0: return {1'b0, 5'd0,  5'd0,  5'd0 };   // black
			3'd1: return {1'b0, 5'd31, 5'd31, 5'd31};   // white
			3'd2: return {1'b0, 5'd31, 5'd31, 5'd0 };   // yellow
			3'd3: return {1'b0, 5'd0,  5'd31, 5'd31};   // cyan
			3'd4: return {1'b0, 5'd31, 5'd0,  5'd31};   // magenta
			3'd5: return {1'b0, 5'd31, 5'd0,  5'd0 };   // red
			3'd6: return {1'b0, 5'd0,  5'd31, 5'd0 };   // green
			default: return {1'b0, 5'd0, 5'd0, 5'd31};  // blue
		endcase
	endfunction

	// Pixel colour by horizontal position: 320 pixels / 32 = ten 32-pixel bars,
	// eight colours repeated. A line is 80 words (320/4), so word[6:0] walks one
	// line and column = word[6:0]*4 + i.
	function automatic [15:0] pattern_pixel(input logic [14:0] word, input logic [1:0] i);
		logic [8:0] col;
		begin
			col = {word[6:0], 2'b00} + {7'd0, i};   // 0..319 within the line
			pattern_pixel = bar_colour({1'b0, col[7:5]});   // col / 32, 0..9, colours repeat every 8
		end
	endfunction

	always @(posedge clk_pix) begin
		fbram_cpu_we <= 1'b0;
		if (core_reset) begin
			w_count  <= 15'd0;
			w_done   <= 1'b0;
			w_phase  <= 1'b0;
		end else if (!w_done) begin
			if (!w_phase) begin
				// present address + data
				fbram_cpu_addr <= w_count;
				fbram_cpu_be   <= 8'hFF;
				w_phase        <= 1'b1;
			end else begin
				fbram_cpu_we   <= 1'b1;
				w_phase        <= 1'b0;
				if (w_count == 15'd19199) begin
					w_done <= 1'b1;
				end else begin
					w_count <= w_count + 15'd1;
				end
			end
		end
	end

	// Four RGB555 pixels per 64-bit word: pixel 0 in [15:0].
	always @(*) begin
		fbram_cpu_data = { pattern_pixel(w_count, 2'd3),
		                   pattern_pixel(w_count, 2'd2),
		                   pattern_pixel(w_count, 2'd1),
		                   pattern_pixel(w_count, 2'd0) };
	end

	assign pattern_done = w_done;
	assign status_word  = {13'd0, w_done, fb_pixel_valid, boot_done};

	// ---------------------------------------------------------------- video out
	// ki_framebuffer gives 8:8:8 and an active-pixel strobe. APF wants the same
	// three signals plus syncs; the syncs are the core's, inverted (it names
	// them _n and pulses low).
	assign video_rgb = {fb_red, fb_green, fb_blue};
	assign video_de   = fb_pixel_valid;
	assign video_skip = 1'b0;
	assign video_hs   = ~native_hs_n;
	assign video_vs   = ~native_vs_n;

	// ---------------------------------------------------------------- audio
	// Nothing oscillates yet: the DCS engine is not instantiated. Silence, at
	// 48 kHz, so the I2S path can be checked on hardware.
	assign clk_audio = clk_core;
	assign audio_l   = 16'sd0;
	assign audio_r   = 16'sd0;
endmodule

`default_nettype wire
