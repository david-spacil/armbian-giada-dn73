# Armbian board support for the Giada DN73

Armbian board profile and device tree for the **Giada DN73**, a fanless RK3328 ARM
digital signage player (ODM JieHe, board marking **JHS557**). Armbian has no
profile for this board; the closest one, `dusun-dsom-010r`, matches only the SoC
and leaves the machine without working ethernet or WiFi.

> **Full disclosure**  
> The port for Giada DN73 board was made solely via Claude Opus 5 from board
> variant for dusun-dsom-010r and the original firmware supplied with the
> set-top-box. The port was tested by a human tester to a limited extent —
> see [What works](#what-works) for what was and was not verified.  
> Testers are welcome.

## Build an image

The profile lives in `userpatches/`, so no fork of `armbian/build` is needed.

```sh
git clone --depth 1 https://github.com/armbian/build.git
git clone --depth 1 https://github.com/david-spacil/armbian-giada-dn73.git
cp -r armbian-giada-dn73/userpatches/* build/userpatches/
cd build
./compile.sh build BOARD=giada-dn73 BRANCH=current RELEASE=trixie \
    BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
```

Add `KERNEL_BTF=no` on build hosts with less than ~6.5 GB of RAM, or the kernel
BTF link step runs out of memory.

Write the image to a microSD card, boot from it, then run `armbian-install` and
choose **boot from eMMC**. Remove the card afterwards — the boot ROM prefers the
eMMC bootloader but that bootloader prefers the card for the rootfs, so a card
left in the slot keeps booting its own system.

## Or patch a running install

A machine already running an image built for `dusun-dsom-010r` can pick up the
same fixes as overlays, without reinstalling:

```sh
for o in gmac2io-rtl8211 dn73-peripherals; do
    dtc -@ -I dts -O dtb -o "/boot/overlay-user/$o.dtbo" "overlay/$o.dts"
done
# then add to /boot/armbianEnv.txt:
#   user_overlays=gmac2io-rtl8211 dn73-peripherals
```

[`gmac2io-rtl8211.dts`](overlay/gmac2io-rtl8211.dts) covers ethernet and WiFi,
[`dn73-peripherals.dts`](overlay/dn73-peripherals.dts) the serial port, RTC and
IR. Two limits compared to building an image: the RTC lands as `rtc1` rather than
`rtc0`, and the ethernet MAC stays random per boot — both come from aliases, which
an overlay cannot usefully change.

## What this fixes

Compared with running the stock `dusun-dsom-010r` profile on this hardware:

| | `dusun-dsom-010r` | this profile |
|---|---|---|
| Ethernet | `gmac2phy`, the internal 100M PHY that is connected to nothing — no link, ever | `gmac2io` + the RTL8211E that the RJ45 actually uses, 1 Gbps |
| PHY supply | always-on regulator, 1.8 V, no GPIO | 3.3 V, switched by GPIO0_A0 |
| PHY reset | not described | GPIO1_D0, actively driven |
| MAC address | random on every boot, new DHCP lease each time | stable, supplied by U-Boot |
| WiFi + Bluetooth | power pin not driven, nothing enumerates | GPIO3_B0 held high, `rtw88_8821cu` + `btusb` |
| RS232 (DB9) | pins claimed by USB VBUS regulators, port does not exist | `/dev/ttyS1` |
| RTC | falls back to the RK805, no battery backup | HYM8563 as `rtc0` |
| IR receiver | not described | `gpio-ir-receiver`, `rc0` + `/dev/lirc0` |
| Reported model | Dusun DSOM 010R | Giada DN73 |
| Boot time | ~2 min, waiting on `systemd-networkd-wait-online` | ~22 s |

## What works

Verified on hardware, Armbian 26.08.0-trunk / Debian trixie / kernel 6.18.40
`current`, installed to eMMC and running from it with no overlays applied:

| | |
|---|---|
| Gigabit ethernet | `end0`, 1 Gbps full duplex, stable MAC across reinstall |
| WiFi | associates and scans — throughput not measured |
| Bluetooth | `hci0`, RTL firmware loads — no device paired |
| USB | all four connectors enumerate — no SuperSpeed device tested |
| RTC | `rtc0`, keeps time — battery retention across power loss not tested |
| IR receiver | `rc0` + `/dev/lirc0`, NEC frames decode from a real remote — no keymap shipped, so no key events |
| Audio | three cards enumerate (line-out, S/PDIF, HDMI) — **no playback tested**; mic-in is not wired up in hardware |
| microSD, eMMC, HDMI console | |
| Boot | 21.5 s, no failed units |

**Not tested at all:** the COM port carrying data, the mini-PCIe slot (it is USB,
not PCIe — RK3328 has none), the watchdog, suspend/resume, thermal behaviour under
sustained load, GPU and video decode, and the `edge` kernel branch. The
`dn73-peripherals.dts` overlay has never been applied to a real install; its
contents were verified only in the board device tree.

## Notes

- Interfaces are `end0` and `wlx<mac>`, not `eth0` and `wlan0`. Scripts carried
  over from a dusun-based install will name the wrong one.
- Mic-in cannot work: the ADC the vendor device tree declares is not populated.
  Use USB audio for capture.
- The RK3328 model is the **DN73**. Giada's DN72 is a different machine built
  around an RK3288; its datasheet does not describe this board.

Board photos are in [`foto_desky/`](foto_desky/). How each value was arrived at,
and the dead ends, are in [CLAUDE.md](CLAUDE.md) and
[docs/diagnosing-a-mismatched-board.md](docs/diagnosing-a-mismatched-board.md) —
along with two scripts (`scripts/`) that are useful for any Rockchip board whose
vendor firmware is available.

Not submitted upstream. U-Boot is borrowed from the Dusun DSOM 010R: same SoC,
same power design, and the kernel loads its own DTB, so the name in the bootloader
has no functional effect.

## License

Device tree sources are GPL-2.0+ OR MIT, matching the kernel sources they derive
from. `rk3328-giada-dn73.dts` started as a copy of `rk3328-dusun-dsom-010r.dts`
from the Armbian build framework.
