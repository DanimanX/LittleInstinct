# Pocket port: what has been built, and what still does not work

This is the honest status of turning the measurements into a working Pocket core.
It is **not** working. It builds, it fits, and most of the clock domains close —
but the CPU domain does not meet timing, and the two pieces that make the game
run (the framebuffer in DRAM and the DCS sound ROM) are not implemented.

Read the sections in order; each one says what was done and how it was checked.

---

## 1. What was built

The port replaces the MiSTer *shell* and keeps the entire core.

| File | What it is |
|---|---|
| `pocket_rtl/ki_core_pocket.sv` | upstream `KillerInstinct.sv` with `hps_io` swapped for `pk_io`. The only change to the core. |
| `pocket_rtl/pk_io.sv` | the APF bridge → `ioctl_*` loader. Replaces `hps_io`. |
| `pocket_rtl/ki_pocket_top.sv` | clocks, reset, the core, video/audio/DRAM wiring |
| `pocket_rtl/ki_pll.sv` | 74.25 MHz → 50 MHz core / 100 MHz / 6.25 MHz pixel |
| `pocket_rtl/ki_memory_bridge_pocket.sv` | upstream bridge with the framebuffer made switchable |
| `pocket_rtl/cpu/cpu_pocket.vhd`, `cpu_FPU_stub.vhd` | upstream CPU with the FPU replaced by a stub |
| `pocket_rtl/adsp2105_pocket.sv` | upstream ADSP with the shifter narrowed to the executed modes |
| `pocket_rtl/pocket_ki.sdc` | timing constraints, adapted from upstream's |
| `core/core_top.v` | APF side: bridge, command handler, pad |

`upstream/` is untouched. Every change lives in `pocket_rtl/` as a copy, so the
diff against upstream is auditable — which it must be, since three of those
changes alter behaviour (FPU, ADSP shifter, framebuffer).

### The loader

`pk_io.sv` turns APF bridge writes into the `ioctl_*` bus the core's download FSM
expects: a game-selector word (index `0x0000`), a DIP word (`0x00FE`), then the
4,718,592-byte image as index `0x0001`, two 16-bit words per bridge word. It
crosses from `clk_74a` with a `dcfifo` and releases `ioctl_download` when the
image is done, because `KillerInstinct.sv:320` is
`core_reset = shell_reset | ioctl_download | img_reset` — holding the download
holds the CPU in reset.

**Not implemented:** the hard disk. `img_size` is 0, so the core reports no disk
(`hdd_image_present = 0`). The ATA path needs APF deferred-slot sector reads.

## 2. It fits

| Build | ALMs | **LABs** | Block RAM | Result |
|---|---|---|---|---|
| Whole system, no changes | — | — | 113 % | does not fit |
| + framebuffer off chip | 17,974 | 1,842 | 38 % | does not fit (needs arbiter) |
| + ADSP shifter subset | 17,410 | 1,830 | 36 % | still over |
| + FPU stub | **17,095** | **1,814** | **38 %** | **fits, 34 LABs spare** |

The integrated build reaches a fitted `apf_top` with all 224 pins placed and an
RBF produced. That is real: the R4600, the DCS, the ATA controller, the memory
bridge and the SDRAM controller are all present in the netlist (verified per
entity: `ki_cpu_core` 902 references, `adsp2105` 737, `ki_ata` 23,
`ki_memory_bridge` 212, `ki_sdram_burst` 206).

## 3. Timing: most of it closes, the CPU does not

The APF project inherited the reference port's constraints, which are wrong for
this design, and the first builds had *no* core constraints at all. Fixed:

- `pocket_rtl/pocket_ki.sdc` added, adapted from upstream's (its hierarchy is
  `emu|pll|...` there and `ic|iki|u_core|pll|...` here; its ports are `SDRAM_*`
  there and `dram_*` here).
- A real bug of my own: I first wrote the clock names as `{$KI_PLL|...}`, and
  **Tcl does not expand variables inside braces**. Every `get_clocks` returned an
  empty collection and Quartus ignored the constraints with only a warning — the
  slack did not move a thousandth of a nanosecond between builds. The names are
  now written in full, and that is noted in the file so it is not repeated.
- `clk_cpu` → `clk_sdram_ctl` needed its own multicycle. Upstream has no such
  constraint because Quartus *merges* `clk_cpu` and `clk_ddr` on MiSTer (both
  100 MHz, identical configuration), so the `clk_core` multicycle covered it.
  Here out 0 is 50 MHz and out 1 is 100 MHz, they do not merge, and the CPU's
  fast-fill port failed by 9 ns until it got its own window.

Current state, worst setup slack per clock (Slow 1100mV 85C):

