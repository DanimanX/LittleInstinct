// psram_phy: one Pocket PSRAM chip (AS1C8M16PL = two AS1C4M16PL dies, CellularRAM 1.5, address/data multiplexed)
// in synchronous burst mode with VARIABLE latency (WAIT monitored), for the Saturn glue (glue/REPORT.txt).
//
// A6 (work/a6, diagnostic build 0.0.1-a6dbg, 2026-11-01), only with `define A6_DBG (without it the file is A5's):
//   * input gap2: 1 = two full PSRAM cycles of CE# high between accesses instead of one: the command is taken as before
//     (cmd_ready is A5's), then the PHY waits one more PSRAM cycle with CE# high in state S_GW before the address cycle
//     (S_ADR). cmd_ready and the take are A5's, so the queues' timing-critical m_ready paths do not see the option.
//     0 = A5's timing exactly (S_GW is never entered).
//   * outputs dbg_rw / dbg_ww (one-clk pulses, bit = the die of the access, a_r[22]): WAIT seen where the datasheet
//     (AS1C4M16PL) allows none. The PHY only watches; nothing it does changes.
//       dbg_rw: a READ data-phase sample (win[RDLAT-1], rd_on, words still expected) with WAIT high although either a
//               word of the burst has already come (WAIT inside a burst: bursts never cross a row here) or the sample
//               is of the PSRAM cycle after K_2LC or later (variable latency code 2: first word after K_LC, or after
//               K_2LC on a refresh collision; Table 5 "Normal 2 / Refresh Collision 4"). The PHY waits correctly in
//               either case (it takes words only with WAIT low); the flag says the device asked for more time than
//               the datasheet allows.
//       dbg_ww: a WRITE word whose WAIT was high: the sample of the WAIT driven after K_c for every c at which wl_r is
//               high (the word driven in cycle c + 1, which the PSRAM takes at K_c+1; with BCR[8] = 0 WAIT is low in
//               the cycle in which data are accepted). WRITEs always use the fixed latency (WAIT asserted LC cycles,
//               Figure 32 note 2): the PHY drives every word at its fixed cycle and does NOT look at WAIT, so a high
//               WAIT there means a word the device did not take as the PHY assumes (lost or shifted write data).
//
// A3 (work/a3, timing closure, 2026-11-01): every pin register (I/O cell) copies a fabric register m_<pin> that
// was loaded one clk earlier with the value the A2 PHY computed for the pin (the same pin waveforms in every clk;
// see work/a3/tools/mk_phy_a3.py): the pin registers' inputs no longer go through the state / phase decodes. The end
// of a read burst on its last word's take (WAIT sampled at the start of that clk) is the one late input: CE0#, CE1#,
// OE#, UB#, LB# take m | (qlast & !wait_s). The phase toggle ph is kept per PHY instance (dont_merge).
// A2 (work/a2, timing closure, 2026-10-31): the pin registers (I/O-cell registers, far from the logic) are loaded
// from registers only; every pin waveform is the B1 PHY's, cycle for cycle, except that a command is now accepted
// in the FIRST clk of a PSRAM cycle (cmd_ready high in that clk) and driven at the end of the second (the B1 PHY took
// it at the end of the second clk and drove it at the same edge):
//   * a command that is valid in the first clk of a PSRAM cycle gives exactly the B1 pins; one that becomes valid
//     only in the second clk starts one PSRAM cycle (2 clk) later. While the PHY is busy the next command is normally
//     ready long before the PHY is idle, so back-to-back accesses are not delayed;
//   * the accepted address is held in a_r (taken in the first clk) and driven from it; the write word of the next
//     PSRAM cycle and the write / read end conditions are registered in the first clk (wd_r, wl_r, wend_r, rlast_r,
//     rend1_r, rle_r: the PHY's own state only changes at the end of the second clk, so the registered values are
//     the ones the B1 PHY computed in the second clk); wd_pop = wl_r (a register, high in the second clk only);
//   * the power-up wait's end compare is registered one clk ahead (pwr_hit), the register-write steps are the B1
//     decodes (5-bit compares of cnt, unchanged), except CRE's: set by pwr_hit, cleared by cre_end (the end of the
//     BCR write, registered one clk ahead), both outside the state case (same pin waveform);
//   * RDLAT = 2 and CLKDIV = 2 only (the delivered build's values; the read-take logic relies on a sample being taken
//     in the second clk of a PSRAM cycle).
// B1 (work/b1, hardware bring-up, 2026-10-31): the configuration at power-up is redone; every access after it is the
// delivered PHY's.
//   * The asynchronous configuration-register write follows the CellularRAM ADMUX protocol of the PSX port that runs
//     on the Pocket (sotn-main vram_psram.vhd: ADV# pulse first, WE# pulse after it): CE# + ADV# low with CRE high and
//     the value on A/DQ, ADV# high 3 clk later (address and CRE latched with both still on the pins), WE# low 2 clk
//     after that for CRE_CYC clk, CE# high 1 clk after WE#, CRE low 1 clk after CE#. The delivered PHY released ADV#,
//     WE# and CE# on the same clk edge as CRE fell (no hold of CRE / the address after the latch closed).
//   * Before it, CE# low on both dies for 2^WAKE_LOG2 clk (17.9 us: a die a previous core left in deep power-down
//     wakes up), then INIT_CYC + 2^WAKE_LOG2 clk (>= 150 us) of wait.
//   * The refresh configuration register is written with its power-on value 0x0010 (full-array refresh, deep
//     power-down off) before the BCR (the registers keep their values from a previous core until power-off). Both
//     registers on both dies at once, as the delivered BCR write.
//   * FIXED / USE_WAIT: for the bring-up diagnostics only (defaults = the delivered behaviour).
//
// Clocking (CLKDIV = 2): clk = clk_ram (2 x clk_sys, 106.75-114.55 MHz); one PSRAM cycle = two clk, so the PSRAM
// runs at clk_sys (53.4-57.3 MHz). The PSRAM clock (p_clk, a register on an I/O cell) is low in the first and high in
// the second clk of each PSRAM cycle; every other pin changes at the start of a PSRAM cycle, a full clk (8.7 ns)
// before the rising edge K that samples it and a full clk after it (tSP / tHD are 2-4 ns). A word the PSRAM drives
// after K_j (tACLK <= 9 ns) is sampled RDLAT = 2 clk later, at the clk edge that makes K_j+1: ~3.4 ns setup margin
// with 3.5 ns clock-out and 1.5 ns input delay; it is held tKOH = 2 ns after K_j+1 at the pins (sotn's vram_psram
// uses this method at 50.8 MHz).
//
// Latency: LC = 2 (BCR[13:11] = 010, "3 clocks", <= 66 MHz on the 108 / 133 MHz parts), variable: the first read
// word is driven after K_LC and sampled at K_LC+1, or LC cycles later when the access collides with a hidden refresh
// (WAIT stays high). WRITEs always use the fixed latency (first word sampled by the PSRAM at K_LC+1).
// Bursts are 1..32 words and must not cross an aligned 32-word block (the requester splits): never a row boundary
// (rows are at least 128 words), and CE# low stays far below tCEM = 4 us (<= 40 PSRAM cycles = 0.75 us).
// CE# is high for one full PSRAM cycle between accesses (a clocked CE# high: a refresh opportunity; > tCBPH and
// > tHZ before the next address is driven).
//
// Timing in PSRAM cycles (address cycle and the CE#-high cycle included, no refresh collision): an access of N
// words takes LC + N + 2 (single word: 5 = 93 ns at 53.7 MHz; 8 words: 12; 32 words: 36); a collision adds LC to a
// READ.
//
// Interface (clk domain):
//   cmd_valid / cmd_ready: one access; cmd_we, cmd_addr = word address {die, A[21:0]}, cmd_len = words - 1 (0..31).
//   (A2) cmd_ready is high in the first clk of a PSRAM cycle; cmd_valid may change in any clk (the command that is
//   valid when cmd_ready is high is the one taken).
//   Write words are pulled in order: wd_pop pulses in the clk the head word (wd_data / wd_be) is taken; (A2) the
//   word is read one clk before that pulse (in the first clk of the PSRAM cycle), so wd_data / wd_be must not change
//   in the clk before a pop (they change only at pops and at the command's take in psram0_arb / fb_queue).
//   Read words come back in order with rd_valid (rd_last on the last one).
//   cfg_done: the bus configuration registers have been written (accesses are accepted from then on).
module psram_phy #(
	parameter int LC       = 2,
	parameter int CLKDIV   = 2,        // (A2: 2 only)
	parameter int RDLAT    = 2,        // (A2: 2 only)
	parameter int INIT_CYC = 16384,    // >= 150 us power-up at clk (16,384 clk = 153 us at 107.4 MHz)
	parameter int CRE_CYC  = 9,        // asynchronous register write: WE# low CRE_CYC clk (>= tWP), CE# low CRE_CYC + 5
	parameter int WAKE_LOG2 = 11,      // (B1) CE# low 2^WAKE_LOG2 clk on both dies first (deep power-down exit)
	parameter bit FIXED    = 1'b0,     // (B1, diagnostics) BCR[14]: 1 = fixed latency
	parameter bit USE_WAIT = 1'b1      // (B1, diagnostics) 0 = read words taken by count alone (with FIXED = 1)
) (
	input  logic        clk,
	input  logic        rst,

	input  logic        cmd_valid,
	output logic        cmd_ready,
	input  logic        cmd_we,
	input  logic [22:0] cmd_addr,
	input  logic  [4:0] cmd_len,

	output logic        wd_pop,
	input  logic [15:0] wd_data,
	input  logic  [1:0] wd_be,

	output logic        rd_valid,
	output logic [15:0] rd_data,
	output logic        rd_last,
	output logic        cfg_done,
`ifdef A6_DBG
	input  logic        gap2,          // (A6) 1: CE# high two PSRAM cycles between accesses
	output logic  [1:0] dbg_rw,        // (A6) READ WAIT anomaly, per die (pulse)
	output logic  [1:0] dbg_ww,        // (A6) WRITE WAIT anomaly, per die (pulse)
`endif

	output logic [21:16] p_a,
	output logic [15:0] p_dq_out,
	output logic        p_dq_oe,
	input  logic [15:0] p_dq_in,
	output logic        p_clk,
	output logic        p_adv_n,
	output logic        p_cre,
	output logic        p_ce0_n,
	output logic        p_ce1_n,
	output logic        p_oe_n,
	output logic        p_we_n,
	output logic        p_ub_n,
	output logic        p_lb_n,
	input  logic        p_wait
);
	// BCR: synchronous burst (15 = 0), variable latency (14 = 0), latency code (13:11), WAIT active high (10 = 1),
	// WAIT asserted during the delay and low in the cycle data is valid (8 = 0), half drive (5:4 = 01), no wrap
	// (3 = 1), continuous burst (2:0 = 111); register select A[19:18] = 10.
	localparam logic [21:0] BCR = {2'b00, 2'b10, 2'b00, 1'b0, FIXED, 3'(LC), 1'b1, 1'b0, 1'b0, 2'b00, 2'b01, 1'b1, 3'b111};
	// (B1) RCR: the power-on value 0x0010 (full-array refresh, deep power-down off); register select A[19:18] = 00.
	// M_RB: the A/DQ bits in which the BCR differs from it (reloaded between the two writes)
	localparam logic [21:0] RCR  = {2'b00, 2'b00, 2'b00, 16'h0010};
	localparam logic [21:0] M_RB = RCR ^ BCR;
	localparam int PWR_END = INIT_CYC + (2 << WAKE_LOG2);   // (B1) wake [0, 2^WAKE_LOG2), then the wait

	// ph: 1 in the first, 0 in the second clk of a PSRAM cycle; step: the clk at whose end the PSRAM-cycle registers
	// update (the second one)
	(* dont_merge *) logic ph;	// (A3) one per PHY (Quartus merged the two PHYs' toggles)
	wire  step = ~ph;

	// (A2) S_ADR: a command was taken in the first clk of this PSRAM cycle; its address cycle starts at the end of it
