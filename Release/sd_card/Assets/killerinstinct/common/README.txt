Killer Instinct ROM and Disk Image Assets
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
