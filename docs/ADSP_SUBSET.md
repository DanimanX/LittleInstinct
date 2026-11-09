# The DCS opcode subset: what the firmware actually executes

Following [ADSP_ATTACK.md](ADSP_ATTACK.md), which found no cut that frees a LAB,
this asks the different question: **which of the ADSP-2105's instructions does
the Killer Instinct DCS firmware actually execute?** If it is a small subset, the
unused datapath can be deleted — and deleting whole functional units is the only
way to free LABs.

Two things came out of it: a real, reproducible saving, and a smaller subset than
expected.

---

## 1. How the evidence was obtained

`tools/measure/dcs_opcodes.py` reconstructs the ADSP program memory from the
sound-ROM boot page and disassembles it following control flow. Nothing is
executed — no simulator is licensed on this machine (see §6).

Facts taken from the emulator itself (`rtl/dcs/adsp2105.sv`), not a manual, so
the decode matches what the hardware model implements:

- **Boot format** (`S_BOOT`): `pagelen = (rom[3] + 1) * 8` words,
  `PM[j] = {rom[4j], rom[4j+1], rom[4j+2]}`. The sound ROM is the second half of
  the `.rom` image (offset `0x80000`, 4 MiB).
- **Control flow**: `0x14-0x17` DO…UNTIL (body next..target), `0x18-0x1F`
  conditional JUMP/CALL (target `op[17:4]`, `op[18]`=CALL), `0x0A` conditional
  RTS/RTI, `0x0B` indirect jump (not statically resolvable). Everything else
  falls through.

The reconstruction lands exactly on the driver: `PM[0] = 0x18022F` is a JUMP to
`0x022`, skipping the copyright string that occupies words 1..0x21. 342 of the
376 loaded words are reachable; the rest is the string and its padding.

## 2. Only one block of the ROM is code

A top-byte (opcode-class) histogram over the 4 MiB sound ROM, in 64 KiB blocks:

| Region | Class entropy | Verdict |
|---|---|---|
| `0x000000` | **4.92** | code-like (the boot page) |
| `0x010000` … `0x3F0000` | **7.9-7.96** | data: sample ROM, near-random |

Maximum entropy for 256 possible top bytes is 8.0. The rest of the ROM is PCM
data, which is exactly what a DCS board holds — the ADSP plays samples, it does
not execute them. **The entire executable surface of the sound system is one
376-word page.**

## 3. The subset, and it is the same for both games

| | KI1 | KI2 |
|---|---|---|
| Boot page | 376 words | 376 words |
| Reachable | 342 | 342 |
| Instruction classes executed | 41 | 41 |
| Classes identical? | **yes — same set, same counts** | |

KI2 is the same DCS driver code. A subset derived from either covers both.

**Classes never executed** (implemented by the emulator, absent from the driver):

- `0x05` — SAT MR
- `0x06`, `0x07` — DIVS, DIVQ
- `0x0B` — indirect JUMP/CALL
- `0x0E` — immediate data move
- `0x10` — shift + internal register move

**Sub-operations never executed:**

- **Shift modes 4-15**: only LSHIFT modes 0-3 appear. ASHIFT, NORM, EXP, EXPX
  and EXPADJ — the entire normalisation and exponent hardware — are unused.
- **ALU/MAC sub-ops 0, 2, D, E**: 12 of 16 are used, so the MAC and ALU must stay
  whole.
- **All 16 condition codes are used**, so the flag logic must stay whole.

One caveat, recorded because it would otherwise look like a bug: class `0xFF`
appears once, at `pc=0x177`, and it is `0xFFFFFF` filler immediately after a
conditional RTS at `0x176`. The analysis follows the not-taken path there because
it cannot evaluate the condition statically. It is padding, not an instruction.

## 4. What it is worth, measured

Every variant built and fitted in isolation (`build/`), each reproducible to the
exact figure on a repeat run:

| Variant | ALMs | **LABs** | Δ LABs |
|---|---|---|---|
| Baseline (`adsp2105.sv` unmodified) | 8,649 | **1,150** | — |
| Shift modes narrowed to 0-3 (drop ASHIFT/NORM/EXP/EXPADJ) | 8,289 | **1,070** | **−80** |
| ↑ plus SAT MR, DIVS, DIVQ, indirect JUMP removed | 8,187 | **1,083** | **−67** |

**The first cut is a real 80 LABs. The second is not.** Removing more logic
*freed ALMs and consumed more LABs* — 1,070 → 1,083 — and that result reproduced
exactly on a second build. Fewer, differently-shaped cells packed worse. This is
the same lesson as `REENGINEERING.md`: ALM counts are not the currency, and a
change that looks strictly smaller can cost LABs.

