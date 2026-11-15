// SPDX-License-Identifier: GPL-3.0-only
// 64-bit beat backing for the ADSP sound-ROM port (dcs_mem ext_* side).
//
// dcs_mem drives ext_req level-high with ext_addr stable and consumes ext_q on
// the clock where it samples ext_rdy. This model answers one clock after the
// request appears and holds both ext_rdy and ext_q for as long as the request
// stays up, so a consumer that needs the beat on a later core_ce still sees it.
//
// Backing data comes from tools/gen_dcs_rom_hex.py: one hex line per beat,
// byte 0 of the image in [7:0].
`default_nettype none
module adsp_rom_model #(
    parameter integer BEATS     = 524288,
    parameter         INIT_FILE = "tests/sim/vectors/dcs_kinst.hex",
    parameter integer TRACE     = 16      // beats to print, 0 = silent
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        ext_req,
    input  wire [18:0] ext_addr,
    output reg         ext_rdy,
    output reg  [63:0] ext_q
);
    reg [63:0] beat [0:BEATS-1];

    initial begin
        $readmemh(INIT_FILE, beat);
    end

    reg        pending;
    reg [18:0] pending_addr;
    reg [18:0] latency;      // largest request->ready gap seen

    integer traced;
    longint requests;

    always @(posedge clk) begin
        if (rst) begin
            ext_rdy      <= 1'b0;
            ext_q        <= 64'd0;
            pending      <= 1'b0;
            pending_addr <= 19'd0;
            latency      <= 19'd0;
            traced       <= 0;
            requests     <= 0;
        end else begin
            // A held request keeps its answer; a new address is a new beat.
            if (!ext_req || (ext_addr != pending_addr)) begin
                ext_rdy      <= 1'b0;
                pending      <= 1'b0;
                pending_addr <= ext_addr;
            end
            if (ext_req) begin
                requests <= requests + 1;
                if (traced < TRACE) begin
                    $display("[rom] t=%0t beat=%0d (byte 0x%06x) q=%016x",
                             $time, ext_addr, ext_addr, beat[ext_addr]);
                    traced <= traced + 1;
                end
                if (ext_addr >= BEATS) begin
                    $display("[rom] ERROR beat %0d outside backing (%0d)",
                             ext_addr, BEATS);
                    ext_q <= 64'hDEAD_DEAD_DEAD_DEAD;
                end else begin
                    ext_q <= beat[ext_addr];
                end
                // One clock behind the request, and one more for a request
                // that arrives on the same edge the model observes it.
                if (!pending && !ext_rdy) begin
                    pending      <= 1'b1;
                    latency      <= 19'd1;
                end else if (pending && !ext_rdy) begin
                    ext_rdy <= 1'b1;
                    pending <= 1'b0;
                end else if (latency != {19{1'b1}}) begin
                    latency <= latency + 19'd1;
                end
            end
        end
    end

    final begin
        $display("[rom] requests=%0d max_gap=%0d beats_used<=%0d",
                 requests, latency, pending_addr);
    end
endmodule
`default_nettype wire
