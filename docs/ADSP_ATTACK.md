# Attacking the ADSP-2105: measured, and the verdict

The DCS sound emulation is 8,203 ALMs in the full core — 48 % of all logic, and
the largest single block. This is what happened when it was attacked directly,
with each proposed cut built and fitted rather than estimated.

Two things came out of it: the block cannot be cut enough to matter, and the
metric everyone (including me) had been quoting is the wrong one.

---

## 1. The metric was wrong: LABs bind, not ALMs

The Pocket's Cyclone V has 18,480 ALMs arranged in **1,848 LABs of 10 ALMs**, and
Quartus reports "Total LABs: partially or completely used". That second number is
the hard wall. ALMs are not.

The proof is in this pair of builds:

| Variant | ALMs | Logic LABs | Memory LABs | Total LABs |
|---|---|---|---|---|
| Core, framebuffer off chip, FPU stubbed | 17,974 | 1,783 | 59 | **1,842 / 1,848** |
| ↑ plus DCS ROM prefetch 512 → 256 lines | **17,410** | 1,783 | 59 | **1,842 / 1,848** |

**564 ALMs saved, zero LABs freed.** The saving was absorbed into LABs that were
already partially used. Every ALM figure in the earlier documents — including the
"17,974 / 18,480 (97 %)" that looked like there was room — is measuring a
capacity that does not bind. What binds is how many of the 1,848 physical LABs
the design touches at all, and the answer is 1,842 with six spare.

Consequence for the whole re-engineering effort: a cut is only worth having if it
empties entire LABs. Cuts that shave ALMs off otherwise-used LABs are worth
nothing, however large the ALM number looks.

## 2. What the block is made of

Method: `tools/measure/measure_fit.sh adsp` builds `adsp2105.sv` + `dcs_mem.sv`
alone against the Pocket device, with the same anti-pruning harness discipline as
the rest of the measurements (`tools/measure/adsp_bench.sv` routes every output
to a pin). Baseline: **8,649 ALMs, 4,312 registers, 12,557 combinational ALUTs,
2 DSP, 84 M10K**. Roughly 4–6 minutes per variant.

`adsp2105.sv` is 2,220 lines: a seven-state instruction sequencer (`S_BOOT`,
`S_FETCH`, `S_DECODE`, `S_DRAIN`, `S_DIV`, `S_ROM`, `S_MEM`, `S_EXEC`), the
complete ADSP-2100-family decoder inside `S_EXEC` (~400 lines, 120 branches), a
32-entry banked register file generalised into a 40-register space (g0/g1/g2/g3),
eight DAG pointer pairs with circular-buffer and bit-reversal addressing, a
40-bit MAC, an ALU with ASTAT flags, a barrel shifter, a restoring divider, a
SPORT autobuffer DMA engine, a timer, a host mailbox, and the boot-DMA path.

12,557 ALUTs at best two per ALM gives a floor of ~6,280 ALMs; the baseline is
8,649. That ~2,400-ALM gap is packaging loss, and in ALM terms it is the only
headroom that exists.

## 3. Every cut measured

| Cut | ALMs | Δ | LABs | Verdict |
|---|---|---|---|---|
| Baseline | 8,649 | — | 1,842 (full core) | |
| `MUX_RESTRUCTURE ON` | 8,649 | **0** | — | no effect |
| Register packing high + `MINIMIZE_AREA` | 8,649 | **0** | — | no effect |
| ROM prefetch cache 512 → 256 lines | 8,518 | −131 | **0** | real ALMs, no LABs |
| Per-store discontinuity diagnostics removed | 8,381 | −268 | — | **already free in the real core, see §4** |
| Read-port mux trees → constant | 6,958 | −1,691 | — | **not a fix, see §5** |
| Register-file write decode removed | 3,333 | −5,316 | — | **not a fix, see §5** |

### 3.1 The one structural idea that had to be rejected

Funnelling the thirteen write-decode sites into one write port — the obvious
refactor — **would break the design.** `adsp2105.sv:1935-1936` legitimately
writes three registers in a single clock:

