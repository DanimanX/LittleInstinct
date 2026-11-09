# Re-engineering: where the bits and the ALMs actually go

Measured with Quartus Prime 25.1std.0 Lite, device `5CEBA4F23C8` (the Analogue
Pocket), on the upstream Killer Instinct core. Every number below comes from a
fit report, not from arithmetic on source. Variants and log paths are in §7 so
each can be re-run.

This supersedes the "two ways forward" sketch at the end of
[docs/FEASIBILITY.md](FEASIBILITY.md) — that sketch assumed the framebuffer was
the whole problem. It is not, and the measurement below shows why.

---

## 1. The headline

There are **two walls, one behind the other**, and the first was hiding the
second.

| Variant | ALMs | LABs | Block RAM | Fit |
|---|---|---|---|---|
| Upstream, as shipped | 18,547 / 18,480 | 1,848 / 1,848 | **113 %** | ✗ RAM |
| Framebuffer off-chip | **19,590** / 18,480 | 1,981 / 1,848 | 36 % | ✗ logic |
| Framebuffer off-chip, FPU removed | **17,159** / 18,480 | **1,823 / 1,848** | 36 % | ✓ |
| ↑ corrected, with the loader path alive | **17,974** / 18,480 | **1,842 / 1,848** | 36 % | ✓ |

> **The last row is the honest one, and it invalidates the row above it.**
> A harness bug had left the core's ROM-download path pruned (§7), which
> understated the core by ~800 ALMs and by the whole ATA block-device path.
> With that fixed — loader stub driving `ioctl_*`, download completing so the
> R4600 leaves reset (`KillerInstinct.sv:320`: `core_reset = shell_reset |
> ioctl_download | img_reset`) — the core is **17,974 ALMs and 1,842 of 1,848
> LABs: six LABs spare, and no framebuffer arbiter in the sum.** Every
> conclusion below that depends on 17,159 should be read as 17,974.

Read the first two rows together. Removing 2.46 Mbit of block RAM *increased*
the reported ALMs by 1,043. That is not a bug: in the first row the fitter
stopped optimising once it hit the M10K wall, so 18,547 is a truncated figure,
not the design's size. The real logic cost of the core is ~19,600 ALMs, and the
quiet question was never "which is over budget" but "how far over is the part
nobody could see".

So the apportionment of blame changes:

- **Block RAM**: entirely the framebuffer, and entirely fixable by moving it off
  chip. 113 % → 36 %.
- **Logic**: ~1,100 ALMs over, of which one block — the R4600's floating-point
  unit — is worth ~2,466 (measured: the whole design drops 2,466 ALMs and 147
  LABs when the FPU is stubbed).

## 2. Where every bit of block RAM goes

Measured per-entity (area build, framebuffer on chip):

| Block | Bits | Share of core | Note |
|---|---|---|---|
| `ki_fb_ram` (2 × 320×240×16 px) | 2,457,600 | 69 % | two pages, 4 physical banks each |
| `adsp2105` PM + DM + `dcs_mem` | 693,760 | 19 % | 16K×24 PM, 16K×16 DM, 512-line cache |
| `ki_cpu_core` caches + tags + TLB | 292,096 | 8 % | 8 KiB I$, 8 KiB D$, 2-way |
| `ki_ata` sector buffer | 65,536 | 2 % | 8 sectors × 512 B |
| `ki_memory_bridge` boot cache | 65,536 | 2 % | 8 KiB |
| plus line buffers, FIFOs | ~4,000 | — | |
| **total** | **3,578,368** | | 113 % of 3,153,920 |

The framebuffer is a quarter of a megabyte of pixel data held in a resource
where a megabyte costs a fifth of the chip. Nothing else comes close.

## 3. Where every ALM goes

Measured per-entity, framebuffer off chip so the fitter runs to completion
(area optimisation throughout):

