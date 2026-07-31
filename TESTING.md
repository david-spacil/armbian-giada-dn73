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
| Kernel | 6.18.41-current-rockchip64, `BRANCH=current`, full BTF |
| U-Boot | `2026.04_armbian`, this profile's own build |
| Installed on | eMMC (`/dev/mmcblk2p1`), microSD removed |
| Overlays | none applied |
| Boot | 21.4 s (4.9 s kernel + 16.5 s userspace), zero failed units |

Re-verified on a second clean install from an image built with
`./compile.sh build giada-dn73`, on the same unit: model `Giada DN73`, rootfs on
`mmcblk2p1`, this profile's U-Boot in charge, `end0` at 1000 Mb/s, `rtc0` =
`rtc-hym8563`, `/dev/ttyS1`, `rc0`, `rtw88_8821cu` loaded, `lima 1.1.0` bound
with `renderD128` present, four V4L2 decoder nodes, zero failed units. The two
boot figures above — 6.18.40 at 21.5 s and 6.18.41 at 21.4 s — are separate
installs a kernel patch release apart.

`BSPFREEZE=yes` was confirmed on that install: `apt-mark showhold` lists eight
packages with no manual intervention. This is the check worth repeating after
every reinstall, because an empty list means the board will eventually be
updated into an unbootable state — see CLAUDE.md.

The stable MAC survived the reinstall, evidenced independently by the DHCP server
handing back the same lease.

A second round of testing added the GPU, video decode, throughput and thermal
rows. That round ran on the same unit and the same image, with Docker and a few
containers installed since — so its boot time is not comparable with the 21.5 s
above, and it is not quoted here. The GPU rows require the `vdd_logic` fix
described below; anything built before that commit has no GPU at all.

### Configuring WiFi costs about a minute of boot time

Worth knowing before quoting the 21.5 s at anyone. Once a WiFi profile exists and
autoconnects, boot goes to **1 min 20 s**, and `systemd-analyze blame` puts
57.7 s of that on `NetworkManager-wait-online.service`.

It is not a misconfiguration — the PSK is stored, `psk-flags` is 0 — it is the
association flakiness in the WiFi row below, priced in seconds. Read
`journalctl -b -u NetworkManager -o short-monotonic`:

```
48.2  supplicant interface state: authenticating -> disconnected
51.7  supplicant interface state: authenticating -> disconnected
73.0  Activation: (wifi) association took too long, failing activation
73.0  state change: config -> failed (reason 'ssid-not-found')
73.0  manager: startup complete          <- wait-online is released here
73.5  Activation: starting connection 'Spacilovi'   <- the retry
75.0  supplicant interface state: associating -> associated
```

Two failed authentications, then NetworkManager gives up on the *first* attempt
at 73 s, which is what finally releases `network-online.target` — and the retry
that follows immediately succeeds. So the box does get WiFi, roughly a minute
after it could have finished booting.

