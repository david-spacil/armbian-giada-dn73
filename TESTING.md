# Testing status

What has actually been verified on hardware, what has not, and how to close the
gaps. The port was written by Claude Opus 5 and tested by one human on one unit,
so the untested list is long and honest — see [Contributing results](#contributing-results).

## Reference platform

Everything below was checked on a single DN73, on an image built by this profile:

| | |
|---|---|
| Armbian | 26.08.0-trunk |
| Release | Debian 13 trixie, CLI (no desktop) |
| Kernel | 6.18.40-current-rockchip64, `BRANCH=current`, full BTF |
| U-Boot | `2026.04_armbian`, this profile's own build |
| Installed on | eMMC (`/dev/mmcblk2p1`), microSD removed |
| Overlays | none applied |
| Boot | 21.5 s (4.9 s kernel + 16.6 s userspace), zero failed units |

Status meanings:

| | |
|---|---|
| ✅ | works, exercised end to end |
| ⚠️ | present and initialises, but the function itself was never exercised |
| ❌ | not tested at all |
| 🚫 | cannot work — hardware is absent |

## Peripherals

| Feature | Status | What was verified | What was not, and how to test it |
|---|---|---|---|
| Gigabit ethernet | ✅ | `end0` at 1000 Mb/s full duplex, DHCP lease, traffic over SSH | throughput: `iperf3 -c <host>` |
| MAC address stability | ✅ | identical across a reboot *and* across the SD→eMMC reinstall | — |
| WiFi | ⚠️ | `rtw88_8821cu` binds, firmware 24.11.0 loads, scan returns 13 networks | never associated with an AP. `nmcli device wifi connect <ssid> password <pw>`, then `iperf3`. 2.4 vs 5 GHz untested |
| Bluetooth | ⚠️ | `hci0` present, RTL firmware `0x826ca99e` loads | never paired. `bluetoothctl` → `scan on` / `pair` / `connect`. A2DP and BLE untested |
| USB — enumeration | ✅ | all four connectors enumerate; hub, keyboard and the internal WiFi visible | — |
| USB — SuperSpeed | ❌ | only USB 2.0-class devices were ever plugged in | plug a USB3 stick into the blue port, expect `5000M` in `lsusb -t`, then measure with `dd if=/dev/sdX of=/dev/null bs=1M count=2000` |
| USB — VBUS enables | ✅ | measured: all four connectors still enumerate with GPIO0_A2 and GPIO2_C5 both driven low, so VBUS is not gated on this revision | — |
| RS232 / DB9 | ❌ | `/dev/ttyS1` exists and uart1 claims its pins | **no data ever sent.** Bridge DB9 pins 2–3, then `stty -F /dev/ttyS1 115200 raw -echo` and `cat /dev/ttyS1 &` / `printf 'loop\r\n' > /dev/ttyS1`. RTS/CTS needs pins 7–8 bridged. RS232 line levels out of the SP213EEA unmeasured |
| RTC — timekeeping | ✅ | `rtc0` is `rtc-hym8563`, reads agree with system time | — |
| RTC — battery backup | ❌ | the CR2032 on `BAT CON` was never relied on | power off, **unplug mains for 15 min**, boot with the ethernet cable out so NTP cannot mask the result, then `cat /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/time` |
| RTC — wakealarm | 🚫 | INT does not reach any SoC pin (checked via `GPIO_EXT_PORT` on every bank with the alarm flag latched); it goes to the power circuitry | scheduled power-on while the SoC is off may still work from the vendor's perspective, but Linux cannot drive it |
| IR — reception | ✅ | `rc0` + `/dev/lirc0`; a real remote produced clean NEC framing, 8.92 ms leader / 4.42 ms space / ~560 µs bits, address and command inversion bytes checking out, scancode `0x0472` plus repeat frames | — |
| IR — key events | ❌ | no keymap ships, so the active protocol is `[lirc]` (raw) and nothing reaches `/dev/input` | `ir-keytable -p nec` then `ir-keytable -t`; map with `ir-keytable -w <keymap>` |
| Audio — enumeration | ⚠️ | three cards: `ANALOG`, `HDMI`, `SPDIF` | — |
| Audio — playback | ❌ | **nothing was ever played through any of them** | `speaker-test -D hw:ANALOG -c 2 -t sine -l 1`, then the same for `hw:HDMI` and `hw:SPDIF` |
| Audio — capture | 🚫 | the ES7243 ADC is not populated: an i2c scan of every controller finds only the PMIC (0x18) and the RTC (0x51). Note `i2c3` ACKs all 112 addresses because SDA is stuck low — that is not a bus full of devices | use a USB audio device |
| HDMI console | ✅ | boot log and console appear (`DEFAULT_CONSOLE="both"`) | modes, EDID handling and 4K untested |
| microSD | ✅ | booted from it, and it works as the install source | untested as a data card while running from eMMC |
| eMMC | ✅ | boots and runs standalone with the card removed | — |
| Watchdog | ❌ | never triggered — this was briefly listed as working in the README, which was wrong | inspect with `wdctl /dev/watchdog0`; to really test it (**the box will reset hard**) hold the device open without writing: `python3 -c "import time; open('/dev/watchdog0','w'); time.sleep(120)"` |
| GPU | ❌ | RK3328 has a Mali-450 (Utgard), so the driver is `lima`, not `panfrost` | `dmesg \| grep -i lima`, then `kmscube` or `es2_info` |
| Video decode | ❌ | rkvdec / H.264+HEVC, mainline support is partial | `v4l2-ctl --list-devices`, then ffmpeg with a V4L2 request hwaccel. Relevant for a signage player |
| mini-PCIe slot | ❌ | no modem available. That the slot is USB on the hub's fourth downstream port is derived from the topology, not observed | insert e.g. a Quectel EC25 and look for `2c7c:0125` in `lsusb` plus `/dev/ttyUSB*` |
| Recovery button | ❌ | an `adc-keys` node with `button-recovery` is in the device tree | `evtest` while pressing it |

## System behaviour

| | Status | Detail |
|---|---|---|
| Boot from eMMC | ✅ | 21.5 s, no failed units, this profile's U-Boot in charge of both stages |
| Boot from microSD | ✅ | works, but the boot ROM prefers the eMMC bootloader — check `/proc/device-tree/chosen/u-boot,version` before concluding which one ran |
| Reboot | ✅ | one cycle, used to confirm MAC stability |
| Cold start after mains loss | ❌ | never power-cycled at the wall |
| Repeated reboot / poweroff cycles | ❌ | reliability over many cycles unknown |
| Suspend / resume | ❌ | `systemctl suspend`; mainline RK3328 suspend is not a given, it may not come back |
| Thermals under load | ❌ | fanless case, OPP table to 1296 MHz, trip points in `tsadc`. Never stressed: `stress-ng --cpu 4 --timeout 600s` while watching `/sys/class/thermal/thermal_zone0/temp` and `cpufreq` |
| Long-term stability | ❌ | longest observed uptime is ~1.5 h |

## Build and install paths

| Path | Status | Notes |
|---|---|---|
| `BRANCH=current` (6.18) | ✅ | the reference build |
| `BRANCH=edge` | ❌ | listed in `KERNEL_TARGET` but never built. **It would silently use the wrong device tree** — `userpatches/kernel/archive/` only has a `rockchip64-6.18` directory, so a different kernel version finds no DTS. Create the matching directory first |
| `RELEASE=trixie`, CLI | ✅ | the reference build |
| Other releases / `BUILD_DESKTOP=yes` | ❌ | untested |
| `KERNEL_BTF=yes` | ✅ | `/sys/kernel/btf/vmlinux` present, 6 213 086 B. Needs ~6.5 GB RAM on the build host |
| `armbian-install` → boot from eMMC | ✅ | verified; U-Boot version string changes to this profile's build |
| Overlay `gmac2io-rtl8211.dts` | ✅ | this is how ethernet and WiFi were first brought up on a dusun-based install |
| Overlay `dn73-peripherals.dts` | ❌ | **never applied to a running system.** Its contents were verified only through the board DTS, and the overlay differs in ways that matter: raw pin numbers instead of `RK_*` macros, and no `rtc0` alias. Compile it, set `user_overlays`, reboot, and check `/dev/ttyS1`, `rtc1` and `rc0` |

## Smoke test

Reproduces the verified set in one pass. Run over SSH as root.

```sh
uname -r; cat /proc/device-tree/model; echo
cat /proc/device-tree/chosen/u-boot,version; echo
findmnt -no SOURCE /                         # expect mmcblk2p1 after install
ethtool end0 | grep -E 'Speed|Link detected'
cat /sys/class/net/end0/address              # must not change across reboots
ls /sys/class/net/                           # end0 + wlx<mac>
iw dev $(ls /sys/class/net | grep ^wlx) scan | grep -c ^BSS
ls /sys/class/bluetooth/                     # hci0
for r in /sys/class/rtc/rtc*; do echo "$(basename $r): $(cat $r/name)"; done
ls /dev/ttyS1 /dev/lirc0; ls /sys/class/rc/
lsusb
cat /proc/asound/cards
ls -l /sys/kernel/btf/vmlinux
systemctl --failed --no-legend             # expect no output
systemd-analyze
```

## Contributing results

Testing on a second unit is the most useful thing anyone can add — every result
here comes from one box, so board-revision differences are invisible. The VBUS
finding in particular ("not gated on this revision") is explicitly revision-bound.

Please open an issue with the reference-platform details above, which row you
exercised, and the command output. Corrections are as welcome as confirmations;
the watchdog row exists because a claim in the README turned out not to be backed
by a measurement.
