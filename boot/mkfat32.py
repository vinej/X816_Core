#!/usr/bin/env python3
"""Generate boot/fat32.img for the FAT32 conformance test.

Built with pyfatfs -- an INDEPENDENT FAT32 implementation -- and verifiable
with 7-Zip, so the reader is tested against someone else's writer rather than
against our own. A reader checked only against an image we produced would
agree with our own misreadings.

    pip install pyfatfs
    python mkfat32.py

/BIG.BIN is 20000 bytes of (i*7 + 13) & 0xFF: 40 clusters at one sector per
cluster, so it cannot be read without walking the FAT chain, and the pattern
is position-dependent, so following the chain to the wrong cluster fails
rather than returning plausible bytes.
"""
import os, sys
from pyfatfs.PyFat import PyFat
from pyfatfs.PyFatFS import PyFatFS

path = sys.argv[1] if len(sys.argv) > 1 else "fat32.img"
with open(path, "wb") as f:
    f.truncate(64 * 1024 * 1024)

fat = PyFat()
fat.mkfs(path, fat_type=PyFat.FAT_TYPE_FAT32, sector_size=512, label="X816TEST")
fat.close()

fs = PyFatFS(path)
fs.writetext("/HELLO.TXT", "Hello from FAT32 on X816!\n")
fs.makedir("/SUB")
fs.writetext("/SUB/NESTED.TXT", "nested file\n")
with fs.open("/BIG.BIN", "wb") as g:
    g.write(bytes(((i * 7 + 13) & 0xFF) for i in range(20000)))
fs.close()
print(path + ": " + str(os.path.getsize(path)) + " bytes")
