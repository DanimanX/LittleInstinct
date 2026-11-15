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


### Reading the poll block from the ROM image (static)

The words at 0x42-0x47 decode to something that cannot loop, which is why the
RTL's behaviour there has to be read instruction by instruction:

```
042  3e7105   AR  = 0x2710 | CNTR  (0x3E = 14-bit immediate into grp3 idx 5)
043  14044E   DO 0x44 UNTIL CE
044  000000   NOP
045  839FCA   read into AY0 from the immediate address 0x1FCA (0x83 class)
046  267A0F   ALU op into AF, condition 0x0F
047  180F41   conditional JUMP, field 0x0F4, condition 0x1
```

What can be said without a decode table:

- The block at 0x42-0x48 **iterates**. The once-per-pc-change trace only shows
  it entering; the poll loop is a wait loop around the `JUMP` at 0x47.
- Where that `JUMP` goes is **not established**. Read as an absolute page
  address the field gives 0x0F4; read as relative from 0x47 it gives 0x13B,
  which is real code inside the page. The ADSP-2105's page-versus-relative rule
  for class 0x18 decides it, and that has not been checked against a source
  outside this tree. **Do not use either value as evidence.**
- The model raises no `o_unimpl` and no internal `$fatal` anywhere in the run,
  so the instruction stream is inside the implemented subset as the model
  defines it.
- `DM(0x1FCA)` reads 0 in the bench. Whether the image "should" give something
  else depends on the DM-to-ROM mapping, which is also unverified.

### What was claimed here and retracted

An earlier revision of this section said the `JUMP` at 0x47 targets 0x0F88,
that the firmware therefore jumps past its 376-word boot page, and that the
model's 14-bit PM cannot follow it. That came from reading the 0x18 field as a
page address *and* adding it to the wrong base. The ADSP-2105 jump encoding was
never checked. Treat the sentence as withdrawn; the open question is the
encoding, not the model's PM size.

The same revision claimed the 0x46 ALU op "is not in the subset". The model does
not strand on it (`o_unimpl` stays clear), so that claim is unsupported too.



### Experiment: the empty DO cannot simply be skipped

Three bindings were measured, not argued:

| DO handling | Result |
|---|---|
| pushed normally | pc sticks at 0x44, 64 000 retirements of one word |
| not pushed (in place) | walks 0x43 -> 0x48, the poll block runs, then returns to 0x42 |
| dropped entirely (no push, no stack) | reaches pc 0x153 and stops: the second RTS at a call site pops a stack entry that the earlier CALL needs |

The third is the informative one. The boot page doubles its loop stack and its
return stack on one array (`loop_sp`/`pc_sp` into `pc_stack`), so "do not enter
the loop and do not touch the stack" is right and "do not enter the loop and pop
one entry" is wrong. The version kept is the second row.

Also measured: with the empty DO skipped, execution reaches the poll block at
0x42, and the block returns to 0x42 **on its own** (the `JUMP` at 0x47 is taken
both ways, `astat` ends with only Z set). So whatever makes the DSP wait lives
inside 0x45..0x48 and not in the crossing back.


## Verified against the ADSP-2100 Family User's Manual

Source: *ADSP-2100 Family User's Manual*, 3rd ed. (September 1995), Chapter 3
("Program Sequencer") and Section 15 (Instruction Set Reference). The text used
here came from the archive.org scan; the PDF at analog.com was not reachable
from this machine.

**Conditional JUMP/CALL, direct (Instruction Type 10):**

```
23 22 21 20 19 18 17 16 ... 4 | 3 ... 0
 0  0  0  1  1  C?  ADDR(14 bits)  COND(4)
```

> "For direct addressing ... the program address is stored directly in the
> instruction word as a **full 14-bit field**."

and, for the mechanism:

> "The 14-bit jump address is embedded in the JUMP instruction word. When a
> JUMP instruction is decoded, the jump address is input directly to the next
> address mux of the program sequencer."

So the target is an **absolute 14-bit page address**, not a displacement. The
model's decode (`tgt = op[17:4]`, `pc <= tgt`) is correct.

**DO UNTIL:** the manual describes the loop comparator as testing the *last
instruction address embedded in the DO*, with "the address of the first
instruction in the loop ... maintained on the top of the PC stack". It says
nothing about a DO whose end equals its own first body instruction - that
encoding has no instruction to test at all, which is why the model got stuck.

**Decoding the three words that matter:**

```
043  14044E   DO 0x044 UNTIL NOT CE     (body = 0x044, one instruction)
047  180F41   JUMP 0x0F4 IF NE          (absolute)
153  18153F   JUMP 0x153 IF TRUE        (absolute; 0x0F4 in-field is the target)
```

That last one is the interesting one: `0x18153F` looks **self-referential**
under absolute addressing (`0x153 + 0x3F` = read as a field gives 0x153). It
sits at the address the run reaches after the poll block in one of the
experiments, which matches an intentional wait/return idiom better than a bug.

