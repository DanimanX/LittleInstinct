# Feasibility: measured, not estimated

Everything here was produced on this machine with Quartus Prime 25.1std.0 Lite
Edition, device `5CEBA4F23C8` (the Analogue Pocket's Cyclone V). Commands are at
the bottom so the numbers can be re-derived.

The point of this file: **the premise in PORTING.md §3 was wrong.** It checked
whether 14 MiB of game memory fits the Pocket's PSRAM (it does) and concluded
feasibility from that. Memory *capacity* was never the binding constraint. What
binds is the FPGA fabric: block RAM and logic cells. Measured, the MiSTer core
does not fit the Pocket.

---

## 1. The Pocket's budget

| Resource | Available |
|---|---|
| ALMs (logic) | 18,480 |
| Block memory | 3,153,920 bits (308 M10K) |
| DSP blocks | 66 |
| PLLs | 4 |
| User I/O pads | 224 |

## 2. The MiSTer core, as upstream ships it

Built unmodified (`KillerInstinct.qsf`, debug build off — `KI_DEBUG_BUILD` is
already commented out upstream), with every output tied so nothing is pruned for
being unobserved. Two synthesis settings, because the setting changes the answer:

| | Aggressive performance | Aggressive area |
|---|---|---|
| ALMs needed | 22,793 / 18,480 (123 %) | **18,547 / 18,480 (100.4 %)** |
| Block memory bits | 3,578,368 / 3,153,920 (113 %) | **3,578,368 / 3,153,920 (113 %)** |
| DSP blocks | 20 / 66 | 20 / 66 |
| Registers | 15,689 | 15,689 |

The reference Pocket port in `references/pocket_saturn_core` builds with
`AGGRESSIVE AREA`, so the right-hand column is the fair comparison. Under it the
logic is **67 ALMs over** — close enough that trimming would find it — and block
memory is **424,448 bits over**, which trimming will not find.

Note also what the first attempt got wrong: an early build with `emu`'s outputs
left dangling reported 13,145 ALMs and 693,760 bits "fitting comfortably". That
was Quartus deleting the CPU, the framebuffer and the ATA controller because
their results went nowhere. A measurement of a partly-pruned design is not a
measurement. Both numbers above come from a build where every output reaches a
pin.

## 3. Where the block memory goes

From the fitter's per-entity table (area build):

| Block | Bits | Share | M10K ≈ |
|---|---|---|---|
| `ki_fb_ram` — the framebuffer | 2,457,600 | 69 % | 240 |
| `ki_dcs_audio` / `adsp2105` | 693,760 | 19 % | 68 |
| `ki_cpu_core` (i-cache, d-cache, tags, TLB) | 292,096 | 8 % | 29 |
| `ki_ata` sector buffer | 65,536 | 2 % | 7 |
| `ki_memory_bridge` boot-ROM cache | 65,536 | 2 % | 7 |
| line buffers, FIFOs, misc | ~4,000 | — | — |
| **total** | **3,578,368** | | ~350 |

The framebuffer alone is two 320×240 RGB555 pages: 2 × 153,600 B. It is 69 % of
the core's block RAM and it does not need to be on-chip at all — see §5.

Take it out and the rest of the core wants **1,120,768 bits (36 % of the
device)**, with room to spare. That is the whole difference between feasible and
not.

## 4. What this changes in the plan

1. **Logic is nearly fine.** 18,547 vs 18,480 ALMs under area optimisation, and
   the Pocket build pays no MiSTer prices: `hps_io` (880 registers, 821 ALUTs),
   the MiSTer video stack (`ascal`, `hq2x`, `scandoubler`, `video_mixer`,
   `gamma_corr`, `shadowmask` — 2,721 ALUTs and 4,364 registers in `ascal`
   alone), the DDR service, the OSD, and the debug overlays all disappear. So the
   real figure to beat is well under 18,480 once the shell is replaced. The 67-ALM
   gap is not the problem.
2. **Block RAM is the problem, and it has one owner.** Any plan that does not
   move the framebuffer off-chip is dead on arrival. PORTING.md §3 asserted the
   framebuffer was "already in block RAM ... so it does not compete for PSRAM" —
   that is exactly backwards: it is the single largest consumer of the resource
   that is over budget.
3. **The Pocket has more board RAM than PORTING.md assumed.** The APF exposes a
   512 Mbit ×16 SDRAM interface (`apf_top.v`, `dram_a[12:0]`/`dram_ba[1:0]`/
   `dram_dq[15:0]`, "sdram, 512mbit x16" in Analogue's own comment) = **64 MB**,
   plus two 32 MiB PSRAM chips. The core needs 14 MiB of game memory + 4 MiB of
   DCS ROM + 300 KiB of framebuffer ≈ 18.3 MiB. It fits in the DRAM alone, with
   3× headroom, and the DRAM is SDR SDRAM — the same protocol `ki_sdram_burst`
   already speaks. Using it is a smaller change than re-plumbing to PSRAM, which
   is a CellularRAM part with burst and latency rules of its own.
4. **The DCS ROM is in the wrong place upstream.** `ki_dcs_audio` pulls its 4 MiB
   through `ki_memory_bridge`'s DDR path. The Pocket has no DDR3; that ROM must
   move to the same DRAM as everything else.

> **Update 2026-11-09 — the analysis below is superseded on two points.**
> A full re-engineering pass ([docs/REENGINEERING.md](REENGINEERING.md)) measured
> what happens when the framebuffer actually leaves the chip. Two corrections:
> (a) the 18,547 ALM figure quoted here is *truncated* — it is where the fitter
> stopped when it hit the block-RAM wall, and the design's real logic cost is
> ~19,590 ALMs; (b) removing the framebuffer frees the block RAM (113 % → 36 %)
> but the logic is still ~1,100 ALMs over, and the lever that closes that is the
> R4600's FPU (~2,466 ALMs, 147 LABs). With both removed the core fits
> (17,127 ALMs, 1,834/1,848 LABs). It is still ~55 LABs short of *including*
> the APF framework, so the answer is "the core fits, the whole machine is a few
> hundred ALMs away" — not "it fits". Read REENGINEERING.md for the measured
> tables and the levers that remain.

## 5. The open engineering question

Moving the framebuffer off-chip costs bandwidth and latency:

- Scanout: `ki_framebuffer` streams a 640-byte line per scanline, once per
  line — 320×240×2 B at 58.98 Hz ≈ **8.9 MB/s**. That is small.
- The CPU: the game blits a 153,600-byte page every frame plus mask-heavy
  shadow/translucency updates. Upstream deliberately gave the framebuffer its own
  RAM port *and* put it in block RAM so that "each of those stores is a single
  cycle". Off-chip it becomes a shared-port transaction, and on a single SDR SDRAM
  that collides with the R4600's own instruction and data fetches.

This is the same failure mode PORTING.md §3 predicted — "the R4600 waits on
memory, and the Saturn port shows exactly that" — it just arrives one resource
earlier than expected: not PSRAM versus SDRAM latency, but block RAM versus
DRAM. The R4600 at 100 MHz with 8 KiB D-cache and 8 KiB I-cache is sensitive to
fetch latency, and `ki_fast_fill` exists upstream precisely because the CPU needs
a direct line-fill path.

Two ways forward, both real:

- **DRAM framebuffer, bank-isolated.** Put the framebuffer in one bank of the
  64 MB DRAM and interleave it with CPU traffic, keeping `ki_fb_ram`'s two-port
  model as a cache in front of it. Preserves upstream's architecture; the
  bandwidth question becomes a row-hit-rate question.
- **Smaller on-chip framebuffer.** A 320×240 8-bit-indexed page is 76,800 B — a
  quarter of the space — if the game's RGB555 palette is captured and indexed. It
  is not a drop-in change (the game writes true-colour words), and it changes
  what the CPU sees, so it is a last resort.

## 6. What was built and what it proves

`src/fpga/` is a Pocket project (`pocket_ki.qpf`) that compiles end to end:

```
quartus_sh --flow compile pocket_ki     # in src/fpga
```

Verified:

- Fitter succeeds: **454 ALMs (2 %), 932 registers, 593,920 block bits (19 %),
  224/224 pins**, top level `apf_top`, device `5CEBA4F23C8`.
- `output_files/pocket_ki.rbf` is produced (1,055,744 bytes).
- The PLL reports what it was asked for: 74.25 MHz reference, 900 MHz VCO,
  50.0 MHz and 100.0 MHz outputs (Quartus's own PLL summary), plus 6.25 MHz
  pixel clock and its 90°-shifted twin.

**Not verified, and this matters:** the milestone-1 build's video output is
almost certainly not a picture. The fitter's per-entity table shows
`ki_framebuffer` reduced to ~63 ALMs with its line-buffer RAMs reduced to zero,
and only one of `ki_fb_ram`'s four pixel banks surviving synthesis. That is the
signature of constant-folded outputs: the scanout chain is being optimised away
because its data never varies. It compiles, fits and produces an RBF, and it
probably shows a blank screen. Treat milestone 1 as "the toolchain, the board
pinout, the clocks and the reset path work", not as "video works".

What is known about it, so the next session does not repeat the search:

- `ki_framebuffer`'s two line RAMs report **0 ALMs and 0 block bits** while the
  module around them keeps 63 ALMs and 69 registers. A RAM that is never read,
  or never written, is deleted; the line buffers are being deleted because
  `write_line = fetch_active && memory_data_valid` never fires or because
  nothing reads them back. The framebuffer's own counters and FSM survive, so
  the reset path and the pixel clock are alive.
- Only `pixel0_bank` of `ki_fb_ram` survives (576,000 bits). Its scanout output
  is 64 bits wide, so this too is consistent with the read path being dead
  rather than with a missing writer.
- Ruled out: `ALTERA_RESERVED_QIS` — `ki_line_buffer` and `ki_ata` instantiate
  their `altsyncram` under that macro with a behavioural `else` branch, and
  Quartus 25.1 does not define it. Adding the macro to the QSF changed nothing
  (0 ALMs before and after), and the fit report names the megafunction instance
  either way, so the real `altsyncram` is present and is being pruned rather
  than never built.
- Ruled out: constant-folded framebuffer outputs. XOR-ing `video_rgb` with
  `h_count` so the output could not be constant left the line buffers at 0 ALMs.

So the fault is in the handshake between `ki_framebuffer`'s
`memory_request`/`memory_data_valid`/`memory_done` FSM and the scanout adapter
in `pocket_rtl/ki_pocket_top.sv` — this port's code, not upstream's. The next
step is to drive that handshake in simulation before trying hardware; there is no
simulator on this machine yet (`verilator`/`iverilog` absent), which is why it
was not caught here.

---

## Reproducing

Feasibility build (the numbers in §2 and §3):

```bash
mkdir -p build/pocket_feas && cd build/pocket_feas
cp -r ../mister/rtl ../mister/KillerInstinct.sv .
mkdir -p sys && cp ../mister/sys/hps_io.sv sys/
# feas.qsf: TOP_LEVEL_ENTITY feas_top, DEVICE 5CEBA4F23C8,
#   files.qip minus rtl/dcs/dcs.qip, plus sys/hps_io.sv, rtl/dcs/dcs.qip, rtl/pll.qip
# feas_top.sv: instantiate `emu`, connect every output to real pins through one
#   reduction so nothing is optimised away.
quartus_sh --flow compile feas
```

The run to compare against: `AGGRESSIVE AREA` in `feas.qsf`. Per-entity numbers
come from `output_files/feas.map.rpt`, section
"Analysis & Synthesis Resource Utilization by Entity".

Pocket project:

```bash
cd src/fpga
quartus_sh --flow compile pocket_ki
sed -n '1,20p' output_files/pocket_ki.fit.summary
```

Requires `QUARTUS_ROOTDIR` on PATH, or
`export PATH=/opt/intelFPGA/25.1/quartus/bin:$PATH`.