Verified for stability: the baseline builds to 8,649 ALMs / 1,150 LABs twice; the
subset builds to 8,187 / 1,083 twice. The numbers are not placement noise.

**Honest conclusion: the usable subset saving is the shifter narrowing — 80 LABs
in isolation, 12 LABs in the full core.**

## 5. What it means at full-core scale

The isolated block saving does not always survive into the full design, so it was
re-measured there (`tools/measure/measure_fit.sh fb-off-no-fpu-shrink`):

| Full core | ALMs | **LABs** |
|---|---|---|
| Framebuffer off chip, FPU stubbed | 17,974 | **1,842 / 1,848** |
| ↑ plus the shifter narrowing | 17,297 | **1,830 / 1,848** |

**−12 LABs in the full core.** The margin goes from 6 LABs to 18. It survives the
move into the whole design — which not every saving does — but it shrinks: 80 LABs
in isolation, 12 in the core, because the core's placement had already absorbed
part of it.

It is the first cut in this entire investigation that frees LABs at all, and it is
worth taking. It is not enough on its own: the framebuffer arbiter, the
write-combining queues and the APF wiring still have to fit in 18 LABs, and they
will not.

What it establishes is the method: **the subset is real, it is small, and it is
the same for both games.** But it also sets the ceiling. There are only 41 live
instruction classes and the unused ones are already dead; the one remaining
datapath saving is the shifter, and it is now measured — 80 LABs isolated, 12 in
the core. **The opcode-subset route is exhausted at 12 LABs.**

## 6. What this evidence is not

**This is static analysis, not execution.** There is no licensed simulator on
this machine: `questa_fse` is installed (`vlog`, `vsim`, `vcom` present) but
`vsim` refuses to start — "Unable to find the license file … Unable to checkout a
license". `iverilog`, `verilator`, `ghdl` and `nvc` are absent.

A dynamic trace would be strictly better evidence, because it would prove
reachability rather than infer it. The static analysis is conservative in the
right direction for *coverage* (it follows both branches of every conditional, so
it over-approximates what can execute — the subset is an upper bound, which is
what a deletion argument needs) but it cannot see code that is loaded later at
runtime by an indirect jump. `0x0B` never appears, so there is no sign of
runtime-loaded overlays, and the data-entropy map in §2 supports that: there is
no second code block in the ROM to load.

Before relying on any of this for a shipping build, run the real firmware and
trap on any instruction outside the subset. The emulator already has the hook:
`o_unimpl` is asserted when an opcode class is not handled, and it is wired to a
counter.

## 7. Continuing

The measured subset changes the shape of a rewrite, not its necessity. A port
that only ever executes 41 classes, four shift modes and 12 ALU sub-ops is a much
smaller machine than a full ADSP-2105 — but the register file, the DAGs, the MAC,
the loop stack, the boot DMA and the SPORT autobuffer are all still needed whole,
and those are the ALM cost.

Next steps, in order:

1. ~~Apply the shifter narrowing to a real ADSP variant and re-measure the full
   core in LABs.~~ **Done: −12 LABs, margin 6 → 18** (§5).
2. Trace the firmware on hardware (once there is hardware) and log every
   `o_unimpl` hit and every class executed, to replace the static subset with a
   measured one.
3. Only then decide whether a subset-targeted rewrite is worth its risk.

---

## Reproducing

```bash
tools/measure/dcs_opcodes.py roms/kinst.rom  --linear --dump 26
tools/measure/dcs_opcodes.py roms/kinst2.rom

export PATH=/opt/intelFPGA/25.1/quartus/bin:$PATH
tools/measure/measure_fit.sh adsp          # isolated block, baseline 8,649 / 1,150
```

Variants from this investigation, under `build/` (git-ignored; patched copies,
never the vendored source):

| Path | Change | ALMs | LABs |
|---|---|---|---|
| `build/adsp`, `build/adsp_rep` | none (baseline, run twice) | 8,649 | 1,150 |
| `build/noshift` | shift modes 4-15 removed | 8,289 | **1,070** |
| `build/nosubset`, `build/nosubset_rep` | + SAT MR, DIVS, DIVQ removed | 8,187 | 1,083 |
| full core, shifter narrowed | via `measure_fit.sh fb-off-no-fpu-shrink` | 17,297 | **1,830** |

Machine-readable subset: `docs/dcs_subset.json`.
