# Killer Instinct → Analogue Pocket: porting analysis

Upstream: `upstream/Arcade-KillerInstinct_MiSTer` (MiSTer-devel, GPL-3.0, vendored at
commit 098f0d6-era head, 2026-11-09). ~43.400 lines of Verilog/SystemVerilog/VHDL.

**This is not a port yet**, but as of 2026-11-09 the feasibility question has been
answered with the toolchain rather than from the source alone, and the answer
overturned §3. Quartus 25.1 Lite now exists on this machine, the upstream core has
been synthesised and fitted against the Pocket's device, and it does not fit: the
block memory is 113 % and the logic 100.4 % under area optimisation. The binding
constraint is the framebuffer's 2,457,600 bits of block RAM, not the game memory the
original §3 analysed. See [docs/FEASIBILITY.md](docs/FEASIBILITY.md) for the numbers,
the per-block breakdown and the options.

---

## 1. What the core is made of

| Block | Files | Notes |
|---|---|---|
| R4600 MIPS III CPU | `rtl/ki_cpu_core.vhd` (36 KB) | MiSTer-independent |
| Memory bridge | `rtl/ki_memory_bridge.sv` (75 KB) | SDRAM + ROM streaming |
| SDRAM PHY/controller | `ki_sdram_adapter`, `ki_sdram_burst`, `ki_sdram_x2`, `ki_sdram_bist` | MiSTer SDRAM pins |
| DCS audio | `rtl/ki_dcs_audio.sv` + `rtl/dcs/` | ADSP-2105 engine, MiSTer-independent |
| Video | `ki_video_timing`, `ki_framebuffer`, `ki_fb_ram`, `ki_fast_fill` | framebuffer in BRAM |
| ATA/HDD | `rtl/ki_ata.sv` (28 KB) | MiSTer block-device interface |
| Board glue | `ki_board_io`, `ki_board_pkg`, `ki_keyboard`, `ki_pause`, `ki_fps_overlay`, `ki_debug_screen` | mixed |

## 2. MiSTer-only dependencies to replace

| Upstream dependency | Where | Pocket replacement |
|---|---|---|
| `hps_io` (ioctl download, OSD, SD block device) | `KillerInstinct.sv` | APF data slots + `core_bridge_cmd` |
| `SDRAM_A/BA/DQ/CKE/nCAS/...` physical pins, 25-bit space | `KillerInstinct.sv:88-108` | PSRAM via `psram_phy` (CellularRAM 1.5) |
| `HPS_BUS` (MT32-pi, SS, etc.) | `KillerInstinct.sv` | not needed |
| `sys/` (`ascal`, `hq2x`, `scandoubler`, `shadowmask`, `spdif`, `vga`/`hdmi` PLLs) | `sys/` | APF video bridge + I2S |
| `osd.v` / `status[]` settings | throughout | `interact.json` + Core Settings |
| `sd_lba`/`sd_rd`/`img_size` block API | `rtl/ki_ata.sv` | deferred data slot, random reads |

`sys/` (1.3 MB) is almost entirely discardable. The reusable part is the RTL in
`rtl/` plus `KillerInstinct.sv`'s instantiations.

## 3. Memory budget — the actual number

From `rtl/ki_board_pkg.sv` and `rtl/ki_memory_bridge.sv`:

| Region | Offset | Size | Ends |
|---|---|---|---|
| low RAM (incl. 2 framebuffer pages) | `0x000_0000` | 512 KiB | `0x008_0000` |
| main RAM (8 MiB, A23 aliased) | `0x010_0000` | 8 MiB | `0x090_0000` |
| boot ROM copy | `0x090_0000` | 512 KiB | `0x098_0000` |
| DCS sound ROM | `0x0A0_0000` | 4 MiB | `0x0E0_0000` |

**Total: 14 MiB (0x0E00_0000).** The decode space is 25 bits (32 MiB).

Pocket PSRAM, from `pocket_saturn_core/src/fpga/core/core_top.v:80`:
two AS1C8M16PL chips, each two 64 Mbit dies → **32 MiB total**. A die is 8 MiB and is
selected by address bit 22.

So 14 MiB of 32 MiB: the memory fits. **This section was nevertheless the wrong
question, and its conclusion misled the plan.** Measured feasibility (docs/FEASIBILITY.md)
shows board memory was never the binding constraint; the FPGA's block RAM is. And the
sentence that used to follow — that the framebuffer being "already in block RAM ... does
not compete for PSRAM" — has it backwards: that framebuffer is 2,457,600 bits, 69 % of
the core's block memory and 78 % of the Pocket's entire 3,153,920-bit budget. It is the
reason the core does not fit.

