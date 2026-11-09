#!/usr/bin/env python3
"""Which ADSP-2105 instruction classes does the DCS firmware actually execute?

Static evidence for "implement only the opcode subset" (docs/ADSP_ATTACK.md).
Nothing here executes anything: it reconstructs the ADSP program memory from the
sound-ROM boot page, disassembles it following control flow, and reports which
top-byte instruction classes appear.

usage:
  dcs_opcodes.py <rom> [--linear] [--dump N]

  <rom>     a .rom built by tools/build_rom.py (boot 0x80000 + DCS 0x400000)
  --linear  also report a linear sweep, for comparison with the flow-followed set
  --dump N  print the first N decoded instructions

Encoding facts are taken from the emulator itself (rtl/dcs/adsp2105.sv), not
from a manual, so the decode matches what the hardware model implements:

  class = op[23:16]
  0x14-0x17  DO <op[17:4]> UNTIL <op[3:0]>   loop body = next..target
  0x18-0x1F  conditional JUMP/CALL, target op[17:4], op[18]=1 -> CALL
  0x1C-0x1F  same group (op[19] selects ALU/MAC forms in the block)
  0x0A       conditional RTS/RTI (op[4]=1 -> RTI)
  0x0B       indirect JUMP/CALL through I<4+op[7:6]>: target not statically known
  everything else falls through to pc+1

Boot format (adsp2105.sv S_BOOT):
  pagelen = (rom[3] + 1) * 8 words
  PM[j]   = {rom[4j], rom[4j+1], rom[4j+2]}
"""

import sys

DCS_OFFSET = 0x80000
DCS_BYTES = 0x400000
PM_WORDS = 16384

# The classes the emulator implements (from the `case (hi)` in adsp2105.sv).
IMPLEMENTED = {0x00, 0x05, 0x06, 0x07}
IMPLEMENTED |= set(range(0x09, 0x20))
IMPLEMENTED |= set(range(0x20, 0xC0))

CLASS_NAMES = {
    0x00: "NOP / system control",
    0x05: "SAT MR",
    0x06: "DIVS",
    0x07: "DIVQ",
    0x09: "MODIFY (Iy,Mn)",
    0x0A: "RTS / RTI (cond)",
    0x0B: "JUMP/CALL indirect (via I)",
    0x0C: "mode control (MSTAT bits)",
    0x0D: "shift immediate + reg",
    0x0E: "immediate data move",
    0x0F: "shift immediate (sc)",
    0x10: "shift + internal reg move",
    0x11: "shift + PM(I,M) DAG2",
    0x12: "shift + DM(I,M) DAG1",
    0x13: "shift + DM(I,M) DAG2",
    0x14: "DO <addr> UNTIL <cond>",
    0x15: "DO <addr> UNTIL <cond>",
    0x16: "DO <addr> UNTIL <cond>",
    0x17: "DO <addr> UNTIL <cond>",
    0x18: "JUMP/CALL immediate (cond)",
    0x19: "JUMP/CALL immediate (cond)",
    0x1A: "JUMP/CALL immediate (cond)",
    0x1B: "JUMP/CALL immediate (cond)",
    0x1C: "ALU/MAC + PM(I,M) read",
    0x1D: "ALU/MAC + PM(I,M) read",
    0x1E: "ALU/MAC + PM(I,M) write",
    0x1F: "ALU/MAC + PM(I,M) write",
}


def dcs_region(rom: bytes) -> bytes:
    if len(rom) < DCS_OFFSET + DCS_BYTES:
        raise SystemExit("rom is %d bytes; expected at least %d"
                         % (len(rom), DCS_OFFSET + DCS_BYTES))
    return rom[DCS_OFFSET:DCS_OFFSET + DCS_BYTES]


def build_pm(dcs: bytes):
    """Reconstruct PM from the bank-0 boot page. Returns (pm, pagelen)."""
    if dcs[3] == 0xFF and dcs[0] == 0xFF:
        raise SystemExit("no boot page: first bytes are %s" % dcs[:4].hex())
    pagelen = (dcs[3] + 1) * 8
    if pagelen > PM_WORDS:
        raise SystemExit("bad boot page length %d" % pagelen)
    pm = [0] * PM_WORDS
    for j in range(pagelen):
        b = 4 * j
        pm[j] = (dcs[b] << 16) | (dcs[b + 1] << 8) | dcs[b + 2]
    return pm, pagelen


