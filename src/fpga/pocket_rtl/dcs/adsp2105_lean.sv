// SPDX-License-Identifier: GPL-3.0-only
// ============================================================================
// adsp2105_lean.sv -- ADSP-2105 core for the DCS board, structural datapath
// ============================================================================
// Drop-in replacement for upstream rtl/dcs/adsp2105.sv (same ports, same
// module name, same clock-by-clock behaviour). Upstream's model commits a
// whole instruction from one behavioural block: rd_reg() is inlined at 12
// call sites and wr_reg() at 13, which synthesises to twelve 40:1 read
// multiplexers and thirteen parallel write decoders (7,9xx ALMs on the
// Pocket's 5CEBA4, 43 % of the device, and the design's critical path).
//
// This file keeps upstream's instruction sequencer (S_FETCH -> S_DECODE ->
// optional stalls -> S_EXEC, identical cycle counts) and replaces the
// datapath around it:
//
//   * ONE general read port and ONE general write port. No instruction class
//     uses more than one of each; the class picks the (group,index).
//   * ONE shared X operand and ONE shared Y operand for ALU / MAC / shifter.
//     The three units never commit in the same instruction.
//   * ONE DAG port (I, M, L, base) per instruction.
//   * Operands are read during S_DECODE (and held through the stall states)
//     into registers, so S_EXEC starts from flops instead of from
//     mstat[0] -> bank mux -> 32:1 register mux.
//   * Per-register write priority is explicit: the general write (lexically
//     last upstream) wins over a unit result, which wins over the autobuffer
//     drain commit. That is upstream's hazard table H1-H10, made structural.
//   * Hardware stacks are plain arrays without reset (unreachable when the
//     stack pointer is 0), so they map to MLABs.
//
// Equivalence is not argued, it is tested: tests/sim/tb_adsp_lockstep.sv runs
// this core and upstream's side by side on the real sound ROM and compares
// every output on every clock.
// ============================================================================
`ifndef KI_DCS_SIMULATION
`ifndef SYNTHESIS
`define SYNTHESIS 1
`endif
`endif

module adsp2105 (
    input  wire        clk,
    input  wire        rst,
    input  wire        core_ce,
    input  wire        host_rst,
    input  wire        host_cmd_w,
    input  wire [15:0] host_cmd_data,
    output wire [15:0] host_status_r,
    output wire [15:0] host_response_r,
    input  wire        host_resp_rd,
    output wire        rom_ddr_req,
    output wire [18:0] rom_ddr_addr,
    input  wire        rom_ddr_rdy,
    input  wire [63:0] rom_ddr_q,
    input  wire        dac_ce_in,
    output reg  [13:0] o_ppc,
    output reg         o_valid,
    output reg         o_unimpl,
    output reg  [15:0] dac_sample,
    output reg         dac_ce,
    // Diagnostics upstream exposes. The board wrapper never consumes the
    // discontinuity watchers, so they are tied off here.
    output wire [13:0] dbg_wrap_pc,
    output wire [7:0]  dbg_wrap_cnt,
    output wire [13:0] dbg_src_pc,
    output wire [13:0] dbg_src_addr,
    output wire [7:0]  dbg_src_cnt,
    output wire [7:0]  dbg_src_op,
    output wire [7:0]  dbg_rom_unstable_o,
    output wire [11:0] dbg_rom_bankdelta_o,
    output reg  [7:0]  dbg_cmd_lost,
    output reg         dbg_cmd_read
);
    assign dbg_wrap_pc = 14'h0;  assign dbg_wrap_cnt = 8'h0;
    assign dbg_src_pc  = 14'h0;  assign dbg_src_addr = 14'h0;
    assign dbg_src_cnt = 8'h0;   assign dbg_src_op   = 8'h0;
    assign dbg_rom_unstable_o = 8'h0; assign dbg_rom_bankdelta_o = 12'h0;

    wire cpu_ce = core_ce;

    // ------------------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------------------
    // g0, both banks: AX0 AX1 MX0 MX1 AY0 AY1 MY0 MY1 SI SE AR MR0 MR1 MR2 SR0 SR1
    reg [15:0] gr [0:31];
    reg [13:0] iR    [0:7];
    reg [13:0] mR    [0:7];     // stored 14-bit, read sign-extended
    reg [13:0] lR    [0:7];
    reg [13:0] baseR [0:7];
    reg [13:0] lmask [0:7];
    reg [15:0] astat, mstat, sstat, imask, icntl, px;
    reg [15:0] afb [0:1];
    reg [15:0] mfb [0:1];
    reg [15:0] sbb [0:1];
    reg [13:0] cntr;
    reg [10:0] data_bank;
    reg [13:0] pc;

    wire bnk = mstat[0];

    // stacks: no reset, only reachable through a non-zero pointer
    reg [13:0] pc_stack   [0:15];
    reg [4:0]  pc_sp;
    reg [13:0] cntr_stack [0:3];
    reg [2:0]  cntr_sp;
    reg [13:0] loop_end   [0:3];
    reg [3:0]  loop_cond  [0:3];
    reg [2:0]  loop_sp;
    reg [47:0] stat_stack [0:15];   // {mstat, imask, astat}
    reg [4:0]  stat_sp;

    wire [13:0] pc_top    = pc_stack[pc_sp[3:0] - 4'd1];
    wire [13:0] cntr_top  = cntr_stack[cntr_sp[1:0] - 2'd1];
    wire [13:0] lend_top  = loop_end[loop_sp[1:0] - 2'd1];
    wire [3:0]  lcond_top = loop_cond[loop_sp[1:0] - 2'd1];
    wire [47:0] stat_top  = stat_stack[stat_sp[3:0] - 4'd1];

    // sequencer / boot
    localparam [2:0] S_BOOT = 3'd0, S_FETCH = 3'd1, S_DECODE = 3'd2, S_DRAIN = 3'd3,
                     S_DIV  = 3'd4, S_ROM   = 3'd5, S_MEM    = 3'd6, S_EXEC  = 3'd7;
    reg [2:0]  state;
    reg        boot_active;
    reg [11:0] boot_idx, boot_plen;
    reg [10:0] boot_bank;
    reg [1:0]  boot_phase;
    reg [7:0]  boot_b0, boot_b1;
    reg        host_rst_r;
    reg        reboot_pending;
    reg [10:0] reboot_bank;

    // timer
    reg [8:0]  tim_scale, tim_scale_cnt;
    reg [15:0] tim_count, tim_period;
    reg        tim_irq_latch;

    // SPORT1 autobuffer
    reg        ab_active;
    reg [2:0]  ab_ireg;
    reg [15:0] ab_size, ab_incs;
    reg [15:0] dac_slot_ctr;
    reg        dac_slot_go;
    reg [15:0] ab_drain_cnt;
    reg        dr_done;
    reg [16:0] dr_idx;
    reg [31:0] dr_acc;
    reg [1:0]  dr_region;

    // host mailbox / interrupts
    reg [15:0] input_data;
    reg        irq2_line, irq2_latch, irq1_pulse;
    reg [15:0] latch_control, output_data;
    assign host_status_r   = latch_control;
    assign host_response_r = output_data;

    reg [15:0] ctl_s1_autobuf, ctl_syscontrol;

    // divider for the TX1 arm
    reg        div_done;
    reg [4:0]  div_i;
    reg [15:0] div_q, div_nd;
    reg [16:0] div_rem, div_v;

    // S_DECODE latches
    reg [23:0] op_r;
    reg [15:0] ea_addr_r;
    reg [13:0] pm_addr_r;
    reg        pm_rd_r, bank_rd_r, tx1_r;
    reg        mem_need_r;

    // ------------------------------------------------------------------------
    // Memories
    // ------------------------------------------------------------------------
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] dm [0:16383];
    reg         dm_we;
    reg  [15:0] dm_wd;
    wire [13:0] dm_addr;
    reg  [15:0] dm_q;
    always @(posedge clk) begin
        if (cpu_ce) begin
            dm_q <= dm[dm_addr];
            if (dm_we) dm[ea_addr_r[13:0]] <= dm_wd;
        end
    end

    reg         pm_we;
    reg  [2:0]  pm_be;
    reg  [13:0] pm_wa;
    reg  [23:0] pm_wd;
    wire [13:0] fetch_addr = pc;
    wire [23:0] fetch_q;
    wire [13:0] pmb_addr;
    wire [23:0] pmb_q;

`ifdef SYNTHESIS
    altsyncram #(
        .address_reg_b("CLOCK1"), .byteena_reg_b("CLOCK1"),
        .clock_enable_input_a("NORMAL"), .clock_enable_input_b("NORMAL"),
        .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
        .indata_reg_b("CLOCK1"), .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"), .numwords_a(16384), .numwords_b(16384),
        .operation_mode("BIDIR_DUAL_PORT"),
        .outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .power_up_uninitialized("FALSE"), .ram_block_type("M10K"),
        .rdcontrol_reg_b("CLOCK1"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .wrcontrol_wraddress_reg_b("CLOCK1"),
        .widthad_a(14), .widthad_b(14), .width_a(24), .width_b(24),
        .width_byteena_a(3), .width_byteena_b(1)
    ) pm_ram (
        .clock0(clk), .address_a(pm_we ? pm_wa : pmb_addr), .data_a(pm_wd),
        .byteena_a(pm_be), .wren_a(pm_we), .q_a(pmb_q),
        .address_b(fetch_addr), .data_b(24'h000000), .byteena_b(1'b1),
        .wren_b(1'b0), .q_b(fetch_q),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clock1(clk), .clocken0(cpu_ce), .clocken1(cpu_ce),
        .clocken2(1'b1), .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
    );
`else
    reg [23:0] pm [0:16383];
    reg [23:0] fetch_r, pmb_r, pm_write_word;
    assign fetch_q = fetch_r;
    assign pmb_q   = pmb_r;
    always @* begin
        pm_write_word = pm[pm_wa];
        if (pm_be[2]) pm_write_word[23:16] = pm_wd[23:16];
        if (pm_be[1]) pm_write_word[15:8]  = pm_wd[15:8];
        if (pm_be[0]) pm_write_word[7:0]   = pm_wd[7:0];
    end
    always @(posedge clk) begin
        if (cpu_ce) begin
            fetch_r <= pm[fetch_addr];
            if (pm_we) begin
                pmb_r     <= pm_write_word;
                pm[pm_wa] <= pm_write_word;
            end else
                pmb_r <= pm[pmb_addr];
        end
    end
    integer k0;
    initial for (k0 = 0; k0 < 16384; k0 = k0 + 1) begin pm[k0] = 24'h0; dm[k0] = 16'h0; end
`endif

    wire        rom_req;
    wire [22:0] rom_addr;
    wire        rom_rdy;
    wire [7:0]  rom_q;
    dcs_mem u_mem
        (.clk(clk), .rst(rst), .core_ce(cpu_ce),
         .rom_req(rom_req), .rom_addr(rom_addr),
         .rom_rdy(rom_rdy), .rom_q(rom_q),
         .ext_req(rom_ddr_req), .ext_addr(rom_ddr_addr),
         .ext_rdy(rom_ddr_rdy), .ext_q(rom_ddr_q));

    // ------------------------------------------------------------------------
    // Helpers (bit-for-bit upstream's)
    // ------------------------------------------------------------------------
    localparam [1:0] RG_DM = 2'd0, RG_ALIAS = 2'd1, RG_BANK = 2'd2, RG_LATCH = 2'd3;
    function [1:0] dm_region(input [15:0] a);
        begin
            if      (a >= 16'h0800 && a <= 16'h1fff) dm_region = RG_ALIAS;
            else if (a >= 16'h2000 && a <= 16'h2fff) dm_region = RG_BANK;
            else if (a >= 16'h3400 && a <= 16'h3403) dm_region = RG_LATCH;
            else                                     dm_region = RG_DM;
        end
    endfunction

    // Pure functions: every piece of state is an argument, so a continuous
    // assignment that calls one is sensitive to all of it.
    function cond_true(input [3:0] c, input [15:0] astat);
        reg az, an, av, ac, as, mv;
        begin
            az = astat[0]; an = astat[1]; av = astat[2];
            ac = astat[3]; as = astat[4]; mv = astat[6];
            case (c)
                4'h0: cond_true = az;
                4'h1: cond_true = !az;
                4'h2: cond_true = !((an^av)|az);
                4'h3: cond_true = (an^av)|az;
                4'h4: cond_true = an^av;
                4'h5: cond_true = !(an^av);
                4'h6: cond_true = av;
                4'h7: cond_true = !av;
                4'h8: cond_true = ac;
                4'h9: cond_true = !ac;
                4'hA: cond_true = as;
                4'hB: cond_true = !as;
                4'hC: cond_true = mv;
                4'hD: cond_true = !mv;
                4'hE: cond_true = 1'b0;   // CE: resolved by the caller
                4'hF: cond_true = 1'b1;
            endcase
        end
    endfunction

    function [13:0] mask_fn(input [13:0] l);
        begin
            if      (l > 14'h2000) mask_fn = 14'h0000;
            else if (l > 14'h1000) mask_fn = 14'h2000;
            else if (l > 14'h0800) mask_fn = 14'h3000;
            else if (l > 14'h0400) mask_fn = 14'h3800;
            else if (l > 14'h0200) mask_fn = 14'h3c00;
            else if (l > 14'h0100) mask_fn = 14'h3e00;
            else if (l > 14'h0080) mask_fn = 14'h3f00;
            else if (l > 14'h0040) mask_fn = 14'h3f80;
            else if (l > 14'h0020) mask_fn = 14'h3fc0;
            else if (l > 14'h0010) mask_fn = 14'h3fe0;
            else if (l > 14'h0008) mask_fn = 14'h3ff0;
            else if (l > 14'h0004) mask_fn = 14'h3ff8;
            else if (l > 14'h0002) mask_fn = 14'h3ffc;
            else if (l > 14'h0001) mask_fn = 14'h3ffe;
            else                   mask_fn = 14'h3fff;
        end
    endfunction

    function [13:0] rev14(input [13:0] a);
        integer j;
        for (j = 0; j < 14; j = j + 1) rev14[j] = a[13-j];
    endfunction

    function [15:0] c_nz(input [15:0] a, input [31:0] r);
        begin
            c_nz = a;
            if ((r & 32'h0000ffff)==0) c_nz = c_nz | 16'h0001;
            c_nz = c_nz | ((r >> 14) & 16'h0002);
        end
    endfunction
    function [15:0] c_v(input [15:0] a, input [31:0] s, input [31:0] d, input [31:0] r);
        c_v = a | (((s ^ d ^ r ^ (r>>1)) >> 13) & 16'h0004);
    endfunction

    function automatic [31:0] alu_eval(input [3:0] sub, input [15:0] xv, input [15:0] yv,
                                       input [15:0] astat, input [15:0] mstat);
        reg [16:0] r; reg [15:0] astn; reg cin; reg [31:0] s32,d32,r32;
        begin
            cin  = astat[3];
            astn = astat & ~(mstat[2] ? 16'h000B : 16'h000F);
            case (sub)
              4'h0: r = {1'b0, yv};
              4'h1: r = {1'b0, yv} + 17'd1;
              4'h2: r = {1'b0, xv} + {1'b0, yv} + {16'h0,cin};
              4'h3: r = {1'b0, xv} + {1'b0, yv};
              4'h4: r = {1'b0, (~yv)};
              4'h5: r = 17'h0 - {1'b0, yv};
              4'h6: r = {1'b0, xv} - {1'b0, yv} + {16'h0,cin} - 17'd1;
              4'h7: r = {1'b0, xv} - {1'b0, yv};
              4'h8: r = {1'b0, yv} - 17'd1;
              4'h9: r = {1'b0, yv} - {1'b0, xv};
              4'ha: r = {1'b0, yv} - {1'b0, xv} + {16'h0,cin} - 17'd1;
              4'hb: r = {1'b0, (~xv)};
              4'hc: r = {1'b0, (xv & yv)};
              4'hd: r = {1'b0, (xv | yv)};
              4'he: r = {1'b0, (xv ^ yv)};
              4'hf: r = xv[15] ? (17'h0 - {1'b0,xv}) : {1'b0,xv};
            endcase
            astn = c_nz(astn, {15'h0, r});
            s32 = {16'h0, xv}; d32 = {16'h0, yv}; r32 = {15'h0, r};
            case (sub)
              4'h2,4'h3: begin astn=c_v(astn,s32,d32,r32); astn=astn | ((r32>>13)&16'h0008); end
              4'h6,4'h7: begin astn=c_v(astn,s32,d32,r32); astn=astn | (((~r32)>>13)&16'h0008); end
              4'h9,4'ha: begin astn=c_v(astn,d32,s32,r32); astn=astn | (((~r32)>>13)&16'h0008); end
              4'h1: if(yv==16'h7fff) astn=astn|16'h0004; else if(yv==16'hffff) astn=astn|16'h0008;
              4'h5: begin if(yv==16'h8000) astn=astn|16'h0004; if(yv==16'h0000) astn=astn|16'h0008; end
              4'h8: if(yv==16'h8000) astn=astn|16'h0004; else if(yv==16'h0000) astn=astn|16'h0008;
              4'hf: begin astn = astat & ~(mstat[2] ? 16'h001B : 16'h001F);
                          if(xv==16'h0) astn=astn|16'h0001;
                          if(xv==16'h8000) astn=astn|16'h0006; if(xv[15]) astn=astn|16'h0010; end
              default: ;
            endcase
            alu_eval = {astn, r[15:0]};
        end
    endfunction

    // pu is the UNSIGNED 16x16 product of xv and yv, registered one enable
    // earlier together with the operands (see pu_r). The signed variants are
    // derived from it: for a 16-bit x read as signed, x_s = x_u - 2^16*x[15],
    // so x_s*y_s = x_u*y_u - 2^16*(x[15]*y_u + y[15]*x_u) modulo 2^32. That
    // keeps the multiplier out of the S_EXEC path (it was multiplier ->
    // 40-bit accumulate -> overflow flag, 20.7 ns in a 20 ns clock).
    function automatic [47:0] mac_eval(input [3:0] sub, input [15:0] xv, input [15:0] yv,
                                       input [31:0] pu,
                                       input [47:0] mr, input [15:0] mstat);
        reg xs, ys; reg [1:0] acc; reg rnd, sh;
        reg signed [31:0] p32; reg [15:0] phi; reg signed [47:0] prod, r, mrold;
        begin
            r = 48'sh0;
            if (sub != 4'h0) begin
                case (sub)
                  4'h1,4'h2,4'h3,4'h4,4'h8,4'hC: begin xs=1'b1; ys=1'b1; end
                  4'h5,4'h9,4'hD:                begin xs=1'b1; ys=1'b0; end
                  4'h6,4'hA,4'hE:                begin xs=1'b0; ys=1'b1; end
                  default:                       begin xs=1'b0; ys=1'b0; end
                endcase
                case (sub)
                  4'h2,4'h8,4'h9,4'hA,4'hB: acc=2'd1;
                  4'h3,4'hC,4'hD,4'hE,4'hF: acc=2'd2;
                  default:                  acc=2'd0;
                endcase
                rnd = (sub==4'h1)||(sub==4'h2)||(sub==4'h3);
                sh  = ~mstat[4];
                phi = pu[31:16] - ((xs && xv[15]) ? yv : 16'h0)
                                - ((ys && yv[15]) ? xv : 16'h0);
                p32 = {phi, pu[15:0]};
                if (sh) p32 = p32 <<< 1;
                prod = {{16{p32[31]}}, p32};
                mrold = $signed(mr);
                case (acc)
                  2'd1:    r = mrold + prod;
                  2'd2:    r = mrold - prod;
                  default: r = prod;
                endcase
                if (rnd) begin
                    r = r + 48'sh8000;
                    if (prod[15:0] == 16'h8000) r[16] = 1'b0;
                end
            end
            mac_eval = r;
        end
    endfunction

    function automatic integer clz32(input [31:0] v);
        integer j;
        begin
            clz32 = 32;
            for (j = 31; j >= 0; j = j - 1)
                if (v[j] && clz32 == 32) clz32 = 31 - j;
        end
    endfunction

    task automatic shift_eval(input [3:0] mode, input [15:0] xr, input signed [7:0] sc,
                              input [15:0] se_v, input [31:0] sr_v, input [15:0] sb_v,
                              input [15:0] astat,
                              output reg [31:0] o_res, output reg [15:0] o_se, output reg o_ss,
                              output reg [15:0] o_sbr,
                              output reg o_se_we, output reg o_ss_we, output reg o_sbr_we);
        reg signed [31:0] xs; reg [31:0] xu, res;
        integer e; reg signed [15:0] sev;
        begin
            o_res=32'h0; o_se=16'h0; o_ss=1'b0; o_sbr=16'h0;
            o_se_we=1'b0; o_ss_we=1'b0; o_sbr_we=1'b0;
            res = 32'h0; xs = 32'sh0; xu = 32'h0; e = 0; sev = 16'sh0;
            case (mode)
              4'h0, 4'h1: begin
                  xu = {xr, 16'h0};
                  if (sc > 0) res = (sc < 32)   ? (xu << sc)    : 32'h0;
                  else        res = (sc > -32)  ? (xu >> (-sc)) : 32'h0;
              end
              4'h2, 4'h3: begin
                  xu = {16'h0, xr};
                  if (sc > 0) res = (sc < 32)   ? (xu << sc)    : 32'h0;
                  else        res = (sc > -32)  ? (xu >> (-sc)) : 32'h0;
              end
              4'h4, 4'h5: begin
                  xs = $signed({xr, 16'h0});
                  if (sc > 0) res = (sc < 32)   ? (xs <<  sc)   : 32'h0;
                  else        res = (sc > -32)  ? (xs >>> (-sc)) : (xs >>> 31);
              end
              4'h6, 4'h7: begin
                  xs = $signed({{16{xr[15]}}, xr});
                  if (sc > 0) res = (sc < 32)   ? (xs <<  sc)   : 32'h0;
                  else        res = (sc > -32)  ? (xs >>> (-sc)) : (xs >>> 31);
              end
              4'h8, 4'h9: begin
                  xs = $signed({xr, 16'h0});
                  if (sc > 0) begin
                      xu  = {astat[3], xs[31:1]};
                      res = xu >> (sc - 1);
                  end else
                      res = (sc > -32) ? (xs << (-sc)) : 32'h0;
              end
              4'hA, 4'hB: begin
                  xu = {16'h0, xr};
                  if (sc > 0) res = (sc < 32)  ? (xu >> sc)    : 32'h0;
                  else        res = (sc > -32) ? (xu << (-sc)) : 32'h0;
              end
              4'hC: begin
                  xs = $signed({{16{xr[15]}}, xr});
                  if (xs < 0) begin
                      o_ss = 1'b1; o_ss_we = 1'b1;
                      e = clz32(~xs) - 16 - 1;
                  end else begin
                      o_ss = 1'b0; o_ss_we = 1'b1;
                      e = clz32(xs) - 16 - 1;
                  end
                  sev = -e; o_se = sev; o_se_we = 1'b1;
              end
              4'hD: begin
                  xs = $signed({{16{xr[15]}}, xr});
                  if (astat[2]) begin
                      sev = 16'sd1; o_se = sev; o_se_we = 1'b1;
                      if (xs < 0) begin o_ss = 1'b0; o_ss_we = 1'b1; end else begin o_ss = 1'b1; o_ss_we = 1'b1; end
                  end else begin
                      if (xs < 0) begin
                          o_ss = 1'b1; o_ss_we = 1'b1; e = clz32(~xs) - 16 - 1;
                      end else begin
                          o_ss = 1'b0; o_ss_we = 1'b1; e = clz32(xs) - 16 - 1;
                      end
                      sev = -e; o_se = sev; o_se_we = 1'b1;
                  end
              end
              4'hE: begin
                  if ($signed(se_v[7:0]) == -8'sd15) begin
                      xs = $signed({{16{xr[15]}}, xr});
                      e  = clz32((astat[7] ? ~xs : xs) & 32'h0000ffff) - 1;
                      sev = -e; o_se = sev; o_se_we = 1'b1;
                  end
              end
              4'hF: begin
                  xs = $signed({{16{xr[15]}}, xr});
                  e  = clz32((xs < 0) ? ~xs : xs) - 16 - 1;
                  if (e < -$signed(sb_v)) begin sev = -e; o_sbr = sev; o_sbr_we = 1'b1; end
              end
            endcase
            if (mode < 4'hC) begin
                if (mode[0]) res = sr_v | res;
                o_res = res;
            end
        end
    endtask

    // ------------------------------------------------------------------------
    // S_DECODE: everything derived from fetch_q, read once
    // ------------------------------------------------------------------------
    wire [23:0] fq  = fetch_q;
    wire [7:0]  fhi = fq[23:16];

    // which unit owns the X/Y operands of this instruction
    wire f_shift = (fhi == 8'h0E) || (fhi == 8'h0F) || (fhi[7:2] == 6'b000100);
    wire f_alu   = !f_shift && fq[17];

    reg [15:0] d_xop, d_yop;
    always @* begin
        case (fq[10:8])
          3'd0: d_xop = f_shift ? gr[{bnk,4'd8}] : f_alu ? gr[{bnk,4'd0}] : gr[{bnk,4'd2}];
          3'd1: d_xop = f_shift ? gr[{bnk,4'd8}] : f_alu ? gr[{bnk,4'd1}] : gr[{bnk,4'd3}];
          3'd2: d_xop = gr[{bnk,4'd10}];
          3'd3: d_xop = gr[{bnk,4'd11}];
          3'd4: d_xop = gr[{bnk,4'd12}];
          3'd5: d_xop = gr[{bnk,4'd13}];
          3'd6: d_xop = gr[{bnk,4'd14}];
          default: d_xop = gr[{bnk,4'd15}];
        endcase
        case (fq[12:11])
          2'd0: d_yop = f_alu ? gr[{bnk,4'd4}] : gr[{bnk,4'd6}];
          2'd1: d_yop = f_alu ? gr[{bnk,4'd5}] : gr[{bnk,4'd7}];
          2'd2: d_yop = f_alu ? afb[bnk] : mfb[bnk];
          default: d_yop = 16'h0;
        endcase
    end

    // the one general read of the instruction
    reg [1:0] d_ggrp; reg [3:0] d_gidx;
    always @* begin
        d_ggrp = 2'd0; d_gidx = fq[7:4];                 // store classes: g0[op 7:4]
        if (fhi == 8'h0D) begin d_ggrp = fq[9:8]; d_gidx = fq[3:0]; end
        else if (fhi == 8'h10 || fhi[7:3] == 5'b00101) d_gidx = fq[3:0];
        else if (fhi[7:5] == 3'b100) begin d_ggrp = fq[19:18]; d_gidx = fq[3:0]; end
    end
    // (group,index) -> 16 bits, pre-instruction state
    reg  [15:0] d_gsrc;
    wire [2:0]  d_gdw = {d_ggrp[1], d_gidx[1:0]};
    always @* begin
        d_gsrc = 16'h0;
        case (d_ggrp)
          2'd0: d_gsrc = gr[{bnk, d_gidx}];
          2'd1, 2'd2: case (d_gidx[3:2])
                  2'd0: d_gsrc = {2'b0, iR[d_gdw]};
                  2'd1: d_gsrc = {{2{mR[d_gdw][13]}}, mR[d_gdw]};
                  2'd2: d_gsrc = {2'b0, lR[d_gdw]};
                  default: d_gsrc = 16'h0;
                endcase
          default: case (d_gidx)
                  4'd0: d_gsrc = astat; 4'd1: d_gsrc = mstat;
                  4'd2: d_gsrc = sstat; 4'd3: d_gsrc = imask;
                  4'd4: d_gsrc = icntl; 4'd5: d_gsrc = {2'b0, cntr};
                  4'd6: d_gsrc = sbb[bnk]; 4'd7: d_gsrc = px;
                  default: d_gsrc = 16'h0;
                endcase
        endcase
    end

    // the one DAG port of the instruction
    wire [2:0] d_w = (fhi == 8'h09)                      ? fq[4:2]
                   : (fhi == 8'h11 || fhi[7:4] == 4'h5)  ? {1'b1, fq[3:2]}
                   : (fhi == 8'h12 || fhi == 8'h13)      ? {fq[16], fq[3:2]}
                   :                                       {fq[20], fq[3:2]};
    wire [2:0]  d_m    = {d_w[2], fq[1:0]};
    wire [13:0] d_iv   = iR[d_w];
    wire [13:0] d_dagaddr = (!d_w[2] && mstat[1]) ? rev14(d_iv) : d_iv;

    // memory pre-decode (upstream's, over the shared DAG port)
    reg         pre_dm_rd, pre_dm_wr, pre_pm_rd;
    reg  [15:0] pre_addr;
    always @* begin
        pre_dm_rd = 1'b0; pre_dm_wr = 1'b0; pre_pm_rd = 1'b0; pre_addr = 16'h0;
        casez (fhi)
          8'h11:        if (!fq[15]) pre_pm_rd = 1'b1;
          8'h12, 8'h13: begin
              pre_addr = {2'b0, d_dagaddr};
              if (fq[15]) pre_dm_wr = 1'b1; else pre_dm_rd = 1'b1;
          end
          8'b0101_????: if (!fq[19]) pre_pm_rd = 1'b1;
          8'b011?_????: begin
              pre_addr = {2'b0, d_dagaddr};
              if (fq[19]) pre_dm_wr = 1'b1; else pre_dm_rd = 1'b1;
          end
          8'b100?_????: begin
              pre_addr = {2'b0, fq[17:4]};
              if (fq[20]) pre_dm_wr = 1'b1; else pre_dm_rd = 1'b1;
          end
          8'b101?_????: begin
              pre_addr  = {2'b0, d_dagaddr};
              pre_dm_wr = 1'b1;
          end
          default: ;
        endcase
    end
    wire [13:0] pre_pm_addr = pre_pm_rd ? d_iv : 14'h0;
    wire [1:0]  pre_region  = dm_region(pre_addr);
    wire        pre_bank_rd = pre_dm_rd && (pre_region == RG_BANK);
    wire        mem_need =
        (pre_dm_rd && pre_region != RG_LATCH && pre_region != RG_BANK) ||
        (pre_dm_wr && pre_region == RG_ALIAS) || pre_pm_rd;

    wire pre_tx1_wr =
        (fhi == 8'h0D && fq[11:10] == 2'd3 && fq[7:4] == 4'hB) ||
        (fq[23:20] == 4'h3 && fq[19:18] == 2'd3 && fq[3:0] == 4'hB) ||
        (fq[23:21] == 3'b100 && !fq[20] && fq[19:18] == 2'd3 && fq[3:0] == 4'hB);

    // autobuffer configuration port (live control-register shadow)
    wire [2:0]  ab_ir_w = ctl_s1_autobuf[11:9];
    wire [2:0]  ab_mr_w = {ctl_s1_autobuf[11], ctl_s1_autobuf[8:7]};
    wire [15:0] ab_m16  = {{2{mR[ab_mr_w][13]}}, mR[ab_mr_w]};
    wire [15:0] pre_ab_incs = (ab_m16 == 16'h0) ? 16'h1 : ab_m16;

    // operand registers: loaded on every non-EXEC enable, so they hold the
    // values of the last check-state clock when S_EXEC commits.
    reg [15:0] xop_r, yop_r, gsrc_r;
    reg [31:0] pu_r;                    // xop_r * yop_r, unsigned
    reg [2:0]  dag_w_r;
    reg [13:0] dag_i_r, dag_m_r, dag_l_r, dag_b_r, jind_r;
    always @(posedge clk) begin
        if (cpu_ce && state != S_EXEC) begin
            xop_r   <= d_xop;
            yop_r   <= d_yop;
            pu_r    <= d_xop * d_yop;
            gsrc_r  <= d_gsrc;
            dag_w_r <= d_w;
            dag_i_r <= d_iv;
            dag_m_r <= mR[d_m];
            dag_l_r <= lR[d_w];
            dag_b_r <= baseR[d_w];
            jind_r  <= iR[{1'b1, fq[7:6]}];
        end
    end

    // ------------------------------------------------------------------------
    // S_EXEC: combinational results from the operand registers
    // ------------------------------------------------------------------------
    wire [23:0] op = op_r;
    wire [7:0]  hi = op[23:16];

    wire c_sat   = (hi == 8'h05);
    wire c_divs  = (hi == 8'h06);
    wire c_divq  = (hi == 8'h07);
    wire c_mod   = (hi == 8'h09);
    wire c_rts   = (hi == 8'h0A);
    wire c_jind  = (hi == 8'h0B);
    wire c_mode  = (hi == 8'h0C);
    wire c_move  = (hi == 8'h0D);
    wire c_shc   = (hi == 8'h0E);
    wire c_shi   = (hi == 8'h0F);
    wire c_shmv  = (hi == 8'h10);
    wire c_shpm  = (hi == 8'h11);
    wire c_shdm  = (hi == 8'h12) || (hi == 8'h13);
    wire c_do    = (hi[7:2] == 6'b000101);
    wire c_jmp   = (hi[7:3] == 5'b00011);
    wire c_cau   = (hi[7:3] == 5'b00100);
    wire c_aumv  = (hi[7:3] == 5'b00101);
    wire c_ldn   = (hi[7:4] == 4'h3);
    wire c_ldd   = (hi[7:4] == 4'h4);
    wire c_aupm  = (hi[7:4] == 4'h5);
    wire c_audm  = (hi[7:5] == 3'b011);
    wire c_dmi   = (hi[7:5] == 3'b100);
    wire c_dmimm = (hi[7:5] == 3'b101);
    wire c_known = (hi == 8'h00) | c_sat | c_divs | c_divq | c_mod | c_rts | c_jind |
                   c_mode | c_move | c_shc | c_shi | c_shmv | c_shpm | c_shdm | c_do |
                   c_jmp | c_cau | c_aumv | c_ldn | c_ldd | c_aupm | c_audm | c_dmi |
                   c_dmimm;

    wire ex = cpu_ce && (state == S_EXEC);

    // conditions and the counter
    wire ce_true   = (cntr > 14'd1);
    wire c_cond    = c_rts | c_jind | c_shc | c_jmp | c_cau;
    wire cflag     = (op[3:0] == 4'hF) ? 1'b1
                   : (op[3:0] == 4'hE) ? ce_true : cond_true(op[3:0], astat);
    wire body_ce   = c_cond && (op[3:0] == 4'hE);
    wire loop_hit  = (loop_sp != 3'd0) && (pc == lend_top);
    wire loop_ce   = loop_hit && (lcond_top == 4'hE);
    wire loop_back = loop_hit && (loop_ce ? ce_true : cond_true(lcond_top, astat));
    wire loop_exit = loop_hit && !loop_back;
    wire ce_dec    = (loop_ce | body_ce) &&  ce_true;
    wire ce_pop    = (loop_ce | body_ce) && !ce_true;

    // shared units
    wire [15:0] se_w = gr[{bnk, 4'd9}];
    wire [31:0] sr_w = {gr[{bnk, 4'd15}], gr[{bnk, 4'd14}]};
    wire [47:0] mr_w = {gr[{bnk, 4'd13}], gr[{bnk, 4'd12}], gr[{bnk, 4'd11}]};
    wire [15:0] ay0_w = gr[{bnk, 4'd4}];
    wire [15:0] af_w  = afb[bnk];
    wire [15:0] sb_w  = sbb[bnk];

    wire [31:0] alu_res = alu_eval(op[16:13], xop_r, yop_r, astat, mstat);
    wire [47:0] mac_r   = mac_eval(op[16:13], xop_r, yop_r, pu_r, mr_w, mstat);
    reg  [31:0] shift_res_v;
    reg  [15:0] shift_se_v, shift_sbr_v;
    reg         shift_ss_v, shift_se_we, shift_ss_we, shift_sbr_we;
    always @* begin
        shift_eval(op[14:11], xop_r, c_shi ? op[7:0] : se_w[7:0], se_w, sr_w, sb_w, astat,
                   shift_res_v, shift_se_v, shift_ss_v, shift_sbr_v,
                   shift_se_we, shift_ss_we, shift_sbr_we);
    end

    wire au_par   = (c_aupm | c_audm) && (op[17:13] != 5'h0);
    wire au_any   = (c_cau && cflag) | c_aumv | au_par;
    wire alu_do   = au_any &&  op[17];
    wire mac_do   = au_any && !op[17] && (op[16:13] != 4'h0);
    wire dst_alt  = op[18];
    wire shift_do = (c_shc && cflag) | c_shi | c_shmv | c_shpm | c_shdm;
    wire sat_do   = c_sat && astat[6];
    wire mac_mv   = (mac_r[39:31] != 9'h000) && (mac_r[39:31] != 9'h1ff);

    // DIVS / DIVQ
    wire [15:0] divq_res  = astat[5] ? (af_w + xop_r) : (af_w - xop_r);
    wire [15:0] div_dmv   = c_divs ? yop_r : divq_res;
    wire        div_tbit  = c_divs ? (xop_r[15] ^ yop_r[15]) : (divq_res[15] ^ xop_r[15]);
    wire        div_do    = c_divs | c_divq;
    wire [15:0] div_af    = {div_dmv[14:0], ay0_w[15]};
    wire [15:0] div_ay0   = {ay0_w[14:0], c_divs ? div_tbit : ~div_tbit};

    // data-memory access of the instruction
    wire dm_wr_i = (c_shdm && op[15]) | (c_audm && op[19]) | (c_dmi && op[20]) | c_dmimm;
    wire dm_rd_i = (c_shdm && !op[15]) | (c_audm && !op[19]) | (c_dmi && !op[20]);
    wire pm_rd_i = (c_shpm && !op[15]) | (c_aupm && !op[19]);
    wire pm_wr_i = (c_shpm &&  op[15]) | (c_aupm &&  op[19]);
    wire [15:0] ea     = ea_addr_r;
    wire [1:0]  ea_rg  = dm_region(ea);
    wire        ea_latch = (ea_rg == RG_LATCH);
    wire [15:0] dm_wdata = c_dmimm ? op[19:4] : gsrc_r;
    wire [15:0] dmv = (ea_rg == RG_ALIAS) ? pmb_q[23:8]
                    : (ea_rg == RG_BANK)  ? {8'hFF, rom_q}
                    : (ea_rg == RG_LATCH) ? input_data
                    : (ea == 16'h3FFC)    ? tim_count : dm_q;
    wire dm_plain_wr = dm_wr_i && (ea_rg != RG_ALIAS) && (ea != 16'h3000) && !ea_latch;

    always @* begin
        dm_we = ex && dm_plain_wr;
        dm_wd = dm_wdata;
    end

    // the one general write of the instruction
    wire gw_en = c_move | c_shmv | pm_rd_i | dm_rd_i | c_aumv | c_ldn | c_ldd;
    wire [1:0] gw_grp = c_move ? op[11:10]
                      : (c_ldn | c_dmi) ? op[19:18] : 2'd0;
    wire [3:0] gw_idx = (c_ldn | c_ldd | c_dmi) ? op[3:0] : op[7:4];
    wire [15:0] gw_val = (c_move | c_shmv | c_aumv) ? gsrc_r
                       : pm_rd_i ? pmb_q[23:8]
                       : dm_rd_i ? dmv
                       : c_ldn   ? {2'b0, op[17:4]}
                       :           op[19:4];
    wire gw_g0 = gw_en && (gw_grp == 2'd0);
    wire gw_g3 = gw_en && (gw_grp == 2'd3);
    wire gw_dag = gw_en && (gw_grp == 2'd1 || gw_grp == 2'd2);
    wire [2:0] gw_dw = {gw_grp[1], gw_idx[1:0]};          // I/M/L number 0..7
    wire gw_i = gw_dag && (gw_idx[3:2] == 2'd0);
    wire gw_m = gw_dag && (gw_idx[3:2] == 2'd1);
    wire gw_l = gw_dag && (gw_idx[3:2] == 2'd2);

    // TX1 write: arm the autobuffer
    wire arm_do = gw_g3 && (gw_idx == 4'hB) && ctl_syscontrol[11] && ctl_s1_autobuf[1];
    wire [13:0] arm_i = iR[ab_ir_w] & 14'h3FF0;

    // DAG post-modify
    wire mod_do = c_mod | c_shpm | c_shdm | c_aupm | c_audm | c_dmimm;
    wire [13:0] mod_sum = dag_i_r + dag_m_r;
    wire [14:0] mod_end = {1'b0, dag_b_r} + {1'b0, dag_l_r};
    wire [13:0] mod_i   = (mod_sum < dag_b_r)          ? (mod_sum + dag_l_r)
                        : ({1'b0, mod_sum} >= mod_end) ? (mod_sum - dag_l_r)
                        :                                mod_sum;

    // autobuffer drain commit
    wire        drain_pend = ab_active && dac_slot_go;
    wire [31:0] dr_cur     = (dr_idx == 17'd0) ? {18'h0, iR[ab_ireg]} : dr_acc;
    wire        drain_commit = drain_pend && dr_done;
    wire        dr_wrap = (dr_cur >= ({18'h0, baseR[ab_ireg]} + {16'h0, ab_size}));
    wire [13:0] dr_i    = dr_wrap ? baseR[ab_ireg] : dr_cur[13:0];

    // PM port A write command
    always @* begin
        pm_we = 1'b0; pm_be = 3'b000; pm_wa = 14'h0000; pm_wd = 24'h000000;
        if (boot_active && rom_rdy && boot_phase == 2'd3) begin
            pm_we = 1'b1; pm_be = 3'b111;
            pm_wa = {2'b0, boot_idx};
            pm_wd = {boot_b0, boot_b1, rom_q};
        end else if (state == S_EXEC) begin
            if (pm_wr_i) begin
                pm_we = 1'b1; pm_be = 3'b111;
                pm_wa = dag_i_r;
                pm_wd = {gsrc_r, px[7:0]};
            end else if (dm_wr_i && ea_rg == RG_ALIAS) begin
                pm_we = 1'b1; pm_be = 3'b110;
                pm_wa = ea[13:0];
                pm_wd = {dm_wdata, 8'h00};
            end
        end
    end

    assign pmb_addr = (state == S_DRAIN) ? dr_cur[13:0]
                    : pm_rd_r            ? pm_addr_r
                    :                      ea_addr_r[13:0];
    assign dm_addr  = (state == S_DRAIN) ? dr_cur[13:0] : ea_addr_r[13:0];

    wire [23:0] boot_rom_base   = ({13'h0, boot_bank} << 12);
    wire [23:0] boot_rom_addr24 = (boot_phase == 2'd0)
                                ? (boot_rom_base + 24'd3)
                                : (boot_rom_base + ({12'h0, boot_idx} << 2)
                                   + {22'h0, boot_phase - 2'd1});
    assign rom_addr = boot_active ? boot_rom_addr24[22:0]
                    : (state == S_DECODE)
                      ? ({data_bank, 12'h0} + {11'h0, pre_addr[11:0]})
                      : ({data_bank, 12'h0} + {11'h0, ea_addr_r[11:0]});
    assign rom_req  = boot_active
                    | (state == S_DECODE && pre_bank_rd)
                    | ((state == S_DRAIN || state == S_DIV || state == S_ROM ||
                        state == S_MEM   || state == S_EXEC) && bank_rd_r);

    // ------------------------------------------------------------------------
    // g0 register file: one write decoder per register
    // ------------------------------------------------------------------------
    wire cpu_clear;   // synchronous clear of the CPU registers (reset / reboot)

    function [15:0] sext8(input [15:0] v);
        sext8 = {{8{v[7]}}, v[7:0]};
    endfunction

    genvar gb, gi;
    generate
      for (gb = 0; gb < 2; gb = gb + 1) begin : g_bank
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_reg
          reg        we;
          reg [15:0] nv;
          always @* begin
              we = 1'b0; nv = gw_val;
              if (gw_g0 && gw_idx == gi) begin
                  we = 1'b1;
                  nv = (gi == 9 || gi == 13) ? sext8(gw_val) : gw_val;
              end else if (gi == 13 && gw_g0 && gw_idx == 4'hC) begin
                  we = 1'b1; nv = {16{gw_val[15]}};
              end else begin
                  case (gi)
                    4:  begin we = div_do; nv = div_ay0; end
                    9:  begin we = shift_do && shift_se_we; nv = shift_se_v; end
                    10: begin
                        we = alu_do && !dst_alt;
                        nv = (mstat[3] && alu_res[18]) ? (alu_res[19] ? 16'h8000 : 16'h7fff)
                                                      : alu_res[15:0];
                    end
                    11: begin
                        we = (mac_do && !dst_alt) || sat_do;
                        nv = sat_do ? (mr_w[39] ? 16'h0000 : 16'hffff) : mac_r[15:0];
                    end
                    12: begin
                        we = (mac_do && !dst_alt) || sat_do;
                        nv = sat_do ? (mr_w[39] ? 16'h8000 : 16'h7fff) : mac_r[31:16];
                    end
                    13: begin
                        we = (mac_do && !dst_alt) || sat_do;
                        nv = sat_do ? (mr_w[39] ? 16'hffff : 16'h0000) : mac_r[47:32];
                    end
                    14: begin we = shift_do && (op[14:11] < 4'hC); nv = shift_res_v[15:0];  end
                    15: begin we = shift_do && (op[14:11] < 4'hC); nv = shift_res_v[31:16]; end
                    default: ;
                  endcase
              end
          end
          always @(posedge clk) begin
              if (cpu_clear)                      gr[gb*16+gi] <= 16'h0;
              else if (ex && bnk == gb && we)     gr[gb*16+gi] <= nv;
          end
        end
        always @(posedge clk) begin
            if (cpu_clear) begin
                afb[gb] <= 16'h0; mfb[gb] <= 16'h0; sbb[gb] <= 16'h0;
            end else if (ex && bnk == gb) begin
                if (div_do)                      afb[gb] <= div_af;
                else if (alu_do && dst_alt)      afb[gb] <= alu_res[15:0];
                if (mac_do && dst_alt)           mfb[gb] <= mac_r[31:16];
                if (gw_g3 && gw_idx == 4'd6)     sbb[gb] <= gw_val;
                else if (shift_do && shift_sbr_we) sbb[gb] <= shift_sbr_v;
            end
        end
      end
    endgenerate

    // ------------------------------------------------------------------------
    // DAG registers: instruction write > autobuffer drain commit
    // ------------------------------------------------------------------------
    genvar dw;
    generate
      for (dw = 0; dw < 8; dw = dw + 1) begin : g_dag
        always @(posedge clk) begin
            if (cpu_clear) begin
                iR[dw] <= 14'h0; mR[dw] <= 14'h0; lR[dw] <= 14'h0;
                baseR[dw] <= 14'h0; lmask[dw] <= 14'h3fff;
            end else if (ex) begin
                // I
                if (mod_do && dag_w_r == dw)            iR[dw] <= mod_i;
                else if (gw_i && gw_dw == dw)           iR[dw] <= gw_val[13:0];
                else if (arm_do && ab_ir_w == dw)       iR[dw] <= arm_i;
                else if (drain_commit && ab_ireg == dw) iR[dw] <= dr_i;
                // M
                if (gw_m && gw_dw == dw)                mR[dw] <= gw_val[13:0];
                // L and its mask
                if (gw_l && gw_dw == dw) begin
                    lR[dw]    <= gw_val[13:0];
                    lmask[dw] <= mask_fn(gw_val[13:0]);
                end
                // base
                if (gw_l && gw_dw == dw)                baseR[dw] <= iR[dw] & mask_fn(gw_val[13:0]);
                else if (gw_i && gw_dw == dw)           baseR[dw] <= gw_val[13:0] & lmask[dw];
                else if (arm_do && ab_ir_w == dw)       baseR[dw] <= arm_i & lmask[dw];
                else if (drain_commit && ab_ireg == dw) baseR[dw] <= dr_i & lmask[dw];
            end
        end
      end
    endgenerate

    // ------------------------------------------------------------------------
    // Sequencer, status registers, stacks, peripherals
    // ------------------------------------------------------------------------
    wire irq_take2 = (icntl[2] ? irq2_latch : irq2_line) && imask[5];
    wire irq_take1 = irq1_pulse && imask[2];
    wire irq_takeT = tim_irq_latch && imask[0];
    wire in_check  = (state == S_DECODE) || (state == S_DRAIN) || (state == S_DIV) ||
                     (state == S_ROM)    || (state == S_MEM);

    // CPU register clear: power-on reset, SYSCONTROL soft reboot, board reset
    assign cpu_clear = rst || (cpu_ce && in_check && (reboot_pending || host_rst_r));

    reg [15:0] mstat_tmp;
    reg [17:0] div_t;
    reg [15:0] dr_smp;

    task automatic launch_boot(input [10:0] bank);
        begin
            boot_active <= 1'b1;
            state       <= S_BOOT;
            boot_bank   <= bank;
            boot_idx    <= 12'h0;
            boot_plen   <= 12'h0;
            boot_phase  <= 2'd0;
        end
    endtask

    task automatic clear_cpu_ctl;
        begin
            dr_done <= 1'b0; dr_idx <= 17'd0; div_done <= 1'b0; div_i <= 5'd0;
            pc <= 14'h0000; o_valid <= 1'b0; o_unimpl <= 1'b0;
            loop_sp <= 3'd0; pc_sp <= 5'd0; cntr_sp <= 3'd0; cntr <= 14'h0; stat_sp <= 5'd0;
            astat <= 16'h0; mstat <= 16'h0; sstat <= 16'h0; imask <= 16'h0;
            icntl <= 16'h0; px <= 16'h0;
            irq2_line <= 1'b0; irq2_latch <= 1'b0; irq1_pulse <= 1'b0;
            tim_irq_latch <= 1'b0;
        end
    endtask

    initial begin
        data_bank = 11'h0; input_data = 16'h0; latch_control = 16'h0C00;
        output_data = 16'h0; host_rst_r = 1'b0;
        tim_scale = 9'd1; tim_count = 16'h0; tim_period = 16'h0;
        tim_scale_cnt = 9'd1; tim_irq_latch = 1'b0;
        dac_sample = 16'h0; dac_ce = 1'b0;
        boot_active = 1'b0; boot_idx = 12'h0; boot_plen = 12'h0; boot_bank = 11'h0;
        boot_phase = 2'd0; boot_b0 = 8'h0; boot_b1 = 8'h0;
        state = S_FETCH; dr_done = 1'b0; dr_idx = 17'd0; dr_acc = 32'h0;
        div_done = 1'b0; div_i = 5'd0; div_q = 16'h0; ab_drain_cnt = 16'h0;
        dr_region = RG_DM;
        ctl_s1_autobuf = 16'h0; ctl_syscontrol = 16'h0;
    end

    always @(posedge clk) begin
        dac_ce       <= 1'b0;
        dbg_cmd_read <= 1'b0;
        if (rst) begin
            clear_cpu_ctl();
            o_ppc <= 14'h0;
            dac_sample <= 16'h0;
            dbg_cmd_lost <= 8'h0;
            data_bank <= 11'h0; reboot_pending <= 1'b0; launch_boot(11'h0);
            latch_control <= 16'h0C00; output_data <= 16'h0;
            ab_active <= 1'b0; dac_slot_ctr <= 16'h0; dac_slot_go <= 1'b0;
            host_rst_r <= 1'b0;
            tim_scale <= 9'd1; tim_count <= 16'h0; tim_period <= 16'h0;
            tim_scale_cnt <= 9'd1;
        end else if (cpu_ce) begin
          case (state)
          S_BOOT: begin
            o_valid <= 1'b0;
            if (rom_rdy) begin
                case (boot_phase)
                  2'd0: begin
                      boot_plen  <= ({4'h0, rom_q} + 12'd1) << 3;
                      boot_phase <= 2'd1;
                  end
                  2'd1: begin boot_b0 <= rom_q; boot_phase <= 2'd2; end
                  2'd2: begin boot_b1 <= rom_q; boot_phase <= 2'd3; end
                  2'd3: begin
                      boot_phase <= 2'd1;
                      if (boot_idx + 12'd1 >= boot_plen) begin
                          boot_active <= 1'b0;
                          state       <= S_FETCH;
                      end else
                          boot_idx <= boot_idx + 12'd1;
                  end
                endcase
            end
          end

          S_FETCH: begin
            o_valid <= 1'b0;
            state   <= S_DECODE;
          end

          S_DECODE, S_DRAIN, S_DIV, S_ROM, S_MEM: begin
            o_valid <= 1'b0;
            if (reboot_pending) begin
                clear_cpu_ctl();
                launch_boot(reboot_bank);
                reboot_pending <= 1'b0;
            end else if (host_rst_r) begin
                clear_cpu_ctl();
                ab_active <= 1'b0; dac_slot_ctr <= 16'h0; dac_slot_go <= 1'b0;
                data_bank <= 11'h0; launch_boot(11'h0);
                latch_control <= 16'h0C00;
                tim_scale <= 9'd1; tim_scale_cnt <= 9'd1;
            end else if (irq_take2 || irq_take1 || irq_takeT) begin
                state <= S_FETCH;
                dr_done <= 1'b0; dr_idx <= 17'd0; div_done <= 1'b0; div_i <= 5'd0;
                pc_stack[pc_sp[3:0]]     <= pc;   pc_sp   <= pc_sp + 5'd1;
                stat_stack[stat_sp[3:0]] <= {mstat, imask, astat};
                stat_sp <= stat_sp + 5'd1;
                if (irq_take2) begin
                    imask <= icntl[4] ? (imask & ~(16'h003F >> 0)) : (imask & ~16'h003F);
                    pc <= 14'h0004;
                    irq2_latch <= 1'b0;
                end else if (irq_take1) begin
                    imask <= icntl[4] ? (imask & ~(16'h003F >> 3)) : (imask & ~16'h003F);
                    pc <= 14'h0010;
                    irq1_pulse <= 1'b0;
                end else begin
                    imask <= icntl[4] ? (imask & ~(16'h003F >> 5)) : (imask & ~16'h003F);
                    pc <= 14'h0018;
                    tim_irq_latch <= 1'b0;
                end
                o_valid <= 1'b0;
            end else begin
              case (state)
                S_DECODE: begin
                    op_r       <= fq;
                    ea_addr_r  <= pre_addr;
                    pm_addr_r  <= pre_pm_addr;
                    pm_rd_r    <= pre_pm_rd;
                    bank_rd_r  <= pre_bank_rd;
                    tx1_r      <= pre_tx1_wr;
                    mem_need_r <= mem_need;
                    if      (drain_pend && !dr_done)  state <= S_DRAIN;
                    else if (pre_tx1_wr && !div_done) state <= S_DIV;
                    else if (pre_bank_rd && !rom_rdy) state <= S_ROM;
                    else if (mem_need)                state <= S_MEM;
                    else                              state <= S_EXEC;
                end

                S_DRAIN: begin
                    if (dr_idx > 17'd0 && dr_idx <= {1'b0, ab_drain_cnt}) begin
                        case (dr_region)
                          RG_ALIAS: dr_smp = pmb_q[23:8];
                          RG_BANK : dr_smp = 16'hFFFF;
                          RG_LATCH: dr_smp = input_data;
                          default : dr_smp = dm_q;
                        endcase
                        dac_sample <= dr_smp;
                        dac_ce     <= 1'b1;
                    end
                    if (dr_idx < {1'b0, ab_drain_cnt}) begin
                        dr_region <= dm_region(dr_cur[15:0]);
                        dr_acc    <= dr_cur + {16'h0, ab_incs};
                        dr_idx    <= dr_idx + 17'd1;
                    end else begin
                        dr_done   <= 1'b1;
                        state     <= (tx1_r && !div_done)    ? S_DIV
                                   : (bank_rd_r && !rom_rdy) ? S_ROM
                                   : mem_need_r              ? S_MEM
                                   :                           S_EXEC;
                    end
                end

                S_DIV: begin
                    if (div_i == 5'd0) begin
                        div_v   <= {pre_ab_incs, 1'b0};
                        div_nd  <= {2'b0, lR[ab_ir_w]};
                        div_rem <= 17'h0;
                        div_q   <= 16'h0;
                        div_i   <= 5'd1;
                    end else begin
                        div_t = {div_rem, div_nd[15]};
                        if (div_t >= {1'b0, div_v}) begin
                            div_rem <= div_t[16:0] - div_v;
                            div_q   <= {div_q[14:0], 1'b1};
                        end else begin
                            div_rem <= div_t[16:0];
                            div_q   <= {div_q[14:0], 1'b0};
                        end
                        div_nd <= {div_nd[14:0], 1'b0};
                        if (div_i == 5'd16) begin
                            div_done <= 1'b1;
                            state    <= (bank_rd_r && !rom_rdy) ? S_ROM
                                      : mem_need_r              ? S_MEM
                                      :                           S_EXEC;
                        end else
                            div_i    <= div_i + 5'd1;
                    end
                end

                S_ROM: begin
                    if (rom_rdy)
                        state <= mem_need_r ? S_MEM : S_EXEC;
                end

                S_MEM: state <= S_EXEC;

                default: ;
              endcase
            end
          end

          S_EXEC: begin
            state   <= S_FETCH;
            dr_done <= 1'b0; dr_idx <= 17'd0; div_done <= 1'b0; div_i <= 5'd0;
            o_ppc    <= pc;
            o_valid  <= 1'b1;
            o_unimpl <= !c_known;

            // timer: one prescale step per retired instruction
            if (mstat[5]) begin
                if (tim_scale_cnt <= 9'd1) begin
                    tim_scale_cnt <= tim_scale;
                    if (tim_count == 16'h0) begin
                        tim_count     <= tim_period;
                        tim_irq_latch <= 1'b1;
                    end else
                        tim_count <= tim_count - 16'h1;
                end else
                    tim_scale_cnt <= tim_scale_cnt - 9'd1;
            end

            if (irq1_pulse) irq1_pulse <= 1'b0;
            if (drain_commit) begin
                if (dr_wrap) irq1_pulse <= 1'b1;
                dac_slot_go <= 1'b0;
            end

            // ---- program counter and stacks: loop handling first, the
            //      instruction's own effect (later upstream) overrides it
            if (loop_back)      pc <= pc_top;
            else                pc <= pc + 14'd1;
            if (loop_exit) begin
                loop_sp <= loop_sp - 3'd1; pc_sp <= pc_sp - 5'd1;
            end
            if (ce_dec)      cntr <= cntr - 14'd1;
            else if (ce_pop) begin cntr <= cntr_top; cntr_sp <= cntr_sp - 3'd1; end

            // ---- status registers
            if (alu_do)                  astat <= alu_res[31:16];
            if (mac_do && !dst_alt)      astat <= mac_mv ? (astat | 16'h0040) : (astat & ~16'h0040);
            if (shift_do && shift_ss_we) astat[7] <= shift_ss_v;
            if (div_do)                  astat <= (astat & ~16'h0020) | (div_tbit ? 16'h0020 : 16'h0000);

            if (c_jind && cflag) begin
                if (op[4]) begin
                    pc_stack[pc_sp[3:0]] <= pc + 14'd1; pc_sp <= pc_sp + 5'd1;
                end
                pc <= jind_r;
            end

            if (c_rts && cflag) begin
                pc <= pc_top; pc_sp <= pc_sp - 5'd1;
                if (op[4]) begin
                    mstat   <= stat_top[47:32];
                    imask   <= stat_top[31:16];
                    astat   <= stat_top[15:0];
                    stat_sp <= stat_sp - 5'd1;
                end
            end

            if (c_mode) begin
                mstat_tmp = mstat;
                if (op[3])  mstat_tmp[6] = op[2];
                if (op[13]) mstat_tmp[4] = op[12];
                if (op[15]) mstat_tmp[5] = op[14];
                if (op[5])  mstat_tmp[0] = op[4];
                if (op[7])  mstat_tmp[1] = op[6];
                if (op[9])  mstat_tmp[2] = op[8];
                if (op[11]) mstat_tmp[3] = op[10];
                mstat <= mstat_tmp;
            end

            if (c_do) begin
                loop_end [loop_sp[1:0]] <= op[17:4];
                loop_cond[loop_sp[1:0]] <= op[3:0];
                loop_sp                 <= loop_sp + 3'd1;
                pc_stack[pc_sp[3:0]]    <= pc + 14'd1;
                pc_sp                   <= pc_sp + 5'd1;
            end

            if (c_jmp && cflag) begin
                if (op[18]) begin
                    pc_stack[pc_sp[3:0]] <= pc + 14'd1; pc_sp <= pc_sp + 5'd1;
                end
                pc <= op[17:4];
            end

            if (pm_rd_i) px <= {8'h0, pmb_q[7:0]};

            // ---- group-3 general writes
            if (gw_g3) begin
                case (gw_idx)
                  4'd0: astat <= gw_val;
                  4'd1: mstat <= gw_val;
                  4'd2: sstat <= gw_val;
                  4'd3: imask <= gw_val;
                  4'd4: icntl <= gw_val;
                  4'd5: begin
                      cntr_stack[cntr_sp[1:0]] <= cntr; cntr_sp <= cntr_sp + 3'd1;
                      cntr <= gw_val[13:0];
                  end
                  4'd7: px <= gw_val;
                  4'hD: cntr <= gw_val[13:0];
                  4'hF: begin
                      pc_stack[pc_sp[3:0]] <= gw_val[13:0]; pc_sp <= pc_sp + 5'd1;
                  end
                  4'hB: if (arm_do) begin
                      ab_size      <= {2'b0, lR[ab_ir_w]};
                      ab_incs      <= ab_m16;
                      ab_ireg      <= ab_ir_w;
                      ab_drain_cnt <= div_q;
                      dac_slot_ctr <= div_q;
                      dac_slot_go  <= 1'b0;
                      ab_active    <= 1'b1;
                  end
                  default: ;
                endcase
            end

            // ---- data-memory side effects
            if (dm_rd_i && ea_latch) begin
                irq2_line     <= 1'b0;
                latch_control <= latch_control | 16'h0800;
                dbg_cmd_read  <= 1'b1;
            end
            if (dm_wr_i) begin
                if (ea_rg == RG_ALIAS) begin
                    // PM alias: committed by the PM port-A decoder
                end else if (ea == 16'h3000)
                    data_bank <= dm_wdata[10:0];
                else if (ea_latch) begin
                    output_data   <= dm_wdata;
                    latch_control <= latch_control & ~16'h0400;
                end else begin
                    if (ea == 16'h3FEF) ctl_s1_autobuf <= dm_wdata;
                    if (ea == 16'h3FFB) begin
                        tim_scale     <= {1'b0, dm_wdata[7:0]} + 9'd1;
                        tim_scale_cnt <= {1'b0, dm_wdata[7:0]} + 9'd1;
                    end
                    if (ea == 16'h3FFC) begin
                        tim_count     <= dm_wdata;
                        tim_scale_cnt <= tim_scale;
                    end
                    if (ea == 16'h3FFD)
                        tim_period    <= dm_wdata;
                    if (ea == 16'h3FFF) begin
                        ctl_syscontrol <= dm_wdata;
                        if (dm_wdata[9]) begin
                            reboot_pending <= 1'b1; reboot_bank <= data_bank;
                        end
                    end
                end
            end
          end
          endcase

          // ---- per-enable peripherals, in upstream's order
          host_rst_r <= host_rst;
          if (dac_ce_in && ab_active) begin
              if (dac_slot_ctr <= 16'd1) begin
                  dac_slot_ctr <= ab_drain_cnt;
                  dac_slot_go  <= 1'b1;
              end else
                  dac_slot_ctr <= dac_slot_ctr - 16'd1;
          end
          if (host_cmd_w) begin
              if (!latch_control[11] && (dbg_cmd_lost != 8'hFF))
                  dbg_cmd_lost <= dbg_cmd_lost + 8'd1;
              input_data <= host_cmd_data;
              if (!irq2_line) irq2_latch <= 1'b1;
              irq2_line  <= 1'b1;
              latch_control <= latch_control & ~16'h0800;
          end
          if (host_resp_rd)
              latch_control <= latch_control | 16'h0400;
        end
    end
endmodule
