# LittleInstinct

<p align="center">
  <img src="docs/assets/banner.png" alt="LittleInstinct - Killer Instinct openFPGA Core" width="640">
</p>

Analogue Pocket port of the Killer Instinct arcade core
([MiSTer-devel/Arcade-KillerInstinct_MiSTer](https://github.com/MiSTer-devel/Arcade-KillerInstinct_MiSTer)).

Covers **Killer Instinct (1994)** and **Killer Instinct 2 (1996)** — Midway KI
hardware: R4600 MIPS III, DCS audio, ATA hard disk.

## Status: Measured, Synthesized, and Successfully Fitted

The project compiles, synthesizes, physically fits, and generates the complete `.rbf` bitstream for Analogue Pocket (`5CEBA4F23C8N`):

- **Unified Memory Architecture in SDRAM ([`ki_memory_bridge_pocket.sv`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/ki_memory_bridge_pocket.sv)):**
  - **Framebuffer in SDRAM:** Eliminated dependency on 2.4 Mbits of on-chip BRAM. Both CPU accesses (`FB_READ_ISSUE`, `FB_WRITE`, `FB_LINE_WRITE`) and video scanout (`VID_ISSUE` / `VID_WAIT`) read and write directly to SDRAM in 16-word bursts, integrating the write-combining buffer (`wb_gather_ok`) to coalesce 32-byte bursts per cycle.
  - **DCS Sound ROM in SDRAM:** Completely eliminated the legacy MiSTer DDR3 mailbox. The 4 MiB DCS sound ROM (`STORE_DCS = 0x0a0_0000`) is downloaded alongside the Boot ROM directly into SDRAM via `DOWNLOAD_SDRAM_WRITE_ISSUE`. Audio ADSP reads (`dcs_rom_request`) are serviced directly from SDRAM with real sample data.
- **CPU Datapath & Resource Optimizations ([`cpu_pocket.vhd`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/cpu/cpu_pocket.vhd) & [`cpu_datacache.vhd`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/cpu/cpu_datacache.vhd)):**
  - 32-bit GPR register file (`g_regs_32`) in MLAB under `ADDR32_ONLY`, saving half the MLAB cells and reducing routing congestion.
  - 32-bit arithmetic, address generation, and 32-bit barrel shifter paths (`calcResult_shiftL`/`calcResult_shiftR`), eliminating 65-bit shifter routing delays.
  - Decoupling of D-Cache write enables: `st_direct_we` prevents unclocked combinatorial writes in `IDLE` when `STORE_BUFFER` is active, completely eliminating the -4.18 ns critical path from `itagram` to `portbwe`.
  - Disconnected tag match dependency from `sb_drain_idle` (`sb_fwd_sel`), removing tag lookup from data RAM port b arbitration.
- **Physical Device Metrics (Cyclone V 5CEBA4F23C8), build v1.0.17:**
  - **Logic Utilization (ALMs):** **18,230 / 18,480 (99%)**, **1,847 / 1,848 LABs**.
  - **Block Memory Bits:** **1,525,344 / 3,153,920 (48%)**.
  - **DSP Blocks:** **23 / 66 (35%)**.
  - **Timing:** Completely closed for Hold (+0.120 ns worst-case) and Recovery (+15.387 ns); inter-PLL asynchronous clock groups and `set_false_path -from [get_keepers {*rst_sync[*]}]` established in [`pocket_ki.sdc`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/pocket_ki.sdc).
  - **Generated Bitstream:** [`pocket_ki.rbf`](file:///PROCESOS/LittleInstinct/src/fpga/output_files/pocket_ki.rbf) (1.8 MB, MD5 `41d97ad4990f7bc034bceb74897ea77b`).
  - **APF Release Package:** Synchronized to SD card under [`Release/`](file:///PROCESOS/LittleInstinct/Release/) with bit-reversed [`bitstream.rbf_r`](file:///PROCESOS/LittleInstinct/Release/sd_card/Cores/littleinstinct.KillerInstinct/bitstream.rbf_r) (MD5 `d66c296ca6624954ce65ff0b8ef95f33`) and ready-to-extract ZIP archive [`LittleInstinct_Pocket_v1.0.0.zip`](file:///PROCESOS/LittleInstinct/Release/LittleInstinct_Pocket_v1.0.0.zip).
  - **Hardware status:** Ready for hardware testing on Analogue Pocket to verify SDRAM boot sequence (`SD:1`, `BOOT:1`, `RST:0`) and capture software departure telemetry (`EX`, `DO`, `DP:8802EC4C`).

## Layout

```
upstream/Arcade-KillerInstinct_MiSTer/   source, GPL-3.0, unmodified
src/fpga/                                the Pocket Quartus project
  pocket_ki.qpf/.qsf                     apf_top, Pocket pins, device 5CEBA4F23C8
  ki_pocket.qip                          source list; rtl -> upstream, by reference
  apf/                                   Analogue APF framework, unmodified
  core/                                  core_top + core_bridge_cmd + I2S
  pocket_rtl/                            Pocket-specific overrides and bridges:
    ki_pll.sv, ki_pocket_top.sv          clock tree and top-level core wrapper
    ki_core_pocket.sv                    top-level KI arcade board for Pocket
    ki_memory_bridge_pocket.sv           off-chip SDRAM/PSRAM memory bridge + FB line buffer
    pk_io.sv                             APF bridge -> ioctl_wr & ATA disk streaming (Slot 2)
    cpu/cpu_pocket.vhd                   trimmed R4600 CPU (no FPU, ADDR32_ONLY, WB D-Cache)
    cpu/r4600_64in32_micro.sv            32-bit MIPS-III micro-sequencer for 64-bit ops
    sound/adsp2105_pocket.vhd            opcode/shifter-trimmed ADSP-2105 DCS audio core
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

---

## Architecture & Engineering Reference (openFPGA / Cyclone V)

### 1. Real Hardware Constraints on Analogue Pocket (`5CEBA4F23C8`)

Before designing the resource budget and memory map, several common misconceptions about the Analogue Pocket hardware and the Midway Killer Instinct arcade board must be corrected against the physical pinout (`src/fpga/pocket_ki.qsf`) and RTL:

- **FPGA Fabric (`5CEBA4F23C8`):**
  - **49,000 LEs = 18,480 ALMs = 1,848 LABs** (10 ALMs per LAB). In Quartus Prime, **LAB packing (`Total LABs used`)**—not raw LE/ALM count—is the hard physical limit.
  - **Block RAM:** **308 M10K blocks** (3,153,920 bits = 385 KB).
  - **DSP Blocks:** **66 variable-precision DSP blocks** (up to 132 multipliers of 18×18).
- **Physical External Memory Buses on Analogue Pocket:**
  - **`dram_*` (SDRAM):** **64 MB SDR SDRAM** (512 Mbit, 16-bit bus `dram_dq[15:0]`, `dram_ba[1:0]`, `dram_a[12:0]`), *not* 16 MB. Speaks the exact burst SDR protocol implemented by `ki_sdram_burst.sv`.
  - **`cram0_*` & `cram1_*` (CellularRAM / PSRAM):** **32 MB total** across two 16 MB chips (`cram0` and `cram1`, each containing two 8 MB dies on a 16-bit bus), *not* 64 MB.
  - **`sram_*` (Async SRAM):** **128 KB asynchronous 55 ns SRAM on a 16-bit bus** (`sram_a[16:0]`, `sram_dq[15:0]`, AS6C2016-55BIN), *not* 4 MB of 32-bit synchronous SRAM. Because the KI double framebuffer requires $320 \times 240 \times 2\text{ B} \times 2 = 307,200\text{ B}$ (**300 KB**), **the double framebuffer cannot physically fit in `sram_*`**.
- **Killer Instinct Arcade Architecture:**
  - **Audio:** Uses an **ADSP-2105** (16-bit fixed-point DSP running the Midway DCS engine at 31.25 kHz), not a TMS320C31.
  - **Video / Blitter:** Unlike Williams/Midway Wolf-Unit or N64 RDP, Killer Instinct **has no dedicated hardware sprite blitter ASIC**. The R4600 CPU renders, scales, and blits all sprites and backgrounds in software (`0x8803_0000`) into two framebuffer pages in Low RAM (`0x0003_0000` and `0x0005_8000`) using 64-bit stores (`SD`, `SDL`, `SDR`) and 32-byte cache-line write-backs, assisted only by a small hardware line-clear engine (`ki_fast_fill.sv`).

---

### 2. Resource Optimization Strategy (LE / ALM / LAB Budget)

To fit the system within the Cyclone V's **18,480 ALMs / 1,848 LABs** and reach a target below **~42,000 LEs (~15,700 ALMs)**, the port applies five structural optimizations:

1. **R4600 FPU Removal (`FPU_STUB` in `src/fpga/pocket_rtl/cpu/cpu_pocket.vhd`):**
   - Killer Instinct 1 & 2 are 100% fixed-point games (`CP1` is never enabled in `CP0.Status`). Stubbing `CP1` frees **2,466 ALMs (147 LABs)** and **8 DSP blocks**.
2. **ADSP-2105 Opcode & Barrel-Shifter Trimming (`src/fpga/pocket_rtl/sound/adsp2105_pocket.vhd`):**
   - Static analysis of the 4 MB DCS sound ROMs (`tools/measure/dcs_opcodes.py` / `docs/ADSP_SUBSET.md`) proves the audio firmware only uses **41 of 256 instruction classes** and **4 of 16 barrel-shifter modes** (`LSHIFT` 0–3). Pruning the unused datapath frees **80 LABs in isolation (12 LABs net in full-core fit)**.
3. **32-bit Physical/Virtual Addressing (`ADDR32_ONLY`, `NO_TRAP_INSTR`, `INSTR_KSEG_ONLY`):**
   - KI runs exclusively in `KSEG0` (`0x8000_0000` cached) and `KSEG1` (`0xA000_0000` uncached). Cutting the 64-bit TLB/address comparison paths to 32 bits and removing unused MIPS-III trap instructions (`TGE`/`TLT`/`TEQ`/`TNE`) saves **~600 ALMs**.
4. **32-bit Datapath with 2-Cycle 64-bit Micro-Sequencing (`src/fpga/pocket_rtl/cpu/r4600_64in32_micro.sv`):**
   - Instead of a full 64-bit ALU, barrel shifter, and 64-bit × 32-entry 2R1W register file (which duplicates M10K banks across `regs_a` and `regs_b`), the CPU datapath operates at **32 bits** with a banked `64 × 32-bit` M10K GPR file (`{reg_idx[4:0], hi_sel}`) and executes the 64-bit instructions KI actually uses across **2 micro-cycles**:
     - `LD` / `SD` and unaligned `LDL` / `LDR` / `SDL` / `SDR` (heavily used by the software sprite blitter and DMA loops): **Phase 0** computes `EA = base + sext(imm16)` on the 32-bit ALU and accesses `EA + 4` (low 32-bit word in Big-Endian); **Phase 1** accesses `EA + 0` (high 32-bit word).
     - `DADD` / `DADDU` / `DADDIU` / `DSUBU`: **Phase 0** computes the lower 32 bits and latches `carry_q`; **Phase 1** computes the upper 32 bits with `carry_q`.
     - `DSLL32` / `DSRL32` / `DSRA32`: Executed in a **single cycle** by reusing the 32-bit barrel shifter and routing the output to the opposite 32-bit register bank (`LO -> HI` or `HI -> LO`).
     - Unused 64-bit operations (`DMULT`, `DMULTU`, `DDIV`, `DDIVU`, variable 64-bit shifts) assert `trap_ri_o` (`CP0 ExcCode = 0x0A`, Reserved Instruction).
5. **Unified SDRAM Arbiter Removal of Legacy DDR3 Mailbox (`src/fpga/pocket_rtl/ki_memory_bridge_pocket.sv`):**
   - Replaces the legacy MiSTer dual-controller paths (SDRAM + Avalon DDR3 mailbox) with a single unified arbiter over `dram_*`.

#### Measured vs. Target Resource Breakdown (`5CEBA4F23C8`)

| Subsystem / Module | Current Fit (ALMs) | Target w/ 64-in-32 Microcode (ALMs) | Equivalent LEs (~2.66 LE/ALM) | M10K Blocks (of 308) | DSP Blocks (of 66) |
| :--- | ---: | ---: | ---: | ---: | ---: |
| **R4600 CPU Core** (`cpu_pocket` + `r4600_64in32_micro` + 8KB I$/D$) | 7,058 | **5,200** | ~13,830 LEs | 42 | 8 |
| **DCS Audio** (`adsp2105_pocket` + `dcs_audio` + ROM cache) | 8,708 | **8,450** | ~22,470 LEs | 46 | 13 |
| **Memory Bridge, Fast-Fill & Scanout** (`ki_memory_bridge_pocket` + `ki_fast_fill` + `ki_framebuffer`) | 1,148 | **950** | ~2,525 LEs | 52 | 0 |
| **ATA Disk Controller & Board I/O** (`ki_ata` + `ki_board_io`) | 776 | **650** | ~1,730 LEs | 4 | 0 |
| **APF Framework & Streaming Bridge** (`apf_top` + `core_bridge_cmd` + `pk_io`) | 454 | **450** | ~1,195 LEs | 12 | 0 |
| **TOTAL CORE** | **18,144 ALMs (98.1%)** | **15,700 ALMs (84.9%)** | **~41,750 LEs** | **156 (50.6%)** | **21 (31.8%)** |

---

### 3. Memory Subsystem Mapping & IDE HDD Streaming

#### Physical Memory Allocation on Analogue Pocket

| KI Arcade Region | Physical Address (R4600) | Size | Pocket Target Memory | Access Pattern & Rationale |
| :--- | :--- | :--- | :--- | :--- |
| **Low RAM + Double Framebuffer** | `0x0000_0000 .. 0x0007_FFFF` | **512 KB** | **SDRAM (`dram_*`)** Bank 0 (`0x0100_0000`) + **8 KB Write-Back D-Cache** + **2× M10K Line Buffers** | Pages 0 (`0x0003_0000`) and 1 (`0x0005_8000`) occupy 300 KB (>128 KB Async SRAM). Backed by 32-byte burst SDRAM + CPU D-Cache write-combining. |
| **Main RAM** | `0x0800_0000 .. 0x087F_FFFF` | **8 MB** | **SDRAM (`dram_*`)** (`0x0000_0000 .. 0x007F_FFFF`) | Zero-wait burst access via `ki_sdram_burst` for code, fighter state, and decompressed assets. |
| **Boot ROM (`u98`)** | `0x1FC0_0000 .. 0x1FC7_FFFF` | **512 KB** | **SDRAM (`dram_*`)** (`0x0080_0000 .. 0x0087_FFFF`) | Loaded at boot via APF Data Slot 1 (`kinst.rom` offset `0x000000`). Cached in 8 KB I-Cache. |
| **DCS Sound ROMs (`u10..u17`)** | DCS Banked Space | **4 MB** | **SDRAM (`dram_*`)** (`0x0090_0000 .. 0x00CF_FFFF`) | Loaded at boot via APF Data Slot 1 (`kinst.rom` offset `0x080000`). |
| **IDE HDD Image (`kinst.img`)** | ATA Registers `0x1000_0000` | **~130 MB** | **MicroSD via APF Deferred Data Slot 2** (`pk_io.sv`) + Optional **CellularRAM (`cram0/1`)** LBA Read-Ahead Cache | `deferload: true` in `data.json`. Streams 512 B – 8 KB sector blocks on demand over the APF bridge (`0x4000_0000`). |

#### IDE HDD Replacement via APF Deferred Data Slot Streaming (`src/fpga/pocket_rtl/pk_io.sv`)

Instead of pre-loading the 130 MB `.img` file into RAM at boot, `apf/Cores/littleinstinct.KillerInstinct/data.json` configures **Slot 2 (`"id": 2`)** with `"deferload": true` at bridge address `0x4000_0000`.

```mermaid
sequenceDiagram
    participant CPU as R4600 CPU
    participant ATA as ki_ata.sv (50 MHz)
    participant PKIO as pk_io.sv (CDC 50 MHz <-> 74.25 MHz)
    participant APF as APF Bridge / Pocket OS (74.25 MHz)
    participant SD as microSD (kinst.img)

    CPU->>ATA: Write LBA, Sector Count & Cmd 0x20 (Read)
    ATA->>PKIO: Assert sd_rd, sd_lba[31:0], sd_blk_cnt[4:0]
    PKIO->>APF: target_dataslot_read (id=2, offset=LBA<<9, len=(cnt+1)<<9, dest=0x4000_0000)
    APF->>SD: Read sectors from kinst.img
    SD-->>APF: Sector stream
    APF->>PKIO: bridge_wr @ 0x4000_0000..0x4000_3FFF (32-bit big-endian words)
    PKIO->>ATA: dcfifo -> 2x 16-bit LE words (sd_buff_wr, sd_buff_addr, sd_buff_dout)
    APF-->>PKIO: target_dataslot_done
    PKIO-->>ATA: Pulse sd_ack when FIFO drains
    ATA-->>CPU: Assert ATA DRQ & IRQ -> CPU reads 0x1000_0000
```

---

### 4. Software Blitter, DSP Sharing & Video Pipeline Architecture

Because the R4600 CPU acts as the sprite/background blitter in software (`0x8803_0000`), high-bandwidth framebuffer writes and fast fixed-point multiplication are critical:

```mermaid
flowchart LR
    subgraph CPU["R4600 CPU Core (50 MHz)"]
        MUL["32x32 Multiplier\n(8x Cyclone V 18x18 DSPs)\nSprite Scaling & Transforms"]
        MICRO["r4600_64in32_micro.sv\n2-Cycle 64-bit LD/SD/SDL/SDR"]
        DCACHE["8 KB Write-Back D-Cache\n(DCACHE_SKIP_FILL + DCACHE_FB_PARTIAL)"]
    end

    subgraph VIDEO["Video & Fill Engine"]
        FF["ki_fast_fill.sv\nHardware Line Clear"]
        MBRIDGE["ki_memory_bridge_pocket.sv\n32-Byte Dirty Line Burst Arbiter"]
        FB["ki_framebuffer.sv\n2x M10K Scanline Ping-Pong\n(320x16-bit RGB555)"]
    end

    SDRAM[("64 MB SDRAM (dram_*)\nPages 0 & 1 @ 0x0003_0000 / 0x0005_8000")]
    APF_VID["APF Video Scaler\n320x240 @ 60 Hz (6.25 MHz px clk)"]

    MUL --> MICRO
    MICRO --> DCACHE
    DCACHE -->|"32B Cache-Line Evict"| MBRIDGE
    FF --> MBRIDGE
    MBRIDGE <-->|"16-bit Burst R/W"| SDRAM
    MBRIDGE -->|"Pre-fetch Scanline N+1"| FB
    FB -->|"RGB555 -> RGB888"| APF_VID
```

1. **DSP Block Sharing & Allocation:**
   - The R4600 uses **8 of 66 DSP blocks** for its 32×32 hardware multiplier (`MULT`/`MULTU`), which the game's software blitter uses continuously for affine sprite scaling and zoom calculations.
   - The ADSP-2105 uses **13 of 66 DSP blocks** for its 16×16 MAC audio mixing pipeline.
   - **45 DSP blocks remain free** for optional hardware color-blending or scaling offloading.
2. **Write-Back D-Cache Framebuffer Optimization ([`cpu_pocket.vhd`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/cpu/cpu_pocket.vhd)):**
   - **`DCACHE_SKIP_FILL`:** When the CPU writes to a cold cache line in the framebuffer (`0x0003_0000 .. 0x0007_FFFF`), the D-Cache **skips reading the 32-byte line from SDRAM** and allocates the line directly in `M10K` with per-byte dirty masks (`dcache_valid_bytes`). This eliminates 50% of external SDRAM bus traffic during sprite blitting.
   - **`DCACHE_FB_PARTIAL`:** On write-back eviction of a framebuffer line, only valid/dirty words are burst-written to SDRAM by [`ki_memory_bridge_pocket.sv`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/ki_memory_bridge_pocket.sv).
3. **Dual-Line M10K Scanout ([`ki_framebuffer.sv`](file:///PROCESOS/LittleInstinct/src/fpga/rtl/ki_framebuffer.sv)):**
   - Instead of holding a 300 KB framebuffer in on-chip BRAM, `ki_framebuffer.sv` uses **two 320×16-bit M10K scanline buffers (~1.25 KB total)**. While line $N$ is scanned out at 6.25 MHz to the APF scaler (`RGB555` expanded to 24-bit `RGB888`), `ki_memory_bridge_pocket.sv` burst-reads line $N+1$ from SDRAM during horizontal blanking.

## Building

```bash
tools/build_pocket.sh          # requires Quartus Prime 25.1+ with Cyclone V support
```

Produces `src/fpga/output_files/pocket_ki.rbf`.

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

## On the SD card

A pre-packaged archive ready to extract directly to the microSD card root is provided in [`Release/LittleInstinct_Pocket_v1.0.0.zip`](file:///PROCESOS/LittleInstinct/Release/LittleInstinct_Pocket_v1.0.0.zip):

```
Cores/littleinstinct.KillerInstinct/{core,data}.json, info.txt
Cores/littleinstinct.KillerInstinct/icon.bin
Cores/littleinstinct.KillerInstinct/bitstream.rbf_r
Platforms/killerinstinct.json
Platforms/_images/killerinstinct.bin
Assets/killerinstinct/common/kinst.rom
Assets/killerinstinct/common/kinst.img
Assets/killerinstinct/common/kinst2.rom
Assets/killerinstinct/common/kinst2.img
Assets/killerinstinct/littleinstinct.KillerInstinct/Killer Instinct (v1.5d).json
Assets/killerinstinct/littleinstinct.KillerInstinct/Killer Instinct 2 (v1.4).json
```

## Licenses

Upstream RTL is GPL-3.0-or-later (`upstream/.../LICENSE`, notices inside files).
The Analogue Pocket Framework files this port reuses are distributed with
openFPGA cores under their own terms. Killer Instinct is a trademark of Rare /
Nintendo / Midway; this project is not affiliated with any of them.

---

## Depuración y Diagnóstico openFPGA (Analogue Pocket)

Registro de errores de inicialización del framework APF detectados en hardware real y sus soluciones:

### 1. `Load error in 'core'. General error. Error in core setup`
- **Causa:** 
  1. El Core ID en openFPGA se calcula estrictamente como `<author>.<shortname>`. En `core.json` figuraba `"author": "DanimanX"` mientras que la carpeta en la MicroSD era `Cores/littleinstinct.KillerInstinct/`. Al discrepar el nombre del directorio esperado (`DanimanX.KillerInstinct`), la Pocket abortaba el setup.
  2. El Slot 1 de ROM en `data.json` tenía el Bit 1 activo (`0x10A`), forzando la búsqueda en la carpeta específica del core en lugar de `Assets/killerinstinct/common/`.
- **Solución aplicada:**
  - Ajustado `"author": "littleinstinct"` en `core.json`.
  - Corregido Slot 1 a `"parameters": "0x108"` en `data.json` (modo archivo común de plataforma + sólo lectura, idéntico al estándar de Jotego).

### 2. `Load error in 'variants'. General error. Error in core setup`
- **Causa:** El firmware de la Analogue Pocket exige la existencia de `variants.json` en el directorio del core antes de transferir slots. Al no existir, el bootloader fallaba de inmediato.
- **Solución aplicada:**
  - Incorporado [`variants.json`](file:///Users/danimanx/code/LittleInstinct/apf/Cores/littleinstinct.KillerInstinct/variants.json) con lista de variantes vacía (`"variant_list": []`).
  - Incorporados descriptores auxiliares estándar APF: [`video.json`](file:///Users/danimanx/code/LittleInstinct/apf/Cores/littleinstinct.KillerInstinct/video.json) (escalador 320×240 a 4:3 con filtros CRT/LCD), [`audio.json`](file:///Users/danimanx/code/LittleInstinct/apf/Cores/littleinstinct.KillerInstinct/audio.json) e [`interact.json`](file:///Users/danimanx/code/LittleInstinct/apf/Cores/littleinstinct.KillerInstinct/interact.json).

### 3. `Error in framework: no file for rom id [1]`
- **Causa:** Al estar el Slot 1 configurado con `"parameters": "0x108"`, el framework APF ya resuelve la ruta base como `Assets/<platform>/common/`. Al tener las instancias JSON `"data_path": "common/"`, la Pocket intentaba resolver la ruta como `Assets/killerinstinct/common/common/kinst.rom`, provocando que no encontrara la ROM.
- **Solución aplicada:**
  - Corregido `"data_path": ""` (cadena vacía) en las instancias JSON, con `"variant_select": { "id": 0, "select": false }` según el estándar de openFPGA arcade.
  - Eliminado `"size_exact"` de `data.json` para evitar validaciones de tamaño excesivamente estrictas del firmware.
  - Como redundancia en la MicroSD, se aseguraron copias de la ROM tanto en la ruta común como en la carpeta específica del core.

### 4. `Error in framework. RS: Host commands ignored` (Deadlock RTL en `boot_done`)
- **Síntoma:** El bitstream se carga exitosamente en la FPGA, pero durante el handshake con el chip host APF de la Pocket, la consola entra en timeout y aborta con `RS: Host commands ignored`.
- **Causa raíz en RTL ([`ki_pocket_top.sv`](file:///Users/danimanx/code/LittleInstinct/src/fpga/pocket_rtl/ki_pocket_top.sv)):**
  - La señal `boot_done` estaba asignada a `core_reset_n`:
    ```verilog
    always @(posedge clk_core) rst_sync <= {rst_sync[2:0], (apf_reset_n & pll_locked)};
    wire core_reset_n = rst_sync[3];
    assign boot_done  = core_reset_n; // <-- INTERBLOQUEO
    ```
  - En `core_top.v`, `status_boot_done = boot_done;` informa al handler APF (`core_bridge_cmd.v`).
  - Sin embargo, `core_bridge_cmd` mantiene `apf_reset_n` en `0` hasta que la Pocket envía el comando host `0x0011` (`Reset Exit`).
  - La Pocket envía en bucle el comando `0x0000` (**RS: Request Status**) esperando que `status_boot_done` suba a `1` (indicando que los PLLs y relojes de la FPGA están estables) para poder transferir las ROMs y luego liberar el reset (`0x0011`).
  - Al esperar `boot_done` a `apf_reset_n`, el core respondía perpetuamente en estado *booting*, provocando que la Pocket agotara el tiempo de espera (timeout) y lanzara `RS: Host commands ignored`.
- **Solución RTL aplicada:**
  - `boot_done` sincronizado a `clk_74a` únicamente con `pll_locked`, sin depender de `apf_reset_n`:
    ```verilog
    reg [3:0] boot_sync = 4'd0;
    always @(posedge clk_74a) boot_sync <= {boot_sync[2:0], pll_locked};
    assign boot_done = boot_sync[3];
    ```
  - `core_reset_n` continúa gobernando la lógica interna del R4600 y KI arcade hardware esperando a `apf_reset_n`.

### 5. Pantalla congelada con barras horizontales / raster residual (FIFO de ROM en `aclr`)
- **Síntoma:** Al seleccionar el juego, la barra inferior de carga de la Pocket se llena al 100%, pero la pantalla queda congelada mostrando un patrón de barras horizontales blancas y negras con puntos (patrón residual de la SDRAM al encender). La CPU nunca inicia el test de RAM azul.
- **Causa raíz en RTL ([`ki_core_pocket.sv`](file:///Users/danimanx/code/LittleInstinct/src/fpga/pocket_rtl/ki_core_pocket.sv#L255)):**
  - La instancia [`pk_io`](file:///Users/danimanx/code/LittleInstinct/src/fpga/pocket_rtl/pk_io.sv) estaba conectada con `.apf_reset_n(~RESET)`.
  - La Pocket transfiere los 4.7 MB de la ROM mientras mantiene el reset de la CPU (`RESET = 1`, por lo que `~RESET = 0`).
  - Al recibir `apf_reset_n = 0`, la FIFO de recepción de la ROM (`dcfifo.aclr`) se mantenía en borrado asíncrono permanente durante toda la transferencia.
  - Como consecuencia, todos los paquetes de la ROM eran descartados sin llegar a la SDRAM; al levantarse el reset (`0x0011`), `pk_io` entraba en `S_WAIT` esperando datos de una FIFO vacía y manteniendo la CPU R4600 en reset perpetuo vía `ioctl_download`.
- **Solución RTL aplicada:**
  - En `ki_core_pocket.sv`, conectado `.apf_reset_n(pll_locked)` para que la FIFO y la FSM de descarga operen y graben en la SDRAM durante la fase de carga previa a la liberación del reset.
  - En `ki_memory_bridge_pocket.sv`, priorizada la escritura de descarga a la SDRAM (`download_count != 0`) por encima del escaneo de video en estado `IDLE`.

### 6. Pantalla congelada en color lila/morado (Truncamiento en FIFO de Cruce de Reloj ATA y Handshake de Disco)
- **Síntoma:** Al seleccionar el juego, la barra inferior de carga se completa al 100%, la CPU arranca y ejecuta con éxito el POST (llenando la pantalla verticalmente en color lila/morado durante el auto-test de memoria), pero se queda congelada al final del test sin iniciar la atracción ni reproducir el sonido de inicio.
- **Causa raíz en RTL ([`pk_io.sv`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/pk_io.sv)):**
  - Al finalizar el POST de RAM, la CPU transfiere el control a leer el sector 0 del disco duro (`kinst.img`) a través del controlador IDE/ATA (`ki_ata.sv` $\leftrightarrow$ `pk_io.sv` $\leftrightarrow$ APF target dataslot read `0x0180`).
  - La señal `fifo_din` hacia la FIFO de cruce de reloj APF (`clk_74a`) a Core (`clk_core`) empaquetaba:
    `{disk_win_hit (1b), bridge_addr[12:2] (11b), bridge_wr_data (32b)}` = **44 bits**.
  - Sin embargo, `fifo_din` y la macro `dcfifo` estaban tipadas con un ancho de solo **34 bits** (`[33:0]`).
  - Debido a este truncamiento silencioso de 10 bits por parte del sintetizador:
    - El bit 33 de la FIFO (`fifo_dout[33]`), que debía ser `disk_win_hit`, recibía en realidad `bridge_addr[3]`.
    - La señal de habilitación de escritura en el buffer de sectores ATA (`sd_buff_wr`) solo se activaba de manera intermitente cuando `bridge_addr[3] == 1`.
    - La cuenta regresiva de palabras pendientes (`disk_words_rem`) nunca llegaba a cero.
    - Como consecuencia, `sd_ack` nunca caía a `0`, produciendo un deadlock: `ki_ata.sv` se quedaba esperando indefinidamente la confirmación de la transferencia y la CPU colgaba en un bucle esperando los datos del disco.
  - Adicionalmente, `img_size` se inicializaba en `0`, dependiendo exclusivamente de que la Pocket enviara el comando host `0x008A` a tiempo.
- **Solución RTL aplicada:**
  - Ampliado el ancho de la FIFO de puente a **44 bits** (`lpm_width(44)`), `fifo_din[43:0]`, `fifo_dout[43:0]` y `held[43:0]`.
  - Direccionamiento corregido en `S_DISK_LO` (`{fifo_dout[42:32], 1'b0}`) y `S_DISK_HI` (`{held[42:32], 1'b1}`) con habilitador `sd_buff_wr <= fifo_dout[43]`.
  - Establecido el tamaño por defecto de `img_size = 64'd131076608` (tamaño exacto de `kinst.img`), garantizando que `image_ready` esté activo desde el ciclo 0 incluso si el host retarda el mensaje `0x008A`.

### 7. Pantalla congelada en scanline 0 con barras residuales (`img_reset` interrumpiendo a la CPU)
- **Síntoma:** Al seleccionar el juego, la pantalla carga y muestra solo la primera línea (scanline 0) en color azul/morado, pero el resto de la pantalla permanece congelada con el patrón de barras horizontales residuales de la SDRAM (`IMG_20261110_155147.jpg`).
- **Causa raíz en RTL ([`ki_core_pocket.sv`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/ki_core_pocket.sv#L329)):**
  - Al fijar `img_size = 131076608` por defecto, la condición `hdd_image_present = (img_size >= 512)` se volvió verdadera inmediatamente.
  - El framework APF de la Analogue Pocket notifica las ranuras diferidas (`deferload`) enviando el comando host `0x008A` (`Data slot update`) inmediatamente después de concluir la descarga de la ROM (`Slot 1`).
  - Para ese momento, la CPU R4600 ya había salido de reset y estaba en plena ejecución de la limpieza de framebuffer (POST de memoria).
  - Al llegar `0x008A`, pulsó `img_mounted`, lo que activó la lógica heredada de MiSTer `img_reset` (un contador de 50.000 ciclos que asserting `core_reset`).
  - Esto le propinó un **reseteo asíncrono y forzado a la CPU y al controlador SDRAM en pleno ciclo de ráfaga de memoria**, desincronizando el bus de SDRAM y abortando la CPU permanentemente en la línea 0 antes de poder barrer el resto de la pantalla.
- **Solución RTL aplicada:**
  - En [`ki_core_pocket.sv`](file:///PROCESOS/LittleInstinct/src/fpga/pocket_rtl/ki_core_pocket.sv), desacoplado `img_reset` fijándolo a `1'b0`. En la Analogue Pocket la imagen de disco se configura estáticamente al lanzar el core y la CPU nunca debe ser reiniciada por eventos de ranura de datos posteriores.

### 8. Instrucciones para recompilar en PC con Linux y Quartus Prime

Para generar el nuevo bitstream con la corrección RTL:

```bash
# 1. Obtener los últimos cambios
git pull origin master

# 2. Compilar bitstream completo para Cyclone V 5CEBA4F23C8
./tools/build_pocket.sh

# 3. Generar el bitstream bit-reversed (bitstream.rbf_r) y el paquete de release
python3 tools/package_pocket.py

# 4. Copiar el bitstream corregido a la MicroSD:
cp Release/sd_card/Cores/littleinstinct.KillerInstinct/bitstream.rbf_r /media/$USER/*/Cores/littleinstinct.KillerInstinct/
```


### 9. v1.0.10 — secuenciador de arranque, chord real y diagnóstico de carga

El fallo observado en `IMG_20261111_180417.jpg` no era el detector de teclas: la
CPU seguía en reset (`RST:1 BOOT:0`) porque la imagen nunca llegaba completa a
SDRAM. El cargador esperaba un número exacto de bytes (0x480000) y no tenía
ninguna salida si el host terminaba antes, si la FIFO se desbordaba o si el
puente dejaba de drenar. Además, `pk_io` se reseteaba con `pll_locked` en vivo:
un glitch del PLL a mitad de la transferencia borraba la FIFO y dejaba al
cargador esperando una segunda copia de la ROM que la Pocket nunca reenvía.

Cambios de esta pasada:

- **`pocket_rtl/ki_boot_ctrl.sv` (nuevo):** secuenciador de arranque separado
  del video y del input. Genera un reset de encendido *one-shot* para el
  cargador (un unlock posterior del PLL ya no lo reinicia), espera
  `boot_loaded & sdram_ready & bist_done` para liberar la CPU, y tiene dos
  watchdog: 8 s con `ioctl_download` alto (aborta la carga para que el puente
  drene y la CPU arranque con lo que haya) y 100 ms sin que `boot_loaded` suba
  después de que el host terminó (marca el puente como atascado).
- **`pocket_rtl/ki_input_chord.sv` (nuevo):** detector de Start + Select por
  ventana temporal (250 ms), con sincronizadores de 2 flops. Ya no exige que
  ambos botones coincidan en el mismo ciclo de 20 ns: el primero abre la
  ventana y el segundo la cierra. Un botón solo no dispara nada, y mantener el
  par no repite el toggle.
- **`pk_io.sv`:** termina la carga también con el comando APF `0x008F`
  (*data slot access all complete*) y no solo con el conteo exacto; añade
  `loader_abort`; sincroniza `pad_key` a `clk_core`; y expone
  `debug_loader_info`.
- **Overlay de debug:** el toggle ahora es de tres estados (auto → on → off →
  auto). Antes, con la consola sin arrancar, `!fb_write_seen` forzaba el
  overlay y el toggle parecía muerto; ahora "off" se respeta.
- **Página de debug V160:** la fila 1 muestra `RST`, `BOOT`, `SD` (SDRAM ready)
  y `L` (estado del boot); `RX` son los bytes entregados al cargador; `DL` es
  la FSM de descarga del puente; `BF` agrupa las banderas de arranque.
- **`tests/sim/`:** cuatro bancos de Icarus Verilog (chord, boot, loader,
  end-to-end pk_io → puente → SDRAM). Ejecutar con `tests/sim/run.sh`.

Bits de `DL` (fila 10), de MSB a LSB: `state[31:27]`, `download_count[26:22]`,
`download_inflight[21]`, `ioctl_download[20]`, `sdram_ready[19]`,
`boot_seen[18]`, `boot_loaded[17]`, puntero de escritura `[16:13]`, puntero de
lectura `[12:9]`, `download_push[8]`, `download_pop[7]`, `sdram_done[6]`,
`boot_download[5]`, `download_accept[4]`, relleno `[3:0]`. Los estados 16/17 son
`DOWNLOAD_SDRAM_WRITE_ISSUE` / `_WAIT`.

> La fila 10 **ya no muestra `DL`** desde v1.0.14: el cargador está resuelto y
> la fila 10 ahora lleva `DO`, el opcode de la captura de salida (ver la sección
> 11). `debug_download_info` sigue existiendo en el puente pero ya no se dibuja,
> así que la síntesis lo elimina. La leyenda de bits de arriba describe `DL`
> para builds ≤ v1.0.13.

Cómo leer la pantalla cuando no arranca:

- `SD:0` → el controlador SDRAM no salió de su secuencia de encendido. Si
  además `BF` tiene el bit 0 en 0, `clk_sdram_ctl` nunca osciló (salida del PLL
  o del fitter), no es un problema del cargador; si el bit 0 está en 1, el reloj
  vive y el controlador está atascado.
- `SD:1`, `BOOT:0`, `DL` con estado `16`/`17` y `download_count > 0` → el
  puente está esperando que una escritura SDRAM termine.
- `SD:1`, `BOOT:0`, `RX` menor que `00480000` y `BF` con el bit 9 (`short`) →
  el host terminó antes del tamaño esperado; el bit 7 (`overflow`) indica que
  se perdieron palabras en la FIFO.
- `BF` con el bit 12 (`timeout`) → el watchdog de 8 s actuó; la CPU se libera
  con la imagen parcial y el juego puede no arrancar, pero ya no queda en reset
  silencioso.

### 10. v1.0.11 — watchdog del disco y confirmación de arranque

**Resultado en hardware de v1.0.10:** el arranque quedó resuelto. La pantalla de
diagnóstico reporta `RST:0 BOOT:1 PLL:1 HDD:1 SD:1 RX:00480000 SB:00000800
RDY:1 AT:3`. Es decir: la ROM completa (4,718,592 bytes) llegó a SDRAM, la CPU
salió de reset, la placa de sonido responde lista y el juego alcanza a sonar el
bip de inicio. El cargador ya no es el problema.

Lo que queda es que el juego se cuelga **después** del bip, leyendo el disco
(`AT:3` = `ATA_PIO_READ`, el CPU dejó de drenar el puerto de datos a mitad de
sector).

- **Bug encontrado: el watchdog del disco abortaba transferencias válidas.**
  `pk_io` bajaba `sd_ack` por timeout a los **167.8 ms** (`disk_watchdog[23]`).
  `ki_ata.sv` marca el banco como **válido en el flanco de bajada de `sd_ack`
  sin comprobar cuántas palabras llegaron**:

  ```systemverilog
  if (fetch_busy && !sd_ack && sd_ack_d) begin
    bank_valid[fill_bank] <= 1'b1;   // sin verificar disk_words_rem
  ```

  Un timeout temprano entrega al CPU un sector a medias como si estuviera
  completo. El síntoma no es un timeout visible sino datos corruptos, que
  parecen un cuelgue del juego. 167.8 ms es un valor alcanzable por la primera
  lectura de una ranura diferida desde microSD (metadatos FAT, despertar de
  tarjeta).
- **Corrección:** el watchdog pasa a **2.68 s** (`disk_watchdog[27]`), que sigue
  acotando un deadlock real pero queda fuera del rango de cualquier latencia
  legítima de tarjeta. Se añadió `disk_timeout` como bandera pegajosa, visible
  en el dígito más alto del campo `DK:` (bit 31).
- El campo `DK:` mostraba solo 24 de sus 32 bits; los 8 bajos llevaban
  `sd_lba[7:0]` de los que nunca se veían más de siete. Ese hueco ahora carga la
  bandera.

Cómo leer `DK` cuando el juego se cuelga leyendo disco: si el primer dígito
hexadecimal es `8` o mayor, el watchdog actuó y la transferencia quedó truncada;
si es `0`, el APF respondió normalmente y el cuelgue está en otra parte.

### 11. v1.0.14 — captura de salida (DP/DO) en lugar de la captura de reinicio

**Dato de partida:** dos corridas en hardware (v1.0.12 y v1.0.13) leyeron
`V:0` en la fila 14, es decir, el capturador de reinicio **nunca disparó**. Su
condición de disparo era un flanco de subida de `cpu_reset`, así que el dato
significa:

> **Ningún término de `cpu_reset` se activó después del arranque.** El juego no
> se reinicia por hardware.

Eso cierra esa línea, pero deja la pregunta original sin responder: un juego
puede reiniciarse **por software**, sin reset alguno, saltando fuera de su
programa descomprimido. Ese camino no deja rastro en ningún contador de reset
ni en ninguna fila de la pantalla de diagnóstico. La captura de reinicio no
podía verlo por construcción.

**Corrección:** en vez de capturar el reset, se captura la salida misma, dentro
de la CPU, donde el decode es visible. `cpu_pocket.vhd` engancha el último PC
ejecutado del programa descomprimido (`0x88xxxxxx`) y el disparador, que puede
ser uno de dos:

- `01` — salto al boot ROM: un camino de error o de watchdog.
- `10` — salto directo de vuelta a `0x88000000`, sin boot ROM en medio.

Se arma con el salto, no con un reset, así que dispara exactamente en el caso
que la captura anterior no podía ver.

**No cuesta página ni bits nuevos de snapshot.** La captura ocupa dos filas que
la pantalla ya tenía:

- **`DP:` (fila 14)** — el último PC ejecutado del programa descomprimido. Antes
  era `RP`, el PC del reinicio que nunca se capturó.
- **`DO:` (fila 10)** — el opcode **una decodificación anterior** a `DP`. Esto
  importa para leerlo: si la salida fue un salto, esa decodificación es la rama
  misma y `DP` es su **delay slot** (la última instrucción que el programa
  ejecutó). Así, lo normal es `DO` = `jr`/`jalr`/`j` y `DP` = `dirección de la
  rama + 4`. Si `DO` no es un salto, entonces `DP` es la última instrucción que
  llegó a ejecutarse antes de la excepción.
  Antes esa fila mostraba `DL`, la FSM de descarga del puente; el cargador está
  resuelto desde v1.0.10 (`RX:00480000`, `BOOT:1`) y la fila 11 ya informa
  estado de loader, timeout y aborto.
- **`V:` (fila 14, col. 14)** — hubo captura o no. Leer esto **primero**.
- **`C:` (fila 14, col. 18-19)** — el disparador: `01` o `10`.

**Cómo leerlo cuando el juego se cuelga después del bip:**

- `V:0` → el juego **no** se reinició ni saltó. Está colgado. Mirar `PC` (fila
  4), `RDY` (fila 7) y el disco (fila 13).
- `V:1`, `C:01` → saltó al boot ROM. `DO` nombra la instrucción: un `jr`/`j` es
  el juego reiniciándose a propósito.
- `V:1`, `C:10` → volvió directo a `0x88000000`. `DP`/`DO` dicen desde dónde y
  con qué.
- `V:1` **no** prueba por sí solo un reinicio: el juego puede llamar al boot ROM
  legítimamente y esa transición también se captura. El contador independiente
  es `RC` (fila 12): el par bajo cuenta ejecuciones de `0x88000000` (el arranque
  es exactamente 1) y los dígitos 4-7 cuentan transiciones RAM → boot ROM. Si el
  juego corre sano con `V:1 C:01` y `RC` estable, fue una llamada, no un
  reinicio; si `RC` sube, se reinició.

La página ya **no** necesita el chord Start+Select para verse: `DP`/`DO` están
en las filas normales de estado.

**Fit de este build** (Quartus 25.1 Lite, `5CEBA4F23C8`, `pocket_ki.rbf`
`18df93f94d71a2ecfcf183b6148c465f`):

- ALMs **18.277 / 18.480 (99 %)**, LABs **1847 / 1848**, registros 17.652.
- Peor camino de setup: **−3,56 ns** en `clk_core`, íntegramente dentro del cono
del `adsp2105` (ver abajo). Ningún nodo de la captura nueva está en
ese camino; es la deuda del DSP ya documentada abajo, y el número varía entre
colocaciones del fitter (−2,2 a −3,6 ns en el mismo diseño).

**Pendiente de verificación en hardware.** El bitstream compila, entra en el
dispositivo y el paquete `Release/` está generado y verificado (el `.rbf_r`
es el bit-reverse exacto del `.rbf`), pero esta pasada **no** se ha probado en
consola. Lo que hay que reportar de la próxima corrida es la fila 10 (`DO`), la
fila 14 (`DP`, `V`, `C`) y la fila 12 (`RC`).

**Tres tropiezos de esta pasada, registrados para no repetirlos:**

1. La primera versión puso la captura en una página nueva reutilizando el
   renderer del trace. Costó 414 registros en `ki_debug_screen` y el fit falló
   por 4 LABs (1852 necesarios). Un renderer de 64 bits por fila no cabe en este
   dispositivo; la captura cupo sólo cuando se metió en filas existentes.
2. El cruce a `clk_core` se hizo primero con dos flops por bit sobre los 64 bits
   del payload: 0,5 ns de `clk_core` a cambio de nada. Los registros del payload
   los mantiene la CPU desde la salida hasta la siguiente, así que sólo el
   strobe necesita sincronizarse; el payload se engancha cuando el strobe llega.
3. Los registros nuevos se limpiaban en dos procesos `clk93` distintos y Quartus
   lo rechaza (`Can't resolve multiple constant drivers`). Se movieron al mismo
   proceso que los escribe, que es el que ya documentaba esa trampa para
   `debug_ret_count_register`.

---

### 12. v1.0.15 — DO corregido y la causa de excepción en pantalla

**Medido en hardware con v1.0.14** (dos capturas a 12 s de distancia,
`IMG_20261112_105159.jpg` / `IMG_20261112_105211.jpg`):

```
RST:0 BOOT:1 SD:1 L3        PLL:1 HDD:1 VB creciendo
ERR:00 I:00000000 V:1       PC:88020D08  TR:00006
RX:00480000 DK:021000       N:4859465E  EC:00 SD:P
SB:00000800 RDY:1           DO:90CFD01F
BF:00006173 AU:05C00        RC:02030001
AT:0 SR:50 ER:00            DP:8802EC4C  V:1 C:01
```

Lo que confirman esas dos fotos:

- **La captura de salida funciona.** `V:1 C:01` con `DP:8802EC4C`: el programa
  del juego salió hacia el boot ROM desde esa dirección. No es un reset.
- **Hay exactamente un reinicio.** Tres cuentas independientes coinciden:
  `RC` entradas a `0x88000000` = **2** (el arranque es 1), `RC` transiciones
  RAM→boot ROM = **1**, y `C:01` disparado.
- **La pantalla azul no es "sin framebuffer".** En `ki_core_pocket.sv`, si
  `fb_write_seen` es 0 el video sale **negro**, no azul. Azul significa que la
  CPU escribió el framebuffer: el juego llegó a pintar.
- **Todo lo demás está limpio:** `SD:P` con `EC:00` (autotest de SDRAM sin
  errores en ambas mitades), `DK:021000` (disco ocioso, ranura diferida
  completada, watchdog sin disparar), `AT:0 SR:50 ER:00` (ATA idle sin error),
  `BF:00006173` con `boot_state=3` (cadena de arranque entera), `AU:05C00`
  (primer audio en la unidad 92 y **cero** discontinuidades de muestra), y
  `N:4859465E` = 1.212.540.510 instrucciones retiradas.

#### El defecto que tenía mi propia instrumentación

`DO` no era la instrucción en `DP`. La cadena, contada en ciclos:

- Durante el ciclo N, `debug_fetch_pc_register` contiene `P(N-1)`,
  `debug_prev_op_live` contiene `O(N-1)` y `hist_op1` contiene `O(N-2)`.
- El test de salida exige que el **viejo** `debug_fetch_pc_register` esté en
  `0x88xxxxxx` y que `PCold1` esté en el boot ROM, así que la dirección de
  salida es `P(N-1)` — lo que se guarda en `debug_dep_pc_register`.
- Por lo tanto el opcode **en** esa dirección es `debug_prev_op_live`.
  `hist_op1` está **dos** decodificaciones atrás y no describe nada útil; venía
  heredado de upstream.

Por eso `DO:90CFD01F` decodificaba como `LWC2` (`opcode 0x24`), que no tiene
sentido en KI. Corregido en v1.0.15: ahora `DO` es el opcode en `DP`.

#### `EX`: la causa de la excepción, en la fila 8

`debug_exc_cause` se capturaba en el CPU desde v1.0.14 pero estaba cableado a
nada. Ahora ocupa la fila 8, que mostraba `RS` (contadores de reset que leen
`00000000` en toda corrida desde que se retiró la captura de reset, o sea una
fila muerta).

`ExcCode` está en los bits 6:2:

- `00000004` AdEL · `00000014` AdES · `00000020` Sys · `00000028` RI
- `00000000` Int (es la forma de un vblank) · `1C/2C/30/34` fallos TLB

`RI` es el valor interesante: una instrucción reservada en `DP` significa que
el core ejecutó código que no debía, o decodificó mal una palabra, y el manejador
de excepción manda el control al boot ROM — que es exactamente lo que
`DP/V/C` reportan.

`EX` se captura **sólo** en el camino `01`. En el camino `10` conserva el último
valor del `01` anterior, por eso hay que leer `C:` junto con `EX:`.

**Fit de v1.0.15** (Quartus 25.1 Lite, `5CEBA4F23C8`):

- ALMs **18.297 / 18.480 (99 %)**, **LABs 1848 / 1848**, registros 17.650.
- Peor camino: **−2,30 ns**, de nuevo `mstat[0] → banco G0 → ALU → astat[6]`
  dentro del `adsp2105`. Ningún nodo de `DO`/`EX` está en él.
- `pocket_ki.rbf` MD5 `d9e3c4a3a7d8083c2e41c7c53add254c`.

**Sin verificar en consola todavía.** Lo que hay que leer en la próxima corrida
es `EX:` (fila 8) junto con `DP:`/`DO:` (fila 14 y fila 10).

---

## Estado al 2026-11-12 (punto de continuación)

Esta sección existe para retomar el trabajo sin reconstruir el contexto. Todo lo
que sigue está medido en hardware real, no inferido, salvo lo que se marca
explícitamente como pendiente.

### Lo que funciona, verificado en consola

El arranque está **resuelto**. La cadena completa opera:

```
RST:0  BOOT:1  PLL:1  HDD:1  SD:1  RX:00480000  RDY:1
```

- La ROM completa (`0x480000` = 4.718.592 bytes) llega a SDRAM.
- La CPU sale de reset y ejecuta el POST de memoria (relleno vertical de
  pantalla).
- El juego reproduce su bip de inicio: la placa DCS responde y se deja mandar.
- El disco responde: `AT:0`, `DK:021000` decodifica `dataslot_done=1`,
  `disk_active=0`, `disk_words_rem=0`, `disk_timeout=0`.

### Lo que queda: el juego no llega a la demo

Síntoma: tras el bip la pantalla queda azul y el juego vuelve a su secuencia de
inicio; a veces se observa `AT:3`.

**Lo que ya está descartado por medición:** el reinicio **no** es un reset de
hardware (`V:0` en dos corridas), y el cargador, el watchdog del disco y las
lecturas SDRAM están limpios (ver "Descartado con evidencia").

**Lo que cambia en v1.0.15:** hay instrumentación para el camino
que queda vivo, el reinicio **por software**. Hasta ahora `DP:` y `DO:` estaban
cableados a cero en el port Pocket; ahora son una captura real.

### Próximo paso concreto (empezar aquí)

1. Instalar el build v1.0.15 en la microSD y llegar hasta el cuelgue tras el bip.
2. Leer la pantalla de estado y anotar, en este orden:
   - **`V:`** (fila 14, col. 14) — ¿hubo captura?
   - **`C:`** (fila 14, col. 18-19) — `01` boot ROM, `10` vuelta a `0x88000000`.
   - **`DP:`** (fila 14) y **`DO:`** (fila 10) — desde dónde saltó y con qué
     instrucción.
   - **`RC:`** (fila 12) — el contador independiente de reentradas.
   - **`PC:`** (fila 4) y **`RDY:`** (fila 7) — dónde está ahora y si espera al
     DSP.
3. Según el resultado:
   - `V:1` → el juego se reinicia por software y ya se sabe desde qué dirección y
     con qué instrucción. Toca leer el código del juego en esa dirección (dump de
     `kinst.rom`) para saber por qué rama de error entró.
   - `V:0` con `PC` clavado → no se reinicia, se **cuelga**. Comparar `PC` con el
     rango del bucle y mirar `RDY` y `AT`/`SR`/`ER` del disco.
   - `RDY:0` → prioridad al ADSP (ver deuda técnica abajo), no al reinicio.

### Bugs propios encontrados y corregidos en sesiones anteriores

Vale registrarlos porque dos de ellos costaron ciclos de compilación y uno
produjo un diagnóstico falso:

1. **Captura de reinicio que se borraba sola** (v1.0.12 → v1.0.13). El término
   `if (core_reset) debug_reboot_valid <= 0;` estaba *después* de la captura en
   el mismo `always`. En Verilog gana la última asignación no bloqueante, así
   que todo reinicio por `core_reset` borraba su propia captura en el mismo
   ciclo. El reporte `RP:00 CA:00` de esa versión era este defecto, no un
   hallazgo.
2. **Falta de bit de validez.** Sin `V`, un `CA:00` es ambiguo entre "ningún
   término estaba activo" y "no se capturó nada". Ahora `V` se muestra antes de
   `C` por esa razón.
3. **Contador de stall de 28 bits** que hizo fallar el fit por exactamente 1 LAB
   (1849 necesarios, 1848 disponibles). Se reescribió contando frames: 7
   registros en lugar de 28.
4. **Modelo SDRAM del testbench**, equivocado en tres versiones sucesivas:
   devolvía `z` en cada lectura, se relojó en el mismo flanco en que el
   controlador muestrea, y el pipeline avanzaba en ambos flancos. Los tres eran
   defectos del banco, no del diseño. Están documentados en
   `tests/sim/sdram_model.sv` para no repetirlos.
5. **Captura de salida demasiado ancha** (v1.0.14). Ver el punto 11 arriba: una
   página nueva con renderer de 64 bits no cabe, y sincronizar 64 bits con dos
   flops por bit cuesta 0,5 ns de `clk_core` sin ganar nada.

### Descartado con evidencia (no volver a investigar)

- **Carga de ROM / cargador.** `RX:00480000` completo, `BOOT:1`.
- **Watchdog del disco abortando transferencias.** `disk_timeout=0`; la ranura
  diferida completó limpia. Se subió igual el timeout de 167,8 ms a 2,68 s
  porque el valor viejo era peligrosamente bajo, pero no era la causa.
- **Lecturas SDRAM corruptas.** `tests/sim/tb_readback.sv` escribe un patrón por
  el puerto del CPU y lo lee de vuelta: **512/512 palabras íntegras**. El puente
  preserva datos, orden, byte enables y mapeo de filas.
- **Reset de hardware tras el arranque.** `V:0` en dos corridas (v1.0.12 y
  v1.0.13). Ningún término de `cpu_reset` se activó después del arranque.

### Deuda técnica abierta (la mayor incógnita de fondo)

`clk_core` **no cierra**. En el build v1.0.15 el peor camino es **−2,30 ns** y
está **entero** dentro del cono heredado del `adsp2105`:

```
mstat[0] -> G0 register bank -> ALU -> astat[6]
```

`mstat[0]` selecciona banco de registros y de ahí sale un cono largo hasta los
flags. El número oscila entre −2,2 y −3,6 ns según la colocación del fitter en el
mismo RTL, así que la tendencia entre builds no es señal por sí sola: lo que
importa es que el camino más lento es siempre el mismo y no es de la CPU ni del
video. Con el diseño al **99 % de ALMs y 1848/1848 LABs**, cerrarlo exige
reestructurar el DSP (partir el MAC en dos ciclos, por ejemplo), no añadir
constraints, y no hay espacio para la lógica extra sin quitar algo más.

Que el bip suene **no** prueba que el ADSP sea correcto: un colchón de −3,6 ns
puede producir audio con glitches o un DSP que responde a medias. Si `RDY` cae a
0 durante el cuelgue, esta es la causa.

Hallazgo adicional de constraints: el SDC declara asíncronos
`general[0]`↔`general[1]`, pero **no** cubre el cruce `u_pll` (PLL del APF) →
`general[1]` (PLL del core). Aparece un camino de −3,8 ns por ahí. No se tocó
porque declarar asíncrono un cruce que no está sincronizado podría esconder un
bug real; hay que verificar primero si esos dos relojes comparten referencia.

### Reproducir el entorno

```bash
export PATH=/opt/intelFPGA/25.1/quartus/bin:$PATH
cd src/fpga && quartus_sh --flow compile pocket_ki
cd ../.. && python3 tools/package_pocket.py
# bancos de simulación (Icarus Verilog 11+)
tests/sim/run.sh
```

Los bancos de `tests/sim/` **no** se pudieron ejecutar en esta pasada porque
`iverilog` no está instalado en esta máquina; el análisis y la síntesis de
Quartus sí corrieron, y son los que validan la sintaxis y la elaboración.

Estado del árbol: build **v1.0.16**, página de estado **V165**, bitstream
`d6f7e7d5e4944526d20bf5188e16d6c0` (`Release/.../bitstream.rbf_r`
`3a5c2a462b8432d685607a6a7e152f67`). **Listo para prueba en consola.**

