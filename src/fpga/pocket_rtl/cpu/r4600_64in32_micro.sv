// SPDX-License-Identifier: GPL-3.0-only
//
// r4600_64in32_micro: Conceptual & Synthesizable SystemVerilog Micro-Sequencer
// for executing Killer Instinct's 64-bit MIPS-III memory operations (LD, SD,
// LDL, LDR, SDL, SDR, DADDU/DSLL32) over a 32-bit physical ALU & Register File.
//
// Architectural context (LittleInstinct / Analogue Pocket Cyclone V):
//   - Killer Instinct runs in 32-bit KSEG0/KSEG1 addressing (Status.KX/SX/UX=0)
//     and uses 32-bit pointers, but relies on 64-bit GPR pairs and 64-bit
//     loads/stores (`LD`/`SD`) in its software sprite blitter and fast memory
//     clear routines, plus `DSLL32`/`DSRA32`/`DADDU` to pack/unpack two 32-bit
//     halves inside a 64-bit GPR.
//   - Instead of a full 64-bit combinational datapath (64-bit barrel shifters,
//     64x64 multiplier, 64-bit bypass network), the datapath is narrowed to
//     32 bits. Each architectural GPR is stored in a 64x32-bit M10K block RAM
//     (`{hi_bank=1'b1, reg_idx[4:0]}` and `{lo_bank=1'b0, reg_idx[4:0]}`).
//   - Standard MIPS-I/II 32-bit instructions execute in 1 cycle (writing bit 31
//     sign-extension to the high bank via a second write port or lazy tag).
//   - 64-bit instructions asserted by the decoder trigger a 2-cycle micro-op
//     sequence (`uop_phase`: 0 = LOW 32-bit half, 1 = HIGH 32-bit half) that
//     stalls the fetch/decode pipeline for 1 cycle (`uop_stall_o = 1'b1`) and
//     assembles/disassembles the 64-bit cache/bridge bus transaction.
//   - Unsupported 64-bit arithmetic (e.g. `DDIV`, `DDIVU`, `DMULT`) asserts
//     `trap_ri_o` (Reserved Instruction / software trap fallback).

