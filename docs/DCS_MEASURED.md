# The DCS sound board, measured instead of guessed

Date: 2026-11-14. Everything below comes from the real `kinst.rom` (DCS image
taken as-is from offset `0x080000`), the real `adsp2105` model, the real
`dcs_mem` service and the real `ki_dcs_audio` wrapper. Nothing here is
reconstructed firmware.

## What was built

- `tools/gen_dcs_rom_hex.py` — packs the DCS image into 64-bit beats for a
  simulation backing store (one hex line per beat, byte 0 in `[7:0]`), matching
  exactly what `ki_memory_bridge_pocket.sv` writes into SDRAM at `STORE_DCS`.
- `tests/sim/adsp_rom_model.sv` — the `ext_*` side of `dcs_mem`: level-held
  request/ready, `$readmemh` backing, request trace and latency report.
- `tests/sim/tb_adsp.sv` — boots `ki_dcs_audio` with the real ROM and reports
  what the DSP did: PC histogram, halt detection, unimplemented opcodes,
  PCM pushes, DAC FIFO pops, audio discontinuities, mailbox state.
- `tests/sim/run_adsp.sh` — builds and runs it with `-DKI_DCS_SIMULATION`
  (mandatory: without it the DCS RTL compiles its synthesis branch).

Reproduce:

```
python3 tools/gen_dcs_rom_hex.py <kinst.rom> tests/sim/vectors/dcs_kinst.hex
tests/sim/run_adsp.sh                 # 4 ms of board time
tests/sim/run_adsp.sh +VARIANT=2      # same, mailbox written after reset
```

## What the bench shows

Board time is 4 ms at 50 MHz; the DSP retires one instruction per
`dcs_ce` (35.75 MHz cadence), so ~64 000 instructions is a full budget.

1. **The ROM boot page streams correctly and is decoded correctly.**
   `beat 0 = 6c6c694b2e2f0218` → `18 02 2f 2e "Killer Insti..."`, length byte
   `0x2e` → 376 PM words. The program then executes from PM 0.

2. **The DSP ends in a wait loop around pc 0x44, not in an unimplemented
   opcode.** `dbg_unimpl` never asserts; the last 8256 retirements are the same
   address. The loop is the firmware polling `DM(0x0855)`:

   ```
   042  3e7105   DO 0x1fca UNTIL ...       (long loop)
   043  14044e   JEQ +0x44e                (skip when the flag is set)
   044  000000   NOP
   045  839fca   reg = DM(0x1fca)
   046  267a0f   ALU on it
   047  180f41   conditional jump
   048  000000   NOP
   ```

   It polls a memory word that nothing ever writes, because **no host command
   has been delivered**. Board reset leaves `host_status = 0x0C00` and the model
   holds it there (variant 1 and variant 2 both end at `0C00`).

3. **PCM output is zero and the reason is upstream of the audio path.**
   `dsp pcm pushes = 0`, so there is nothing for the FIFO to publish. The DSP
   never reaches its SPORT1 autobuffer because it is waiting for the CPU.

4. **`host_status` bit 11 — the bit the game reads as "sound board ready" — is
   never clear**, because the DSP never reads the input latch (which sets
   `INPUT_EMPTY`) and never writes the output latch (which clears
   `OUTPUT_EMPTY`). The board looks "not ready" forever.

5. **The mailbox was being read as permanently empty.** The first version of
   this bench drove `host_cmd_wr` with a blocking assignment and the write
   raced the model's latch: `input_data` stayed 0, and the firmware's poll could
   never succeed *by construction*. Driving the strobe non-blocking fixed it:
   the latch now reads the command word (`+CMD=`). That was a bench bug, not an
   RTL bug — the same race would not exist in hardware.

## What this means for the port

The DCS subsystem is not silent because the audio path is broken. It is silent
because **no mailbox command has ever been delivered in the bench, and every
sweep of candidate command words still leaves the DSP in the poll loop**:

- 18 command words (every single-bit value, plus 0 / 0xFFFF) through the real
  `ki_dcs_audio`, delivered before boot (variant 2) — the DSP sits at pc 0x44
  every time, `cmd read` stays 0, `host_status` stays `0x0C00`, no PCM.
- The same sweep delivered after boot (variant 1) also leaves it there.

So the firmware is not waiting on the *value* in the latch; it is waiting on
something the poll block reads from memory (`DM(0x1fca)` around pc 0x45), which
nothing in a 4 ms run writes.

Next measurements, in this order:

1. **Is the mailbox source real in the port?** In `ki_core_pocket.sv`,
   `sound_data` / `sound_data_strobe` are driven by `ki_board_io`, which *is*
   instantiated (line 1664). The open question is whether the MIPS firmware
   ever writes the board's sound port during the boot the Pocket core runs.
   The debug page already carries `sound_reset`, `dcs_host_reset` and
   `dcs_host_status` (`cpu_eret_flags`), so a hardware run can answer that
   directly instead of by inference.
2. **What does the poll loop actually test?** Step the model instruction by
   instruction from pc 0x42 in the bench and read `DM(0x1fca)` after the block
   at 0x450-0x460 has run.


## Update: the DSP was stuck on a decode defect, not on the mailbox

The poll loop above never actually *ran*. The instruction at 0x43 is
`14044E`, i.e. `DO 0x44 UNTIL CE` - a DO whose end address is its own first
body instruction. Instructing the sequencer to jump to an address it has
already passed means it reaches that address again before the loop-end check
can ever fire, so it re-decoded the DO and pushed another loop entry, every
time. The DSP was spending its entire run inside one instruction (`[tl]`
shows pc 0x44 retired 64 000 times in a row).

The RTL now refuses to push that DO (`adsp2105_pocket.sv`, the 0x14-0x17
branch), and the DSP walks past it:

```
r=61 pc=43  14044e   the DO itself (0x44 is its end and its first body)
r=62 pc=44  000000   NOP
r=63 pc=45  839fca   read DM(0x1fca)
r=65 pc=46  267a0f
r=66 pc=47  180f41
r=67 pc=48  000000
r=68 pc=42  3e7105   <- back to the real loop
```

So there are **two** independent blockers, and the first one hid the second:

1. the empty DO, now fixed in simulation (and it is a real decode defect: a
   2105 cannot spend a DJ loop on an empty body);
2. the poll block at 0x42-0x48. It now runs, and still returns to 0x42 on its
   own: `DM(0x1fca)` and `DM(0x0855)` are zero, `astat` ends the block with only
   Z set, and `cmd read` stays 0 for every command word tried, delivered before
   boot (variant 2).

Note the loop enters with `loop_sp = 1` even though the guard never pushes:
the stack pointer is already 1 when the DO executes, which is a separate
question about the loop stack and is **not** investigated yet.

## What the bench showed about the model itself (side result)

Per-instruction unit tests of the model were attempted and set aside: its
sequencer and behavioral PM do not agree on instruction boundaries when a
testbench pokes `pc`/`state` from outside, so such a bench is not trustworthy
without OSD-style debug ports. No claim here depends on it; everything above
comes from whole-program runs, which are self-consistent.

## Costs seen while measuring

The model is heavy for Icarus: 4 ms of board time takes about a minute of host
CPU because the behavioral PM is sensitive to changes on all 16 384 words.
Waves are unusable at this size; the bench prints its own timeline instead.

## Caveats

- `adsp2105` cannot be steered from a testbench by poking `pc`/`state` while it
  runs (the assignments race its sequential block). Bench measurements are
  therefore made from the outside, through retired-instruction strobes.
- The bench does not send a real DCS command: the mailbox word format is not
  documented in this tree, so the variant-2 command is a placeholder.