The Pocket also exposes a 512 Mbit ×16 SDR SDRAM (`dram_a[12:0]`, `dram_ba[1:0]`,
`dram_dq[15:0]` in `apf_top.v`; Analogue's own comment calls it "sdram, 512mbit x16"),
i.e. 64 MB — twice the PSRAM, and the same SDR protocol `ki_sdram_burst` already
implements. 14 MiB of game memory + 4 MiB of DCS ROM + 300 KiB of framebuffer ≈ 18.3 MiB
fits there with 3× headroom.

Not free: PSRAM is slower and burst-constrained (1..32 words, never crossing an aligned
32-word block) compared with MiSTer's SDR SDRAM. `ki_sdram_burst`/`ki_sdram_x2` assume
SDR timing and must be re-placed behind `psram_phy`. This is where the real risk is:
the R4600 waits on memory, and the Saturn port shows exactly that failure mode
(Pocket memory latency starving the CPU). Expect the CPU memory path to be the
hard part, not the logic.

## 4. What the game loads, and how it maps to APF

Upstream ROM delivery (`KillerInstinct.sv:283-287`, `ki_memory_bridge.sv:377-400`):

| ioctl index | Payload | Destination |
|---|---|---|
| `0x0000` | 1 word: game selector (0 = KI1) | `game_ki2` |
| `0x0001` | **one 0x480000-byte image** | first 0x80000 → boot ROM; rest 0x400000 → DCS |
| `0x00FE` | 1 word of DIP switches | `dip_switches` |

That is why `data.json` here declares a single `size_exact: 4718592` ROM slot: the
MRA's nine `<part>` files concatenate to exactly that. `tools/build_rom.py` builds and
CRC-checks it.

The ATA hard disk is the awkward one. `ki_ata.sv` expects a 512-byte-sector block
device (`sd_lba`, `sd_blk_cnt`, `sd_rd`, `img_size`) served by the HPS. APF has no
block API. The only workable analogue is the deferred data slot with random reads —
the same mechanism `pocket_saturn_core` uses for CD sectors
(`src/fw/cdb/cd_src.c`: `cmd_start(CUE_ID, off, left, 0)`). A new module must translate
ATA PIO READ/WRITE SECTORS into slot reads, keeping the CHS translation
(13 heads × 47 sectors for KI1) that `ki_ata.sv` already implements.

## 5. Work breakdown

Ordered; each step has an acceptance test.

1. **Vendor the RTL** — copy `rtl/` and `KillerInstinct.sv` minus `sys/`; drop `hps_io`.
   *Test:* `quartus_map` parses it (needs Quartus).
   **DONE.** `src/fpga/rtl` symlinks the vendored upstream RTL; `src/fpga/ki_pocket.qip`
   lists it the way upstream's `files.qip` does, minus `KillerInstinct.sv` and the
   MiSTer PLL.
2. **APF top level** — new `apf_top` with clock bridge, reset, data slots, video, I2S.
   Reuse the structure of `pocket_saturn_core/src/fpga/apf/` (same author, GPL-3.0).
   *Test:* bitstream builds; Pocket shows a black frame.
   **PARTIAL.** `src/fpga/` builds and fits: `apf_top` + `core_top` + `apf/`
   framework vendored unmodified, `pocket_rtl/ki_pll.sv` (74.25 → 50/100/6.25 MHz,
   verified by Quartus's PLL report) and `pocket_rtl/ki_pocket_top.sv` (the core's own
   `ki_video_timing`, `ki_framebuffer` and `ki_fb_ram` plus a colour-bar writer).
   `quartus_sh --flow compile pocket_ki` produces `output_files/pocket_ki.rbf`
   (454 ALMs, 224/224 pins). The frame is **not** verified: the fitter shows the
   scanout chain constant-folded away, a defect in `ki_pocket_top`'s scanout adapter.
   Fixing that is the next task, before anything else in this list.
3. **ROM load path** — slot 1 → `ioctl_addr/dout` equivalent → `ki_memory_bridge`.
   *Test:* boot ROM checksum matches; CPU fetches valid instructions (debug screen).
4. **PSRAM memory path** — replace `ki_sdram_burst`/`ki_sdram_x2` with `psram_phy`
   bursts. *Test:* `ki_sdram_bist` passes against PSRAM; memory test in service mode.
5. **Disk path** — ATA → deferred slot adapter. *Test:* KI boots past the disk check.
6. **Video** — 320×240 BGR555 → APF; aspect options. *Test:* image centred, correct colours.
7. **Audio** — DCS → I2S. *Test:* attract-mode music, no underruns.
8. **Controls/DIPs** — `interact.json` from the MRA switch table (blood, coinage,
   country, test). *Test:* each option changes behaviour.
9. **KI2 instance** — second `.rom`/`.img` pair; game selector word.
10. **Hardware soak** — timing across attract, fight, finish-move, pause.

Steps 2-4 are the ones that decide whether this is a weekend or a season.

## 6. Reference ports worth reading

Real MiSTer → Pocket arcade ports, all with the APF scaffolding this folder imitates:

- `akoaysigod/pocket_saturn_core` — same author; PSRAM arbiter and deferred data slots.
- `McNast13/NamcoSystem11-Pocket` — arcade core, ROM slot pattern.
- `finner/openFPGA-SEGASYS1` — `data.json` / instance JSON / `.rom` build pattern.
- `obsidian-dot-dev/openFPGA-Joust2` — small, complete, easy to read.

No Killer Instinct Pocket port exists as of 2026-11-09 (GitHub search).

## 7. Blocked here, and why

- ~~**No FPGA toolchain on this machine.**~~ **Resolved 2026-11-09:** Quartus Prime
  25.1std.0 Lite with Cyclone V support is installed at `/opt/intelFPGA/25.1`, and
  `5CEBA4F23C8` synthesises, fits and assembles. No simulator is installed
  (`verilator`, `iverilog`, `modelsim` absent), so RTL behaviour still cannot be
  simulated — only synthesised, fitted and timed.
- **No hardware.** Fit, timing closure and boot can only be confirmed on a Pocket.
- **No ROMs.** `kinst.zip`, `kinst2.zip` and the disk images are copyrighted
  Midway/Rare content. They are not in this tree and will not be downloaded. The tools
  here verify and assemble *your* dumps; they cannot substitute for them.

## 8. State of this folder

Done and verified:

- Upstream source vendored, license intact (`upstream/`, 6.4 MB).
- `apf/` metadata: `core.json`, `data.json`, `platforms/killerinstinct.json`, two game
  instance JSONs, `info.txt`.
- `tools/build_rom.py` — MRA + MAME zip → the 0x480000 `.rom`.
  Verified: positive case produces exactly 4718592 bytes; wrong CRC and wrong total
  size both exit 1.
- `tools/check_setup.py` — verifies `.rom` size and `.img` sector alignment.
- **Feasibility, measured** (docs/FEASIBILITY.md): upstream core fitted against
  `5CEBA4F23C8` with Quartus 25.1. It does not fit — 18,547/18,480 ALMs and
  3,578,368/3,153,920 block-memory bits under area optimisation. The framebuffer
  is 2,457,600 of those bits. §3 corrected accordingly.
- `src/fpga/` Pocket project: `apf_top` + `core_top` + APF framework (unmodified) +
  `ki_pll.sv` + `ki_pocket_top.sv`. `tools/build_pocket.sh` compiles it to
  `output_files/pocket_ki.rbf` (456 ALMs, 224/224 pins, exit 0).
- `tools/fetch_references.sh` + `references.lock` pin the reference Pocket core
  the APF scaffolding came from.
- **Re-engineering, measured** (docs/REENGINEERING.md): the framebuffer is 69 %
  of the core's block RAM; moving it off chip takes block RAM from 113 % to 36 %.
  That reveals a logic overrun the RAM wall had been hiding (~19,590 ALMs, not
  the 18,547 the truncated fit reported). Stubbing the R4600 FPU (~2,466 ALMs)
  brings the core to **17,974 ALMs / 1,842 of 1,848 LABs — six LABs spare**,
  with a loader stub standing in for the APF bridge and no memory arbiter yet.
  The core fits; the machine does not.
- **ADSP attacked, measured** (docs/ADSP_ATTACK.md): the DCS block is 8,203 ALMs
  (48 % of core logic). Every behaviour-preserving cut was built. Synthesis
  settings: ±0. ROM prefetch cache 512→256: −564 ALMs in the full core but
  **0 LABs**. Diagnostics: already pruned by the real build, so free but worth
  nothing. No cut frees a LAB. Reducing it further means rewriting the emulator.
- **LABs bind, not ALMs** (docs/ADSP_ATTACK.md §1): 18,480 ALMs are 1,848 LABs
  of 10, and only the LAB count is a wall. Earlier ALM percentages overstated
  the headroom.
- **Opcode subset derived and measured** (docs/ADSP_SUBSET.md): the DCS firmware
  executes 41 of the ADSP-2105's instruction classes — identical set and counts
  for KI1 and KI2 — and only LSHIFT modes 0-3 of 16. Everything else in the 4 MiB
  sound ROM is sample data (entropy 7.9/8.0). Deleting the unused shift datapath
  gives 80 LABs in isolation and **12 LABs in the full core: margin 6 → 18**.
  Static analysis; no simulator is licensed here. The route is exhausted at
  12 LABs.
  `tools/measure/measure_fit.sh` reproduces every figure.

Known defect, before anything else: the milestone-1 build's video is blank. The
fitter deletes `ki_framebuffer`'s line RAMs; the fault is in the scanout adapter's
handshake in `pocket_rtl/ki_pocket_top.sv`. Evidence and the two leads already
ruled out are in docs/FEASIBILITY.md §6. A simulator would settle it in minutes and
none is installed.

Not done: the rest of §5.
