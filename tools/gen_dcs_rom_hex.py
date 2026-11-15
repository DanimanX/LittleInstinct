#!/usr/bin/env python3
"""Pack the DCS sound ROM into 64-bit beats for the simulation backing store.

The DCS sound image is the last 4 MiB of a .rom built by tools/build_rom.py:
boot 0x000000..0x07FFFF, then the eight 512 KiB ROMs packed back to back at
0x080000..0x47FFFF. dcs_mem.sv consumes exactly that 4 MiB through a packed
beat port ("byte i at [8*i +: 8]"), so byte 0 of the image is beat 0 [7:0].

usage:
  gen_dcs_rom_hex.py <rom> <out.hex> [--bank N]

  <rom>      a .rom built by tools/build_rom.py (4 718 592 bytes)
  <out.hex>  one 64-bit beat per line, most-significant byte first, so a line
             reads as bytes 7..0 of that beat (little-endian in memory)
  --bank N   emit only one 512 KiB ROM (N = 0..7) instead of the whole 4 MiB

The .rom layout is byte-identical to what the Pocket download path pushes into
SDRAM at STORE_DCS: ki_memory_bridge_pocket.sv assembles each beat from four
consecutive ioctl halfwords and writes it with sdram_byte_enable 0000_00ff at
memory_word_address + 2, i.e. the lowest-address byte lands in the low byte of
the beat. This file is that same order, with no re-packing.
"""

import sys

ROM_BYTES = 0x480000
BOOT_BYTES = 0x80000
DCS_BYTES = 0x400000
BEAT_BYTES = 8
BEATS = DCS_BYTES // BEAT_BYTES          # 524288
BANK_BYTES = 0x80000                      # 512 KiB per physical ROM


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)

    rom_path, out_path = args[0], args[1]
    bank = None
    if "--bank" in args:
        bank = int(args[args.index("--bank") + 1])
        if not 0 <= bank <= 7:
            raise SystemExit("--bank must be 0..7")

    rom = open(rom_path, "rb").read()
    if len(rom) != ROM_BYTES:
        raise SystemExit("%s is %d bytes; expected %d"
                         % (rom_path, len(rom), ROM_BYTES))

    dcs = rom[BOOT_BYTES:BOOT_BYTES + DCS_BYTES]
    if bank is not None:
        dcs = dcs[bank * BANK_BYTES:(bank + 1) * BANK_BYTES]

    beats = len(dcs) // BEAT_BYTES
    with open(out_path, "w") as out:
        for i in range(beats):
            b = dcs[i * BEAT_BYTES:(i + 1) * BEAT_BYTES]
            # b[0] is the lowest-address byte -> beat [7:0] -> printed last.
            out.write("%016x\n" % int.from_bytes(b, "little"))

    head = int.from_bytes(dcs[:8], "little")
    print("in      %s (%d bytes)" % (rom_path, len(rom)))
    print("region  DCS %s (%d bytes)%s"
          % ("bank %d" % bank if bank is not None else "whole 4 MiB",
             len(dcs), "" if bank is None else " of 8"))
    print("beats   %d written to %s" % (beats, out_path))
    print("beat 0  %016x  (image bytes %s)" % (head, dcs[:8].hex()))
    print("first four PM words from beat 0: %s"
          % " ".join("%06x" % ((head >> (8 * k)) & 0xFFFFFF) for k in (0, 1, 2)))
    print("boot page length byte image[3] = 0x%02x -> %d PM words"
          % (dcs[3], (dcs[3] + 1) * 8))


if __name__ == "__main__":
    main()
