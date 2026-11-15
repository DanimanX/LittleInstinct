// SPDX-License-Identifier: GPL-3.0-only
// ADSP sound board bench: real DCS ROM in, PCM samples out?
//
// Instantiates the real ki_dcs_audio wrapper with the real adsp2105 core and
// the real dcs_mem ROM service, fed by the kinst DCS image. Nothing here
// rewrites the RTL: the only stimulus is a clock, reset, and (optionally) one
// host command word, the way the MIPS side writes the board.
//
// Build with -DKI_DCS_SIMULATION so the behavioral memories and the core's
// internal checks are compiled in.
//
// Evidence reported at the end:
//   - instructions retired, last PC, addresses the program reached
//   - first unimplemented opcode (class + PC), and the same for every class
//   - boot page streamed OK? (the core releases the CPU only after it)
//   - PCM: samples produced by the DSP, samples pushed into the DAC FIFO,
//     samples popped to the output, audio discontinuities
`default_nettype none
module tb_adsp;
    localparam integer CLK_HZ     = 50000000;
    localparam realtime CLK_NS    = 20.0;      // 50 MHz, the Pocket core clock
    localparam realtime RUN_NS    = 4000000.0; // 4 ms of board time
    localparam integer TRACE      = 8;
    // Host command word written in phase 2. 0x0000 is a placeholder: it exercises
    // the mailbox and IRQ2 path but is not a real DCS command.
    localparam [15:0]  CMD        = 16'h0000;
    // The mailbox word for a run: +CMD=hhhh. Real DCS commands are not
    // documented in this tree; this exists so a known word can be replayed.
    integer cmd_plus = 0;
    // Variant 2's command: a non-zero word so the mailbox really differs from
    // the reset state (INPUT_FULL), but not a real DCS command yet.
    localparam [15:0]  CMD4       = 16'h0001;

    reg clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    reg rst = 1'b1;
    reg host_reset = 1'b1;
    reg pause      = 1'b0;
    reg host_cmd_wr = 1'b0;
    // Watch for the first command the DSP's latch accepts.
    integer latch_seen = 0;
    always @(posedge clk) begin
        if (u_dcs.u_adsp.input_data !== 16'h0000 && latch_seen == 0) begin
            latch_seen <= 1;
            $display("[adsp] DSP input latch accepted %04h at t=%0t",
                     u_dcs.u_adsp.input_data, $time);
        end
    end
    reg [15:0] host_cmd_data = 16'h0000;

    wire [15:0] host_status;
    wire rom_req;
    wire [18:0] rom_addr;
    wire rom_rdy;
    wire [63:0] rom_q;
    wire signed [15:0] audio;
    wire dbg_valid;
    wire dbg_unimpl;
    wire dbg_pcm_push;
    wire [13:0] dbg_pc;
    wire [31:0] dbg_pcm_health;
    wire [31:0] dbg_pcm_level;

    adsp_rom_model u_rom (
        .clk(clk), .rst(rst),
        .ext_req(rom_req), .ext_addr(rom_addr),
        .ext_rdy(rom_rdy), .ext_q(rom_q)
    );

    ki_dcs_audio u_dcs (
        .clk(clk), .rst(rst), .pause(pause), .host_reset(host_reset),
        .host_cmd_wr(host_cmd_wr), .host_cmd_data(host_cmd_data),
        .host_status(host_status),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_rdy(rom_rdy), .rom_q(rom_q),
        .audio(audio),
        .dbg_valid(dbg_valid), .dbg_unimpl(dbg_unimpl), .dbg_pcm_push(dbg_pcm_push),
        .dbg_pc(dbg_pc),
        .dbg_pcm_health(dbg_pcm_health), .dbg_pcm_level(dbg_pcm_level)
    );


    // ---- variant / mailbox controls -----------------------------------------
    integer variant  = 1;

    // ---- instrumentation ----------------------------------------------------
    longint retired;          // dbg_valid pulses (one per executed instruction)
    longint pushed;           // DAC samples the DSP emitted
    longint nonzero;          // ... of them non-zero
    longint audio_changes;    // output samples that differ from the previous one
    logic [15:0] last_audio_l;
    logic [15:0] prev_push;

    // Per class accounting of the first time we see it, so a single text
    // report answers "which opcode stopped it".
    reg seen_unimpl;
    logic [13:0] unimpl_pc;
    logic [15:0] unimpl_pc_hist [0:7];
    integer      unimpl_n;

    // Address coverage in 1 KiB pages, 14-bit PC space.
    reg [15:0] page_hits [0:15];
    logic [13:0] last_pc;
    integer i;

    initial begin
        retired = 0; pushed = 0; nonzero = 0; audio_changes = 0;
        last_audio_l = 16'h0000; prev_push = 16'h0000;
        seen_unimpl = 1'b0; unimpl_pc = 14'h0; unimpl_n = 0;
        for (i = 0; i < 16; i = i + 1) page_hits[i] = 16'd0;
        for (i = 0; i < 8; i = i + 1) unimpl_pc_hist[i] = 16'h0;
        last_pc = 14'h0;
    end

    integer pushed_traced = 0;

    always @(posedge clk) begin
        if (!rst) begin
            if (dbg_valid) begin
                retired <= retired + 1;
                last_pc <= dbg_pc;
                if (page_hits[dbg_pc[13:10]] != 16'hFFFF)
                    page_hits[dbg_pc[13:10]] <= page_hits[dbg_pc[13:10]] + 1'b1;
            end
            if (dbg_pcm_push) begin
                pushed <= pushed + 1;
                if (u_dcs.dcs_sample != 16'h0000)
                    nonzero <= nonzero + 1;
                if (pushed_traced < TRACE) begin
                    $display("[pcm] t=%0t push #%0d sample=%0d (0x%04x) pc=%0h nz=%0d",
                             $time, pushed, $signed(u_dcs.dcs_sample),
                             u_dcs.dcs_sample, dbg_pc,
                             u_dcs.dcs_sample != 16'h0000);
                    pushed_traced <= pushed_traced + 1;
                end
                prev_push <= u_dcs.dcs_sample;
            end
                    if (audio !== last_audio_l) begin
                audio_changes <= audio_changes + 1;
                last_audio_l <= audio;
            end
            if (dbg_unimpl && !seen_unimpl) begin
                seen_unimpl <= 1'b1;
                unimpl_pc   <= dbg_pc;
                $display("[adsp] FIRST UNIMPLEMENTED at t=%0t pc=%0h op=%0h -- the model has no path for this class",
                         $time, dbg_pc, u_dcs.u_adsp.op_r);
            end
        end
    end

    // ---- PC trace -----------------------------------------------------------
    // Bounded, and only armed by `run_for` from a point the bench chooses, so a
    // fresh instruction the program reaches is always visible below.
    longint trace_left = 0;
    reg     trace_arm = 1'b0;
    integer trace_at  = 0;
    always @(posedge clk) begin
        if (!rst && trace_arm && trace_left < 64) begin
            if (retired >= trace_at) begin
                $display("[trace] pc=%0h op=%0h astat=%04h mstat=%04h i0=%04h i7=%04h st=%04h",
                         dbg_pc, u_dcs.u_adsp.op_r,
                         u_dcs.u_adsp.astat, u_dcs.u_adsp.mstat,
                         u_dcs.u_adsp.iR[0], u_dcs.u_adsp.iR[7], host_status);
                trace_left <= trace_left + 1;
            end
        end
    end

    // ---- halt detection -----------------------------------------------------
    // Retired instructions that did not change pc, counted down from the last
    // pc change. A DSP that stops at one address is not executing its program.
    reg  [13:0] halt_pc    = 14'h3FFF;
    longint     halt_since = 0;
    // Instructions retired while the DSP sat at ONE address (a wait loop with
    // no other retired instructions in it looks identical to a halt here).
    longint     spins_since = 0;
    longint     spins = 0;
    longint     halt_retired = 0;
    always @(posedge clk) begin
        if (!rst && dbg_valid) begin
            if (dbg_valid_q || dbg_valid) begin
                // Previous retire was at the same address: a local spin.
                spins <= spins + 1;
            end
            if (dbg_pc != halt_pc) begin
                halt_pc      <= dbg_pc;
                halt_since   <= retired;
                spins_since  <= spins;
            end else begin
                halt_retired <= retired - halt_since;
            end
        end
        dbg_valid_q <= !rst && dbg_valid;
    end
    reg dbg_valid_q = 1'b0;

    // Timeline of pc changes (boot -> the address it settled on), so the route
    // through the program is visible without a wave dump.
    integer tl_n = 0;
    always @(posedge clk) begin
        if (!rst && dbg_valid && (dbg_pc != halt_pc) && (tl_n < 64)) begin
            $display("[tl] retired=%0d pc=%0h op=%0h sstat=%04h mstat=%04h ar=%04h mr0=%04h mr1=%04h dm0850=%04h",
                     retired, dbg_pc, u_dcs.u_adsp.op_r,
                     u_dcs.u_adsp.sstat, u_dcs.u_adsp.mstat,
                     u_dcs.u_adsp.gr[{u_dcs.u_adsp.bnk, 4'b0000} + 10],
                     u_dcs.u_adsp.gr[{u_dcs.u_adsp.bnk, 4'b0000} + 11],
                     u_dcs.u_adsp.gr[12],
                     u_dcs.u_adsp.dm[16'h0850]);
            tl_n <= tl_n + 1;
        end
    end

    // Mailbox: what the DSP's input latch holds and whether the board has seen
    // a write. Printed once, at the end.
    // DM traffic: every store the screen would show as a memory change. The
    // program's own stores are invisible from outside otherwise, and a boot
    // that stores nothing has no route to the mailbox or the autobuffer.
    // Sampled by watching the DM array words the boot page touches.
    longint dm_stores;
    integer dm_stores_logged = 0;
    initial begin
        dm_stores = 0;
    end

    // Where the DSP spends its time: pc histogram, printed at the end.
    longint pc_hits [0:16383];
    initial for (i = 0; i < 16384; i = i + 1) pc_hits[i] = 0;
    always @(posedge clk) begin
        if (!rst && dbg_valid) begin
            pc_hits[dbg_pc] <= pc_hits[dbg_pc] + 1;
        end
    end

    // ---- run/drive tasks ----------------------------------------------------
    // Run board time, printing the first 64 instructions retired after
    // `trace_from` instructions.
    task automatic run_for(input realtime ns, input integer trace_from = -1);
        begin
            if (trace_from >= 0) begin
                trace_at   = trace_from;
                trace_arm  = 1'b1;
            end
            #(ns);
            trace_arm = 1'b0;
        end
    endtask

    // Write one host command word into the mailbox.
    reg [15:0] status_was;

    task automatic send_cmd(input [15:0] cmd);
        begin
            // Drive the strobe with non-blocking assignments so the write and
            // the model's latch see the same edge instead of a race.
            status_was <= host_status;
            host_cmd_data <= cmd;
            host_cmd_wr   <= 1'b1;
            @(posedge clk);
            host_cmd_wr   <= 1'b0;
            $display("[adsp] host command %04h written at t=%0t (host_status was %04h, is %04h; latch now %04h)",
                     cmd, $time, status_was, host_status, u_dcs.u_adsp.input_data);
        end
    endtask

    // Full board reset, as the MIPS side asserts it.
    task automatic board_reset();
        begin
            rst        = 1'b1;
            host_reset = 1'b1;
            repeat (10) @(posedge clk);
            rst = 1'b0;
            repeat (10) @(posedge clk);
            host_reset = 1'b0;
        end
    endtask

    task automatic report();
        integer k;
        begin
            $display("");
            $display("== RESULT");
            $display("instructions retired  %0d", retired);
            $display("last pc               %0h, unchanged for %0d retired instructions",
                     last_pc, halt_retired);
            $display("instructions retired at a repeated address (spin) %0d of %0d, last run %0d",
                     spins, retired, retired - spins_since);
            $display("pc pages seen (1 KiB)");
            for (k = 0; k < 16; k = k + 1)
                if (page_hits[k] != 0)
                    $display("  %0h000-%0h3ff  %0d", k, k, page_hits[k]);
            if (seen_unimpl) begin
                $display("FIRST UNIMPLEMENTED   pc=%0h", unimpl_pc);
            end else begin
                $display("unimplemented opcode  none");
            end
            $display("host_status           %04h (INPUT_EMPTY=%b OUTPUT_EMPTY=%b)",
                     host_status, host_status[11], host_status[10]);
            $display("DSP input latch       %04h (host command word)", u_dcs.u_adsp.input_data);
            $display("DCS status at bench   %04h", u_dcs.dcs_status);
            $display("dsp pcm pushes        %0d (non-zero %0d)", pushed, nonzero);
            $display("audio transitions     %0d (last %0d)", audio_changes, $signed(audio));
            $display("pcm_health            %08h first_audio_t=%0d (x1024 DAC slots = %0d us)",
                     dbg_pcm_health, dbg_pcm_health[19:8],
                     dbg_pcm_health[19:8] * 32768 / 1000);
            $display("dsp audio discontinuities %0d", u_dcs.au_discont);
            $display("source discontinuities    %0d (src pc=%0h op=%02h)",
                     u_dcs.au_src_discont, u_dcs.dcs_src_pc, u_dcs.dcs_src_op);
            $display("autobuffer wraps          %0d (pc=%0h)",
                     u_dcs.dcs_wrap_cnt, u_dcs.dcs_wrap_pc);
            $display("cmd lost / cmd read       %0d / %0d",
                     u_dcs.dcs_cmd_lost, u_dcs.dcs_cmd_read);
            $display("rom fetch unstable        %0d (bankdelta %0h)",
                     u_dcs.dcs_rom_unstable, u_dcs.dcs_rom_bankdelta);
            $display("rom requests          %0d (see [rom] lines)", u_rom.requests);
            $display("hottest pcs (top 10):");
            for (k = 0; k < 10; k = k + 1) begin
                longint best = -1;
                integer best_pc = -1;
                for (i = 0; i < 16384; i = i + 1) begin
                    if (pc_hits[i] > best) begin
                        best    = pc_hits[i];
                        best_pc = i;
                    end
                end
                if ((best_pc >= 0) && (best > 0)) begin
                    $display("  pc %04h  %0d", best_pc, best);
                    pc_hits[best_pc] = -1;
                end
            end
            $display("== END");
        end
    endtask

    // ---- run sequence -------------------------------------------------------
    // Variants (vvp +VARIANT=n, +CMD=hhhh):
    //   1  boot with an empty mailbox, then one command at half time (default)
    //   2  board reset, then one command immediately
    //   3  one command immediately, then a second word at half time
    initial begin
        if (!$value$plusargs("VARIANT=%d", variant))
            variant = 1;
        if ($value$plusargs("CMD=%h", cmd_plus))
            $display("[adsp] mailbox word from +CMD=%04h", cmd_plus[15:0]);

        $display("== tb_adsp: CLK_HZ=%0d, run=%0.1f ms, VARIANT=%0d",
                 CLK_HZ, RUN_NS / 1.0e6, variant);
        repeat (20) @(posedge clk);
        rst = 1'b0;
        // The MIPS side releases the sound board reset once the core is out.
        repeat (10) @(posedge clk);
        host_reset = 1'b0;
        $display("[adsp] reset released at t=%0t, host_status=%04h", $time, host_status);

        case (variant)
          2: begin
              send_cmd(cmd_plus[15:0]);
              run_for(RUN_NS);
          end
          3: begin
              send_cmd(cmd_plus[15:0]);
              run_for(RUN_NS / 2);
              send_cmd(16'h0000);
              run_for(RUN_NS / 2, retired);
          end
          default: begin
              run_for(RUN_NS / 2);
              $display("[adsp] t=%0t retired=%0d last_pc=%0h pushes=%0d",
                       $time, retired, last_pc, pushed);
              send_cmd(cmd_plus[15:0]);
              run_for(RUN_NS / 2, retired);
          end
        endcase
        report();
        $finish;
    end

    initial begin
        #(RUN_NS * 4);
        $display("[adsp] watchdog: bench exceeded 4x its run time");
        report();
        $finish;
    end
endmodule
`default_nettype wire
