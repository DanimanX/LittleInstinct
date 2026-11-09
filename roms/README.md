Put your own dumps here. Nothing is shipped in this folder.

Needed:

  kinst.zip      MAME merged set for Killer Instinct (v1.5d)
  kinst2.zip     MAME merged set for Killer Instinct 2 (v1.4)
  kinst.chd      hard-disk image for KI1, from the same set
  kinst2.chd     hard-disk image for KI2, from the same set

Then:

  ../tools/build_rom.py ../upstream/Arcade-KillerInstinct_MiSTer/releases/"Killer Instinct (v1.5d).mra" . kinst.rom
  chdman extracthd -i kinst.chd -o kinst.img
  chdman extracthd -i kinst2.chd -o kinst2.img
  ../tools/check_setup.py .

These are copyrighted works. Supply them from your own legally obtained dumps;
this project does not distribute them and does not link to sources for them.