| Block | ALMs | Share | What it is |
|---|---|---|---|
| `adsp2105` (DCS sound) | 8,287 | 48 % | ADSP-2105 emulation: sequencer, DAGs, ALU, MAC |
| `ki_cpu_core` | 6,656 | 39 % | R4600 with FPU stubbed: caches, COP0, mul, divider |
| ↳ of which `cpu_FPU` | **~2,466** | 14 % | the FPU, measured as the whole-design delta |
| `ki_memory_bridge` | 1,353 | 8 % | SDRAM/DDR arbitration, download, scanout |
| `dcs_mem` prefetch | 513 | 3 % | 512-line direct-mapped ROM cache |
| `ki_sdram_burst` + adapter + fast fill | 567 | 3 % | SDR SDRAM controller and its wrapper |
| `ki_framebuffer` + timing | 75 | — | counter, line buffer control |
| `ki_ata` | 122 | — | ATA PIO |
| `ki_board_io` | 14 | — | |
| `ki_ata` (with the block path alive) | 318 | 2 % | ATA PIO, up from 122 when pruned |
| **core total** | **17,974** | | 97 % of 18,480 ALMs, 1,842/1,848 LABs |

Two blocks are 87 % of the logic. Everything else together is under 1,800 ALMs.

## 4. The FPU, and why it is the decisive lever

Removing it is worth ~2,466 ALMs and 147 LABs — more than the entire overrun. It is also the
one change here that alters what the machine *is*, so it needs justification,
not just a measurement.

**For removing it:**

- The R4600 shipped in three variants. `R4600PC` and `R4600SC` have no FPU;
  only the full R4600 does. Midway's KI boards used the cost-reduced parts,
  which is why the hardware has no FPU workload to run.
- The core's FPU is inherited baggage, not a decision about KI. The RTL's own
  comments say so indirectly: the CPU arrives with clocks named `clk93` and
  `clk1x` and ~28 signals carrying `_93` / `_1x` suffixes, which the upstream
  source explains are "from the N64 core this CPU is derived from" and are
  "wrong here". The FPU came along with the same import.

**Against, honestly:**

- I could not confirm from the software that KI never executes a COP1
  instruction. A static scan of `roms/kinst.rom` was **inconclusive and I am not
  treating it as evidence**: the boot image is not flat MIPS (30 % of it is
  zeros, the rest is high-entropy data, and every opcode including `LUI` and
  `LW` appears at close to the uniform 1/64 rate). The game code lives on the
  hard disk image, which I did not scan. A disassembler following the reset
  vector would answer it; none is installed here.

So: the hardware strongly suggests no FPU, the RTL structure suggests nobody
ever checked, and the software is unverified. Treat removal as the plan and
**the FPU's first job on hardware as a test** — the core already exposes
`error_FPU` and folds it into `cpu_errors`, so a Reserved-Instruction trap on
COP1 will show up rather than corrupt silently.

A port-identical stub is at `tools/measure/cpu_FPU_stub.vhd`; it is a measurement
artefact, not a proposal to ship it as-is. The shipping version would keep the
register file and the transfer/CSR instructions (so `mfc1`/`mtc1`/`cfc1` and the
FCR still behave) and trap only on arithmetic — which costs far less than the
2,466 ALMs of datapath being deleted.

> **Correction, measured after the fact: LABs bind, not ALMs.** The Pocket's
> 18,480 ALMs are arranged in 1,848 LABs of 10, and Quartus's "Total LABs:
> partially or completely used" is the hard wall. A later variant that saved
> **564 ALMs freed exactly zero LABs** — the saving vanished into already-used
> LABs. Every ALM percentage in this document overstates the headroom. Read the
> LAB figures: the core sits at **1,842 of 1,848**. See
> [ADSP_ATTACK.md](ADSP_ATTACK.md) §1.

## 5. The budget, honestly

The 17,159 ALM figure is a **floor**, not the finished system. It is the core
alone, with the framebuffer's storage deleted outright. It does not include:

- the APF framework (`apf_top`, `core_top`, bridge, pad controller) — measured
  separately at **69 LABs** in the real Pocket build;
- an arbiter and queues between the framebuffer clients and PSRAM/DRAM. The
  nearest reference, the Saturn port's `psram0_arb` + queues, is ~1,900 lines of
  glue; it will not be free;
- the ATA → deferred-data-slot adapter.

Arithmetic on the measured figures:

```
core, framebuffer off chip, no FPU      1,842 LABs   (6 spare of 1,848)
  ...including a loader stub standing in for the APF bridge
framebuffer arbiter + queues            not counted, not written
                                        -------------
                                        already at 99.7 % of the LABs
```

**It does not fit.** The core alone — framebuffer banished, FPU stubbed, a
loader stub where the APF bridge will go — lands on 1,842 of 1,848 LABs. Six
LABs. And the memory arbiter, the write-combining queues and the framebuffer
line-cache that make an off-chip framebuffer workable are not merely uncounted:
they do not exist yet, and the nearest reference implementation is ~1,900 lines
of the Saturn port's glue. Six LABs will not hold them.

Honest verdict: **the core fits with nothing to spare, and the machine does
not.**

That is the real answer to "can it be made to fit": **the core fits, barely, and
the gluing needed to make the off-chip framebuffer real does not.** The gap is a
few hundred ALMs — and [ADSP_ATTACK.md](ADSP_ATTACK.md) measures the largest
remaining block and finds only ~400 ALMs of behaviour-preserving savings in it.
The gap and the available savings are the same order of magnitude, which makes
this a design change rather than a trimming exercise.

## 6. Levers left, largest first

Nothing here is free; each costs behaviour or fidelity. Ordered by measured or
estimated value:

1. **`adsp2105` — 8,287 ALMs, 48 % of everything. Attacked and measured:
   see [ADSP_ATTACK.md](ADSP_ATTACK.md).** Every behaviour-preserving cut was
   built and fitted in isolation. The total available is ~400 ALMs (268 from
   removing per-store diagnostics, 131 from halving the ROM prefetch cache);
   synthesis settings gave exactly zero; and the two large numbers that appear
   possible are artefacts of pruning the state they operate on. The block cannot
   be reduced enough to close the gap without rewriting the emulator.
2. **`ki_memory_bridge` — 1,353 ALMs.** On MiSTer it serves SDRAM *and* DDR3
   (the DCS ROM is streamed from DDR3). The Pocket has no DDR3: moving the DCS
   ROM into the same DRAM as everything else deletes that whole path, which is
   the cheapest real saving available and is required by the memory plan anyway.
3. **`dcs_mem` prefetch cache — 513 ALMs at 512 lines.** Halving it to 256 lines
   should return a few hundred ALMs for more ROM-cache misses. `PF_LINES` is
   already a parameter; this is a knob, not a rewrite.
4. **`ki_sdram_burst`/adapter — 567 ALMs.** These speak SDR SDRAM, which is
   exactly what the Pocket's 64 MB `dram_*` interface is, so much of this may
   survive rather than need replacing. Worth keeping rather than rewriting.
5. **Register packing.** `ALM_REGISTER_PACKING_EFFORT` and
   `AUTO_PACKED_REGISTERS_STRATIXII` together moved 3 ALMs across the whole
   design. Measured, and worthless. Not a lever; recorded so nobody spends a day
   on it.

## 7. Reproducing every number

The whole experiment is scripted, because it was run by hand first and a
hand-run measurement cannot be checked:

```bash
tools/measure/measure_fit.sh baseline        # upstream, untouched
tools/measure/measure_fit.sh fb-off          # framebuffer off chip
tools/measure/measure_fit.sh fb-off-no-fpu   # + R4600 FPU stubbed
tools/measure/measure_fit.sh all             # all three
```

Each variant assembles a throwaway tree under `build/measure/<variant>/` from
copies of `upstream/` — the vendored source and `src/fpga/` are never touched —
applies that variant's patches, compiles, and prints the fit summary. 6–10
minutes per variant. `PREPARE_ONLY=1` stops after patching so the tree can be
inspected without paying for a compile.