The cheap mitigation, if boot time matters more than WiFi being up early, is to
stop the profile autoconnecting (`nmcli connection modify <name>
connection.autoconnect no`) or to cap the wait
(`systemctl edit NetworkManager-wait-online.service`, `ExecStart=` then
`ExecStart=/usr/bin/nm-online -s -q --timeout=15`). Neither is applied on the
reference unit, and neither fixes the association itself.

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
| Gigabit ethernet | ✅ | `end0` at 1000 Mb/s full duplex, DHCP lease. Throughput measured against a wired gigabit peer, 3 GiB of raw TCP each way: **935 Mb/s** transmit, **941 Mb/s** receive — line rate | — |
| MAC address stability | ✅ | identical across a reboot *and* across the SD→eMMC reinstall | — |
| WiFi — throughput | ✅ | associated to a WPA2/WPA3-transition AP on 2.4 GHz at −26 dBm, MCS 5–7 / 40 MHz. 20/20 pings to the gateway and to a wired peer, 0 % loss, 3.0 ms average; **77.8 Mb/s** of raw TCP transmit, link still up 30 s later | 5 GHz untested — the only 5 GHz SSID in range reads −90 dBm from where the box sits. Receive-direction throughput not measured |
| WiFi — association | ⚠️ | it does connect, but **not on the first try**: 5 consecutive failures before the 6th succeeded, and across 12 further attempts only 2 came up. Failures stop at `SME: Trying to authenticate` and the AP deauthenticates with `reason=7` / `reason=9`, so it is 802.11 authentication that does not complete, not the key exchange. `rtw88_8821cu: failed to get tx report from firmware` appears in `dmesg` alongside | one AP, one band, one unit. Whether it is the driver, this firmware (24.11.0) or this AP is unresolved. Retrying is a workable stopgap; `NetworkManager` does it by itself, it just takes a few minutes to come up |
| Bluetooth | ⚠️ | `hci0` present, RTL firmware `0x826ca99e` loads | never paired. `bluetoothctl` → `scan on` / `pair` / `connect`. A2DP and BLE untested |
| USB — enumeration | ✅ | all four connectors enumerate; hub, keyboard and the internal WiFi visible | — |
| USB — SuperSpeed | ❌ | only USB 2.0-class devices were ever plugged in | plug a USB3 stick into the blue port, expect `5000M` in `lsusb -t`, then measure with `dd if=/dev/sdX of=/dev/null bs=1M count=2000` |
| USB — VBUS enables | ✅ | measured: all four connectors still enumerate with GPIO0_A2 and GPIO2_C5 both driven low, so VBUS is not gated on this revision | — |
| RS232 / DB9 | ❌ | `/dev/ttyS1` exists and uart1 claims its pins | **no data ever sent.** Bridge DB9 pins 2–3, then `stty -F /dev/ttyS1 115200 raw -echo` and `cat /dev/ttyS1 &` / `printf 'loop\r\n' > /dev/ttyS1`. RTS/CTS needs pins 7–8 bridged. RS232 line levels out of the SP213EEA unmeasured |
| RTC — timekeeping | ✅ | `rtc0` is `rtc-hym8563`, reads agree with system time | — |
| RTC — battery backup | ❌ | the CR2032 on `BAT CON` was never relied on | power off, **unplug mains for 15 min**, boot with the ethernet cable out so NTP cannot mask the result, then `cat /sys/class/rtc/rtc0/date /sys/class/rtc/rtc0/time` |
| RTC — wakealarm | 🚫 | INT does not reach any SoC pin (checked via `GPIO_EXT_PORT` on every bank with the alarm flag latched); it goes to the power circuitry | scheduled power-on while the SoC is off may still work from the vendor's perspective, but Linux cannot drive it |
| IR — reception | ✅ | `rc0` + `/dev/lirc0`; a real remote produced clean NEC framing, 8.92 ms leader / 4.42 ms space / ~560 µs bits, address and command inversion bytes checking out, scancode `0x0472` plus repeat frames | — |
| IR — key events | ⚠️ | `ir-keytable -p nec` takes effect — `/sys/class/rc/rc0/protocols` becomes `rc-5 [nec] rc-6 …`, and rc0 holds an input device. The decoder side is therefore in place | no remote was pressed afterwards, so **no key event has ever been seen**. `ir-keytable -t` while pressing, then `ir-keytable -w <keymap>` for real keycodes. Note the change is not persistent — it needs a `/etc/rc_maps.cfg` entry or a udev rule to survive a reboot |
| Audio — enumeration | ✅ | three cards: `ANALOG`, `HDMI`, `SPDIF` | — |
| Audio — playback | ⚠️ | all three PCMs reach `state: RUNNING` and the DMA advances at exactly the right rate — `hw_ptr` gains ~144 950 frames in 3 s at 48 kHz, against 144 000 expected. So the I2S, SPDIF and HDMI audio clocks are real | **nobody has heard any of them.** A wrong mux or a dead amplifier would look identical from `hw_ptr`. Needs a person with headphones on the jack, a monitor on HDMI and an SPDIF receiver |
| Audio — capture | 🚫 | the ES7243 ADC is not populated: an i2c scan of every controller finds only the PMIC (0x18) and the RTC (0x51). Note `i2c3` ACKs all 112 addresses because SDA is stuck low — that is not a bus full of devices | use a USB audio device |
| HDMI console | ✅ | boot log and console appear (`DEFAULT_CONSOLE="both"`) | modes, EDID handling and 4K untested |
| microSD | ✅ | booted from it, and it works as the install source | untested as a data card while running from eMMC |
| eMMC | ✅ | boots and runs standalone with the card removed | — |
| Watchdog | ✅ | `Synopsys DesignWare Watchdog`, 30 s. Held open without a ping: `timeleft` counted 28 → 24 → 19 → 14 → 9 → 4 and the board reset ~30 s after arming. It came back with no filesystem errors, no failed units, and the GPU, RTC, serial and IR all present. The `dw_wdt: No valid TOPs array specified` warning at probe is cosmetic — the 30 s timeout is honoured | never used to recover a real hang, and `bootstatus` stays 0 after a watchdog reset, so software cannot tell a watchdog reboot from any other |
| GPU | ✅ | **was broken until this was tested** — see [The GPU was not untested, it was broken](#the-gpu-was-not-untested-it-was-broken). With the `vdd_logic` fix: `lima` binds, `/dev/dri/renderD128` appears, `GL_RENDERER` is `Mali450` on Mesa 25.0.7, OpenGL ES 2.0. A headless GBM/EGL benchmark rendered 3 000 frames of 512×512 in 4.46 s (**672 fps**) with correct pixel readback and `glGetError == 0`, and devfreq stepped the GPU 200 → 400 MHz under load | never driven to a real display, so KMS scanout and compositing are unproven. GLES 2.0 is the ceiling — Utgard has no GLES 3.0, no Vulkan |
| Video decode | ✅ | both blocks work through GStreamer 1.26 `v4l2codecs`. `rkvdec` decodes HEVC, H.264 and VP9; the Hantro block decodes MPEG-2 and VP8; both output NV12. Measured against software on the same clips: **4K HEVC 92 fps at 2.6 ms CPU per frame, versus 17 fps and 202 ms in software**; 1080p HEVC 60 fps / 16 ms versus 39 fps / 71 ms; 1080p H.264 57 fps / 16 ms versus 60 fps / 52 ms | only synthetic `testsrc2` clips, no real-world streams, no interlaced content, no 10-bit HEVC. Decoded to `fakesink`, never to a display, so zero-copy to KMS is unproven |
| mini-PCIe slot | ❌ | no modem available. That the slot is USB on the hub's fourth downstream port is derived from the topology, not observed | insert e.g. a Quectel EC25 and look for `2c7c:0125` in `lsusb` plus `/dev/ttyUSB*` |
| Recovery button | ⚠️ | the `adc-keys` node registers an input device, and `saradc` channel 0 reads 1022 raw at rest — with `in_voltage_scale` 1.7578 that is ~1796 mV, just under the 1.8 V rail and comfortably above the 1.75 V `keyup-threshold`. So the divider is wired and idles high, as the device tree assumes | nobody has pressed it. `evtest` on the `adc-keys` device while pressing; expect `KEY_VENDOR` and the raw value dropping towards the 10 mV press threshold |

## The GPU was not untested, it was broken

Worth writing down, because it is the second time on this board that a value
copied from the Dusun profile disabled something unrelated to the node it sits
in — the first was the USB VBUS pins taking away the serial port.

`lima` never bound. The whole of the evidence in the log was:

```
core: _opp_supported_by_regulators: OPP minuV: 1075000 maxuV: 1075000, not supported by regulator
lima ff300000.gpu: _opp_add: OPP not supported by regulators (200000000)
lima ff300000.gpu: Fatal error during devfreq init
lima ff300000.gpu: probe with driver lima failed with error -34
```

`opp-table-gpu` in `rk3328.dtsi` asks for 1 075 000 µV at 200, 300 and 400 MHz.
The rail it asks it of is `mali-supply`, which is `vdd_logic`, which the Dusun
profile constrains to a minimum of 1 100 000 µV. All three OPPs fall outside
that, `_opp_add` drops them, devfreq init fails, and the driver gives up.

Nothing about the symptom points at a regulator. The board came up with
`/dev/dri/card0` present — that is `rockchip-drm`, the display controller, which
probes fine — and no render node at all. Anyone checking "is there a DRM device"
would have said yes.

The fix is one number: 712 500, the RK805 DCDC1 minimum, which is also what
upstream RK3328 boards with the same PMIC use. Afterwards:

| | |
|---|---|
| `dmesg` | `[drm] Initialized lima 1.1.0 for ff300000.gpu on minor 0` |
| render node | `/dev/dri/renderD128` appears |
| `GL_RENDERER` | `Mali450`, Mesa 25.0.7, OpenGL ES 2.0 |
| offscreen benchmark | 3 000 frames of 512×512 in 4.46 s = 672 fps, pixel readback correct, `glGetError == 0` |
| devfreq | 200 / 300 / 400 MHz available, steps up to 400 MHz under load |
| rail | `vdd_log` sits at 1 075 000 µV whenever the GPU is up |

The 500 MHz OPP stays absent, which is not this bug: `lima` reports the GPU
clock's parent at 491.52 MHz, below the 500 MHz the OPP asks for.

Because `vdd_logic` is also `vcodec-supply` for the VPU, dropping it to 1.075 V
was checked under combined load rather than at idle — 600 s of four-thread
`stress-ng` with a 4K HEVC decode loop and a GLES2 render loop running together.
No instability, no decode errors, no throttling.

**Anything that talks to `/dev/dri` needs `video` and `render` group
membership.** The nodes are `root:video` and `root:render`.

## Hardware video decode needs GStreamer, not ffmpeg

Both decoders are stateless V4L2 request-API devices — their output formats are
named "Parsed Slice Data", which is the giveaway. The `ffmpeg` in Debian trixie
cannot drive them: `ffmpeg -hwaccels` lists no `v4l2request`, and the
`h264_v4l2m2m` / `hevc_v4l2m2m` decoders it does ship are the *stateful* M2M
wrappers, which these devices are not.

GStreamer 1.26 does, through `v4l2codecs`: `v4l2slh264dec`, `v4l2slh265dec`,
`v4l2slvp8dec`, `v4l2slvp9dec`, `v4l2slmpeg2dec`. They find the hardware without
configuration.

The split between the two blocks is not the obvious one:

| | Node | Decodes |
|---|---|---|
| `rkvdec` | `platform:rkvdec` | HEVC, H.264, VP9 → NV12 |
| Hantro | `ff350000.video-codec` | MPEG-2, VP8 → NV12 |

**The `/dev/videoN` numbers are not stable across boots** — they swapped between
two reboots during testing, and `/dev/video-dec2` and `/dev/video-dec3` are
plain symlinks to `videoN`, so they swap with them. Match on the driver name
from `v4l2-ctl --info`, not on the number.

## Two traps that cost time here

Both wasted a measurement, and both would waste anyone else's.

**`wdctl` disarms the watchdog.** `nowayout` is 0, so closing `/dev/watchdog0`
stops it — and `wdctl` opens the device to read its properties, then closes it.
Running `wdctl` to "check on" an armed watchdog silently cancels the very thing
being tested. The first attempt here survived five minutes unfed for exactly
that reason and looked like a hardware defect.

**Do not measure WiFi while ethernet is up on the same subnet.** With `end0` and
the WLAN both holding addresses in the same `/24`, the box answers ARP for the
wireless address out of the wired port, replies come back over the wire, and the
wireless link looks catastrophically broken — receive rate pinned at 1.0 Mb/s
and 75–100 % packet loss, at −26 dBm signal. Disconnecting `end0` for the
duration of the test turned that into 0 % loss and 77.8 Mb/s. The association
flakiness in the WiFi row above is real and survives this correction; the
throughput collapse was not.

## System behaviour

| | Status | Detail |
|---|---|---|
| Boot from eMMC | ✅ | 21.5 s, no failed units, this profile's U-Boot in charge of both stages |
| Boot from microSD | ✅ | works, but the boot ROM prefers the eMMC bootloader — check `/proc/device-tree/chosen/u-boot,version` before concluding which one ran |
| Reboot | ✅ | five consecutive cycles, all identical: same MAC, 1000 Mb/s link, `rtc0` the HYM8563, `lima` initialised with no failures, `renderD128` present, `vdd_log` at 1 075 000 µV, `/dev/ttyS1` and `/dev/lirc0` present, no failed units |
| Hard reset | ✅ | the watchdog reset (above) is an unclean power-cycle of the SoC, and the machine came back with a clean filesystem |
| Cold start after mains loss | ❌ | never power-cycled at the wall. The watchdog reset is the closest thing tried, and it does not cut the rails |
| Repeated reboot / poweroff cycles | ⚠️ | five reboots, zero failures. `poweroff` followed by a manual power-on was never tried, and five is not a reliability figure |
| Suspend / resume | ❌ | `systemctl suspend`; mainline RK3328 suspend is not a given, it may not come back |
| Thermals under load | ✅ | 600 s of `stress-ng --cpu 4` with a 4K HEVC decode loop and an offscreen GLES2 loop running alongside — CPU, VPU and GPU all busy at once. Peak **75.8 °C**, average 72.6 °C, starting from 58 °C. All four cores held 1 296 MHz for all 194 samples: **no throttling**, and the 80 °C passive trip was never reached, let alone the 95 °C and 100 °C ones. Ambient was room temperature; a hot rack would eat the 4 °C of headroom |
| Long-term stability | ❌ | longest observed uptime is ~1.5 h, and the second test round deliberately rebooted the machine seven times, so nothing longer exists |

## Build and install paths

| Path | Status | Notes |
|---|---|---|
| `BRANCH=current` (6.18) | ✅ | the reference build |
| `BRANCH=edge` | ❌ | never built, but no longer silently wrong: `edge` resolves to kernel 7.1, and `userpatches/kernel/archive/rockchip64-7.1/dt/` now carries an identical copy of the DTS. The two copies must be kept in sync by hand — `diff` them before trusting an edge build |
| `RELEASE=trixie`, CLI | ✅ | the reference build |
| Other releases / `BUILD_DESKTOP=yes` | ❌ | untested |
| `KERNEL_BTF=yes` | ✅ | `/sys/kernel/btf/vmlinux` present, 6 213 086 B. Needs ~6.5 GB RAM on the build host |
| `armbian-install` → boot from eMMC | ✅ | verified; U-Boot version string changes to this profile's build |
| Overlay `gmac2io-rtl8211.dts` | ✅ | this is how ethernet and WiFi were first brought up on a dusun-based install |
| Overlay `dn73-peripherals.dts` | ⚠️ | **never applied to a running system**, but it does compile, and `fdtoverlay` merges it and `gmac2io-rtl8211.dtbo` onto the stock `rk3328-dusun-dsom-010r.dtb` without complaint. Spot checks of the merged blob: `uart1` `okay`, `rtc@51` `haoyu,hym8563`, `vdd_log` minimum 712500, `gmac2io` `okay`, `ir-receiver` present. So every fragment lands on the node it targets | that says nothing about behaviour. Install a dusun-based image, set `user_overlays`, reboot, and check `/dev/ttyS1`, `rtc1`, `rc0` and `renderD128` |

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
ls /dev/dri/                                 # card0, card1 and renderD128
dmesg | grep -i lima                         # must not say "failed with error"
cat /sys/class/devfreq/ff300000.gpu/available_frequencies
v4l2-ctl --list-devices                      # rkvdec and the Hantro block
cat /sys/class/thermal/thermal_zone0/temp
systemctl --failed --no-legend             # expect no output
systemd-analyze
```

A missing `renderD128`, or `lima … failed with error -34`, means the image was
built without the `vdd_logic` fix.

## Contributing results

Testing on a second unit is the most useful thing anyone can add — every result
here comes from one box, so board-revision differences are invisible. The VBUS
finding in particular ("not gated on this revision") is explicitly revision-bound.

Please open an issue with the reference-platform details above, which row you
exercised, and the command output. Corrections are as welcome as confirmations;
the watchdog row exists because a claim in the README turned out not to be backed
by a measurement.
