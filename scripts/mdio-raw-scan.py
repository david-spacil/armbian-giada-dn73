#!/usr/bin/env python3
"""Precte MDIO primo z registru DWMAC1000 pres /dev/mem.

Obchazi to phylib uplne - vidi se skutecne hodnoty na sbernici, takze jde
odlisit "sbernice plave nahore" (0xffff, nikdo neodpovida) od "drzena dole"
(0x0000, typicky nenapajeny PHY) od skutecne odpovedi.

Driver musi zustat navazany, jinak se vypnou hodiny MACu a MDC neticka.
Vyzaduje CONFIG_IO_STRICT_DEVMEM vypnuty.
"""

import mmap
import os
import struct
import sys
import time

GMAC_BASE = 0xFF540000  # gmac2io
MII_ADDR = 0x10
MII_DATA = 0x14

# CSR Clock Range -> delicka MDC (dwmac1000)
CR_NAMES = {
    0: "60-100 MHz (CSR/42)",
    1: "100-150 MHz (CSR/62)",
    2: "20-35 MHz (CSR/16)",
    3: "35-60 MHz (CSR/26)",
    4: "150-250 MHz (CSR/102)",
    5: "250-300 MHz (CSR/124)",
}


class Gmac:
    def __init__(self, base):
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        self.mm = mmap.mmap(self.fd, 4096, offset=base)

    def rd(self, off):
        return struct.unpack("<I", self.mm[off : off + 4])[0]

    def wr(self, off, val):
        self.mm[off : off + 4] = struct.pack("<I", val)

    def wait_idle(self, timeout=0.1):
        end = time.time() + timeout
        while time.time() < end:
            if not (self.rd(MII_ADDR) & 1):
                return True
            time.sleep(0.0005)
        return False

    def mdio_read(self, phy, reg, cr):
        if not self.wait_idle():
            return None
        self.wr(MII_ADDR, (phy << 11) | (reg << 6) | (cr << 2) | 1)
        if not self.wait_idle():
            return None
        return self.rd(MII_DATA) & 0xFFFF

    def close(self):
        self.mm.close()
        os.close(self.fd)


def main():
    g = Gmac(GMAC_BASE)
    print(f"MII_ADDR={g.rd(MII_ADDR):#010x}  MII_DATA={g.rd(MII_DATA):#010x}\n")

    for cr in sorted(CR_NAMES):
        hits = []
        vals = set()
        for phy in range(32):
            id1 = g.mdio_read(phy, 2, cr)
            if id1 is None:
                vals.add("timeout")
                continue
            vals.add(f"{id1:#06x}")
            if id1 not in (0x0000, 0xFFFF):
                id2 = g.mdio_read(phy, 3, cr)
                hits.append((phy, id1, id2))

        summary = ", ".join(sorted(vals)) if len(vals) <= 4 else f"{len(vals)} ruznych"
        print(f"CR={cr} {CR_NAMES[cr]:<22} reg2 = {summary}")
        for phy, id1, id2 in hits:
            print(f"    *** adresa {phy}: PHYID1={id1:#06x} PHYID2={id2:#06x}")

    g.close()


if __name__ == "__main__":
    sys.exit(main())