What each patch does, and how the harness avoids lying to itself:

| Effect | How |
|---|---|
| Framebuffer out of block RAM | `KI_FB_OFFCHIP=1`: `ki_memory_bridge.sv` `FB_WORDS` 38400 → 640 |
| Framebuffer out entirely | `KI_FB_BYPASS=1`: the `ki_fb_ram` instance replaced by two zero assignments |
| FPU removed | `cpu.vhd`: `entity work.cpu_FPU` → `cpu_FPU_stub` (port-identical stub, `tools/measure/cpu_FPU_stub.vhd`) |
| Area, not speed | `OPTIMIZATION_MODE "AGGRESSIVE AREA"`, as every real Pocket port uses |
| Nothing pruned | `tools/measure/feas_top.sv` ties every `emu` output to a pin through one reduction, and drives every input |

### Three ways this measurement lied before it was trustworthy

Each of these produced a plausible-looking, wrong number. They are listed
because the numbers they produced were *smaller*, which is the direction that
makes a hopeless design look feasible.

1. **Dangling outputs.** An early harness left `emu`'s outputs unconnected.
   Quartus deleted the CPU, the framebuffer and the ATA controller and reported
   a comfortable 13,145-ALM "fit". Fixed by
   `tools/measure/feas_top.sv`, which routes every output to a pin through one
   reduction.
2. **An undriven `HPS_BUS`.** With the real `hps_io` instantiated but its bus at
   `z`, `ioctl_download` never asserted and the whole ROM-download path was
   pruned out of `ki_memory_bridge` — measurable as `hps_io` and every `ioctl_*`
   signal absent from the fit report. Fixed by
   `tools/measure/hps_io_stub.sv`, which drives the loader interface from
   counters.
3. **A stub that held the CPU in reset.** The first stub asserted
   `ioctl_download` permanently. `KillerInstinct.sv:320` is
   `core_reset = shell_reset | ioctl_download | img_reset`, so the R4600 never
   came out of reset, every register became constant, and the CPU vanished:
   8,712 ALMs and 2 DSP blocks instead of 17,974 and 22. Fixed by bounding the
   download to one pass of the 4.5 MiB image.

Lesson worth carrying: for this design, a number that looks good should be
distrusted first. Verify the CPU is present per-entity (`ki_cpu_core` at
~7,000 ALMs, `ki_dcs_audio` at ~8,200) before believing any total.

Per-entity tables are the "Fitter Resource Utilization by Entity" section of
`build/measure/<variant>/feas.fit.rpt`; synthesis-time tables are in
`feas.map.rpt`.

Note on `AUTO_RAM_TO_MLAB_CONVERSION`: it is not an assignment name Quartus
accepts; the real one is `BLOCK_RAM_TO_MLAB_CELL_CONVERSION`, and turning it
off changed nothing (1,981 → 1,978 LABs). `RamMLAB.vhd` pins `ram_block_type`
to `"MLAB"` by hand, and simply changing it to `"M10K"` **fails to elaborate**:
Cyclone V M10K cannot do the asynchronous read that `altdpram` uses, so that
path would need a registered address and an extra cycle of latency in the R4600
cache. Recorded because it looks like free ALMs and is not.

## 8. What this means for the port

The plan from here, in order:

1. Framebuffer to DRAM. Not optional: it is the only way block RAM fits, and it
   also removes the coherency question by making the DRAM copy authoritative.
2. FPU: stub it, and wire `error_FPU` to something visible so hardware answers
   the software question the disassembler could not.
3. Collapse the bridge's DDR3 path into the DRAM path (saving 2 above).
4. Then measure again. The gap should be within the prefetch-cache and
   bridge-trim levers; if it is not, the ADSP is the only block left that can
   pay, and that is a decision to take deliberately, not by accident.
