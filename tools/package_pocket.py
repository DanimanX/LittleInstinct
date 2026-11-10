#!/usr/bin/env python3
"""
Assemble a release package for Analogue Pocket SD card deployment.
Generates bitstream.rbf_r (bit-reversed per APF requirement) and structures:
  Release/
    Cores/littleinstinct.KillerInstinct/
      bitstream.rbf_r
      core.json
      data.json
      info.txt
    Platforms/
      killerinstinct.json
    Assets/killerinstinct/
      common/
        README.txt
      littleinstinct.KillerInstinct/
        Killer Instinct (v1.5d).json
        Killer Instinct 2 (v1.4).json

Also produces a ready-to-extract ZIP archive: Release/LittleInstinct_Pocket_v1.0.0.zip
"""

import os
import sys
import shutil
import zipfile
import hashlib
import argparse

def reverse_bits(data: bytes) -> bytes:
    table = bytes(int('{:08b}'.format(b)[::-1], 2) for b in range(256))
    return data.translate(table)

def main():
    parser = argparse.ArgumentParser(description="Package LittleInstinct core for Analogue Pocket")
    parser.add_argument("--rbf", default="src/fpga/output_files/pocket_ki.rbf", help="Path to compiled .rbf bitstream")
    parser.add_argument("--apf", default="apf", help="Path to APF template tree")
    parser.add_argument("--out", default="Release", help="Output directory")
    parser.add_argument("--zip", default=True, action="store_true", help="Generate ZIP archive")
    args = parser.parse_args()

    here = os.path.abspath(os.path.dirname(__file__) + "/..")
    rbf_path = os.path.join(here, args.rbf)
    apf_path = os.path.join(here, args.apf)
    out_path = os.path.join(here, args.out)

    if not os.path.isfile(rbf_path):
        print(f"Error: RBF bitstream not found at {rbf_path}", file=sys.stderr)
        sys.exit(1)

    print(f"[*] Reading bitstream: {rbf_path}")
    raw_rbf = open(rbf_path, "rb").read()
    rbf_md5 = hashlib.md5(raw_rbf).hexdigest()
    print(f"    Size: {len(raw_rbf)} bytes, MD5: {rbf_md5}")

    print("[*] Reversing bitstream bits for openFPGA APF (.rbf_r)...")
    rbf_r = reverse_bits(raw_rbf)
    rbf_r_md5 = hashlib.md5(rbf_r).hexdigest()
    print(f"    Size: {len(rbf_r)} bytes, MD5: {rbf_r_md5}")

    # Prepare output release directory
    sd_root = os.path.join(out_path, "sd_card")
    if os.path.exists(sd_root):
        shutil.rmtree(sd_root)
    os.makedirs(sd_root, exist_ok=True)

    # Copy APF directories
    core_id = "littleinstinct.KillerInstinct"
    cores_dir = os.path.join(sd_root, "Cores", core_id)
    platforms_dir = os.path.join(sd_root, "Platforms")
    assets_dir = os.path.join(sd_root, "Assets", "killerinstinct", core_id)
    assets_common = os.path.join(sd_root, "Assets", "killerinstinct", "common")

    os.makedirs(cores_dir, exist_ok=True)
    os.makedirs(platforms_dir, exist_ok=True)
    os.makedirs(assets_dir, exist_ok=True)
    os.makedirs(assets_common, exist_ok=True)

    # Write bitstream.rbf_r
    rbf_r_dest = os.path.join(cores_dir, "bitstream.rbf_r")
    with open(rbf_r_dest, "wb") as f:
        f.write(rbf_r)
    print(f"[+] Wrote: {rbf_r_dest}")

    # Copy core metadata and assets (core.json, data.json, info.txt, icon.bin)
    src_core_dir = os.path.join(apf_path, "Cores", core_id)
    for fname in os.listdir(src_core_dir):
        src_f = os.path.join(src_core_dir, fname)
        if os.path.isfile(src_f):
            shutil.copy2(src_f, os.path.join(cores_dir, fname))
            print(f"[+] Copied: Cores/{core_id}/{fname}")

    # Copy platform metadata and banner images (killerinstinct.json, _images/)
    src_plat_dir = os.path.join(apf_path, "Platforms")
    for item in os.listdir(src_plat_dir):
        src_item = os.path.join(src_plat_dir, item)
        dst_item = os.path.join(platforms_dir, item)
        if os.path.isdir(src_item):
            shutil.copytree(src_item, dst_item, dirs_exist_ok=True)
            print(f"[+] Copied directory: Platforms/{item}")
        elif os.path.isfile(src_item):
            shutil.copy2(src_item, dst_item)
            print(f"[+] Copied: Platforms/{item}")

    src_assets = os.path.join(apf_path, "Assets", "killerinstinct", core_id)
    if os.path.isdir(src_assets):
        for fname in os.listdir(src_assets):
            src_f = os.path.join(src_assets, fname)
            if os.path.isfile(src_f):
                shutil.copy2(src_f, os.path.join(assets_dir, fname))
                print(f"[+] Copied: Assets/killerinstinct/{core_id}/{fname}")

    # Write Assets/killerinstinct/common/README.txt
    readme_common = os.path.join(assets_common, "README.txt")
    with open(readme_common, "w") as f:
        f.write("""Killer Instinct ROM and Disk Image Assets
=========================================

Place the following game files in this folder (Assets/killerinstinct/common/):

For Killer Instinct 1 (v1.5d):
- kinst.rom  (4,718,592 bytes - assembled from MAME dump using tools/build_rom.py)
- kinst.img  (Sector disk image extracted from kinst.chd using 'chdman extracthd -i kinst.chd -o kinst.img')

For Killer Instinct 2 (v1.4):
- kinst2.rom (4,718,592 bytes - assembled from MAME dump using tools/build_rom.py)
- kinst2.img (Sector disk image extracted from kinst2.chd using 'chdman extracthd -i kinst2.chd -o kinst2.img')

Verification:
Run 'python3 tools/check_setup.py' to verify the exact file sizes and checksums.
""")
    print(f"[+] Wrote: {readme_common}")

    # Generate ZIP
    zip_name = "LittleInstinct_Pocket_v1.0.0.zip"
    zip_path = os.path.join(out_path, zip_name)
    print(f"[*] Packaging ZIP: {zip_path}")
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as z:
        for root, dirs, files in os.walk(sd_root):
            for file in sorted(files):
                full_path = os.path.join(root, file)
                rel_path = os.path.relpath(full_path, sd_root)
                # Store uncompressed for .rbf_r
                if file.endswith(".rbf_r"):
                    z.write(full_path, rel_path, compress_type=zipfile.ZIP_STORED)
                else:
                    z.write(full_path, rel_path, compress_type=zipfile.ZIP_DEFLATED)

    print(f"[✓] Release package successfully created at: {out_path}")
    print(f"    ZIP Archive: {zip_path} ({os.path.getsize(zip_path):,} bytes)")

if __name__ == "__main__":
    main()
