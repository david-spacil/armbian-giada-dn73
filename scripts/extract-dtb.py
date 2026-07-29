#!/usr/bin/env python3
"""Vytahne device tree bloby z Rockchip firmware image.

Nehleda se struktura RKFW/RKAF - staci projet soubor na FDT magic
(0xd00dfeed), overit hlavicku a blob ulozit. Partition images uvnitr
update.img jsou ulozene nekomprimovane, takze DTB je videt primo.
"""

import mmap
import struct
import sys
from pathlib import Path

FDT_MAGIC = b"\xd0\x0d\xfe\xed"
FDT_HEADER = 40  # bajtu
MIN_SIZE = 256
MAX_SIZE = 2 * 1024 * 1024


def scan(path: Path, outdir: Path) -> int:
    outdir.mkdir(parents=True, exist_ok=True)
    found = 0

    with path.open("rb") as fh:
        mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        pos = 0
        while True:
            pos = mm.find(FDT_MAGIC, pos)
            if pos < 0:
                break

            if pos + FDT_HEADER > len(mm):
                break

            # Poradi v FDT hlavicce: totalsize, off_dt_struct, off_dt_strings,
            # off_mem_rsvmap, version.
            totalsize, off_struct, off_strings, _rsvmap, version = struct.unpack(
                ">IIIII", mm[pos + 4 : pos + 24]
            )

            # Hlavicka musi davat smysl, jinak je to nahodna shoda bajtu.
            plausible = (
                MIN_SIZE <= totalsize <= MAX_SIZE
                and pos + totalsize <= len(mm)
                and off_struct < totalsize
                and off_strings < totalsize
                and 16 <= version <= 17
            )
            if plausible:
                blob = mm[pos : pos + totalsize]
                out = outdir / f"dtb-{pos:012d}.dtb"
                out.write_bytes(blob)
                print(f"{pos:>12}  {totalsize:>9} B  -> {out.name}")
                found += 1
                pos += totalsize
            else:
                pos += 4

        mm.close()

    return found


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"pouziti: {sys.argv[0]} <firmware.img> <vystupni-adresar>")
    n = scan(Path(sys.argv[1]), Path(sys.argv[2]))
    print(f"\nnalezeno {n} DTB")