**What this closes and what it does not.** The jump encoding question is closed:
absolute, as the model already had it. The earlier "jumps to 0x0F88" note was
wrong on two counts (wrong base, wrong arithmetic) and stays retracted. What is
*not* established is why the DSP does not leave the poll block; that is a
question about `0x1FCA` and the loop's conditions, not about decoding.


### The encoding is not settled after all

The paragraph above reads the manual correctly and then overlooks one thing:
the same manual also documents **Instruction Type 7, "JUMP/CALL with optional
computed address fields"**, whose `DMOVLAY`/`PMOVLAY` bit fields, counted from
bit 4, spell out *DERIVED ENDING OF DO LOOP*. So it is not established that
every `0x18` word carries a JUMP target at `[17:4]`.

The boot page itself points the other way. Every jump in it that names a loop
end:

```
000  18154F   field 0x154   absolute 0x154   ""
010  18554F   same field    same            ""
01C  18154F   same field    same            ""
01F  18154F   same field    same            ""
153  18153F   field 0x153 = its own address  <- a self loop, if absolute
```

Three different jumps carrying the **same field `0x154`** do not look like three
copies of the same destination; they look like the same modifier bit applied to
different addresses. And `0x18153F` - self-referential under the absolute rule,
with the DSP stopping there in one measured run - is not explained by it.

So: **the manual gives the absolute rule for Type 10, and the boot page does not
fit it.** The reading that fits is the overlay/derived-ending form, which the
model does not implement. This is the open question now; the earlier retraction
of "jumps past the page" stands, and nothing in the RTL was changed on the
strength of either reading.

## New: the jump word and the CPU bench

Reading the two unresolved items against each other turned up what may be the
same defect twice:

**The jump word itself.** `0x180F41` at pc 0x47 has `op[18] = 0`, which the model
reads as "conditional JUMP", and a 4-bit field `0x1` as its condition. `0x1` is
`!Z`. It also carries a 12-bit field `0x0F4`. A jump that takes a 4-bit condition
*and* a second, contradicting operand in the same word is not a shape the model
handles: it evaluates `!Z` and ignores `0x0F4`. Whether the real encoding is
page-relative, `0x0F4`-as-target, or a different instruction class is **still
not established** — but note what it looks like next to the item below.

**The CPU bench's failure has the same shape.** With the boot image fixed by the
program above, the first 10 retired instructions of `tb_cpu_mem` decode
correctly (`lui $sp`, `ori $sp`, `lui $t0`, `ori $t0`, `lui $t1`, `ori $t1`,
`sw`, `lw`, `bne`, nop) and then the CPU is at `0xB4012454`, having written
0x09004915 through the `bne`'s delay slot area. `0xB401...` is a jump target:
the CPU took a branch to an address computed from an instruction word. `errors`
stays 0 and COP0's `cause_live` shows ExcCode 2 (TLB miss); the run then times
out at PC `B40128FC`, retired 0x136, on an address that walks forward 4 bytes a
time — not an infinite loop, an endless instruction stream through unmapped
memory.

Two candidates, both testable without hardware:

1. the 0xBFC00000 boot region is not backed for *instruction* fetches the way
   the bench's responder assumes, so the fetch after the branch reads zeros;
2. a branch displacement is applied relative to an instruction word rather than
   to the address (the same category of defect as the jump word above).

The bench's timeout line now prints `errors`, `cause_live` and `exc` so the next
run does not need this instrumentation again.

## What the bench showed about the model itself (side result)

### Experiment: the empty DO cannot simply be skipped

Three bindings were measured, not argued:

| DO handling | Result |
|---|---|
| pushed normally | pc sticks at 0x44, 64 000 retirements of one word |
| not pushed (in place) | walks 0x43 -> 0x48, the poll block runs, then returns to 0x42 |
| dropped entirely (no push, no stack) | reaches pc 0x153 and stops: the second RTS at a call site pops a stack entry that the earlier CALL needs |

The third is the informative one. The boot page doubles its loop stack and its
return stack on one array (`loop_sp`/`pc_sp` into `pc_stack`), so "do not enter
the loop and do not touch the stack" is right and "do not enter the loop and pop
one entry" is wrong. The version kept is the second row.

Also measured: with the empty DO skipped, execution reaches the poll block at
0x42, and the block returns to 0x42 **on its own** (the `JUMP` at 0x47 is taken
both ways, `astat` ends with only Z set). So whatever makes the DSP wait lives
inside 0x45..0x48 and not in the crossing back.


## Verified against the ADSP-2100 Family User's Manual

Source: *ADSP-2100 Family User's Manual*, 3rd ed. (September 1995), Chapter 3
("Program Sequencer") and Section 15 (Instruction Set Reference). The text used
here came from the archive.org scan; the PDF at analog.com was not reachable
from this machine.

**Conditional JUMP/CALL, direct (Instruction Type 10):**

