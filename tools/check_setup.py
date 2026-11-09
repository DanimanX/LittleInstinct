#!/usr/bin/env python3
"""Check that the files the Pocket core expects are present and sane.

usage:
  check_setup.py <roms_dir_or_sd_asset_dir>

Looks for, for each game (kinst, kinst2):
  <stem>.rom  exactly 4718592 bytes (0x480000: 0x80000 boot + 0x400000 DCS)
  <stem>.img  present, non-empty, a whole number of 512-byte sectors

Exit code 0 when everything checks out, 1 otherwise.
"""
import os
import sys

ROM_BYTES = 0x480000
SECTOR = 512
GAMES = ("kinst", "kinst2")


def check(dirpath):
    problems = []
    for stem in GAMES:
        rom = os.path.join(dirpath, stem + ".rom")
        img = os.path.join(dirpath, stem + ".img")

        if not os.path.exists(rom):
            problems.append("missing %s" % rom)
        else:
            size = os.path.getsize(rom)
            if size != ROM_BYTES:
                problems.append("%s is %d bytes, expected %d"
                                % (rom, size, ROM_BYTES))
            else:
                print("ok   %s (%d bytes)" % (rom, size))

        if not os.path.exists(img):
            problems.append("missing %s (chdman extracthd from %s.chd)" % (img, stem))
        else:
            size = os.path.getsize(img)
            if size == 0 or size % SECTOR:
                problems.append("%s is %d bytes, not a whole number of %d-byte sectors"
                                % (img, size, SECTOR))
            else:
                print("ok   %s (%d bytes, %d sectors)"
                      % (img, size, size // SECTOR))

    for p in problems:
        print("FAIL " + p)
    return 0 if not problems else 1


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    return check(sys.argv[1])


if __name__ == "__main__":
    sys.exit(main())
