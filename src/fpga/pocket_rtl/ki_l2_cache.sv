// SPDX-License-Identifier: GPL-3.0-only
`default_nettype none

// 64 KiB direct-mapped L2 cache for main RAM, spliced on clk_core (50 MHz)
// between {ki_memory_bridge, cpu direct-fill} and ki_sdram_adapter.
//
// Why here. The R4600's 16 KiB L1 D-cache and 16 KiB L1 I-cache miss heavily
// into main RAM (0x0800_0000..0x087F_FFFF plus its 9th-MiB hardware mirror
// 0x0880_0000..0x088F_FFFF), paying 15-35+ clk_core cycles on contended SDRAM.
// The Cyclone V 5CEBA4 has ~112 free M10Ks while ALMs and LABs are nearly full,
// so a 64 KiB M10K cache sitting directly on the existing bridge and fast-fill
// interfaces buys hit latency down to 3-4 cycles without touching the CPU or
// bridge RTL.
//
// Organization (66 M10Ks total):
//   - 2,048 lines x 32 bytes (4 x 64-bit qwords), direct-mapped.
//   - Index: main_off[15:5] (11 bits). Tag: main_off[22:16] (7 bits) + 1 valid.
//   - Tag RAM:  2,048 x 8 (2 M10Ks). Swept to zero in 2,048 cycles on reset.
//   - Data RAM: 8,192 x 64 built as eight 8,192 x 8 byte-lane M10K banks
//     (8 x 8 = 64 M10Ks), keeping separate per-byte write enables ready for a
//     later write-update revision at zero M10K overhead.
//
// Coherency (V1 write-invalidate):
//   - Every main-RAM writer in the core (D-cache dirty line write-backs,
//     uncached stores, and narrow-store RMWs) crosses bridge_write. On any
//     main-RAM bridge_write, the write passes straight through to SDRAM and
//     its L2 index is invalidated unconditionally on the same cycle.
//   - Because EARLY_RESTART lets the CPU resume during a direct-fill miss tail
//     and emit a main-RAM store onto bridge_write before beats 1..3 return from
//     SDRAM, any main-RAM bridge_write while a direct-fill miss is in flight
//     sets l2_fill_poison so beat 3 does not validate the line.
//   - To prevent a poisoned or in-flight miss from overwriting Data while the
//     old tag at that index still reads valid, every miss invalidates its tag
//     entry on launch before SDRAM data arrives; if Tag Port A is busy on that
//     edge (or the other path is already filling the same index), the miss is
//     poisoned up front and writes neither Data nor Tag.
//   - Non-main-RAM regions (framebuffers, low RAM, boot ROM, DCS ROM, video
//     scanout, ROM download) and uncached reads (fast_req_line[0]=1 or bridge
//     burst != 16) bypass straight through without touching L2 state.
//   - Setting L2_ENABLE=0 removes the cache and restores a pure wire-through
//     for hardware bisecting.
module ki_l2_cache #(
  parameter bit L2_ENABLE = 1'b1,
  // V235: 0 = the CPU's direct-fill port passes straight through, exactly as
  // without this module, and the L2 serves the bridge path only. V234 with
  // the direct path through the L2 hung (ERR 02): the CPU launches a direct
  // fill only while the bridge is idle, and ki_sdram_burst relies on that
  // toggle arriving before the bridge's next request can; the lookup cycles
  // here delayed it until a bridge request could land on the same edge, and
  // ki_sdram_burst's new_rd then overwrote the direct request (lost for good).
  parameter bit L2_FAST   = 1'b0
) (
  input  wire         clk,               // clk_core (50 MHz)
  input  wire         reset,             // sdram_init_reset (resets adapter link)
  input  wire         cpu_reset,         // clears L2 tags; bridge bypass stays live

  // Bridge side (from/to ki_memory_bridge).
  input  wire  [24:0] bridge_address,
  input  wire [255:0] bridge_write_data,
  input  wire  [31:0] bridge_byte_enable,
  input  wire   [4:0] bridge_burst,
  input  wire         bridge_read,
  input  wire         bridge_write,
  output wire  [31:0] bridge_read_data,
  output wire   [1:0] bridge_read_be,
  output wire         bridge_data_valid,
  output wire         bridge_done,

  // Adapter primary side (to/from ki_sdram_adapter).
  output wire  [24:0] sdram_address,
  output wire [255:0] sdram_write_data,
  output wire  [31:0] sdram_byte_enable,
  output wire   [4:0] sdram_burst,
  output wire         sdram_read,
  output wire         sdram_write,
  input  wire  [31:0] sdram_read_data,
  input  wire   [1:0] sdram_read_be,
  input  wire         sdram_data_valid,
  input  wire         sdram_done,

  // CPU direct-fill side (from/to ki_cpu_core).
  input  wire         cpu_fast_req_tog,
  input  wire  [31:0] cpu_fast_req_line,
  output wire         cpu_fast_window,
  output wire         cpu_fast_beat,
  output wire         cpu_fast_first,
  output wire  [63:0] cpu_fast_qword,
  output wire         cpu_fast_done_tog,

  // Adapter direct-fill side (to/from ki_sdram_adapter / ki_fast_fill).
  output wire         sdram_fast_req_tog,
  output wire  [31:0] sdram_fast_req_line,
  input  wire         sdram_fast_window,
  input  wire         sdram_fast_beat,
  input  wire         sdram_fast_first,
  input  wire  [63:0] sdram_fast_qword,
  input  wire         sdram_fast_done_tog,

  // Per-game-frame L2 line-fill counters, latched on perf_flip like the census.
  input  wire         perf_flip,
  output wire  [15:0] perf_l2_hits,
  output wire  [15:0] perf_l2_misses
);

  generate
    if (!L2_ENABLE) begin : g_bypass
      assign sdram_address       = bridge_address;
      assign sdram_write_data    = bridge_write_data;
      assign sdram_byte_enable   = bridge_byte_enable;
      assign sdram_burst         = bridge_burst;
      assign sdram_read          = bridge_read;
      assign sdram_write         = bridge_write;
      assign bridge_read_data    = sdram_read_data;
      assign bridge_read_be      = sdram_read_be;
      assign bridge_data_valid   = sdram_data_valid;
      assign bridge_done         = sdram_done;

      assign sdram_fast_req_tog  = cpu_fast_req_tog;
      assign sdram_fast_req_line = cpu_fast_req_line;
      assign cpu_fast_window     = sdram_fast_window;
      assign cpu_fast_beat       = sdram_fast_beat;
      assign cpu_fast_first      = sdram_fast_first;
      assign cpu_fast_qword      = sdram_fast_qword;
      assign cpu_fast_done_tog   = sdram_fast_done_tog;

      assign perf_l2_hits        = 16'd0;
      assign perf_l2_misses      = 16'd0;

      wire _unused_bypass = &{1'b0, clk, reset, cpu_reset, perf_flip};
    end else begin : g_l2

      // ----------------------------------------------------------------------
      // Address decoding
      //
      // Main RAM lives at SDRAM storage bytes 0x010_0000..0x08F_FFFF (8 MiB,
      // with the 9th-MiB alias 0x0880_0000..0x088F_FFFF folded onto the first
      // MiB by ki_storage_address). On the bridge, addresses are 16-bit word
      // offsets, so main RAM is 25'h008_0000..25'h047_FFFF (bits [24:19] in
      // 1..8). Subtracting 1 yields 0..7 in br_in_hi[2:0] with [5:3] == 0.
      // ----------------------------------------------------------------------
      wire  [5:0] br_in_hi       = bridge_address[24:19] - 6'd1;
      wire        br_in_is_main  = (br_in_hi[5:3] == 3'b000);
      wire  [6:0] br_in_tag      = {br_in_hi[2:0], bridge_address[18:15]};
      wire [10:0] br_in_idx      = bridge_address[14:4];

      // On the direct-fill path, cpu_fast_req_line is a 32-bit physical byte
      // address with bit 0 set for an uncached qword read. Dropping bit 23
      // folds 0x0880_0000..0x088F_FFFF onto 0x0800_0000..0x080F_FFFF so tag
      // and index match the bridge's storage-address decode identically.
      wire        fast_in_is_main = !cpu_fast_req_line[0] &&
                                    (cpu_fast_req_line[4:0] == 5'd0) &&
                                    (cpu_fast_req_line[31:24] == 8'h08) &&
                                    (cpu_fast_req_line[23:20] <= 4'h8);
      wire [10:0] fast_in_idx     = cpu_fast_req_line[15:5];

      // ----------------------------------------------------------------------
      // State machines
      // ----------------------------------------------------------------------
      typedef enum logic [1:0] {
        FAST_IDLE,
        FAST_LOOKUP,
        FAST_HIT_STREAM,
        FAST_MISS_WAIT
      } fast_state_t;

      typedef enum logic [2:0] {
        BR_IDLE,
        BR_WAIT_PORT,
        BR_LOOKUP,
        BR_HIT_WAIT_DONE,
        BR_HIT_STREAM,
        BR_HIT_DONE,
        BR_MISS_WAIT
      } br_state_t;

      fast_state_t fast_state = FAST_IDLE;
      br_state_t   br_state   = BR_IDLE;

      // Tag sweep on power-up, SDRAM re-init, or any rising edge of cpu_reset.
      // Sweeps all 2,048 entries to invalid in 2,048 clk_core cycles (41 us),
      // hidden inside SDRAM startup / ROM download. While active (or while
      // cpu_reset is high), all reads bypass L2 so ROM downloads and resets
      // never stall.
      logic        clear_active = 1'b1;
      logic [10:0] clear_idx    = 11'd0;
      logic        cpu_reset_d  = 1'b1;

      // Direct-fill state. Toggle FFs (fast_rseen, fast_done_tog_r, and
      // sdram_fast_req_tog_r) are deliberately never reset on cpu_reset:
      // neither cpu_pocket.vhd's fast_tog_r nor ki_fast_fill's rseen resets,
      // so resetting a toggle here would launch a phantom direct read after
      // an OSD reset.
      logic        fast_rseen           = 1'b0;
      logic        fast_done_tog_r      = 1'b0;
      logic        sdram_fast_req_tog_r = 1'b0;
      // One-cycle gap after any direct fill finishes. When a second demand
      // fill queues behind an EARLY_RESTART tail (fast_go_q) and targets
      // qword 3 (making datacache_fill_last=1), Line 1's tail clears on edge
      // T_last+3; holding acceptance until T_last+2 puts Line 2's hit Beat 0
      // (fast_first) on T_last+4, strictly after tail clears, while adding
      // zero cycles to non-queued direct fills.
      logic        fast_cooldown        = 1'b0;
      // Shared between the active lookup/miss and sdram_fast_req_line: only
      // written in FAST_IDLE after the previous SDRAM fast window has closed,
      // so it stays completely stable across the clk_core -> clk_sdram_ctl
      // multicycle path whenever sdram_fast_req_tog_r toggles.
      logic [31:0] fast_req_line_r      = 32'd0;
      logic        fast_cur_cacheable   = 1'b0;
      logic        fast_lookup_killed   = 1'b0;
      logic        l2_fill_poison       = 1'b0;
      logic  [1:0] fast_beat_cnt        = 2'd0;
      logic        fast_hit_win         = 1'b0;
      logic [63:0] fast_hit_q           = 64'd0;

      wire   [6:0] fast_cur_tag         = fast_req_line_r[22:16];
      wire  [10:0] fast_cur_idx         = fast_req_line_r[15:5];
      wire         fast_cur_qword_read  = fast_req_line_r[0];

      // Bridge state. sdram_br_outstanding tracks bridge requests already sent
      // to sdram_adapter whose sdram_done pulse has not yet returned. Because
      // ki_memory_bridge closes a read on its final beat and sets done_owed=1
      // until sdram_done arrives, an L2 bridge hit waits in BR_HIT_WAIT_DONE
      // until sdram_br_outstanding drops to zero so an owed sdram_done passes
      // through cleanly before any hit beat is emitted.
      logic  [1:0] sdram_br_outstanding = 2'd0;
      logic [24:0] br_req_addr          = 25'd0;
      logic  [6:0] br_req_tag           = 7'd0;
      logic        br_fill_poison       = 1'b0;
      logic  [2:0] br_beat_cnt          = 3'd0;
      // Holds the current 64-bit qword during a bridge hit, and reuses [31:0]
      // to hold the even 32-bit half while packing a bridge miss into M10K.
      logic [63:0] br_q_buf             = 64'd0;

      wire  [10:0] br_req_idx           = br_req_addr[14:4];

      // V234 fix (first hardware run hung with ERR 02, error_stall): the
      // bridge closes a line read on its one-but-last beat and returns to
      // IDLE with done_owed set, so it may issue its NEXT request (scanout,
      // DCS ROM, a write-back) while this module is still streaming a hit
      // (BR_HIT_STREAM/BR_HIT_DONE) or finishing a miss (BR_MISS_WAIT).
      // The adapter queues such a request; this module used to look at
      // bridge_read/bridge_write only in BR_IDLE and dropped it, and the
      // bridge then waited forever for its done. One request can be
      // outstanding (the bridge waits for its done before the next), so a
      // one-deep pending flag is enough: it is replayed in BR_IDLE. Address,
      // burst, data and byte enables are registers in the bridge that hold
      // until that request's done, so they need no copy here.
      logic        br_pend_rd           = 1'b0;
      logic        br_pend_wr           = 1'b0;
      wire         br_req_read          = bridge_read  || br_pend_rd;
      wire         br_req_write         = bridge_write || br_pend_wr;

      // ----------------------------------------------------------------------
      // M10K storage (66 explicit altsyncram M10Ks under synthesis)
      // ----------------------------------------------------------------------
      logic [10:0] tag_wr_addr;
      logic  [7:0] tag_wr_data;
      logic        tag_wren;
      logic [10:0] tag_rd_addr;
      wire   [7:0] tag_rd_data;

      logic [12:0] data_wr_addr;
      logic [63:0] data_wr_data;
      logic  [7:0] data_wren;
      logic [12:0] data_rd_addr;
      wire  [63:0] data_rd_data;

      ki_l2_sdp_ram #(
        .ADDR_W (11),
        .DATA_W (8)
      ) u_tag_ram (
        .clk     (clk),
        .wr_addr (tag_wr_addr),
        .wr_data (tag_wr_data),
        .wren    (tag_wren),
        .rd_addr (tag_rd_addr),
        .rd_data (tag_rd_data)
      );

      genvar lane;
      for (lane = 0; lane < 8; lane = lane + 1) begin : g_data_lane
        ki_l2_sdp_ram #(
          .ADDR_W (13),
          .DATA_W (8)
        ) u_data_ram (
          .clk     (clk),
          .wr_addr (data_wr_addr),
          .wr_data (data_wr_data[lane * 8 +: 8]),
          .wren    (data_wren[lane]),
          .rd_addr (data_rd_addr),
          .rd_data (data_rd_data[lane * 8 +: 8])
        );
      end

      // ----------------------------------------------------------------------
      // Combinational lookup, arbitration, and pass-through muxes
      // ----------------------------------------------------------------------
      wire cache_active   = !cpu_reset && !clear_active;
      wire br_in_eligible = cache_active && br_in_is_main &&
                            (bridge_burst == 5'd16) &&
                            (bridge_address[3:0] == 4'd0);

      // Any main-RAM bridge write invalidates its L2 index immediately.
      wire br_inv_now = cache_active && (br_state == BR_IDLE) &&
                        br_req_write && br_in_is_main;

      // Read Port B ownership. A waiting bridge read (BR_WAIT_PORT) outranks a
      // newly arriving direct fill so neither path can starve.
      wire fast_port_busy = (fast_state == FAST_LOOKUP) ||
                            (fast_state == FAST_HIT_STREAM);
      wire br_port_busy   = (br_state == BR_LOOKUP) ||
                            (br_state == BR_HIT_WAIT_DONE) ||
                            (br_state == BR_HIT_STREAM);

      wire fast_req_new     = L2_FAST && (cpu_fast_req_tog != fast_rseen) && !fast_cooldown;
      wire fast_rd_start    = (fast_state == FAST_IDLE) && fast_req_new &&
                              fast_in_is_main && cache_active &&
                              !br_port_busy && (br_state != BR_WAIT_PORT);
      wire fast_bypass_start = (fast_state == FAST_IDLE) && fast_req_new &&
                               (!fast_in_is_main || !cache_active);

      wire br_rd_start_idle = (br_state == BR_IDLE) && br_req_read &&
                              br_in_eligible && !fast_port_busy && !fast_rd_start;
      wire br_rd_start_wait = (br_state == BR_WAIT_PORT) &&
                              !fast_port_busy && !fast_rd_start;

      // Tag compare results. A bridge write on either the tag-read cycle
      // (fast_lookup_killed) or the compare cycle (br_inv_now) forces a direct
      // fill to miss so OLD_DATA from M10K can never return an invalidated line.
      wire fast_hit = cache_active && !fast_lookup_killed && !br_inv_now &&
                      tag_rd_data[7] && (tag_rd_data[6:0] == fast_cur_tag);
      wire br_hit   = cache_active &&
                      tag_rd_data[7] && (tag_rd_data[6:0] == br_req_tag);

      wire br_sdram_clear_next = (sdram_br_outstanding == 2'd0) ||
                                 ((sdram_br_outstanding == 2'd1) && sdram_done);

      // Miss fill commit and miss-launch tag invalidation events.
      wire fast_miss_commit = cache_active && (fast_state == FAST_MISS_WAIT) &&
                              fast_cur_cacheable && !l2_fill_poison &&
                              !br_inv_now && sdram_fast_beat &&
                              (fast_beat_cnt == 2'd3);
      wire br_miss_commit   = cache_active && (br_state == BR_MISS_WAIT) &&
                              !br_fill_poison && sdram_data_valid &&
                              (br_beat_cnt == 3'd7);

      wire fast_miss_idx_clash = (br_state == BR_MISS_WAIT) &&
                                 (br_req_idx == fast_cur_idx);
      wire br_miss_idx_clash   = (fast_state == FAST_MISS_WAIT) &&
                                 (fast_cur_idx == br_req_idx);

      wire fast_miss_launch = (fast_state == FAST_LOOKUP) && !fast_hit;
      wire br_miss_launch   = (br_state == BR_LOOKUP) && !br_hit;

      // If Tag Port A is busy on the miss-launch edge or the other path is
      // already filling the same index, poison the new fill up front instead
      // of leaving a stale tag over overwritten Data.
      wire fast_miss_can_inv = cache_active && fast_miss_launch &&
                               !br_inv_now && !br_miss_commit &&
                               !fast_miss_idx_clash;
      wire br_miss_can_inv   = cache_active && br_miss_launch &&
                               !br_inv_now && !fast_miss_commit &&
                               !br_miss_idx_clash;

      // Tag Write Port A arbitration (mutually exclusive priority).
      always_comb begin
        tag_wren    = 1'b0;
        tag_wr_addr = clear_idx;
        tag_wr_data = 8'h00;
        if (clear_active) begin
          tag_wren    = 1'b1;
          tag_wr_addr = clear_idx;
          tag_wr_data = 8'h00;
        end else if (br_inv_now) begin
          tag_wren    = 1'b1;
          tag_wr_addr = br_in_idx;
          tag_wr_data = 8'h00;
        end else if (fast_miss_commit) begin
          tag_wren    = 1'b1;
          tag_wr_addr = fast_cur_idx;
          tag_wr_data = {1'b1, fast_cur_tag};
        end else if (br_miss_commit) begin
          tag_wren    = 1'b1;
          tag_wr_addr = br_req_idx;
          tag_wr_data = {1'b1, br_req_tag};
        end else if (fast_miss_can_inv) begin
          tag_wren    = 1'b1;
          tag_wr_addr = fast_cur_idx;
          tag_wr_data = 8'h00;
        end else if (br_miss_can_inv) begin
          tag_wren    = 1'b1;
          tag_wr_addr = br_req_idx;
          tag_wr_data = 8'h00;
        end
      end

      // Data Write Port A: snoop returning miss beats from either path.
      // ki_sdram_burst is single-ported and serializes direct and bridge reads
      // by at least five clk_core cycles, so these two never assert together;
      // priority is still made deterministic and poisons the loser defensively.
      wire fast_data_wr = cache_active && (fast_state == FAST_MISS_WAIT) &&
                          fast_cur_cacheable && !l2_fill_poison &&
                          !br_inv_now && sdram_fast_beat;
      wire br_data_wr   = cache_active && (br_state == BR_MISS_WAIT) &&
                          !br_fill_poison && sdram_data_valid && br_beat_cnt[0];

      always_comb begin
        data_wren    = 8'h00;
        data_wr_addr = {fast_cur_idx, fast_beat_cnt};
        data_wr_data = sdram_fast_qword;
        if (fast_data_wr) begin
          data_wren    = 8'hFF;
          data_wr_addr = {fast_cur_idx, fast_beat_cnt};
          data_wr_data = sdram_fast_qword;
        end else if (br_data_wr) begin
          data_wren    = 8'hFF;
          data_wr_addr = {br_req_idx, br_beat_cnt[2:1]};
          data_wr_data = {sdram_read_data, br_q_buf[31:0]};
        end
      end

      // Read Port B address mux (Tag and Data M10K).
      always_comb begin
        if (fast_rd_start)
          tag_rd_addr = fast_in_idx;
        else if (br_rd_start_idle)
          tag_rd_addr = br_in_idx;
        else
          tag_rd_addr = br_req_idx;

        if (fast_rd_start)
          data_rd_addr = {fast_in_idx, 2'b00};
        else if (fast_state == FAST_LOOKUP)
          data_rd_addr = {fast_cur_idx, 2'b01};
        else if (fast_state == FAST_HIT_STREAM)
          data_rd_addr = {fast_cur_idx, fast_beat_cnt + 2'd2};
        else if (br_rd_start_idle)
          data_rd_addr = {br_in_idx, 2'b00};
        else if (br_rd_start_wait)
          data_rd_addr = {br_req_idx, 2'b00};
        else
          data_rd_addr = {br_req_idx, br_beat_cnt[2:1] + 2'd1};
      end

      // Adapter primary outputs. Write payload and byte enables pass straight
      // through without adding 288 holding registers in the L2.
      assign sdram_write_data  = bridge_write_data;
      assign sdram_byte_enable = bridge_byte_enable;
      assign sdram_write       = (br_state == BR_IDLE) ? br_req_write : 1'b0;
      assign sdram_read        = (br_state == BR_IDLE)   ? (br_req_read && !br_in_eligible) :
                                 (br_state == BR_LOOKUP) ? !br_hit :
                                 1'b0;
      assign sdram_address     = (br_state == BR_LOOKUP) ? br_req_addr : bridge_address;
      assign sdram_burst       = (br_state == BR_LOOKUP) ? 5'd16       : bridge_burst;

      wire sdram_br_issue = sdram_read || sdram_write;

      // Bridge return outputs.
      wire br_hit_driving = (br_state == BR_HIT_STREAM) || (br_state == BR_HIT_DONE);

      assign bridge_read_data  = br_hit_driving
                                 ? (br_beat_cnt[0] ? br_q_buf[63:32] : br_q_buf[31:0])
                                 : sdram_read_data;
      assign bridge_read_be    = br_hit_driving ? 2'b11 : sdram_read_be;
      assign bridge_data_valid = (br_state == BR_HIT_STREAM) ? 1'b1 :
                                 ((br_state == BR_IDLE) || (br_state == BR_MISS_WAIT)) ? sdram_data_valid :
                                 1'b0;
      assign bridge_done       = (br_state == BR_HIT_DONE)   ? 1'b1 :
                                 (br_state == BR_HIT_STREAM) ? 1'b0 :
                                 sdram_done;

      // Direct-fill outputs. Without L2_FAST the FSM never leaves FAST_IDLE
      // (fast_req_new is 0) and the port is a wire, as in g_bypass.
      assign sdram_fast_req_tog  = L2_FAST ? sdram_fast_req_tog_r : cpu_fast_req_tog;
      assign sdram_fast_req_line = L2_FAST ? fast_req_line_r      : cpu_fast_req_line;

      assign cpu_fast_window   = !L2_FAST ? sdram_fast_window :
                                 fast_hit_win ||
                                 ((fast_state == FAST_MISS_WAIT) && sdram_fast_window);
      assign cpu_fast_beat     = !L2_FAST ? sdram_fast_beat :
                                 fast_hit_win ||
                                 ((fast_state == FAST_MISS_WAIT) && sdram_fast_beat);
      assign cpu_fast_first    = !L2_FAST ? sdram_fast_first :
                                 (fast_hit_win && (fast_beat_cnt == 2'd0)) ||
                                 ((fast_state == FAST_MISS_WAIT) && sdram_fast_first);
      assign cpu_fast_qword    = (!L2_FAST || !fast_hit_win) ? sdram_fast_qword : fast_hit_q;
      assign cpu_fast_done_tog = L2_FAST ? fast_done_tog_r : sdram_fast_done_tog;

      // ----------------------------------------------------------------------
      // Sequential control
      // ----------------------------------------------------------------------
      always_ff @(posedge clk) begin
        cpu_reset_d   <= cpu_reset;
        fast_cooldown <= 1'b0;

        // Tag invalidation sweep.
        if (reset || (cpu_reset && !cpu_reset_d)) begin
          clear_active <= 1'b1;
          clear_idx    <= 11'd0;
        end else if (clear_active) begin
          if (clear_idx == 11'h7FF)
            clear_active <= 1'b0;
          else
            clear_idx <= clear_idx + 11'd1;
        end

        // Track transactions outstanding in sdram_adapter on the primary port.
        if (reset) begin
          sdram_br_outstanding <= 2'd0;
        end else begin
          case ({sdram_br_issue, sdram_done})
            2'b10: if (sdram_br_outstanding != 2'd3)
                     sdram_br_outstanding <= sdram_br_outstanding + 2'd1;
            2'b01: if (sdram_br_outstanding != 2'd0)
                     sdram_br_outstanding <= sdram_br_outstanding - 2'd1;
            default: ;
          endcase
        end

        // ---- Direct-fill FSM ----
        if (reset) begin
          fast_state         <= FAST_IDLE;
          fast_hit_win       <= 1'b0;
          fast_cur_cacheable <= 1'b0;
          fast_lookup_killed <= 1'b0;
          l2_fill_poison     <= 1'b1;
          fast_beat_cnt      <= 2'd0;
        end else begin
          case (fast_state)
            FAST_IDLE: begin
              fast_hit_win <= 1'b0;
              if (fast_rd_start) begin
                fast_rseen         <= cpu_fast_req_tog;
                fast_req_line_r    <= cpu_fast_req_line;
                fast_cur_cacheable <= 1'b1;
                fast_lookup_killed <= br_inv_now;
                fast_state         <= FAST_LOOKUP;
              end else if (fast_bypass_start) begin
                fast_rseen           <= cpu_fast_req_tog;
                fast_req_line_r      <= cpu_fast_req_line;
                fast_cur_cacheable   <= 1'b0;
                l2_fill_poison       <= 1'b1;
                sdram_fast_req_tog_r <= ~sdram_fast_req_tog_r;
                fast_beat_cnt        <= 2'd0;
                fast_state           <= FAST_MISS_WAIT;
              end
            end

            FAST_LOOKUP: begin
              if (fast_hit) begin
                fast_hit_q    <= data_rd_data;
                fast_hit_win  <= 1'b1;
                fast_beat_cnt <= 2'd0;
                fast_state    <= FAST_HIT_STREAM;
              end else begin
                sdram_fast_req_tog_r <= ~sdram_fast_req_tog_r;
                l2_fill_poison       <= !fast_miss_can_inv;
                fast_beat_cnt        <= 2'd0;
                fast_state           <= FAST_MISS_WAIT;
              end
            end

            FAST_HIT_STREAM: begin
              if (fast_beat_cnt == 2'd3) begin
                fast_hit_win    <= 1'b0;
                fast_done_tog_r <= ~fast_done_tog_r;
                fast_cooldown   <= 1'b1;
                fast_state      <= FAST_IDLE;
              end else begin
                fast_hit_q    <= data_rd_data;
                fast_beat_cnt <= fast_beat_cnt + 2'd1;
              end
            end

            FAST_MISS_WAIT: begin
              if (br_inv_now || cpu_reset || clear_active ||
                  (br_miss_launch && br_miss_idx_clash))
                l2_fill_poison <= 1'b1;

              if (sdram_fast_beat) begin
                if ((fast_beat_cnt == 2'd3) || fast_cur_qword_read) begin
                  fast_done_tog_r <= ~fast_done_tog_r;
                  fast_cooldown   <= 1'b1;
                  fast_state      <= FAST_IDLE;
                end else begin
                  fast_beat_cnt <= fast_beat_cnt + 2'd1;
                end
              end
            end
          endcase
        end

        // ---- Bridge request pending slot ----
        // Set by a request that arrives outside BR_IDLE; cleared once BR_IDLE
        // has taken it (every request seen in BR_IDLE is taken that cycle).
        if (reset) begin
          br_pend_rd <= 1'b0;
          br_pend_wr <= 1'b0;
        end else if (br_state == BR_IDLE) begin
          br_pend_rd <= 1'b0;
          br_pend_wr <= 1'b0;
        end else begin
          if (bridge_read)  br_pend_rd <= 1'b1;
          if (bridge_write) br_pend_wr <= 1'b1;
        end

        // ---- Bridge FSM ----
        if (reset) begin
          br_state       <= BR_IDLE;
          br_fill_poison <= 1'b1;
          br_beat_cnt    <= 3'd0;
        end else begin
          case (br_state)
            BR_IDLE: begin
              if (br_req_read && br_in_eligible) begin
                br_req_addr <= bridge_address;
                br_req_tag  <= br_in_tag;
                if (br_rd_start_idle)
                  br_state <= BR_LOOKUP;
                else
                  br_state <= BR_WAIT_PORT;
              end
            end

            BR_WAIT_PORT: begin
              if (br_rd_start_wait)
                br_state <= BR_LOOKUP;
            end

            BR_LOOKUP: begin
              if (br_hit) begin
                br_q_buf    <= data_rd_data;
                br_beat_cnt <= 3'd0;
                if (br_sdram_clear_next)
                  br_state <= BR_HIT_STREAM;
                else
                  br_state <= BR_HIT_WAIT_DONE;
              end else begin
                br_fill_poison <= !br_miss_can_inv;
                br_beat_cnt    <= 3'd0;
                br_state       <= BR_MISS_WAIT;
              end
            end

            BR_HIT_WAIT_DONE: begin
              if (br_sdram_clear_next) begin
                br_beat_cnt <= 3'd0;
                br_state    <= BR_HIT_STREAM;
              end
            end

            BR_HIT_STREAM: begin
              if (br_beat_cnt == 3'd7) begin
                // Leave br_beat_cnt at 7 so BR_HIT_DONE keeps holding the
                // final beat's data while raising bridge_done for one cycle.
                br_state <= BR_HIT_DONE;
              end else begin
                if (br_beat_cnt[0])
                  br_q_buf <= data_rd_data;
                br_beat_cnt <= br_beat_cnt + 3'd1;
              end
            end

            BR_HIT_DONE: begin
              br_state <= BR_IDLE;
            end

            BR_MISS_WAIT: begin
              if (cpu_reset || clear_active ||
                  (fast_miss_launch && fast_miss_idx_clash) ||
                  (fast_data_wr && br_data_wr))
                br_fill_poison <= 1'b1;

              if (sdram_data_valid) begin
                if (!br_beat_cnt[0])
                  br_q_buf[31:0] <= sdram_read_data;
                if (br_beat_cnt == 3'd7)
                  br_state <= BR_IDLE;
                else
                  br_beat_cnt <= br_beat_cnt + 3'd1;
              end
            end

            default: br_state <= BR_IDLE;
          endcase
        end
      end

      // ----------------------------------------------------------------------
      // Per-game-frame L2 line-fill counters (LH / LX on the Perf page)
      //
      // FAST_LOOKUP and BR_LOOKUP are mutually exclusive (they share Read Port
      // B), so at most one lookup resolves per cycle. Both count only eligible
      // main-RAM line fills, latched on perf_flip and saturating at 16'hFFFF.
      // ----------------------------------------------------------------------
      wire l2_hit_evt  = cache_active &&
                         (((fast_state == FAST_LOOKUP) && fast_hit) ||
                          ((br_state   == BR_LOOKUP)   && br_hit));
      wire l2_miss_evt = cache_active &&
                         (((fast_state == FAST_LOOKUP) && !fast_hit) ||
                          ((br_state   == BR_LOOKUP)   && !br_hit));

      logic        perf_flip_d     = 1'b0;
      logic [15:0] l2_hit_cnt      = 16'd0;
      logic [15:0] l2_miss_cnt     = 16'd0;
      logic [15:0] perf_l2_hits_r  = 16'd0;
      logic [15:0] perf_l2_misses_r = 16'd0;

      assign perf_l2_hits   = perf_l2_hits_r;
      assign perf_l2_misses = perf_l2_misses_r;

      always_ff @(posedge clk) begin
        perf_flip_d <= perf_flip;
        if (cpu_reset) begin
          l2_hit_cnt       <= 16'd0;
          l2_miss_cnt      <= 16'd0;
          perf_l2_hits_r   <= 16'd0;
          perf_l2_misses_r <= 16'd0;
        end else if (perf_flip != perf_flip_d) begin
          perf_l2_hits_r   <= l2_hit_cnt;
          perf_l2_misses_r <= l2_miss_cnt;
          l2_hit_cnt       <= {15'd0, l2_hit_evt};
          l2_miss_cnt      <= {15'd0, l2_miss_evt};
        end else begin
          if (l2_hit_evt && (l2_hit_cnt != 16'hFFFF))
            l2_hit_cnt <= l2_hit_cnt + 16'd1;
          if (l2_miss_evt && (l2_miss_cnt != 16'hFFFF))
            l2_miss_cnt <= l2_miss_cnt + 16'd1;
        end
      end

      // sdram_fast_done_tog is only used by the L2_ENABLE=0 pass-through; in
      // L2 mode ki_l2_cache owns fast_done_tog_r directly.
      wire _unused_l2 = &{1'b0, sdram_fast_done_tog};
    end
  endgenerate

endmodule

// Simple dual-port M10K primitive (write Port A, read Port B, same clock,
// unregistered Q for 1-cycle read latency). Explicit altsyncram matches
// ki_fb_ram.sv so Quartus 17.0 never silently falls back to logic registers.
module ki_l2_sdp_ram #(
  parameter int ADDR_W = 11,
  parameter int DATA_W = 8
) (
  input  wire              clk,
  input  wire [ADDR_W-1:0] wr_addr,
  input  wire [DATA_W-1:0] wr_data,
  input  wire              wren,
  input  wire [ADDR_W-1:0] rd_addr,
  output wire [DATA_W-1:0] rd_data
);
`ifdef SYNTHESIS
  altsyncram #(
    .address_aclr_b                     ("NONE"),
    .address_reg_b                      ("CLOCK0"),
    .clock_enable_input_a               ("BYPASS"),
    .clock_enable_input_b               ("BYPASS"),
    .clock_enable_output_b              ("BYPASS"),
    .intended_device_family             ("Cyclone V"),
    .lpm_type                           ("altsyncram"),
    .numwords_a                         (1 << ADDR_W),
    .numwords_b                         (1 << ADDR_W),
    .operation_mode                     ("DUAL_PORT"),
    .outdata_aclr_b                     ("NONE"),
    .outdata_reg_b                      ("UNREGISTERED"),
    .power_up_uninitialized             ("FALSE"),
    .ram_block_type                     ("M10K"),
    .read_during_write_mode_mixed_ports ("OLD_DATA"),
    .widthad_a                          (ADDR_W),
    .widthad_b                          (ADDR_W),
    .width_a                            (DATA_W),
    .width_b                            (DATA_W),
    .width_byteena_a                    (1)
  ) altsyncram_component (
    .clock0         (clk),
    .address_a      (wr_addr),
    .data_a         (wr_data),
    .wren_a         (wren),
    .address_b      (rd_addr),
    .q_b            (rd_data),
    .aclr0          (1'b0),
    .aclr1          (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .byteena_a      (1'b1),
    .byteena_b      (1'b1),
    .clock1         (1'b1),
    .clocken0       (1'b1),
    .clocken1       (1'b1),
    .clocken2       (1'b1),
    .clocken3       (1'b1),
    .data_b         ({DATA_W{1'b1}}),
    .eccstatus      (),
    .q_a            (),
    .rden_a         (1'b1),
    .rden_b         (1'b1),
    .wren_b         (1'b0)
  );
`else
  logic [DATA_W-1:0] mem [0:(1 << ADDR_W)-1];
  logic [DATA_W-1:0] q_r = '0;
  integer i;
  initial begin
    for (i = 0; i < (1 << ADDR_W); i = i + 1)
      mem[i] = '0;
  end
  always_ff @(posedge clk) begin
    q_r <= mem[rd_addr];
    if (wren)
      mem[wr_addr] <= wr_data;
  end
  assign rd_data = q_r;
`endif
endmodule

`default_nettype wire