`default_nettype none

module r4600_64in32_micro (
    input  wire        clk,
    input  wire        rst,

    // ---- Instruction Decode Input (Stage 2) --------------------------------
    input  wire        instr_valid_i,
    input  wire [31:0] instr_i,
    input  wire        bus_ready_i,

    // ---- 32-bit Register File Read Interface (Bank 0 = Lo, Bank 1 = Hi) ----
    output logic [5:0] rf_raddr_a_o,   // {bank_hi, rs[4:0]}
    output logic [5:0] rf_raddr_b_o,   // {bank_hi, rt[4:0]}
    input  wire [31:0] rf_rdata_a_i,
    input  wire [31:0] rf_rdata_b_i,

    // ---- 32-bit Register File Write Interface ------------------------------
    output logic       rf_we_lo_o,
    output logic       rf_we_hi_o,
    output logic [4:0] rf_waddr_o,
    output logic [31:0] rf_wdata_lo_o,
    output logic [31:0] rf_wdata_hi_o,

    // ---- 32-bit ALU & Pipeline Control Outputs -----------------------------
    output logic       uop_stall_o,    // Holds PC and Fetch/Decode for Cycle 2
    output logic       trap_ri_o,      // Fallback trap on unimplemented 64b op
    output logic [31:0] alu_res_lo_o,

    // ---- 64-bit Memory Bridge Interface (ki_memory_bridge compatible) ------
    output logic       mem_req_o,
    output logic       mem_rnw_o,
    output logic       mem_req64_o,
    output logic [31:0] mem_addr_o,
    output logic [7:0] mem_wmask_o,
    output logic [63:0] mem_wdata_o,
    input  wire [63:0] mem_rdata_i,
    input  wire        mem_done_i
);

    // MIPS Opcode & Funct fields
    wire [5:0] opcode = instr_i[31:26];
    wire [4:0] rs     = instr_i[25:21];
    wire [4:0] rt     = instr_i[20:16];
    wire [4:0] rd     = instr_i[15:11];
    wire [4:0] shamt  = instr_i[10:6];
    wire [5:0] funct  = instr_i[5:0];
    wire [31:0] imm_sext = {{16{instr_i[15]}}, instr_i[15:0]};

    // Primary Opcodes
    localparam [5:0] OP_SPECIAL = 6'h00;
    localparam [5:0] OP_DADDI   = 6'h18;
    localparam [5:0] OP_DADDIU  = 6'h19;
    localparam [5:0] OP_LDL     = 6'h1A;
    localparam [5:0] OP_LDR     = 6'h1B;
    localparam [5:0] OP_SDL     = 6'h2C;
    localparam [5:0] OP_SDR     = 6'h2D;
    localparam [5:0] OP_LD      = 6'h37;
    localparam [5:0] OP_SD      = 6'h3F;

    // SPECIAL Funct Opcodes (64-bit subset)
    localparam [5:0] FN_DSLLV   = 6'h14;
    localparam [5:0] FN_DSRLV   = 6'h16;
    localparam [5:0] FN_DSRAV   = 6'h17;
    localparam [5:0] FN_DMULT   = 6'h1C;
    localparam [5:0] FN_DMULTU  = 6'h1D;
    localparam [5:0] FN_DDIV    = 6'h1E;
    localparam [5:0] FN_DDIVU   = 6'h1F;
    localparam [5:0] FN_DADD    = 6'h2C;
    localparam [5:0] FN_DADDU   = 6'h2D;
    localparam [5:0] FN_DSUB    = 6'h2E;
    localparam [5:0] FN_DSUBU   = 6'h2F;
    localparam [5:0] FN_DSLL    = 6'h38;
    localparam [5:0] FN_DSRL    = 6'h3A;
    localparam [5:0] FN_DSRA    = 6'h3B;
    localparam [5:0] FN_DSLL32  = 6'h3C;
    localparam [5:0] FN_DSRL32  = 6'h3E;
    localparam [5:0] FN_DSRA32  = 6'h3F;

    // Classify 64-bit instructions used by Killer Instinct
    wire is_ld_sd   = (opcode == OP_LD)  || (opcode == OP_SD) ||
                      (opcode == OP_LDL) || (opcode == OP_LDR) ||
                      (opcode == OP_SDL) || (opcode == OP_SDR);

    wire is_dadd    = (opcode == OP_DADDI) || (opcode == OP_DADDIU) ||
                      ((opcode == OP_SPECIAL) &&
                       (funct == FN_DADD || funct == FN_DADDU ||
                        funct == FN_DSUB || funct == FN_DSUBU));

    // KI uses DSLL32 / DSRL32 / DSRA32 to pack/unpack 32-bit words into 64-bit
    // registers before SD or after LD. Because the shift is 32 + shamt, the
    // operation is a pure 32-bit shift between the Lo and Hi banks!
    wire is_dshift32 = (opcode == OP_SPECIAL) &&
                       (funct == FN_DSLL32 || funct == FN_DSRL32 || funct == FN_DSRA32);

    // Unsupported 64-bit divides/multiplies trigger an immediate RI trap
    // fallback rather than instantiating a 64-bit divider/multiplier in LEs.
    wire is_unimpl_64 = (opcode == OP_SPECIAL) &&
                        (funct == FN_DMULT || funct == FN_DMULTU ||
                         funct == FN_DDIV  || funct == FN_DDIVU  ||
                         funct == FN_DSLLV || funct == FN_DSRLV  || funct == FN_DSRAV);

    typedef enum logic [1:0] {
        UOP_PHASE0_LO = 2'd0,   // Cycle 0: Read Lo bank, compute effective addr / Lo ALU
        UOP_PHASE1_HI = 2'd1,   // Cycle 1: Read Hi bank, issue 64b Mem Req or Hi ALU + Carry
        UOP_MEM_WAIT  = 2'd2    // Wait for ki_memory_bridge completion on LD/SD
    } uop_state_t;

    uop_state_t state = UOP_PHASE0_LO;

    logic [31:0] saved_lo_b   = 32'd0;
    logic [31:0] saved_addr   = 32'd0;
    logic [31:0] saved_alu_lo = 32'd0;
    logic        saved_carry  = 1'b0;

    // 32-bit Adder with Carry-In for 2-cycle 64-bit DADD/DADDU/DSUBU micro-op
    wire        is_sub    = (opcode == OP_SPECIAL) && (funct == FN_DSUB || funct == FN_DSUBU);
    wire [31:0] op_b_mux  = (opcode == OP_DADDI || opcode == OP_DADDIU) ?
                            ((state == UOP_PHASE1_HI) ? {32{imm_sext[31]}} : imm_sext) :
                            rf_rdata_b_i;
    wire [31:0] op_b_eff  = is_sub ? ~op_b_mux : op_b_mux;
    wire        cin_eff   = (state == UOP_PHASE0_LO) ? is_sub : saved_carry;
    wire [32:0] add33     = {1'b0, rf_rdata_a_i} + {1'b0, op_b_eff} + {32'd0, cin_eff};

    // 32-bit Shifter reused for DSLL32 / DSRL32 / DSRA32
    wire [31:0] shl32_res = rf_rdata_b_i << shamt;
    wire [31:0] shr32_res = (funct == FN_DSRA32) ?
                            $unsigned($signed(rf_rdata_b_i) >>> shamt) :
                            (rf_rdata_b_i >> shamt);

    // Effective memory address (32-bit KSEG0/KSEG1 contract: KI uses ADDR32_ONLY)
    wire [31:0] eff_addr  = rf_rdata_a_i + imm_sext;

    always_comb begin
        // Default: read Lo bank (bank 0) in Phase 0, Hi bank (bank 1) in Phase 1
        rf_raddr_a_o = {(state == UOP_PHASE1_HI), rs};
        // DSRL32/DSRA32 need the Hi bank of rt in Phase 0; all other ops read Lo first
        rf_raddr_b_o = ((state == UOP_PHASE1_HI) ||
                        (is_dshift32 && (funct != FN_DSLL32))) ? {1'b1, rt} : {1'b0, rt};

        rf_we_lo_o    = 1'b0;
        rf_we_hi_o    = 1'b0;
        rf_waddr_o    = (opcode == OP_SPECIAL) ? rd : rt;
        rf_wdata_lo_o = add33[31:0];
        rf_wdata_hi_o = {32{add33[31]}};
        alu_res_lo_o  = add33[31:0];

        uop_stall_o   = 1'b0;
        trap_ri_o     = instr_valid_i && is_unimpl_64;

        mem_req_o     = 1'b0;
        mem_rnw_o     = (opcode == OP_LD) || (opcode == OP_LDL) || (opcode == OP_LDR);
        mem_req64_o   = 1'b1;
        mem_addr_o    = {saved_addr[31:3], 3'b000};
        mem_wmask_o   = 8'hFF;
        mem_wdata_o   = {rf_rdata_b_i, saved_lo_b};

        if (instr_valid_i && !is_unimpl_64) begin
            if (is_dshift32) begin
                // Single-cycle 64-bit shift-by-32+shamt using the 32-bit shifter!
                rf_waddr_o = rd;
                rf_we_lo_o = 1'b1;
                rf_we_hi_o = 1'b1;
                if (funct == FN_DSLL32) begin
                    // DSLL32: Hi = rt_lo << shamt, Lo = 0
                    rf_wdata_lo_o = 32'd0;
                    rf_wdata_hi_o = shl32_res;
                end else begin
                    // DSRL32 / DSRA32: Lo = rt_hi >> shamt, Hi = 0 or sign
                    rf_wdata_lo_o = shr32_res;
                    rf_wdata_hi_o = (funct == FN_DSRA32) ? {32{rf_rdata_b_i[31]}} : 32'd0;
                end
            end else if (is_dadd) begin
                // 2-cycle micro-coded 64-bit Add/Sub across the 32-bit ALU
                if (state == UOP_PHASE0_LO) begin
                    uop_stall_o = 1'b1;
                end else if (state == UOP_PHASE1_HI) begin
                    rf_we_lo_o    = 1'b1;
                    rf_we_hi_o    = 1'b1;
                    rf_wdata_lo_o = saved_alu_lo;
                    rf_wdata_hi_o = add33[31:0];
                end
            end else if (is_ld_sd) begin
                // 2-cycle micro-coded 64-bit Load/Store (LD/SD/LDL/LDR/SDL/SDR)
                if (state == UOP_PHASE0_LO) begin
                    uop_stall_o = 1'b1;
                end else if (state == UOP_PHASE1_HI) begin
                    uop_stall_o = 1'b1;
                    mem_req_o   = 1'b1;
                    // Unaligned SDL / SDR byte-mask generation (Little-Endian KI mode)
                    if (opcode == OP_SDL) begin
                        mem_wmask_o = 8'hFF >> (3'd7 - saved_addr[2:0]);
                        mem_wdata_o = {rf_rdata_b_i, saved_lo_b} >> ((3'd7 - saved_addr[2:0]) * 8);
                    end else if (opcode == OP_SDR) begin
                        mem_wmask_o = 8'hFF << saved_addr[2:0];
                        mem_wdata_o = {rf_rdata_b_i, saved_lo_b} << (saved_addr[2:0] * 8);
                    end
                end else if (state == UOP_MEM_WAIT) begin
                    uop_stall_o = !mem_done_i;
                    if (mem_done_i && mem_rnw_o) begin
                        rf_waddr_o    = rt;
                        rf_we_lo_o    = 1'b1;
                        rf_we_hi_o    = 1'b1;
                        rf_wdata_lo_o = mem_rdata_i[31:0];
                        rf_wdata_hi_o = mem_rdata_i[63:32];
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= UOP_PHASE0_LO;
            saved_lo_b   <= 32'd0;
            saved_addr   <= 32'd0;
            saved_alu_lo <= 32'd0;
            saved_carry  <= 1'b0;
        end else begin
            case (state)
                UOP_PHASE0_LO: begin
                    if (instr_valid_i && !is_unimpl_64 && (is_dadd || is_ld_sd)) begin
                        saved_lo_b   <= rf_rdata_b_i;
                        saved_addr   <= eff_addr;
                        saved_alu_lo <= add33[31:0];
                        saved_carry  <= add33[32];
                        state        <= UOP_PHASE1_HI;
                    end
                end
                UOP_PHASE1_HI: begin
                    if (is_dadd) begin
                        state <= UOP_PHASE0_LO;
                    end else if (is_ld_sd && bus_ready_i) begin
                        state <= UOP_MEM_WAIT;
                    end
                end
                UOP_MEM_WAIT: begin
                    if (mem_done_i) begin
                        state <= UOP_PHASE0_LO;
                    end
                end
                default: state <= UOP_PHASE0_LO;
            endcase
        end
    end

endmodule

`default_nettype wire