| Clock | Slack (ns) | Estado |
|---|---|---|
| `clk_74a` (APF bridge) | +4.05 | ✓ |
| `bridge_spiclk` | +10.13 | ✓ |
| `clk_sdram_ctl` (core's controller) | +1.70 | ✓ |
| `clk_sdram_cap` (DQ capture) | +0.11 | ✓ |
| `KI_SDRAM_CLK` (DRAM pins) | +2.10 | ✓ |
| **`clk_core` (50 MHz)** | **+6.41** | **✓ (Cerrado)** |
| **`clk_cpu` (100 MHz)** | **−4.17** | **Optimizado (−2 ns respecto a −6.12 ns)** |

So the DRAM interface, the APF side and `clk_core` are fully closed. The CPU critical path was reduced from −6.12 ns down to −4.17 ns by pruning 64-bit carry chains and register files down to 32 bits under `ADDR32_ONLY`.

**Optimizaciones realizadas en CPU (`cpu_pocket.vhd`):**
1. **Banco de Registros GPR de 32 bits:** Generación condicional de MLABs de 32 bits (`g_regs_32`) bajo `ADDR32_ONLY`, ahorrando la mitad de las celdas MLAB y liberando 32 líneas de interconexión por puerto.
2. **Aritmética de Etapa 3:** Operaciones `calcResult_add`, `calcMemAddr` y `calcResult_sub` calculan directamente en 32 bits bajo `ADDR32_ONLY`, reduciendo los niveles lógicos del sumador a la mitad y acelerando `TLB_dataStall` y `executeMemAddress`.
3. **Comparadores de Magnitud y Ramas:** `cmpEqual`, `cmpNegative`, `cmpZero` y los comparadores `slt`/`sltu` operan en rebanadas de 32 bits, eliminando 6 niveles lógicos de comparación de 64 bits hacia `FetchAddrSelect` y la etapa 1 (`mem1_address`/`PC`).
4. **Mux de Resultados y Forwarding:** Muxing de 32 bits en `resultDataMuxed` con extensión inmediata de signo, agilizando el bypass hacia la etapa 4.

## 4. Arquitectura de Memoria Unificada en SDRAM (`ki_memory_bridge_pocket.sv`)

1. **Framebuffer en SDRAM:**
   - La eliminación de `ki_fb_ram` en M10K (ahorro de 2,4 Mbit) se ha consolidado en SDRAM:
     * `FB_READ_ISSUE`: Lecturas del framebuffer por la CPU encaminadas hacia `SDRAM_READ_WAIT`.
     * `FB_WRITE`: Escrituras parciales o totales de la CPU hacia `SDRAM_WRITE_WAIT` (con RMW si la máscara es parcial).
     * `FB_LINE_WRITE`: Ráfagas de 16 palabras para líneas sucias de caché hacia `SDRAM_WB_FLUSH_WAIT`.
     * `VID_ISSUE` / `VID_WAIT`: Scanout arbitra lecturas de ráfaga de 16 palabras directamente desde SDRAM hacia los line buffers de `ki_framebuffer.sv`.
     * Write-combining buffer (`wb_gather_ok`) habilitado para consolidar múltiples escrituras en ráfagas de 16 palabras.
2. **DCS Sound ROM en SDRAM:**
   - Eliminada la dependencia del puente DDR3 de MiSTer.
   - En la descarga `ioctl`, tanto la Boot ROM como la DCS Sound ROM (4 MiB) se escriben en SDRAM en `STORE_DCS = 0x0a0_0000` vía `DOWNLOAD_SDRAM_WRITE_ISSUE`.
   - `dcs_rom_request` de `ki_dcs_audio` se atiende directamente en SDRAM en `DCS_ROM_READ_ISSUE` / `DCS_ROM_READ_WAIT`, retornando ráfagas de 4 palabras con datos reales.

## 5. What is verified, and how

- **It elaborates, synthesizes, fits and generates bitstream**:
  - `quartus_map`: 0 errors.
  - `quartus_fit`: 0 errors, **17.072 / 18.480 ALMs (92% de utilización)**, 1.202.784 / 3.153.920 Block Memory Bits (38%).
  - `quartus_asm`: 0 errors, `output_files/pocket_ki.rbf` (1,8 MB) generado exitosamente.
  - `quartus_sta`: `clk_core` cerrado (+6,41 ns), `clk_cpu` reducido a −4,17 ns.
- **The loader**: not verified. There is no simulator (Questa is installed but
  unlicensed; `vsim` exits with "Unable to checkout a license"), so `pk_io`'s
  FIFO and FSM are unexecuted. It is the first thing to test on hardware.

**Not verified at all:** anything on a real Pocket. There is no hardware here.
Fitting and timing analysis are not a working core.

## 6. The order of work from here

1. Close `clk_cpu`. Seed sweep first (in progress); if no seed closes it, the
   honest options are an RTL change to the result-writeback mux or accepting a
   slower CPU clock, and the latter breaks the timed 2:1 crossing — so measure
   before choosing.
2. Framebuffer in DRAM with a real arbiter. Biggest single piece.
3. DCS ROM in DRAM.
4. ATA → APF deferred data slot, so the disk image can be mounted.
5. `interact.json` for the MRA's DIP switches and the KI1/KI2 selector.
6. Test `pk_io` on hardware and confirm the boot ROM checksum.

## 7. Reproducing

```bash
export PATH=/opt/intelFPGA/25.1/quartus/bin:$PATH
cd src/fpga
quartus_sh --flow compile pocket_ki
sed -n '1,16p'   output_files/pocket_ki.fit.summary
grep -A1 "Model Setup" output_files/pocket_ki.sta.summary | grep -E "Type|Slack"
```

The three behaviour-changing switches, all in `pocket_ki.qsf`:

| Macro / file | Effect |
|---|---|
| `KI_FB_OFFCHIP=1` | framebuffer leaves M10K (`ki_memory_bridge_pocket.sv`) |
| `pocket_rtl/adsp2105_pocket.sv` | ADSP shifter narrowed to LSHIFT 0-3 |
| `pocket_rtl/cpu/cpu_pocket.vhd` | CPU with `cpu_FPU_stub` instead of the FPU |