def decode_flow(op: int):
    """Return (kind, target) for the instruction's control effect.

    kind is one of: 'seq', 'jump', 'call', 'do', 'ret', 'indirect'.
    """
    cls = (op >> 16) & 0xFF
    if 0x14 <= cls <= 0x17:
        return "do", (op >> 4) & 0x3FFF
    if 0x18 <= cls <= 0x1F:
        tgt = (op >> 4) & 0x3FFF
        # op[18] set selects CALL in this group
        return ("call" if (op >> 18) & 1 else "jump"), tgt
    if cls == 0x0A:
        return "ret", None
    if cls == 0x0B:
        return "indirect", None
    return "seq", None


def follow(pm, pagelen, start):
    """Recursive disassembly. Returns (reachable_words, decoded, unresolved)."""
    reachable = set()
    decoded = []          # (pc, op, kind, target)
    work = [start]
    unresolved = []
    while work:
        pc = work.pop()
        while True:
            if pc >= PM_WORDS or pc >= pagelen:
                unresolved.append(pc)
                break
            if pc in reachable:
                break
            reachable.add(pc)
            op = pm[pc]
            kind, tgt = decode_flow(op)
            decoded.append((pc, op, kind, tgt))
            if kind == "seq" or kind == "do":
                # DO: body is next..target, reached by falling through
                pc += 1
                continue
            if kind == "jump" or kind == "call":
                if tgt < pagelen:
                    work.append(tgt)
                else:
                    unresolved.append(tgt)
                if kind == "call":
                    pc += 1
                    continue
                # unconditional JUMP: no fall-through. We do not know the
                # condition statically, so follow the fall-through too; that
                # only ever adds reachable words, never removes any.
                pc += 1
                continue
            if kind == "ret":
                pc += 1      # conditional return: fall-through also possible
                continue
            # indirect
            unresolved.append(pc)
            break
    return reachable, decoded, unresolved


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    rom_path = args[0]
    linear = "--linear" in args
    dump = 0
    if "--dump" in args:
        dump = int(args[args.index("--dump") + 1])

    rom = open(rom_path, "rb").read()
    dcs = dcs_region(rom)
    pm, pagelen = build_pm(dcs)
    print("rom            %s" % rom_path)
    print("boot page      %d words (%d bytes of ROM), from bank 0 offset 0"
          % (pagelen, 4 * pagelen))
    print("header bytes   %s  (length byte 0x%02x)"
          % (dcs[:4].hex(), dcs[3]))
    print("PM[0]          %06x  class 0x%02x" % (pm[0], pm[0] >> 16))

    kind0, tgt0 = decode_flow(pm[0])
    print("PM[0] decodes  %s -> 0x%03x" % (kind0, tgt0 or 0))
    start = tgt0 if kind0 in ("jump", "call") and tgt0 else 0

    reachable, decoded, unresolved = follow(pm, pagelen, start)
    print("\nreachable      %d words of %d loaded (%.1f %%)"
          % (len(reachable), pagelen, 100.0 * len(reachable) / pagelen))

    classes = {}
    for pc, op, kind, tgt in decoded:
        cls = (op >> 16) & 0xFF
        classes.setdefault(cls, []).append(pc)

    print("\nclasses executed (flow-followed, %d distinct):" % len(classes))
    for cls in sorted(classes):
        name = CLASS_NAMES.get(cls, "")
        print("  0x%02x  %5d  %s" % (cls, len(classes[cls]), name))

    unused = sorted(IMPLEMENTED - set(classes))
    unimplemented_used = sorted(set(classes) - IMPLEMENTED)
    print("\nimplemented by the emulator but never reached: %d of %d"
          % (len(unused), len(IMPLEMENTED)))
    print("  " + " ".join("0x%02x" % c for c in unused))
    if unimplemented_used:
        print("WARNING: reached classes the emulator does not implement: %s"
              % " ".join("0x%02x" % c for c in unimplemented_used))

    if linear:
        lin = {}
        for pc in range(start, pagelen):
            cls = (pm[pc] >> 16) & 0xFF
            lin.setdefault(cls, 0)
            lin[cls] += 1
        print("\nlinear sweep over %d..%d (%d words), for comparison:"
              % (start, pagelen - 1, pagelen - start))
        print("  distinct classes %d; classes not in the flow set: %s"
              % (len(lin),
                 " ".join("0x%02x" % c for c in sorted(set(lin) - set(classes)))
                 or "(none)"))

    if dump:
        print("\nfirst %d decoded instructions from 0x%03x:" % (dump, start))
        for pc, op, kind, tgt in sorted(decoded)[:dump]:
            extra = (" -> 0x%03x" % tgt) if tgt is not None else ""
            print("  %04x: %06x  %-8s%s" % (pc, op, kind, extra))

    if unresolved:
        print("\nflow targets not followed: %d (indirect jumps or out of page)"
              % len(unresolved))


if __name__ == "__main__":
    main()
