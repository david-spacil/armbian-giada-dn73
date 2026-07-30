# Armbian board support for the Giada DN73

Device tree and Armbian board profile for the **Giada DN73**, a fanless RK3328
ARM digital signage player. Armbian has no profile for this board — the closest
one, `dusun-dsom-010r`, matches only the SoC and leaves the machine without
working ethernet or WiFi.

With this profile everything works out of the box: gigabit ethernet, WiFi,
Bluetooth, the RS232 port, the RTC, the IR receiver, HDMI console.

> **Full disclosure**  
> The port for Giada DN73 board was made solely via Claude Opus 5 from board
> variant for dusun-dsom-010r and the original firmware supplied with the
> set-top-box. The port was tested by a human tester to a limited extent.
> What **was not** tested at all: COM port, PCIe slot.  
> Testers are welcome.

## The hardware

The DN73 is not a system-on-module design. The RK3328, DDR3, eMMC, the ethernet
PHY and the WiFi/BT combo are all soldered onto one Giada-designed board
(ODM JieHe, board marking **JHS557**).

| Designator | Part | Notes |
|---|---|---|
| U800 | Rockchip RK3328 | quad Cortex-A53 |
| U46 | **Realtek RTL8211E** | gigabit ethernet PHY, 48-pin QFN |
| Y3 | 25.000 MHz crystal | PHY reference clock |
| — | AE-SC24002 | 100/1000 Base-T LAN transformer, 4 pairs |
| U8 | Genesys GL850G | USB 2.0 hub |
| — | Realtek RTL8821CU | WiFi 802.11ac + Bluetooth, **USB** attached |
| — | Rockchip RK805-1 | PMIC |
| — | Haoyu **HYM8563** | battery-backed RTC, i2c1 @ 0x51, CR2032 on `BAT CON` |
| U31 | Sipex **SP213EEA** | RS232 transceiver for the DB9 |
| — | *(unmarked)* | IR receiver on GPIO2_A2 |
| U1800/U1801 | Samsung DDR3 | |

The four USB connectors are one USB 3.2 Gen1 on the xHCI, one USB 2.0 OTG on
the dwc2 (wired `dr_mode = "host"`), and two USB 2.0 behind the GL850G hub.
The hub's fourth downstream port goes to the full-size mini-PCIe slot — the
RK3328 has no PCIe at all, so the advertised 3G/4G support is a USB modem
(Quectel EC25) in a mini-PCIe form factor. Nothing in the device tree is
needed for it.

Board photos are in [`foto_desky/`](foto_desky/).

> The RK3328 model is the **DN73**. Giada's DN72 is a different machine built
> around an RK3288 — its datasheet does not describe this board.

## Why stock Armbian is not enough

Four independent things have to be right at the same time, which is what makes
this board look dead rather than merely misconfigured.

- **Ethernet needs three conditions at once.** The RJ45 goes through an external
  RTL8211E on `gmac2io`, which stock Armbian disables in favour of the internal
  100M PHY that is connected to nothing. The PHY's supply is switched by
  **GPIO0_A0**, its reset has to be actively driven on **GPIO1_D0**, and it must
  be declared as an `mdio` child at address 1. Miss any one and MDIO reads return
  zeros with no link LEDs — indistinguishable from dead silicon.
- **WiFi has its own power pin.** **GPIO3_B0**, held high with a `gpio-hog`.
  Both the wlan interface (`rtw88_8821cu`) and Bluetooth (`btusb`) then appear;
  the firmware ships with Armbian.
- **Two GPIOs belong to the serial port.** The dusun profile drives GPIO3_A5 and
  GPIO3_A7 as USB VBUS enables. On this board they are uart1 RTS and CTS — the
  DB9 on the back panel — so pinctrl hands them to the regulators and the serial
  port silently does not exist. The real enables are GPIO0_A2 and GPIO2_C5.
- **Two peripherals stock Armbian never looks for.** A battery-backed HYM8563
  RTC on i2c1 at 0x51, and a demodulating IR receiver on GPIO2_A2 that works
  with `gpio-ir-receiver` — the vendor drives it from PWM capture through a
  driver with no mainline counterpart, which is presumably why nobody bothers
  with IR on RK3328.

The reasoning behind each value, the measurements, and the dead ends are in
[CLAUDE.md](CLAUDE.md) and
[docs/diagnosing-a-mismatched-board.md](docs/diagnosing-a-mismatched-board.md).

## Using it

### Building an image

The profile lives in `userpatches/`, so no fork of `armbian/build` is needed.

```sh
git clone --depth 1 https://github.com/armbian/build.git
cp -r userpatches/* build/userpatches/
cd build
./compile.sh build BOARD=giada-dn73 BRANCH=current RELEASE=trixie \
    BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
```

Build hosts with less than ~6.5 GB of RAM need `KERNEL_BTF=no` added, otherwise
the kernel BTF link step runs out of memory.

Write the image to a microSD card, boot it, then run `armbian-install` and choose
**boot from eMMC**.

