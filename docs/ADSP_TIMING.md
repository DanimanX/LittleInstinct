# Why setup does not close, and why it is only the sound DSP

Measured on the v1.0.29 bitstream, Quartus 25.1std Lite, `5CEBA4F23C8`,
SEED 9, Slow 1100 mV 85 C corner.

## The finding

`report_timing -setup -npaths 400` returns 400 paths and **all 400 violate, and
all 400 are inside `adsp2105`**. Nothing else in the design is negative.

Worst path, full detail:

```
Slack      -3.017 ns
From       ...|adsp2105:u_adsp|mstat[0]
To         ...|adsp2105:u_adsp|gr[29][15]        (the 48-bit MR, top word)
Launch/Latch clock  clk_core (general[0], 50 MHz, 20 ns)

clock path 13.314 ns   (PLL + global network, spent before the data leaves
                        mstat[0])
data path  22.278 ns
    mstat[0] -> Mux635~2                     2.175
    Mux635~2 -> Mux491~1                     2.178
    -> Mult0~24 (DSP block, ay[10])          4.597
    -> Mult0~374/370/366/5/1/13  carry chain ~5.700
    -> Add21~41 carry chain                  1.256
    -> ... to gr[29][15]
```

The other violations are the same cone: `mstat[0]` and `op_r[8]` to
`gr[29][*]` and to `astat[6]` (the MV flag), all between -2.9 and -3.0 ns.

Every path that ends in `ki_cpu_core` has **at least +1.436 ns of slack**. The
MIPS core is not the problem, and never was: v1.0.26's -2.039 ns and v1.0.27's
-2.199 ns were this same ADSP cone, not the CPU.

## Why a multicycle constraint cannot fix it

It is tempting: the DSP advances on `core_ce`, not every clock, so the path
"has more time". That is wrong here, and it is checkable.

`ki_dcs_audio.sv` sets `DCS_ENGINE_HZ = 35_750_000` against `CLK_HZ = 50_000_000`
and drives `dcs_ce` from a fractional phase accumulator:

```
wire dcs_ce = !pause && (dcs_phase_sum >= DCS_PHASE_MOD);
```

Simulating that accumulator over 40 clocks gives

```
0110111011011101101110110111011011101101
```

- duty 0.70
- **longest run of consecutive `dcs_ce` high: 3**

Three consecutive enables means a register-to-register path through the MAC
must complete in **one** 20 ns period. A `set_multicycle_path` of 2 or 3 would
be a false constraint that only holds for some clock phases - exactly the kind
of change that makes a build pass the report and behave intermittently on
hardware. It is not done, and should not be.

## What the real fix is

The MAC is evaluated combinationally in one cycle
(`adsp2105_pocket.sv`: `mac_r48_f`, called at the top of the clocked block, with
writeback at the call sites). Its structure is:

```
operand mux (op_r / mstat)  ->  32x32 multiply  ->  sign-extend to 48
    ->  48-bit add/sub  ->  optional round  ->  MR / MF / astat
```

The multiply lands in a DSP block (`Mult0~24`, 4.6 ns). Everything after it -
the sign extension and the 48-bit accumulate - is built in fabric cells
(`Mult0~374` onward, ~5.7 ns of carry chain) and then another fabric adder
(`Add21~41`, 1.3 ns). Quartus did **not** infer the DSP block's embedded
accumulator, because the accumulate is a `case` over `acc` with a separate
round and saturate path, not a plain `acc <= acc + a*b`.

So the path to closing this is to let the DSP block do mult+add, which removes
the fabric carry chain and most of the difference. That is a genuine change to
`mac_r48_f` and it has to be validated on hardware - the DSP's own audio output
is the acceptance test, and it currently produces none.

## Why this matters more than "a timing number"

`AU:00000` on the debug page has read zero for every hardware run recorded in
this repository: the DCS board produces no audio at all, ever.

A datapath that misses its period by 3 ns at the fast corner computes MAC
results that are simply wrong at speed. A sound DSP whose MAC returns garbage
does not play its music - and it is also the block the game waits on through
`dcs_host_status` bit 11. The timing failure and the silence are plausibly the
same fact.

That makes closing this cone the highest-value remaining work, ahead of the AdEL
that started the investigation: the AdEL is one path the game takes, this is a
whole subsystem that has never worked.
