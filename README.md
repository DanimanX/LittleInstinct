# LittleInstinct

Analogue Pocket port of the Killer Instinct arcade core
([MiSTer-devel/Arcade-KillerInstinct_MiSTer](https://github.com/MiSTer-devel/Arcade-KillerInstinct_MiSTer)).

Covers **Killer Instinct (1994)** and **Killer Instinct 2 (1996)** — Midway KI
hardware: R4600 MIPS III, DCS audio, ATA hard disk.

## Status: measured, and the measurement changes the plan

There is still no working core and no verified bitstream. What has changed is
that the feasibility question is now answered from the toolchain rather than
assumed:

- **Quartus Prime 25.1 Lite (Cyclone V) is installed and works.** The
  Analogue Pocket's device, `5CEBA4F23C8`, compiles and fits on this machine.
- **The upstream MiSTer core does not fit the Pocket.** Under the area
  optimisation the real Pocket ports use, it needs 18,547 of 18,480 ALMs
  (100.4 %) and 3,578,368 of 3,153,920 block-memory bits (113 %).
- **Block RAM is the binding constraint, not logic.** 69 % of it is the
  framebuffer (`ki_fb_ram`, 2,457,600 bits). Move that off-chip and the rest of
  the core uses 36 % of the device.
- **PORTING.md §3's central claim was wrong.** It checked that 14 MiB of game
  memory fits the Pocket's PSRAM, which it does, and treated that as the
  feasibility answer. Memory capacity was never the problem; the framebuffer
  occupying the scarce resource was. The Pocket also exposes a 64 MB SDR SDRAM
  (`dram_*` in the APF), which is bigger than the PSRAM and speaks the protocol
  `ki_sdram_burst` already implements.

Since then a re-engineering pass answered "can the RAM be made to fit?" with a
measured yes, and exposed a second wall behind it:

- **Framebuffer off chip: block RAM 113 % → 36 %.** That is the whole RAM
  problem, and it is solved.
- **But the logic was hiding behind it.** The 18,547-ALM figure above is where
  the fitter *stopped* at the RAM wall; the core's real cost is ~19,590. Moving
  the framebuffer off chip raises the reported ALMs by 1,043 rather than
  lowering them.
- **The lever that closes it is the R4600's FPU** (~2,466 ALMs, 147 LABs).
- **Measured honestly, the core then lands at 17,974 ALMs and 1,842 of 1,848
  LABs — six LABs spare.** That figure already includes a loader stub standing
  in for the APF bridge. It does not include the framebuffer arbiter and
  write-combining queues, which do not exist yet.
- **Verdict: the core fits with nothing to spare; the machine does not.**

- **The last large lever does not pay either.** The DCS/ADSP block is 48 % of
  all logic; attacking it directly found no behaviour-preserving cut that frees
  a single LAB. See [docs/ADSP_ATTACK.md](docs/ADSP_ATTACK.md).
- **And the metric was wrong all along.** The Pocket's ALMs live in 1,848 LABs
  of 10, and Quartus's *Total LABs used* is the wall, not the ALM percentage.
  Measured: a change saving 564 ALMs freed **0** LABs.
- **The opcode-subset route was then taken and measured.** The DCS firmware
  executes only 41 of the ADSP-2105's instruction classes (identical for KI1 and
  KI2), and only 4 of 16 shift modes. Deleting the unused datapath gives 80 LABs
  in isolation but **12 LABs in the full core** — margin 6 → 18. See
  [docs/ADSP_SUBSET.md](docs/ADSP_SUBSET.md).

Read [docs/REENGINEERING.md](docs/REENGINEERING.md) for the measured tables and
the per-block breakdown. [docs/FEASIBILITY.md](docs/FEASIBILITY.md) is the earlier,
narrower analysis, annotated where it is superseded.

A Pocket project now exists at `src/fpga/pocket_ki.qpf` and compiles to an RBF
(454 ALMs, 224/224 pins assigned, `output_files/pocket_ki.rbf`). Its clock tree,
reset path and board pinout are verified by Quartus. **Its video output is not
verified and is probably blank**: the fitter shows the scanout chain being
optimised away, which is a defect in this port's own scanout adapter, not in
upstream.

## Layout

```
upstream/Arcade-KillerInstinct_MiSTer/   source, GPL-3.0, unmodified
src/fpga/                                the Pocket Quartus project
  pocket_ki.qpf/.qsf                     apf_top, Pocket pins, device 5CEBA4F23C8
  ki_pocket.qip                          source list; rtl -> upstream, by reference
  apf/                                   Analogue APF framework, unmodified
  core/                                  core_top + core_bridge_cmd + I2S
  pocket_rtl/                            ki_pll.sv, ki_pocket_top.sv (new code)
docs/FEASIBILITY.md                      first fit measurement (block RAM wall)
docs/REENGINEERING.md                    re-engineering pass: where every bit and ALM
                                         goes, and what closes the gap
docs/ADSP_ATTACK.md                      measured attack on the DCS/ADSP block (48 %
                                         of all logic) and why it is not enough
docs/ADSP_SUBSET.md                      which opcodes the DCS firmware really runs,
                                         and what deleting the rest is worth
docs/dcs_subset.json                     that subset, machine-readable
tools/measure/dcs_opcodes.py             derives it from the sound ROM
apf/Cores/littleinstinct.KillerInstinct/ core.json, data.json, info.txt
apf/Platforms/killerinstinct.json
apf/Assets/killerinstinct/littleinstinct.KillerInstinct/
                                        one JSON per game
tools/build_pocket.sh                    Quartus compile -> pocket_ki.rbf
tools/measure/measure_fit.sh             fit-measurement harness (see docs/REENGINEERING.md)
tools/fetch_references.sh                re-fetch the reference Pocket core
tools/build_rom.py                       MAME zip + MRA -> .rom (CRC-checked)
tools/check_setup.py                     validates .rom size and .img sectors
roms/                                    where your dumps go (empty on purpose)
```

## Building

```bash
tools/build_pocket.sh          # needs Quartus 25.1+ with Cyclone V
```

Produces `src/fpga/output_files/pocket_ki.rbf`. Read the status above first: it
builds and fits, but the video path is not finished.

## What you supply

The ROMs and disk images are copyrighted Midway/Rare content and are **not**
included. Bring your own dumps:

```bash
# 1. assemble the 4.5 MiB ROM image from your MAME zip
tools/build_rom.py \
  upstream/Arcade-KillerInstinct_MiSTer/releases/"Killer Instinct (v1.5d).mra" \
  roms/ roms/kinst.rom

# 2. turn the CHD into the raw sector image the core expects
chdman extracthd -i kinst.chd -o roms/kinst.img
chdman extracthd -i kinst2.chd -o roms/kinst2.img

# 3. repeat for Killer Instinct 2 (v1.4).mra -> kinst2.rom

# 4. check everything
tools/check_setup.py roms/
```

## On the SD card, once a bitstream exists

```
Cores/littleinstinct.KillerInstinct/{core,data,input,video,audio,interact}.json
Cores/littleinstinct.KillerInstinct/bitstream.rbf_r
Platforms/killerinstinct.json
Assets/killerinstinct/common/kinst.rom
Assets/killerinstinct/common/kinst.img
Assets/killerinstinct/common/kinst2.rom
Assets/killerinstinct/common/kinst2.img
Assets/killerinstinct/littleinstinct.KillerInstinct/Killer Instinct (v1.5d).json
Assets/killerinstinct/littleinstinct.KillerInstinct/Killer Instinct 2 (v1.4).json
```

## Licenses

Upstream RTL is GPL-3.0-or-later (`upstream/.../LICENSE`, notices inside files).
The Analogue Pocket Framework files this port will reuse are distributed with
openFPGA cores under their own terms. Killer Instinct is a trademark of Rare /
Nintendo / Midway; this project is not affiliated with any of them.
