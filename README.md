# Armbian board support for the Giada DN73

Armbian board profile and device tree for the **Giada DN73**, a fanless RK3328 ARM
digital signage player (ODM JieHe, board marking **JHS557**). Armbian has no
profile for this board; the closest one, `dusun-dsom-010r`, matches only the SoC
and leaves the machine without working ethernet or WiFi.

> **Full disclosure**  
> The port for Giada DN73 board was made solely via Claude Opus 5 from board
> variant for dusun-dsom-010r and the original firmware supplied with the
> set-top-box. The port was tested by a human tester to a limited extent —
> [TESTING.md](TESTING.md) records exactly what was and was not verified.  
> Testers are welcome.

## Build an image

The profile lives in `userpatches/`, so no fork of `armbian/build` is needed.

```sh
git clone --depth 1 https://github.com/armbian/build.git
git clone --depth 1 https://github.com/david-spacil/armbian-giada-dn73.git
mkdir -p build/userpatches
cp -r armbian-giada-dn73/userpatches/* build/userpatches/
cd build
./compile.sh build giada-dn73
```

The board, branch, release and the package freeze come from
`userpatches/config-giada-dn73.conf`; anything on the command line still
overrides it.

Add `KERNEL_BTF=no` on build hosts with less than ~6.5 GB of RAM, or the kernel
BTF link step runs out of memory. The host also needs an arm64 binfmt handler —
without it the build stops at `arm64: not supported on this machine/kernel`.
Debian and Ubuntu hosts get one from `qemu-user-static`, Fedora from
`qemu-user-static-aarch64`.

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
| GPU | `vdd_logic` floor of 1.1 V puts the Mali OPPs out of range, `lima` fails to probe, no render node | 712.5 mV floor, `lima` binds, `renderD128`, Mali-450 on GLES 2.0 |
| Reported model | Dusun DSOM 010R | Giada DN73 |
| Boot time | ~2 min, waiting on `systemd-networkd-wait-online` | ~22 s |

## What works

Verified on hardware, Armbian 26.08.0-trunk / Debian trixie / kernel 6.18.40
`current`, installed to eMMC and running from it with no overlays applied:
gigabit ethernet at line rate (935/941 Mb/s), a stable MAC, WiFi, Bluetooth, all
four USB connectors, `/dev/ttyS1`, the RTC as `rtc0`, IR reception, HDMI console,
microSD and eMMC — booting in 21.5 s with no failed units.

The GPU works through `lima` (Mali-450, GLES 2.0), and both hardware video
decoders work through GStreamer — 4K HEVC at 92 fps for 2.6 ms of CPU per frame,
against 17 fps in software. Ten minutes of CPU, GPU and VPU load together peaked
at 75.8 °C with no throttling.

Several things were confirmed to initialise without the function itself being
exercised, and a fair amount was never tested at all: the COM port carrying data,
audio actually being audible, the watchdog biting, the mini-PCIe slot,
suspend/resume, the `edge` branch, and the `dn73-peripherals.dts` overlay on a
running system. WiFi associates, but often only after several attempts.
**[TESTING.md](TESTING.md) has the row-by-row status, with a command for each
gap** — start there before trusting anything on this list.

## Notes

- **Do not `apt upgrade` the kernel from `apt.armbian.com`.** Armbian's
  `linux-dtb-current-rockchip64` contains 255 device trees and not this one, so
  installing it removes the DTB U-Boot boots from. Images built from this
  repository hold the kernel packages automatically (`BSPFREEZE=yes`); on a
  machine installed before that, run `armbian-config --api
  module_armbian_firmware hold`. Update by rebuilding from here instead.
- Interfaces are `end0` and `wlx<mac>`, not `eth0` and `wlan0`. Scripts carried
  over from a dusun-based install will name the wrong one.
- Configuring WiFi costs about a minute of boot time. The first association
  attempt fails, `NetworkManager-wait-online` waits out the whole 57.7 s before
  the retry succeeds, and boot goes from 21.5 s to 1 min 20 s. See
  [TESTING.md](TESTING.md) for the mitigation.
- Hardware video decode needs GStreamer. Debian's `ffmpeg` cannot drive these
  decoders — they are stateless V4L2 request-API devices and it has no
  `v4l2request` hwaccel. `gstreamer1.0-plugins-bad` provides `v4l2slh264dec` and
  `v4l2slh265dec`, which find the hardware by themselves.
- Do not key anything off `/dev/videoN`: the numbers swap between boots. Match on
  the driver name from `v4l2-ctl --info`.
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