### Fixing an existing install without reinstalling

If the machine already runs an Armbian image built for `dusun-dsom-010r`, two
overlays apply the same fixes without a reinstall —
[`overlay/gmac2io-rtl8211.dts`](overlay/gmac2io-rtl8211.dts) for ethernet and
WiFi, [`overlay/dn73-peripherals.dts`](overlay/dn73-peripherals.dts) for the
serial port, the RTC and IR:

```sh
for o in gmac2io-rtl8211 dn73-peripherals; do
    dtc -@ -I dts -O dtb -o "/boot/overlay-user/$o.dtbo" "overlay/$o.dts"
done
# then in /boot/armbianEnv.txt:
#   user_overlays=gmac2io-rtl8211 dn73-peripherals
```

The overlays leave the RTC as `rtc1`, because the RK805 has already taken `rtc0`
by the time it probes. The board DTS sets the alias properly.

## Known quirks

**The interfaces are `end0` and `wlx<mac>`, not `eth0` and `wlan0`.** Setting
`ethernet0 = &gmac2io` in `aliases` is what makes udev see the ethernet port as
onboard device 0. The RTL8821CU is a USB device with no device tree node, so udev
has no onboard index for it and falls back to the MAC address; that one is not
fixable from the device tree, only with a `systemd.link` file. Firewall rules and
scripts carried over from a dusun-based install will name the wrong interface.

**The MAC address is stable, and the alias is why.** Rockchip U-Boot derives a
MAC from the SoC cpuid and writes it into `local-mac-address` on whatever node
`ethernet0` points at. On the dusun device tree that is `gmac2phy`, so `gmac2io`
got nothing and the kernel invented a random address on every boot — a different
DHCP lease each time.

**Running from SD does not mean running your U-Boot.** The boot ROM picks the
*bootloader* and prefers eMMC; that U-Boot then picks the *operating system*, and
its `boot_targets` puts the card first. So a box with an existing eMMC install
runs the old bootloader with the new kernel, even though the card carries a
complete bootloader of its own. `/proc/device-tree/chosen/u-boot,version` says
which one actually ran, and is worth reading before concluding anything about a
card-booted system. `armbian-install` settles it.

**MIC-IN is not wired up, in hardware.** The RK3328's internal codec is playback
only, and the separate ADC the vendor device tree declares — an Everest ES7243 —
is not populated. Use a USB audio device if you need capture. Line-out, S/PDIF
and HDMI playback all work.

**Two-minute boot,** not board-specific but it bites on every Armbian image here:
`systemd-networkd-wait-online` waits for `systemd-networkd`, which manages nothing
because netplan renders through NetworkManager. `userpatches/customize-image.sh`
masks the unit.

## Tools

Two scripts written while working this out, useful for any Rockchip board whose
vendor firmware is available:

- [`scripts/extract-dtb.py`](scripts/extract-dtb.py) — pulls device tree blobs
  out of a Rockchip `update.img` by scanning for the FDT magic. This is how the
  board's GPIO assignments were recovered from the Android firmware.
- [`scripts/mdio-raw-scan.py`](scripts/mdio-raw-scan.py) — reads MDIO straight
  from the DWMAC1000 registers via `/dev/mem`, bypassing phylib. It distinguishes
  "bus floating high", "held low" and a real PHY answering. This is what proved
  the PHY was alive while the driver still reported `no phy found`.

## Status

Armbian 26.08.0-trunk, Debian trixie, kernel 6.18.40 (`current`), full BTF.
Verified on hardware from an image built by this profile, with no overlays
applied — first from SD, then **installed to eMMC** and re-verified running
standalone with the card removed and this profile's own U-Boot
(`2026.04_armbian`) in charge of both stages.

| | |
|---|---|
| Gigabit ethernet | `end0`, 1 Gbps full duplex, stable U-Boot-supplied MAC across reinstall |
| WiFi + Bluetooth | `rtw88_8821cu` (as `wlx<mac>`), scans; `hci0` with RTL firmware loaded |
| USB | all four connectors enumerate |
| RS232 (DB9) | `/dev/ttyS1` |
| RTC | HYM8563 as `rtc0` — timekeeping only, no wakealarm |
| IR receiver | `rc0` + `/dev/lirc0`, NEC frames decode cleanly; no keymap shipped |
| Audio | line-out, S/PDIF, HDMI — **not** mic-in |
| microSD, eMMC, HDMI, watchdog | |
| Boot time | 21.5 s (4.9 s kernel + 16.6 s userspace), no failed units |

Not submitted upstream. U-Boot is borrowed from the Dusun DSOM 010R — same SoC,
same power design, and it boots this board fine; the kernel loads its own DTB, so
the name in the bootloader has no functional effect.

## License

Device tree sources are GPL-2.0+ OR MIT, matching the kernel sources they derive
from. `rk3328-giada-dn73.dts` started as a copy of `rk3328-dusun-dsom-010r.dts`
from the Armbian build framework.