`ifdef A6_DBG
	typedef enum logic [2:0] { S_PWR, S_CRE, S_GAP, S_IDLE, S_ADR, S_ACC, S_GW } st_t;   // (A6) S_GW: the gap option's extra cycle
`else
	typedef enum logic [2:0] { S_PWR, S_CRE, S_GAP, S_IDLE, S_ADR, S_ACC } st_t;
`endif
	st_t         st;
	logic [14:0] cnt;          // power-up / register write counter (clk), else PSRAM cycle within the access
	logic        ci;           // (B1) register write: 0 RCR, 1 BCR
	logic        we_r;
	logic  [4:0] len_r;        // words - 1
	logic  [5:0] wsent;        // write words driven
	logic  [5:0] rgot;         // read words taken
	logic        rd_on;        // a read is in progress
	// (A2) registered in the first clk of a PSRAM cycle (or every clk; the values used at the end of the second clk
	// are those of the PSRAM cycle's state, which does not change in between)
	logic [22:0] a_r;          // the address of the command taken (driven in its address cycle)
	logic        ce_hi;        // both CE# high (internal copy of the I/O-cell registers' state)
	logic        pwr_hit;      // cnt == PWR_END in S_PWR (registered one clk ahead)
	logic        cre_end;      // (A2) S_CRE, BCR write (ci), cnt[4:0] == 6 + CRE_CYC (registered one clk ahead): CRE low
	logic        wl_r;         // a write word is driven at the end of this PSRAM cycle (high in its second clk)
	logic [15:0] wd_r;         // ... this one
	logic  [1:0] wbe_r;
	logic        wend_r;       // the last write word went out in the previous PSRAM cycle: CE# high now
	logic        rlast_r;      // rgot == len_r
	logic        rend1_r;      // rgot == len_r + 1
	logic        rle_r;        // rgot <= len_r

	// read samples: dq / WAIT sampled every clk; win marks the samples that belong to the data phase of the read
	// (PSRAM cycle LC or later); win_in is computed in the step clk of a PSRAM cycle, the sample of the word driven
	// after its K arrives RDLAT clk after that K, i.e. in win[RDLAT-1]'s clk (the second clk of a PSRAM cycle)
	logic [15:0] dq_s;
	logic        wait_s;
	logic [RDLAT-1:0] win;
	always_ff @(posedge clk) begin
		dq_s   <= p_dq_in;
		wait_s <= p_wait;
	end
	wire win_in = (st == S_ACC) && step && !we_r && (cnt >= LC);
	always_ff @(posedge clk) begin
		if (rst) win <= '0;
		else     win <= {win[RDLAT-2:0], win_in};
	end
	wire take = win[RDLAT-1] && (!wait_s || !USE_WAIT) && rd_on && rle_r;

`ifdef A6_DBG
	// (A6) WAIT anomaly monitors (see the header); winw: the write words' WAIT samples (wl_r = a word goes out in the
	// next PSRAM cycle; its WAIT, driven after this cycle's K, is sampled RDLAT clk later, as a read word)
	logic [RDLAT-1:0] winw;
	always_ff @(posedge clk) begin
		if (rst) winw <= '0;
		else     winw <= {winw[RDLAT-2:0], wl_r};
		dbg_rw <= '0; dbg_ww <= '0;
		if (!rst && win[RDLAT-1] && rd_on && rle_r && wait_s && (rgot != 6'd0 || cnt >= 15'(2 * LC + 1)))
			dbg_rw[a_r[22]] <= 1'b1;
		if (!rst && winw[RDLAT-1] && wait_s)
			dbg_ww[a_r[22]] <= 1'b1;
	end