```verilog
if (`G0(13)[7]) begin `G0(13)<=16'hffff; `G0(12)<=16'h8000; `G0(11)<=16'h0000; end
else           begin `G0(13)<=16'h0000; `G0(12)<=16'h7fff; `G0(11)<=16'hffff; end
```

That is MR overflow saturation and it needs three simultaneous writes. The
thirteen sites are genuine parallel write ports, not duplicated decoders.
Recorded so nobody spends a day on it.

## 4. The diagnostics were already free

Removing the per-store discontinuity diagnostics saves 268 ALMs *in the isolated
benchmark*, and **nothing at all in the real core**, because the real core never
reads them: `ki_dcs_audio` declares `dcs_wrap_cnt`, `dcs_src_cnt`, `dcs_rom_unstable`,
`dcs_cmd_lost` etc. and connects them to the ADSP, but never consumes them, so
Quartus prunes the whole diagnostic chain already. Verified by presence in the
netlist:

| Register | Full core fit report | Isolated benchmark |
|---|---|---|
| `dbg_wrap_cnt` | 0 mentions | 2 |
| `dbg_src_cnt` | 0 | 1 |
| `dbg_w_prev` | 0 | 5 |
| `dbg_ab_prev` | 0 | 3 |

A harness that pins every output — correct for measuring a block, and what made
the other numbers trustworthy — counts diagnostics the shipping build does not
have. Worth knowing before quoting an isolated benchmark as a saving.

## 5. The two big numbers are artefacts

`rd_reg` has **12 call sites** and `wr_reg` **13**; Verilog inlines both, so in
principle there are twelve independent 32:1 16-bit read multiplexers and thirteen
write decoders. Replacing `rd_reg` with a constant does remove 1,691 ALMs — by
making every read zero, which freezes the architectural state, which lets the
synthesiser delete the state. The measured delta is mostly deleted registers.
Stubbing `wr_reg` collapses the block to 3,333 ALMs for the same reason: with no
writes, nothing is a register.

Neither number is achievable. They are recorded because they are large enough to
mislead a future reader who finds them in a log.

## 6. Verdict

**The ADSP cannot be cut enough to matter by any means that preserves the
hardware's behaviour, and the one real cut found — the ROM prefetch cache — frees
no LABs at all.**

The block is 48 % of the core's logic and behaves like it: a complete DSP with
eleven functional units, already written with shared datapath evaluation, one
consolidated writeback per unit (`alu_wb` / `mac_wb` / `shift_wb` all consume
single shared result wires), and a clock-enable structure Quartus accepts. There
is no accumulated cruft to sweep out; the upstream author built it this way on
purpose.

Against a shortfall that needs the framebuffer arbiter, the write-combining
queues and the APF wiring — none of which exist yet — **the measured available
saving here is zero LABs.** That is the whole answer.

If this port is ever to fit, the decision is not a knob:

1. **Do not emulate the ADSP-2105.** Reimplement only the opcode subset the DCS
   firmware actually executes. **This was then done — see
   [ADSP_SUBSET.md](ADSP_SUBSET.md).** The subset is real and small (41 classes,
   the same for both games), but the saving it yields is 80 LABs in isolation and
   **12 LABs in the full core**, because only one datapath unit turns out to be
   unused. The route is exhausted, not promising.
2. **Accept a larger device.** Not available for the Pocket.
3. **Do not port this core.**

## 7. What this does not change

The facts in [REENGINEERING.md](REENGINEERING.md) stand: the framebuffer is 69 %
of block RAM and moving it off chip is mandatory and sufficient for the RAM wall
(113 % → 36 %); the FPU is 2,466 ALMs and removing it is the largest legitimate
logic saving. Those closed the RAM wall and most of the logic wall.

They did not close it completely, the ADSP was the last large block that could
plausibly have paid for the rest — and measured properly, in the metric that
binds, it pays nothing.

---

## Reproducing

```bash
export PATH=/opt/intelFPGA/25.1/quartus/bin:$PATH

# isolated block benchmark (8,649 ALMs baseline)
tools/measure/measure_fit.sh adsp

# the two full-core variants in the table (§1)
tools/measure/measure_fit.sh fb-off-no-fpu       # 17,974 ALMs, 1,842 LABs
tools/measure/measure_fit.sh fb-off-no-fpu-pf    # 17,410 ALMs, 1,842 LABs
```

Ad-hoc variants from this investigation are under `build/` (git-ignored;
patched copies, never the vendored source):

| Path | Change | Result |
|---|---|---|
| `build/kn_mux` | `MUX_RESTRUCTURE ON` | 8,649 (no change) |
| `build/kn_pack` | register packing high + minimize area | 8,649 (no change) |
| `build/kn_pf` | `dcs_mem` `PF_LINES` 512 → 256 | 8,518 |
| `build/nodbg` | `dm_write` diagnostics removed | 8,381 (artefact: already pruned) |
| `build/abl_rd` | `rd_reg` → constant | 6,958 (artefact) |
| `build/abl_wr` | `wr_reg` → no-op | 3,333 (artefact) |

Always read **Total LABs** from `feas.fit.rpt` before believing an ALM figure.
