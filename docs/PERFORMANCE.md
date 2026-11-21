# Performance: why the Pocket build runs Killer Instinct at 30 fps

Written 2026-11-21, after the speed work of builds V224-V237 (v1.1.38 -
v1.1.51), released as **v1.2.0**. Same rule as `STATUS.md`: **measured** means
an on-hardware census or a Quartus report says so; **estimate** means
arithmetic on those numbers.

## Summary

- **Measured:** in fights and in the attract demo the game draws a new frame
  every **two** vblanks (~29.5 fps against the arcade's ~59 fps), with
  occasional frames at three before V230. v1.2.0 is stable: no hangs, no
  graphics corruption (V237 played through fights on hardware).
- **Measured:** the CPU is busy for the whole two vblanks. It is not waiting
  for anything: the idle meter reads under 2 % of the frame.
- **Measured:** the instructions alone do not fit in one vblank at 50 MHz.
  A fight frame retires RT = 0F34-0FF8 units (x256) of instructions; one
  vblank is 0CEF units. Even with a perfect memory system (one instruction per
  cycle, zero stalls), a frame would take ~1.2 vblanks.
- **Conclusion:** 30 fps is the ceiling of this design on the Pocket. The
  arcade's R4600 runs at 100 MHz; this core's CPU runs at 50 MHz, and the
  Pocket's FPGA cannot clock it faster (see "Raising the clock" below). 60 fps
  would need a CPU core roughly twice as fast, not more cache or bridge tuning.

## How to measure (debug Perf page)

Start+Select switches the overlay between the status page and the **Perf**
page. Values are hex, in units of 256 CPU cycles unless noted; a window is
one game frame (page flip to page flip).

| Field | Meaning |
|---|---|
| `C` | cycles in the frame. `19DE` = two vblanks at 50 MHz; one vblank is `0CEF` |
| `RT` | instructions retired |
| `DC` | data-cache stall (cached accesses) |
| `S1` | instruction-fetch stall; `LB` load-use bubble; `MD` multiply/divide |
| `MC` | data-cache misses (a count); `LM` of them below 0x80000 (framebuffers) |
| `ID` (row 14, V236+) | **idle** cycles: inside runs of >256 cycles with no lost cycle. `C - ID` is the frame's busy time |
| `FP` (row 14, V233+) | **game frames per 5.37 s** (2^28 cycles, ~316 vblanks). `013C` = every frame in one vblank (60 fps), `009E` = every frame in two (30 fps), lower = some in three |

The one-frame census swings with the scene (the same build read lost cycles
0A51 and 0CD7 a minute apart). Compare builds on **FP** over the same scene,
after staying on the page ~6 s.

## What was tried, in order

| Build | Change | Result on hardware |
|---|---|---|
| V225 | `DCACHE_SKIP_FILL` + `DCACHE_FB_PARTIAL` (upstream defaults) | faster, **graphics corruption** in the gym stage; timing needed seed 1 |
| V226 | bisect: FB_PARTIAL off | clean; slowest frame 2 vblanks instead of 3 |
| V227 | bridge `LINE_DQM`: one 16-word write-back burst with real byte enables | clean; **proves DQM works on the Pocket** (a MiSTer comment said otherwise) |
| V228 | FB_PARTIAL back on with LINE_DQM | clean, no gain |
| V229 | `WB_EARLY` + `STORE_BUFFER` + `SB_FORWARD` | **hung at boot** (PC 8802DBD0) |
| V230 | `WB_EARLY` alone | clean, **best single gain**: lost cycles 0CDF -> 0968, DC 09C6 -> 0620 |
| V231 | store buffer fixed (two bugs from commit 73d38f3's timing edits) and re-enabled | clean, neutral |
| V232 | CPU outranks scanout and DCS ROM after 4 cycles instead of 64 | clean, neutral within noise |
| V233 | `FP` field | baseline: fights at FP 009C-009E |
| V234 | 64 KiB M10K L2 cache on both fill paths | **hung at boot** (ERR 02, error_stall) |
| V235 | L2 on the bridge path only | clean, **~20 % hit rate**, FP unchanged; a fight sweeps far more than 64 KiB |
| V236 | L2 off; `ID` idle meter | fights: ID 0040-006E, i.e. **busy the whole frame** |
| V237 | `DCACHE_READ_AHEAD` + `RA_ANSWER` (upstream defaults) | clean; released as v1.2.0 |

The D-cache generics now match upstream except `DCACHE_CWF_FB`,
`DCACHE_FILL_FIRST` and `DCACHE_FILL_AT_MISS`, which assume a fill order the
Pocket bridge does not implement and a framebuffer in on-chip RAM (here it is
in SDRAM).

### Bugs found on the way (fixed)

- **Store buffer** (`cpu_datacache.vhd`, V231): commit 73d38f3 had edited the
  buffer for timing while it was disabled. A store that hit the parked qword
  index in the other way was dropped while its tag was marked dirty, and a
  load the buffer could not forward read the RAM without the store. Both are
  restored to upstream's semantics without the tag compare on the write
  enables.
- **L2 on the direct-fill path** (`ki_l2_cache.sv`, V234 -> V235): the CPU
  launches a direct fill only while the bridge is idle, and `ki_sdram_burst`
  relies on that toggle reaching it before the bridge's next request can. The
  L2's lookup delayed the toggle 1-2 cycles; a scanout or DCS request could
  then land on the same edge, and `ki_sdram_burst`'s `new_rd` overwrote the
  direct request for good. `L2_FAST=0` keeps that port a wire. The L2 is now
  instantiated with `L2_ENABLE=0` (a pass-through).

## Raising the clock (not possible on this FPGA)

- **Separate CPU clock at 69-75 MHz** (measured, V231 timing report): 1,423
  CPU endpoints fail at 69 MHz and 2,041 at 75 MHz; worst CPU path ~55 MHz.
  The device is at 93-98 % ALMs and 100 % LABs, speed grade -8. An
  asynchronous CPU clock also loses `SYNC_CROSSING`, `DIRECT_FILL` and
  `DCACHE_EARLY_RESTART`, which together cost about what the faster clock
  would gain (estimate: +3.5-5.5 ms per frame).
- **Whole synchronous domain at 56.25 / 112.5 MHz** (measured, timing-only
  build, branch discarded): the CPU itself nearly fits (4 endpoints, -0.47 ns),
  but the SDRAM data capture has a negative eye (-0.53 ns setup and -0.19 ns
  hold at once; no PLL phase fixes both), the direct-fill data path fails by
  -4.08 ns, and the Pocket's AS4C32M16MSA-6 needs CL3, tRP 3 and tRCD 3 above
  100 MHz, so SDRAM wall-clock latency would not improve.

## If someone continues

Only these could move the ceiling, and none is small:

1. A faster CPU core (dual-issue, or a deeper pipeline that closes ~100 MHz)
   on a larger FPGA. Out of reach on the 5CEBA4.
2. Moving both framebuffers to the Pocket's two idle 16 MB PSRAMs, so the
   SDRAM serves only the CPU. Estimate 15-25 % on stalls; it would remove
   three-vblank frames but cannot reach one vblank, because the instructions
   alone exceed it.

Freeing ALMs first means a release build without the debug overlay and the
census (`DEBUG_BUILD=0`, ~1,150 ALMs), which also removes the Perf page used
to measure.