`endif
	assign cmd_ready = (st == S_IDLE) && ph;
`ifdef A6_DBG
	assign cfg_done  = (st == S_IDLE) || (st == S_ADR) || (st == S_ACC) || (st == S_GW);
`else
	assign cfg_done  = (st == S_IDLE) || (st == S_ADR) || (st == S_ACC);
`endif
	assign wd_pop    = wl_r;

	// (A2) state-only conditions, registered every clk (used in the second clk of a PSRAM cycle; wl_r only in it)
	always_ff @(posedge clk) begin
		rlast_r <= rgot == {1'b0, len_r};
		rend1_r <= rgot == {1'b0, len_r} + 6'd1;
		rle_r   <= rgot <= {1'b0, len_r};
		wend_r  <= (st == S_ACC) && we_r && (wsent == {1'b0, len_r} + 6'd1);
		wl_r    <= ph && (st == S_ACC) && we_r && (cnt >= LC) && (wsent <= {1'b0, len_r});
		wd_r    <= wd_data;
		wbe_r   <= wd_be;
		pwr_hit <= !rst && (st == S_PWR) && (cnt == 15'(PWR_END - 1));
		cre_end <= !rst && (st == S_CRE) && ci && (cnt[4:0] == 5'(5 + CRE_CYC));
	end

	always_ff @(posedge clk) begin
		rd_valid <= 1'b0;
		rd_last  <= 1'b0;
		if (take) begin
			rd_valid <= 1'b1;
			rd_data  <= dq_s;
			rd_last  <= rlast_r;
			rgot     <= rgot + 6'd1;
		end
		if (rst) begin
			st <= S_PWR; cnt <= '0; rd_on <= 1'b0; ph <= 1'b1; ci <= 1'b0; ce_hi <= 1'b1;
			// (A3) the pins: below (m_* registers, one clk ahead)
		end else begin
			ph <= ~ph;
			case (st)
				S_PWR: begin   // (B1) wake (CE# low on both dies), the power-up wait, then the RCR write (CRE high, ADV# low)
					cnt <= cnt + 15'd1;
					ce_hi <= !(cnt[14:WAKE_LOG2] == '0);
					if (pwr_hit) begin
						cnt <= '0; st <= S_CRE; ci <= 1'b0; ce_hi <= 1'b0;
					end
				end
				S_CRE: begin   // (B1) ADMUX register write (RCR, then BCR): address + CRE latched by ADV#, then WE#
					cnt <= cnt + 15'd1;
					case (cnt[4:0])   // (A3: the pins of each step in the m_* logic below)
						5'(5 + CRE_CYC): ce_hi <= 1'b1;
						5'(6 + CRE_CYC): if (ci) begin cnt <= '0; st <= S_GAP; end   // DQ released in S_GAP
						5'(8 + CRE_CYC): begin   // (ci = 0) the BCR write, the same steps (CE# was high 3 clk)
							cnt <= '0; ci <= 1'b1; ce_hi <= 1'b0;
						end
						default: ;
					endcase
				end
				S_GAP: begin
					cnt <= cnt + 15'd1;
					if (cnt >= 15'(4 * CLKDIV) && step) begin cnt <= '0; st <= S_IDLE; end
				end
				S_IDLE: if (ph) begin
					// (A2) first clk of a PSRAM cycle: take the command (CE# has been high since the start of this cycle:
					// S_IDLE is entered with CE# going high); the address and command bits are taken in any case
					a_r <= cmd_addr; we_r <= cmd_we; len_r <= cmd_len;
`ifdef A6_DBG
					if (cmd_valid && ce_hi) st <= gap2 ? S_GW : S_ADR;   // (A6) gap 2: one more PSRAM cycle of CE# high first
`else
					if (cmd_valid && ce_hi) st <= S_ADR;
`endif
				end
`ifdef A6_DBG
				S_GW: if (ph) st <= S_ADR;   // (A6) the take's PSRAM cycle and the next one with CE# high, then the address cycle
`endif
				S_ADR: if (step) begin   // address cycle: CE# and ADV# low with the address; WE# says READ / WRITE for
					           // the whole burst (the cycle before an address cycle always has CE# high)
					st <= S_ACC; cnt <= '0; ce_hi <= 1'b0;
					wsent <= '0; rgot <= '0; rd_on <= !we_r;
				end
				S_ACC: if (step) begin
					cnt <= cnt + 15'd1;
					if (we_r) begin
						// write words from PSRAM cycle LC + 1 on, one per cycle (driven at the start of the cycle)
						if (wl_r) wsent <= wsent + 6'd1;
						if (wend_r) begin   // the last word was in this cycle: CE# high next
							st <= S_IDLE; ce_hi <= 1'b1;
						end
					end else begin
						// all words taken: CE# high (the PSRAM may have driven one more word: ignored)
						if (rend1_r || (take && rlast_r)) begin
							st <= S_IDLE; rd_on <= 1'b0; ce_hi <= 1'b1;
						end
					end
				end
				default: st <= S_PWR;
			endcase
		end
	end

	// ------------------------------------------------------------------------------------------- (A3) the pins
	// m_<pin>: in every clk, the value the pin takes at the end of that clk, loaded at the end of the clk before from
	// that clk's state (nx_*: the A2 PHY's pin logic applied to the state of the NEXT clk, which follows from this one);
	// "hold" keeps the pin's value (the pin's value in the next clk is m_<pin> now, or m | end_now for the five pins a
	// read can end on).
	logic        m_ce0, m_ce1, m_adv, m_we, m_oe, m_ub, m_lb, m_dqoe, m_cre, m_clk;
	logic [21:16] m_a;
	logic [15:0] m_dq;
	logic        qlast;   // the next clk is S_ACC's step clk of a read whose take there would be the last word (but WAIT)
	wire         end_now = qlast && (!wait_s || !USE_WAIT);   // = take && rlast_r in S_ACC's step clk of a read
	logic        nx_ce0, nx_ce1, nx_adv, nx_we, nx_oe, nx_ub, nx_lb, nx_dqoe, nx_cre, nx_clk;
	logic [21:16] nx_a;
	logic [15:0] nx_dq;
	wire  [14:0] cnt1 = cnt + 15'd1;
	wire         adr = st == S_ADR;   // (v2) the address cycle's clk (S_ADR lasts one clk, a step clk)
	always_comb begin
		// hold (the pins' values in the next clk)
		nx_ce0 = m_ce0 | end_now; nx_ce1 = m_ce1 | end_now; nx_oe = m_oe | end_now; nx_ub = m_ub | end_now; nx_lb = m_lb | end_now;
		nx_adv = m_adv; nx_we = m_we; nx_dqoe = m_dqoe; nx_a = m_a; nx_dq = m_dq;
		// p_clk: high in the second clk of a PSRAM cycle outside S_PWR / S_CRE (the next clk's phase is !ph; the next
		// state is neither after S_GAP / S_IDLE / S_ADR / S_ACC and after S_CRE's end; any other code goes to S_PWR)
`ifdef A6_DBG
		nx_clk = !ph && ((st == S_GAP) || (st == S_IDLE) || (st == S_ADR) || (st == S_ACC) || (st == S_GW) || (st == S_CRE && ci && cnt[4:0] == 5'(6 + CRE_CYC)));
`else
		nx_clk = !ph && ((st == S_GAP) || (st == S_IDLE) || (st == S_ADR) || (st == S_ACC) || (st == S_CRE && ci && cnt[4:0] == 5'(6 + CRE_CYC)));
`endif
		// p_cre: set with pwr_hit, cleared with cre_end (their values in the next clk are their registers' inputs now)
		nx_cre = (st == S_PWR && cnt == 15'(PWR_END - 1)) ? 1'b1 : (st == S_CRE && ci && cnt[4:0] == 5'(5 + CRE_CYC)) ? 1'b0 : m_cre;
		case (st)
			S_PWR: if (!pwr_hit) begin   // the next clk is S_PWR at cnt + 1 (its pwr_hit = cnt == PWR_END - 1)
				if (cnt == 15'(PWR_END - 1)) begin   // pwr_hit there: CE# + ADV# low with the RCR on A/DQ
					nx_ce0 = 1'b0; nx_ce1 = 1'b0; nx_adv = 1'b0;
					nx_a = RCR[21:16]; nx_dq = RCR[15:0]; nx_dqoe = 1'b1;
				end else begin
					nx_ce0 = !(cnt1[14:WAKE_LOG2] == '0); nx_ce1 = !(cnt1[14:WAKE_LOG2] == '0);
				end
			end   // (pwr_hit now: the next clk is S_CRE at cnt 0, no pin change)
			S_CRE: case (cnt[4:0])   // the next clk is S_CRE at cnt + 1 (the A2 steps one clk earlier), or S_GAP
				5'd1:            nx_adv = 1'b1;                                // latch closes, CRE / address held
				5'd3:            nx_we  = 1'b0;
				5'(3 + CRE_CYC): nx_we  = 1'b1;                                // the register is loaded
				5'(4 + CRE_CYC): begin nx_ce0 = 1'b1; nx_ce1 = 1'b1; end
				5'(5 + CRE_CYC): if (!ci) {nx_a, nx_dq} = ({m_a, m_dq} & ~M_RB) | (BCR & M_RB);   // the BCR
				5'(6 + CRE_CYC): if (ci) nx_dqoe = 1'b0;                       // the next clk is S_GAP: DQ released
				5'(7 + CRE_CYC): begin nx_ce0 = 1'b0; nx_ce1 = 1'b0; nx_adv = 1'b0; end   // (ci = 0) the BCR write
				default: ;
			endcase
			S_GAP: if (!(cnt >= 15'(4 * CLKDIV) && step)) nx_dqoe = 1'b0;   // the next clk is S_GAP
			S_IDLE: ;   // (v2) no pin change in the next clk: S_IDLE again, or S_ADR, whose pins are selected at the pin (below)
`ifdef A6_DBG
			S_GW: ;     // (A6) no pin change: S_GW again or S_ADR (CE# stays high)
`endif
			S_ACC: if (ph) begin   // the next clk is S_ACC's step clk: wl_r / wend_r / wd_r / wbe_r / rend1_r there are
				                   // the values their registers load now
				nx_adv = 1'b1;
				if (we_r) begin
					if ((cnt >= LC) && (wsent <= {1'b0, len_r})) begin   // wl_r
						nx_dq = wd_data; nx_dqoe = 1'b1; nx_ub = !wd_be[1]; nx_lb = !wd_be[0];
					end
					if (wsent == {1'b0, len_r} + 6'd1) begin   // wend_r
						nx_ce0 = 1'b1; nx_ce1 = 1'b1; nx_we = 1'b1; nx_dqoe = 1'b0; nx_ub = 1'b1; nx_lb = 1'b1;
					end
				end else begin
					nx_dqoe = 1'b0; nx_oe = 1'b0;
					if (rgot == {1'b0, len_r} + 6'd1) begin   // rend1_r
						nx_ce0 = 1'b1; nx_ce1 = 1'b1; nx_oe = 1'b1; nx_ub = 1'b1; nx_lb = 1'b1;
					end
				end
			end
			S_ADR: begin   // the next clk is S_ACC's first clk (no pin change): m holds the address cycle's values, which
				           // the pins take at the end of this clk through the S_ADR select below
				nx_ce0 = a_r[22]; nx_ce1 = !a_r[22];
				nx_adv = 1'b0; nx_we = !we_r; nx_oe = 1'b1;
				nx_a = a_r[21:16]; nx_dq = a_r[15:0]; nx_dqoe = 1'b1;
				nx_ub = 1'b0; nx_lb = 1'b0;
			end
			default: begin nx_ce0 = !(cnt[14:WAKE_LOG2] == '0); nx_ce1 = !(cnt[14:WAKE_LOG2] == '0); end   // (unused codes: S_PWR next, cnt kept)
		endcase
	end
	always_ff @(posedge clk) begin
		// the first clk after the reset is S_PWR at cnt 0: CE# low (wake), every other pin keeps its reset value
		qlast <= !rst && (st == S_ACC) && ph && !we_r && win[RDLAT-2] && rd_on && (rgot == {1'b0, len_r});
		if (rst) begin
			m_ce0 <= 1'b0; m_ce1 <= 1'b0; m_adv <= 1'b1; m_we <= 1'b1; m_oe <= 1'b1; m_ub <= 1'b1; m_lb <= 1'b1;
			m_dqoe <= 1'b0; m_cre <= 1'b0; m_clk <= 1'b0;
		end else begin
			m_ce0 <= nx_ce0; m_ce1 <= nx_ce1; m_adv <= nx_adv; m_we <= nx_we; m_oe <= nx_oe; m_ub <= nx_ub; m_lb <= nx_lb;
			m_dqoe <= nx_dqoe; m_cre <= nx_cre; m_clk <= nx_clk; m_a <= nx_a; m_dq <= nx_dq;
		end
		// the I/O-cell registers: copies of m (the five read-end pins: | end_now), in the S_ADR clk the address cycle's
		// values from a_r / we_r (v2), the synchronous reset as before
		p_ce0_n <= rst || (adr ? a_r[22] : m_ce0 || end_now); p_ce1_n <= rst || (adr ? !a_r[22] : m_ce1 || end_now);
		p_oe_n  <= rst || adr || m_oe || end_now;
		p_ub_n  <= rst || (!adr && (m_ub || end_now));  p_lb_n  <= rst || (!adr && (m_lb || end_now));
		p_adv_n <= rst || (!adr && m_adv); p_we_n <= rst || (adr ? !we_r : m_we);
		p_dq_oe <= !rst && (adr || m_dqoe); p_cre <= !rst && m_cre; p_clk <= !rst && m_clk;
		if (!rst) begin p_a <= adr ? a_r[21:16] : m_a; p_dq_out <= adr ? a_r[15:0] : m_dq; end   // (held during the reset, as before)
	end
endmodule
