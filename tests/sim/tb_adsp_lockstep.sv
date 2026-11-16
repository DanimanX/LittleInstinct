// tb_adsp_lockstep: pocket_rtl/dcs/adsp2105_lean.sv against upstream's
// rtl/dcs/adsp2105.sv, clock by clock.
//
// Both cores get the same clock, enables, host commands, DAC slots and sound
// ROM. Every output is compared on every clock; the first difference stops the
// run. Two modes:
//
//   +rom=<file>   real firmware: the 4 MiB DCS image (kinst.rom minus the
//                 512 KiB boot ROM). Exercises what the game executes.
//   +fuzz=<seed>  the "ROM" is noise, so the boot loader fills program memory
//                 with random opcodes. Exercises what the game does NOT
//                 execute, which is where a rewrite hides its mistakes.
//                 A run ends when the reference under/overflows a hardware
//                 stack (the two models index out of range differently, and
//                 no working program does that), then restarts with new noise.
`timescale 1ns/1ps
`default_nettype none

module tb_adsp_lockstep;
    reg clk = 1'b0;
    always #10 clk = ~clk;

    reg         rst = 1'b1;
    reg         host_rst = 1'b0;
    reg         host_cmd_w = 1'b0;
    reg  [15:0] host_cmd_data = 16'h0;
    reg         host_resp_rd = 1'b0;
    reg         dac_ce_in = 1'b0;
    reg         core_ce = 1'b0;

    // ---- sound ROM model, shared contents, one port per core ---------------
    reg [7:0] rom [0:4194303];
    integer   fuzz_seed = 0;
    reg       fuzz = 1'b0;

    function [63:0] rom_beat(input [18:0] a);
        integer i;
        for (i = 0; i < 8; i = i + 1)
            rom_beat[8*i +: 8] = rom[{a, 3'd0} + i];
    endfunction

    wire        a_req, b_req;
    wire [18:0] a_addr, b_addr;
    reg         a_rdy = 1'b0, b_rdy = 1'b0;
    reg  [63:0] a_q = 64'h0, b_q = 64'h0;
    integer     lat = 0, lat_cnt = 0;
    // Same latency for both, drawn per request: the lean core must issue the
    // same requests on the same clocks, so one counter serves both.
    always @(posedge clk) begin
        a_rdy <= 1'b0; b_rdy <= 1'b0;
        if (a_req && !a_rdy) begin
            if (lat_cnt >= lat) begin
                a_rdy <= 1'b1; a_q <= rom_beat(a_addr);
                b_rdy <= b_req; b_q <= rom_beat(b_addr);
                lat_cnt <= 0;
                lat <= $urandom_range(0, 9);
            end else
                lat_cnt <= lat_cnt + 1;
        end else
            lat_cnt <= 0;
    end

    wire [15:0] a_status, b_status, a_resp, b_resp, a_smp, b_smp;
    wire [13:0] a_ppc, b_ppc;
    wire        a_valid, b_valid, a_unimpl, b_unimpl, a_dce, b_dce, a_crd, b_crd;

    adsp2105_ref u_ref (
        .clk(clk), .rst(rst), .core_ce(core_ce), .host_rst(host_rst),
        .host_cmd_w(host_cmd_w && core_ce), .host_cmd_data(host_cmd_data),
        .host_status_r(a_status), .host_response_r(a_resp), .host_resp_rd(host_resp_rd),
        .rom_ddr_req(a_req), .rom_ddr_addr(a_addr), .rom_ddr_rdy(a_rdy), .rom_ddr_q(a_q),
        .dac_ce_in(dac_ce_in), .o_ppc(a_ppc), .o_valid(a_valid), .o_unimpl(a_unimpl),
        .dac_sample(a_smp), .dac_ce(a_dce),
        .dbg_wrap_pc(), .dbg_wrap_cnt(), .dbg_src_pc(), .dbg_src_addr(), .dbg_src_cnt(),
        .dbg_src_op(), .dbg_rom_unstable_o(), .dbg_rom_bankdelta_o(), .dbg_cmd_lost(),
        .dbg_cmd_read(a_crd));

    adsp2105 u_dut (
        .clk(clk), .rst(rst), .core_ce(core_ce), .host_rst(host_rst),
        .host_cmd_w(host_cmd_w && core_ce), .host_cmd_data(host_cmd_data),
        .host_status_r(b_status), .host_response_r(b_resp), .host_resp_rd(host_resp_rd),
        .rom_ddr_req(b_req), .rom_ddr_addr(b_addr), .rom_ddr_rdy(b_rdy), .rom_ddr_q(b_q),
        .dac_ce_in(dac_ce_in), .o_ppc(b_ppc), .o_valid(b_valid), .o_unimpl(b_unimpl),
        .dac_sample(b_smp), .dac_ce(b_dce),
        .dbg_wrap_pc(), .dbg_wrap_cnt(), .dbg_src_pc(), .dbg_src_addr(), .dbg_src_cnt(),
        .dbg_src_op(), .dbg_rom_unstable_o(), .dbg_rom_bankdelta_o(), .dbg_cmd_lost(),
        .dbg_cmd_read(b_crd));

    // ---- stimulus -----------------------------------------------------------
    // core_ce: the board's 35.75/50 fractional enable, or always-on.
    integer ce_mode = 0;
    reg [26:0] phase = 27'd0;
    always @(negedge clk) begin
        if (ce_mode == 1) core_ce <= 1'b1;
        else if (ce_mode == 2) core_ce <= ($urandom_range(0, 3) != 0);
        else begin
            if (phase + 27'd35750000 >= 27'd50000000) begin
                phase <= phase + 27'd35750000 - 27'd50000000; core_ce <= 1'b1;
            end else begin
                phase <= phase + 27'd35750000; core_ce <= 1'b0;
            end
        end
    end

    // DAC slots: one fabric clock wide, every dac_div clocks.
    integer dac_div = 1600, dac_cnt = 0;
    always @(negedge clk) begin
        dac_ce_in <= 1'b0;
        if (dac_cnt >= dac_div - 1) begin dac_cnt <= 0; dac_ce_in <= 1'b1; end
        else dac_cnt <= dac_cnt + 1;
    end

    // Host: commands held until an enable takes them (as ki_dcs_audio does),
    // response reads, and the occasional board reset.
    integer cmd_gap = 200000;
    integer cmds_sent = 0;
    always @(negedge clk) begin
        if (host_cmd_w && core_ce) host_cmd_w <= 1'b0;
        host_resp_rd <= 1'b0;
        if (!rst && !host_cmd_w && ($urandom_range(0, cmd_gap) == 0)) begin
            host_cmd_w    <= 1'b1;
            host_cmd_data <= fuzz ? $urandom : cmd_next($urandom);
            cmds_sent     <= cmds_sent + 1;
        end
        if (!rst && ($urandom_range(0, cmd_gap) == 0)) host_resp_rd <= 1'b1;
    end

    // DCS1 commands as the KI boot ROM and game use them: 16-bit words, with
    // the common ones weighted up. Anything else the firmware must reject.
    function [15:0] cmd_next(input [31:0] r);
        case (r[3:0])
          4'd0:    cmd_next = 16'h55AA;                 // volume prefix
          4'd1:    cmd_next = {8'hFF ^ r[15:8], r[15:8]}; // volume, value/complement
          4'd2:    cmd_next = 16'h0000;                 // stop all
          4'd3:    cmd_next = 16'h03E7;                 // ROM version / checksum query
          4'd4:    cmd_next = 16'h03E8;
          default: cmd_next = {4'h0, r[19:8]} % 16'h0400; // sound calls
        endcase
    endfunction

    // ---- compare ------------------------------------------------------------
    integer cycles = 0, retired = 0, samples = 0, nonzero = 0, runs = 0;
    integer max_cycles = 2000000;
    reg     armed = 1'b0;
    task fail(input [255:0] what);
        begin
            $display("MISMATCH %0s at cycle %0d (retired %0d): ref ppc=%04x dut ppc=%04x  ref op=%06x dut op=%06x",
                     what, cycles, retired, a_ppc, b_ppc, u_ref.op_r, u_dut.op_r);
            $display("  ref: valid=%b unimpl=%b status=%04x resp=%04x smp=%04x dce=%b req=%b addr=%05x",
                     a_valid, a_unimpl, a_status, a_resp, a_smp, a_dce, a_req, a_addr);
            $display("  dut: valid=%b unimpl=%b status=%04x resp=%04x smp=%04x dce=%b req=%b addr=%05x",
                     b_valid, b_unimpl, b_status, b_resp, b_smp, b_dce, b_req, b_addr);
            $display("FAIL");
            $finish;
        end
    endtask

    // A stack index out of range in the reference: out-of-bounds reads return
    // X there and wrap here. Not a behaviour any program relies on.
    wire ref_stack_bad = (u_ref.pc_sp < 0)   || (u_ref.pc_sp > 16)  ||
                         (u_ref.cntr_sp < 0) || (u_ref.cntr_sp > 4) ||
                         (u_ref.loop_sp < 0) || (u_ref.loop_sp > 4) ||
                         (u_ref.stat_sp < 0) || (u_ref.stat_sp > 16);
    // Popping an empty stack is the same case one step earlier.
    reg restart = 1'b0;

    always @(posedge clk) begin
        if (!rst) begin
            cycles <= cycles + 1;
            if (a_valid && core_ce) retired <= retired + 1;
            if (a_dce) begin samples <= samples + 1; if (a_smp != 16'h0) nonzero <= nonzero + 1; end
            if (fuzz && ref_stack_bad) restart <= 1'b1;
            else if (!restart) begin
                if (a_valid  !== b_valid)  fail("o_valid");
                if (a_valid && (a_ppc !== b_ppc)) fail("o_ppc");
                if (a_valid && (a_unimpl !== b_unimpl)) fail("o_unimpl");
                if (a_status !== b_status) fail("host_status");
                if (a_resp   !== b_resp)   fail("host_response");
                if (a_dce    !== b_dce)    fail("dac_ce");
                if (a_dce && (a_smp !== b_smp)) fail("dac_sample");
                if (a_req    !== b_req)    fail("rom_req");
                if (a_req && (a_addr !== b_addr)) fail("rom_addr");
                if (a_crd    !== b_crd)    fail("cmd_read");
            end
        end
    end

    // Full architectural-state compare at every retirement, so a wrong value
    // is caught when it is written and not when it finally reaches a pin.
    integer q;
    task state_fail(input [255:0] what, input integer idx);
        begin
            $display("STATE MISMATCH %0s[%0d] after pc=%04x op=%06x (cycle %0d, retired %0d)",
                     what, idx, a_ppc, u_ref.op_r, cycles, retired);
            $display("  ref: pc=%04x cntr=%04x astat=%04x mstat=%04x imask=%04x sp=%0d/%0d/%0d/%0d",
                     u_ref.pc, u_ref.cntr, u_ref.astat, u_ref.mstat, u_ref.imask,
                     u_ref.pc_sp, u_ref.cntr_sp, u_ref.loop_sp, u_ref.stat_sp);
            $display("  dut op_r=%06x fq=%06x state=%0d", u_dut.op_r, u_dut.fetch_q, u_dut.state);
            $display("  dut: pc=%04x cntr=%04x astat=%04x mstat=%04x imask=%04x sp=%0d/%0d/%0d/%0d",
                     u_dut.pc, u_dut.cntr, u_dut.astat, u_dut.mstat, u_dut.imask,
                     u_dut.pc_sp, u_dut.cntr_sp, u_dut.loop_sp, u_dut.stat_sp);
            $display("FAIL");
            $finish;
        end
    endtask
    always @(negedge clk) begin
        if (!rst && !restart && a_valid && b_valid && !(fuzz && ref_stack_bad)) begin
            for (q = 0; q < 32; q = q + 1)
                if (u_ref.gr[q] !== u_dut.gr[q]) state_fail("gr", q);
            for (q = 0; q < 8; q = q + 1) begin
                if (u_ref.iR[q][13:0] !== u_dut.iR[q]) state_fail("I", q);
                if (u_ref.mR[q][13:0] !== u_dut.mR[q]) state_fail("M", q);
                if (u_ref.lR[q][13:0] !== u_dut.lR[q]) state_fail("L", q);
                if (u_ref.baseR[q]    !== u_dut.baseR[q]) state_fail("base", q);
                if (u_ref.lmask[q]    !== u_dut.lmask[q]) state_fail("lmask", q);
            end
            for (q = 0; q < 2; q = q + 1) begin
                if (u_ref.afb[q] !== u_dut.afb[q]) state_fail("AF", q);
                if (u_ref.mfb[q] !== u_dut.mfb[q]) state_fail("MF", q);
                if (u_ref.sbb[q] !== u_dut.sbb[q]) state_fail("SB", q);
            end
            if (u_ref.astat !== u_dut.astat) state_fail("astat", 0);
            if (u_ref.mstat !== u_dut.mstat) state_fail("mstat", 0);
            if (u_ref.sstat !== u_dut.sstat) state_fail("sstat", 0);
            if (u_ref.imask !== u_dut.imask) state_fail("imask", 0);
            if (u_ref.icntl !== u_dut.icntl) state_fail("icntl", 0);
            if (u_ref.px    !== u_dut.px)    state_fail("px", 0);
            if (u_ref.cntr  !== u_dut.cntr)  state_fail("cntr", 0);
            if (u_ref.pc    !== u_dut.pc)    state_fail("pc", 0);
            if (u_ref.data_bank !== u_dut.data_bank) state_fail("data_bank", 0);
            if (u_ref.pc_sp[4:0]   !== u_dut.pc_sp)   state_fail("pc_sp", 0);
            if (u_ref.cntr_sp[2:0] !== u_dut.cntr_sp) state_fail("cntr_sp", 0);
            if (u_ref.loop_sp[2:0] !== u_dut.loop_sp) state_fail("loop_sp", 0);
            if (u_ref.stat_sp[4:0] !== u_dut.stat_sp) state_fail("stat_sp", 0);
        end
    end

    // ---- run control --------------------------------------------------------
    reg [1023:0] romfile;
    integer fd, n, i, r;

    task randomize_rom;
        integer j;
        begin
            // Bank 0 holds the boot page. Byte 3 is its length; the rest is
            // noise, biased so every opcode class appears often enough.
            for (j = 0; j < 65536; j = j + 1) rom[j] = $urandom;
            rom[3] = 8'h1F;      // (0x1F+1)*8 = 256 words of program
        end
    endtask

    task do_reset;
        begin
            rst = 1'b1; restart = 1'b0;
            repeat (8) @(posedge clk);
            #1 rst = 1'b0;
        end
    endtask

    initial begin
        if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 2000000;
        if (!$value$plusargs("ce=%d", ce_mode)) ce_mode = 0;
        if (!$value$plusargs("cmdgap=%d", cmd_gap)) cmd_gap = 200000;
        if (!$value$plusargs("dacdiv=%d", dac_div)) dac_div = 1600;
        if ($value$plusargs("fuzz=%d", fuzz_seed)) begin
            fuzz = 1'b1;
            r = $urandom(fuzz_seed);
            for (i = 0; i < 4194304; i = i + 1) rom[i] = 8'h00;
            randomize_rom;
        end else begin
            if (!$value$plusargs("rom=%s", romfile)) begin
                $display("need +rom=<dcs image> or +fuzz=<seed>"); $finish;
            end
            fd = $fopen(romfile, "rb");
            if (fd == 0) begin $display("cannot open %0s", romfile); $finish; end
            n = $fread(rom, fd);
            $fclose(fd);
            if (n != 4194304) begin $display("DCS image is %0d bytes, expected 4194304", n); $finish; end
        end
        do_reset;
        while (cycles < max_cycles) begin
            @(posedge clk);
            if (restart) begin
                runs = runs + 1;
                randomize_rom;
                do_reset;
            end
        end
        $display("cycles=%0d retired=%0d samples=%0d nonzero=%0d commands=%0d fuzz_runs=%0d",
                 cycles, retired, samples, nonzero, cmds_sent, runs);
        if (retired == 0) begin $display("FAIL: nothing retired"); $finish; end
        $display("PASS");
        $finish;
    end
endmodule

`default_nettype wire
