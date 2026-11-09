#!/usr/bin/env python3
"""Build the single .rom the Pocket core loads, from a MAME zip and the MRA.

The MiSTer core takes ioctl index 1 as ONE 0x480000-byte image:
the first 0x80000 is the boot ROM, the remaining 0x400000 is the DCS sound ROM
(see upstream/Arcade-KillerInstinct_MiSTer/rtl/ki_memory_bridge.sv,
ROM_DOWNLOAD_BYTES). This tool concatenates the MRA's <part> list in order into
exactly that file, checking every part's CRC32 first.

usage:
  build_rom.py <game.mra> <roms_dir> <out.rom>

  <roms_dir> holds the MAME zips named by the MRA (e.g. kinst.zip).
"""
import argparse, os, sys, xml.etree.ElementTree as ET, zipfile, zlib

ROM_BYTES = 0x480000


def crc32(data):
    return zlib.crc32(data) & 0xFFFFFFFF


def parse_mra(path):
    root = ET.parse(path).getroot()
    roms = {}
    for rom in root.iter("rom"):
        idx = rom.get("index")
        parts = [p for p in rom.iter("part")]
        roms[idx] = {"zip": rom.get("zip"), "parts": parts}
    name = (root.findtext("name") or "").strip()
    return name, roms


def read_parts(parts, zip_path):
    """Return [(name, bytes)] in MRA order, verifying CRC32 when declared."""
    out = []
    with zipfile.ZipFile(zip_path) as z:
        index = {os.path.basename(n).lower(): n for n in z.namelist()}
        for p in parts:
            pname = p.get("name")
            want = p.get("crc")
            if not pname:
                # <part>00</part> is a literal byte value, not a file
                out.append((None, bytes.fromhex(p.text.strip())))
                continue
            key = pname.lower()
            if key not in index:
                raise SystemExit("missing part %r in %s" % (pname, zip_path))
            data = z.read(index[key])
            if want:
                got = "%08x" % crc32(data)
                expected = want.lower()
                if expected.startswith("0x"):
                    expected = expected[2:]
                if got != expected:
                    raise SystemExit("CRC mismatch for %s: got %s want %s"
                                     % (pname, got, expected))
            out.append((pname, data))
    return out


def build(mra, roms_dir, out):
    name, roms = parse_mra(mra)
    if "1" not in roms:
        raise SystemExit("no <rom index=\"1\"> in %s" % mra)
    zip_name = roms["1"]["zip"]
    if not zip_name:
        raise SystemExit("rom index 1 has no zip attribute")
    zip_path = os.path.join(roms_dir, zip_name)
    if not os.path.exists(zip_path):
        raise SystemExit("missing %s" % zip_path)

    parts = read_parts(roms["1"]["parts"], zip_path)
    blob = b"".join(d for _, d in parts)
    if len(blob) != ROM_BYTES:
        raise SystemExit("assembled %d bytes (0x%X), expected %d (0x%X)"
                         % (len(blob), len(blob), ROM_BYTES, ROM_BYTES))

    with open(out, "wb") as fh:
        fh.write(blob)
    print("%s: %d parts -> %s (%d bytes, crc32 %08x)"
          % (name or mra, len(parts), out, len(blob), crc32(blob)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mra")
    ap.add_argument("roms_dir")
    ap.add_argument("out")
    a = ap.parse_args()
    build(a.mra, a.roms_dir, a.out)


if __name__ == "__main__":
    main()
