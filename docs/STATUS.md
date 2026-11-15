# Where the port stands, and what is actually established

Written 2026-11-15, after a session that produced one real fix and several
retracted claims. The point of this file is that the next session does not have
to repeat the walk: it separates what a tool measured from what was inferred,
and names the open questions instead of leaving them to be rediscovered.

Rule for reading: **established** means a command was run and its output is
quoted somewhere in `docs/`. **Hypothesis** means it fits the evidence and has
not been tested. **Retracted** means it was written down here as fact and is not.

---

## 1. The Pocket build itself

| Fact | Value | Where |
|---|---|---|
| Device | Cyclone V `5CEBA4F23C8` | `src/fpga/pocket_ki.qsf` |
| Fit, last successful | 18 253 / 18 480 ALM (99 %); 1 846 / 1 848 LAB | `src/fpga/output_files/pocket_ki.fit.summary`, `.fit.rpt` |
| Block memory | 1 525 344 / 3 153 920 bits | same |
| DSP blocks | 23 / 66 | same |
| Registers | 17 125 | same |
| Setup timing | open: all 400 worst paths in `adsp2105`, worst −3.017 ns | `docs/ADSP_TIMING.md` |
| Hold / recovery | closed (+0.120 ns / +15.387 ns) | same |
| Bitstream | `pocket_ki.rbf`, and the APF package under `Release/` | repo |

**Established.** The design synthesises and fits; it does not close setup, and
every violating path is the sound DSP's MAC cone.

## 2. Regression suite

`tests/sim/run.sh` → **24 PASS, 0 FAIL** (loader, boot sequencer, input chord,
PK I/O paths, disk batch and data, readback, loader end-to-end).

`tests/sim/run_adsp.sh` → runs the DCS boot with the real ROM (see §3).

`tests/sim/run_cpu.sh` → **fails, and cannot currently succeed** (see §4).

## 3. The DCS sound board

### Established by running it

- Real `kinst.rom` DCS image boots on the real `adsp2105` model through the real
  `dcs_mem` and `ki_dcs_audio`. The boot page streams correctly
  (`18 02 2f 2e "Killer Inst…"`, length byte `0x2e` → 376 words).
- **The DSP ran 60 763 instructions in 4 ms** and stayed inside the implemented
  subset: no `o_unimpl`, no internal assertion, one 1 KiB page of address space.
- **`0x14044E` at pc 0x43 is an empty DO** (`DO 0x44 UNTIL NOT CE`): its end is
  its own first body instruction. Pushed normally it traps the sequencer on one
  instruction (64 000 retirements of pc 0x44). Not pushed, the DSP walks past
  and reaches its real poll block at 0x42-0x48. **Fixed** in
  `adsp2105_pocket.sv`; the loop stack is deliberately left alone because it is
  also the return stack (measured: popping it stops the run at pc 0x153).
- With that fix, the poll block runs and returns to 0x42 on its own.
- **No PCM output** (`dsp pcm pushes = 0`), `host_status = 0x0C00`, the input
  latch accepts a host word but the DSP never reads it (`cmd read = 0`) for any
  of 18 candidate command words, delivered before or after boot.
- **The condition-code table was wrong** from code 0x2 upwards (had GT where the
  manual has LT, etc.). Replaced with the manual's Table 15.9/15.8. No change in
  the 4 ms run (the poll's branch uses NE, where both tables agree).

### Established against the manual

- *ADSP-2100 Family User's Manual* (3rd ed., Sept 1995): a direct conditional
  JUMP/CALL carries a **full 14-bit absolute page address** (Instruction Type
  10). The model already decodes it that way.
- Same manual, Table 15.9: condition codes EQ NE LT GE LE GT AC NOTAC AV NOTAV
  MV NOTMV NEG POS NOTCE.

### Open

- **Why the DSP does not leave the poll block.** `DM(0x1FCA)` reads 0 with no
  store ever targeting it; whether that is right is unknown, because the DM-to-
  ROM mapping has not been verified against a source.
- **A second jump form exists.** Three separate jumps in the page carry the same
  field `0x154`, and `0x18153F` points at itself under the absolute rule. The
  manual also documents **Type 7, JUMP/CALL with computed address fields**,
  whose bit-4-relative fields include *derived ending of DO loop*. That form is
  not implemented. Which one the page uses is unresolved.
- The model's `o_unimpl` covers opcode *classes*; it does not prove every
  sub-operation of a class is right.

### Retracted

- "The firmware jumps past its 376-word page, so the model's 14-bit PM cannot
  follow it." Written as fact, false. The jump field is a page address and
  0x0F4 is inside the page.
- "The 0x46 ALU op is not in the implemented subset." The model never raises
  `o_unimpl` on it.
- "The DSP's silence is a model/decoder gap." Not established; the model may
  simply be waiting for something the MIPS side never sends.

## 4. The MIPS CPU

### Established by running it

- `tb_cpu_mem` builds and runs under GHDL 6.0.0 (mcode) from the bundled
  `upstream/.../cpu/*.vhd` plus `src/fpga/pocket_rtl/cpu/*.vhd`.
- It retires instructions and then stops at `PC = B40128FC`, `retired = 0x136`,
  `errors = 00`, COP0 `cause_live` ExcCode 2 (TLB miss). Adding `errors` and the
  cause to the failure line is the one change made to it.

### Established about the bench itself

- The memory responder answers **every** read — instruction fetch or data load —
  out of the boot-ROM array. So a fetch can return data bytes and a load can
  return an opcode. **The `0xB4012454` landing is not evidence about the CPU.**
- The core routes instruction fetches through its instruction cache
  (`INSTRCACHEON`, tied high by `ki_core_pocket.sv`), which this bench does not
  model.

### Open

- Whether the CPU executes correctly at all, once it has a fetch path a bench
  can actually serve. That needs either `INSTRCACHEON` off end to end or an
  icache model behind `cache_data`/`cache_data_ready`.
- The branch base. The R4000 manual adds the branch offset to the **delay-slot**
  instruction's address; the model's `PCnextBranch` adds it to `PCold0`, the
  fetching instruction's own address. Hypothesis, untested.

### Retracted

- "The CPU jumps to a target instead of the next instruction" — from reading
  opcodes that were data bytes, and addresses built from them.
- "The DSP jump and the CPU failure share a defect." They do not.

## 5. What not to redo

- Do not re-derive the jump encoding from scratch; the retraction above exists
  because that happened twice.
- Do not widen the ADSP PM to 24 bits on the strength of the retired "jumps past
  the page" claim.
- Do not treat `tb_cpu_mem`'s failure as a CPU bug until the bench serves real
  instruction fetches.
- Do not sweep more mailbox words: 18 were tried, none change anything.

## 6. Next work that does not depend on an open question

1. **ADSP setup timing (−3.017 ns).** Needs the MAC cone restructured so the DSP
   block does the multiply and accumulate, and it costs ALMs in a design at
   99 %. Real, measurable with Quartus, independent of the firmware.
2. **SPORT1 autobuffer path.** It has never been exercised with real samples in
   the bench; the DSP never gets there today.
3. **The instruction-fetch bench**, if the CPU is to be trusted at all.
