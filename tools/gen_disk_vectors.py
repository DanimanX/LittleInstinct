#!/usr/bin/env python3
"""Emit ATA sector vectors from a CHD-extracted disk image for tests/sim.

The game verifies disk data itself: 0x8802D560 walks 0x1F8 (504) bytes of a
sector as a checksum and 0x8802EC48 loads the 4-byte value at +0x1F8 with an
unaligned `lwu`. If that word disagrees with the checksum the game takes an
AdEL and leaves for the boot ROM, which is what the hardware showed
(DP:8802EC4C, EX:00000012). So the only question that matters is whether the
halfwords the CPU reads out of the data port are the halfwords in the file.

This script writes them out in the order ki_ata delivers them - one 16-bit
halfword per line, little-endian, 256 per sector - so a bench can compare a
drained PIO sector against the file byte for byte.

    tools/gen_disk_vectors.py roms/kinst.img --lba 0 1 2 255919

Writes tests/sim/vectors/disk_sectors.hex (one halfword per line) and a
companion .lbas file recording which LBA each 256-line block came from.
"""

import argparse
import os
import sys

SECTOR = 512
HALFWORDS = SECTOR // 2


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="raw sector image (kinst.img / kinst2.img)")
    ap.add_argument("--lba", type=lambda s: int(s, 0), nargs="+",
                    default=[0, 1, 2], help="LBAs to emit, in order")
    ap.add_argument("--out", default="tests/sim/vectors")
    args = ap.parse_args()

    size = os.path.getsize(args.image)
    sectors = size // SECTOR
    here = os.path.abspath(os.path.dirname(__file__) + "/..")
    out_dir = args.out if os.path.isabs(args.out) else os.path.join(here, args.out)
    os.makedirs(out_dir, exist_ok=True)

    hex_path = os.path.join(out_dir, "disk_sectors.hex")
    lba_path = os.path.join(out_dir, "disk_sectors.lbas")

    with open(args.image, "rb") as img, \
         open(hex_path, "w") as hx, \
         open(lba_path, "w") as lb, \
         open(os.path.join(out_dir, "disk_sectors.params.vh"), "w") as ph:
        lb.write("# LBA per 256-halfword block, in file order\n")
        for lba in args.lba:
            if lba >= sectors:
                print(f"error: LBA {lba} is past the end ({sectors} sectors)",
                      file=sys.stderr)
                sys.exit(1)
            img.seek(lba * SECTOR)
            data = img.read(SECTOR)
            if len(data) != SECTOR:
                print(f"error: short read at LBA {lba}", file=sys.stderr)
                sys.exit(1)
            lb.write(f"{lba}\n")
            for n in range(HALFWORDS):
                hx.write(f"{data[2 * n] | (data[2 * n + 1] << 8):04x}\n")
        ph.write(f"localparam integer VEC_SECTORS = {len(args.lba)};\n")

    print(f"wrote {hex_path}: {len(args.lba)} sectors, {len(args.lba) * HALFWORDS} halfwords")
    print(f"wrote {lba_path}")
    for lba in args.lba:
        img = open(args.image, "rb")
        img.seek(lba * SECTOR)
        d = img.read(SECTOR)
        # What the game's own check does: sum-ish over 0x1F8, then read +0x1F8.
        crc = int.from_bytes(d[0x1F8:0x1FC], "little")
        print(f"  LBA {lba:<7} +0x1F8..0x1FB = {crc:08x}  "
              f"first8={d[:8].hex()}  last8={d[-8:].hex()}")
        img.close()


if __name__ == "__main__":
    main()