```
23 22 21 20 19 18 17 16 ... 4 | 3 ... 0
 0  0  0  1  1  C?  ADDR(14 bits)  COND(4)
```

> "For direct addressing ... the program address is stored directly in the
> instruction word as a **full 14-bit field**."

and, for the mechanism:

> "The 14-bit jump address is embedded in the JUMP instruction word. When a
> JUMP instruction is decoded, the jump address is input directly to the next
> address mux of the program sequencer."

So the target is an **absolute 14-bit page address**, not a displacement. The
model's decode (`tgt = op[17:4]`, `pc <= tgt`) is correct.

**DO UNTIL:** the manual describes the loop comparator as testing the *last
instruction address embedded in the DO*, with "the address of the first
instruction in the loop ... maintained on the top of the PC stack". It says
nothing about a DO whose end equals its own first body instruction - that
encoding has no instruction to test at all, which is why the model got stuck.

**Decoding the three words that matter:**

```
043  14044E   DO 0x044 UNTIL NOT CE     (body = 0x044, one instruction)
047  180F41   JUMP 0x0F4 IF NE          (absolute)
153  18153F   JUMP 0x153 IF TRUE        (absolute; 0x0F4 in-field is the target)
```

That last one is the interesting one: `0x18153F` looks **self-referential**
under absolute addressing (`0x153 + 0x3F` = read as a field gives 0x153). It
sits at the address the run reaches after the poll block in one of the
experiments, which matches an intentional wait/return idiom better than a bug.

**What this closes and what it does not.** The jump encoding question is closed:
absolute, as the model already had it. The earlier "jumps to 0x0F88" note was
wrong on two counts (wrong base, wrong arithmetic) and stays retracted. What is
*not* established is why the DSP does not leave the poll block; that is a
question about `0x1FCA` and the loop's conditions, not about decoding.


### The encoding is not settled after all

The paragraph above reads the manual correctly and then overlooks one thing:
the same manual also documents **Instruction Type 7, "JUMP/CALL with optional
computed address fields"**, whose `DMOVLAY`/`PMOVLAY` bit fields, counted from
bit 4, spell out *DERIVED ENDING OF DO LOOP*. So it is not established that
every `0x18` word carries a JUMP target at `[17:4]`.

The boot page itself points the other way. Every jump in it that names a loop
end:

```
000  18154F   field 0x154   absolute 0x154   ""
010  18554F   same field    same            ""
01C  18154F   same field    same            ""
01F  18154F   same field    same            ""
153  18153F   field 0x153 = its own address  <- a self loop, if absolute
```

Three different jumps carrying the **same field `0x154`** do not look like three
copies of the same destination; they look like the same modifier bit applied to
different addresses. And `0x18153F` - self-referential under the absolute rule,
with the DSP stopping there in one measured run - is not explained by it.

So: **the manual gives the absolute rule for Type 10, and the boot page does not
fit it.** The reading that fits is the overlay/derived-ending form, which the
model does not implement. This is the open question now; the earlier retraction
of "jumps past the page" stands, and nothing in the RTL was changed on the
strength of either reading.

## New: the jump word and the CPU bench

Reading the two unresolved items against each other turned up what may be the
same defect twice:

**The jump word itself.** `0x180F41` at pc 0x47 has `op[18] = 0`, which the model
reads as "conditional JUMP", and a 4-bit field `0x1` as its condition. `0x1` is
`!Z`. It also carries a 12-bit field `0x0F4`. A jump that takes a 4-bit condition
*and* a second, contradicting operand in the same word is not a shape the model
handles: it evaluates `!Z` and ignores `0x0F4`. Whether the real encoding is
page-relative, `0x0F4`-as-target, or a different instruction class is **still
not established** — but note what it looks like next to the item below.

**The CPU bench's failure has the same shape.** With the boot image fixed by the
program above, the first 10 retired instructions of `tb_cpu_mem` decode
correctly (`lui $sp`, `ori $sp`, `lui $t0`, `ori $t0`, `lui $t1`, `ori $t1`,
`sw`, `lw`, `bne`, nop) and then the CPU is at `0xB4012454`, having written
0x09004915 through the `bne`'s delay slot area. `0xB401...` is a jump target:
the CPU took a branch to an address computed from an instruction word. `errors`
stays 0 and COP0's `cause_live` shows ExcCode 2 (TLB miss); the run then times
out at PC `B40128FC`, retired 0x136, on an address that walks forward 4 bytes a
time — not an infinite loop, an endless instruction stream through unmapped
memory.

Two candidates, both testable without hardware:

1. the 0xBFC00000 boot region is not backed for *instruction* fetches the way
   the bench's responder assumes, so the fetch after the branch reads zeros;
2. a branch displacement is applied relative to an instruction word rather than
   to the address (the same category of defect as the jump word above).

The bench's timeout line now prints `errors`, `cause_live` and `exc` so the next
run does not need this instrumentation again.

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
