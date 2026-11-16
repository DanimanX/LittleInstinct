#!/usr/bin/env python3
"""Gate a Pocket build: PLL as designed, timing closed, constraints all applied.

Run after tools/build_pocket.sh. Exit status 0 means the bitstream may be
packaged; anything else prints what is wrong.

Why this exists: earlier builds of this port shipped with a PLL output at the
wrong phase, with negative setup slack, and with SDC lines Quartus had silently
ignored. Each was visible in the reports and none was looked at.
"""
import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "src/fpga/output_files"

# counter -> (MHz, degrees). The table in src/fpga/pocket_rtl/ki_pll.sv.
PLL = {
    0: (50.0, 0.0),
    1: (100.0, 245.0),   # 6806 ps
    2: (100.0, 20.0),    #  556 ps
    3: (100.0, 50.0),    # 1389 ps
    4: (6.25, 0.0),
    5: (6.25, 90.0),
}
# SDC filters that are allowed to match nothing (debug registers that only
# exist when the trace page is compiled in).
OPTIONAL_FILTERS = ("debug_trace_frozen_meta", "debug_trace_shadow")


def main() -> int:
    bad = []
    fit = (OUT / "pocket_ki.fit.rpt").read_text(errors="replace")
    sta = (OUT / "pocket_ki.sta.rpt").read_text(errors="replace")
    summ = (OUT / "pocket_ki.sta.summary").read_text(errors="replace")

    # ---- PLL
    if "; 900.0 MHz" not in fit:
        bad.append("PLL VCO is not 900.0 MHz")
    seen = {}
    for m in re.finditer(
        r"counter\[(\d)\]\.output_counter\s*;[^\n]*\n"
        r"[^\n]*Output Clock Frequency\s*;\s*([\d.]+) MHz[^\n]*\n"
        r"(?:[^\n]*\n){0,4}?[^\n]*Phase Shift\s*;\s*([\d.]+) degrees", fit):
        seen[int(m.group(1))] = (float(m.group(2)), float(m.group(3)))
    for n, (mhz, deg) in PLL.items():
        got = seen.get(n)
        if got is None:
            bad.append(f"PLL counter[{n}] not found in the fitter report")
        elif abs(got[0] - mhz) > 1e-3 or abs(got[1] - deg) > 0.6:
            bad.append(f"PLL counter[{n}] is {got[0]} MHz / {got[1]} deg, "
                       f"expected {mhz} MHz / {deg} deg")
    if len(re.findall(r"^;\s+-- PLL Type", fit, re.M)) > 1 or \
            "Total PLLs : 1 /" not in (OUT / "pocket_ki.fit.summary").read_text():
        bad.append("the design must contain exactly one PLL")

    # ---- timing: every analysis at every corner
    worst = {}
    for kind, clock, slack in re.findall(
            r"Type\s*:\s*(.+?) '(.+?)'\s*\nSlack\s*:\s*(-?[\d.]+)", summ):
        slack = float(slack)
        check = kind.split("Model ")[-1]
        if check not in worst or slack < worst[check][0]:
            worst[check] = (slack, kind, clock)
        if slack < 0:
            bad.append(f"negative slack {slack} ns: {kind} '{clock}'")
    for need in ("Setup", "Hold", "Recovery", "Removal"):
        if need not in worst:
            bad.append(f"no {need} analysis in the timing summary")

    # ---- constraints that Quartus dropped
    for line in sta.splitlines():
        if "Warning (332174)" in line or "Warning (332049)" in line:
            if not any(f in line for f in OPTIONAL_FILTERS) and \
                    not re.search(r"pocket_ki\.sdc\((\d+)\)", line) is None:
                n = re.search(r"pocket_ki\.sdc\((\d+)\)", line).group(1)
                txt = (Path(__file__).resolve().parent.parent /
                       "src/fpga/pocket_rtl/pocket_ki.sdc").read_text().splitlines()[int(n) - 1]
                if not any(f in txt for f in OPTIONAL_FILTERS):
                    bad.append("ignored constraint: " + line.split("): ", 1)[-1][:150])

    for check in ("Setup", "Hold", "Recovery", "Removal"):
        if check in worst:
            s, kind, clock = worst[check]
            print(f"  worst {check:<9}{s:+7.3f} ns  {kind.split(' Model')[0]}  {clock.split('|')[-2] if '|' in clock else clock}")
    m = re.search(r"Logic utilization \(in ALMs\) : (.+)", (OUT / "pocket_ki.fit.summary").read_text())
    print("  ALMs            ", m.group(1) if m else "?")
    if bad:
        print("\nBUILD NOT RELEASABLE:")
        for b in dict.fromkeys(bad):
            print("  -", b)
        return 1
    print("\nOK: one PLL as designed, timing closed at all four corners.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
