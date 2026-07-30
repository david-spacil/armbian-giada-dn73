# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An out-of-tree **Armbian board profile** for the Giada DN73 (RK3328, ODM JieHe
board JHS557). It is not an application: there is no build system, no test suite
and no CI. The content is device trees plus a board config file, consumed by the
separate [`armbian/build`](https://github.com/armbian/build) framework.

Correctness cannot be established by running anything locally. A device tree that
compiles, and even one that boots, says nothing about whether it describes *this*
board — `docs/diagnosing-a-mismatched-board.md` is the writeup of exactly that
trap. Verification means booting the hardware and checking each peripheral.

`README.md` is the user-facing document and is deliberately kept to the minimum,
in the style of `armbian/build`'s own: how to build, how to patch a running
install, what changes versus the stock profile, and what was and was not verified.
The reasoning, the measurements and the dead ends live here and in `docs/`. Resist
letting depth flow back into the README.

## The board

Not a system-on-module design: the SoC, DDR3, eMMC, the ethernet PHY and the
WiFi/BT combo are all soldered onto one Giada-designed PCB.

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

The four USB connectors are one USB 3.2 Gen1 on the xHCI, one USB 2.0 OTG on the
dwc2 (wired `dr_mode = "host"`), and two USB 2.0 behind the GL850G hub. The hub's
fourth downstream port goes to the full-size mini-PCIe slot.

Board photos are in `foto_desky/`. The RK3328 model is the **DN73**; Giada's DN72
is an RK3288 machine and its datasheet does not describe this board.

## Commands

Building an image (Armbian auto-detects and relaunches itself in Docker, so the
subcommand is `build`, never `docker`):

```sh
git clone --depth 1 https://github.com/armbian/build.git
mkdir -p build/userpatches
cp -r userpatches/* build/userpatches/
cd build
./compile.sh build giada-dn73
```

The bare argument resolves `userpatches/config-giada-dn73.conf`, which carries
the board, branch, release and `BSPFREEZE=yes`. Command-line switches still win,
so `./compile.sh build giada-dn73 BRANCH=edge` works.

`mkdir -p` is not decoration: a fresh clone has no `userpatches/` directory at
all, and `cp -r src/* build/userpatches/` fails outright without it.

Add `KERNEL_BTF=no` on hosts with less than ~6.5 GB RAM, or the BTF link step
runs out of memory — Armbian reports what it has as
`Considering available RAM for BTF build [ <avail>/<needed> MiB ]`. A full build
with BTF takes ~42 min on 20 cores.

**The build host needs a registered arm64 binfmt handler.** Armbian's Docker
container cannot install one for you: every `update-binfmts --enable` it runs
fails with exit 2, and the build then dies on

```
INFO: checking [ arch-test for 'arm64' ]
arm64: not supported on this machine/kernel
```

which names neither qemu nor binfmt and points nowhere near this profile. On
Fedora the fix is `sudo dnf install -y qemu-user-static-aarch64`; check it took
with `ls /proc/sys/fs/binfmt_misc/` (expect `qemu-aarch64`, `flags: F`) and
force it with `systemctl restart systemd-binfmt` if not.

Compiling the overlays (needs `dtc` from the `dtc` / `device-tree-compiler`
package; it is not installed on every dev host, but Armbian images ship it):

```sh
dtc -@ -I dts -O dtb -o gmac2io-rtl8211.dtbo overlay/gmac2io-rtl8211.dts
```

**The board DTS cannot be compiled standalone.** It `#include`s `rk3328.dtsi`,
`rk3328-dram-default-timing.dtsi` and `dt-bindings/` headers, so it only builds
inside a kernel tree — in practice, by running the image build. The overlays have
no includes and do compile on their own, which makes them the faster iteration
path.

Do not pipe `dtc` through `head`: `head` closes the pipe, SIGPIPE kills `dtc`
before it writes the output file, and you get a silent no-op.

## Layout and the one thing that must stay in sync

```
userpatches/config/boards/giada-dn73.csc          board config (U-Boot, kernel target)
userpatches/kernel/archive/rockchip64-6.18/dt/    board DTS for BRANCH=current
userpatches/kernel/archive/rockchip64-7.1/dt/     the same DTS for BRANCH=edge
userpatches/customize-image.sh                     runs in the image chroot
overlay/*.dts                                      same fixes, for existing installs
scripts/extract-dtb.py, mdio-raw-scan.py           diagnostic tools
scripts/check-upstream.sh                          reports drift from armbian/build
.github/workflows/upstream-drift.yml               runs it weekly, files an issue
docs/diagnosing-a-mismatched-board.md              method, and the dead ends
```

The two diagnostic scripts generalise to any Rockchip board whose vendor
firmware is available. `extract-dtb.py` pulls device tree blobs out of a Rockchip `update.img`
by scanning for the FDT magic — this is how the board's GPIO assignments were
recovered. `mdio-raw-scan.py` reads MDIO straight from the DWMAC1000 registers via
`/dev/mem`, bypassing phylib, and distinguishes "bus floating high" from "held low"
from a real PHY answering; it is what proved the PHY was alive while the driver
still reported `no phy found`.

**Every hardware fix exists in two places.** The full board DTS is what a new
image gets; the two overlays exist so a machine already running a
`dusun-dsom-010r` image can pick the fixes up without being reinstalled
(`gmac2io-rtl8211.dts` for ethernet and WiFi, `dn73-peripherals.dts` for serial,
RTC and IR). A change to one is incomplete until it is in the other. Nothing
enforces this.

Two differences between the forms are deliberate, not oversights:

- The board DTS uses `RK_PA2`-style macros; the overlays use raw pin numbers
  (`<0 2 0 ...>`) because plugin sources here include no bindings headers.
- The board DTS sets `rtc0 = &hym8563` in `aliases`; the overlay cannot, because
  the RK805 has already taken `rtc0` by the time it probes. Overlays cannot
  usefully reorder aliases at all, which is also why the overlay path leaves the
  ethernet MAC problem below unfixed.

### The `userpatches` path is exact

`userpatches/kernel/archive/<family>-<version>/dt/` — the `archive/` component is
mandatory, and `<version>` must match what the board's `KERNEL_TARGET` resolves
to. The versions live in `KERNEL_MAJOR_MINOR` in
`config/sources/families/include/rockchip64_common.inc` upstream: `current` is
6.18 and `edge` is 7.1. When either moves the directory has to be renamed, or
the DTS is **silently ignored** and the image builds against the wrong device
tree.

`giada-dn73.csc` lists `KERNEL_TARGET="current,edge"`, so **both** versions need
a directory, and the DTS is kept as two identical copies:

```
userpatches/kernel/archive/rockchip64-6.18/dt/rk3328-giada-dn73.dts   BRANCH=current
userpatches/kernel/archive/rockchip64-7.1/dt/rk3328-giada-dn73.dts    BRANCH=edge
```

`diff` between them must come back empty. `scripts/check-upstream.sh` enforces
that, along with everything else below. Only `current` is tested
(`KERNEL_TEST_TARGET`); the `edge` copy exists so that building it does not
silently fall back to a device tree for a different board.

## Keeping up with upstream

### How the DTS actually reaches the build

Worth knowing precisely, because the failure mode is silent. Upstream declares
the mechanism in `patch/kernel/archive/rockchip64-<version>/0000.patching_config.yaml`:

```yaml
dts-directories:
  - { source: "dt", target: "arch/arm64/boot/dts/rockchip" }
```

The patcher walks its root directories — the framework's own `patch/` and our
`userpatches/` — looking for that same relative path in each, keys the files it
finds by basename, and lets **userpatches win**. That is the whole of why this
profile works without forking `armbian/build`.

The dangerous line is in `lib/tools/common/dt_makefile_patcher.py`:

```python
if not os.path.isdir(full_path_source):
    continue
```

A directory whose name no longer matches `KERNEL_MAJOR_MINOR` is skipped with no
error and only a `log.debug`. The build succeeds, the image ships the
`dusun-dsom-010r` device tree, and the board comes up with no ethernet, no WiFi,
no serial and no RTC. `userpatches/customize-image.sh` now fails the build if
`rk3328-giada-dn73.dtb` is missing from the rootfs or does not contain the
string `Giada DN73`, which is the only cheap way to make that loud.

There is a gift in the same file: when a file we ship already exists upstream,
the patcher warns *"Target file already exists; will overwrite it; consider if
it should be removed."* That is the automatic signal that our DTS has landed in
mainline and this repository can shed weight.

### What this profile is actually pinned to

`giada-dn73.csc` is a copy of upstream's `config/boards/dusun-dsom-010r.csc`
with the board name and `BOOT_FDT_FILE` changed. Everything else —
`BOOTCONFIG`, `BOOTBRANCH_BOARD`, `BOOTPATCHDIR`, `BOOT_SCENARIO`,
`BOARDFAMILY` — is inherited verbatim. So "keeping up with upstream" in practice
means **tracking that one board**, not the framework in general. When Armbian
bumps the Dusun board's U-Boot pin, this profile should almost certainly follow.

Two of those dependencies are not mainline at all, which is easy to assume
wrongly:

- `dusun-dsom-010r-rk3328_defconfig` is **not** in U-Boot. Armbian supplies it,
  and it moved shape between releases — a patch under
  `patch/u-boot/v2025.10/board_dusun-dsom-010r/`, a bare file under
  `patch/u-boot/v2026.04/defconfig/`.
- `rk3328-dusun-dsom-010r.dts` is **not** in the kernel. Armbian ships it as a
  bare DTS through the same `dt/` mechanism this profile uses.

If Armbian ever drops the Dusun board, both go with it, and the overlays lose
the device tree they are written against. The escape hatch for the U-Boot half
is `${USERPATCHES_PATH}/u-boot/<patch_dir>/`, which
`lib/functions/artifacts/artifact-uboot.sh:65` adds as a patch root alongside
the framework's own — the defconfig is 90 lines and could be vendored here. It
is deliberately *not* vendored today, because a second copy is a second thing to
keep in sync and `check-upstream.sh` already fails loudly if the file goes away.

### Why the base board is still Dusun

Every rk3328 board in Armbian and in mainline was scored against what actually
defines this machine, rather than against the SoC. Settled; do not redo it.

Nothing came close. The best candidates — `rk3328-nanopi-r2s`,
`rk3328-orangepi-r1-plus`, `rk3328-a1` — match on ethernet and nothing else:
`gmac2io` with an external RGMII PHY, an `mdio` child, a driven reset, and in
the NanoPi's case the same RTL8211E at address 1. But their PHY supply is a
plain always-on regulator, which is precisely the bug that kept this board's
ethernet dead, and none of them has the HYM8563, `uart1` as a real port, an IR
receiver, a USB-attached WiFi power hog, or an enabled GPU. Dusun itself scores
*below* them; it wins only on the GPU being switched on at all, and it has that
wrong.

That does not matter, because **the DTS ancestry is history, not coupling.**
`rk3328-giada-dn73.dts` is standalone — it includes `rk3328.dtsi` and
`rk3328-dram-default-timing.dtsi`, never the Dusun file. Re-deriving it would
churn a hardware-verified file for no functional gain.

The one live coupling is `BOOTCONFIG`, and it is **not** safely swappable. The
two Armbian-supplied rk3328 defconfigs, `dusun-dsom-010r` and `z28pro`, are
exactly the two that set `CONFIG_ROCKCHIP_EXTERNAL_TPL=y`: DRAM init comes from
the rkbin blob. Every mainline rk3328 defconfig — `roc-cc`, `rock64`,
`nanopi-r2s`, `orangepi-r1-plus` — builds U-Boot's own TPL instead. Switching
would replace working DDR3 init on these Samsung parts with untested init, which
is the one change that can leave a box that boots from eMMC unable to boot at
all. The rest of the U-Boot pin (`BOOTBRANCH_BOARD`, `BOOTPATCHDIR`,
`BOOT_SCENARIO`) is identical across all of them anyway, so there is nothing
else to gain.

Note that `z28pro-rk3328_defconfig` pairs `CONFIG_ROCKCHIP_EXTERNAL_TPL=y` with
`CONFIG_DEFAULT_DEVICE_TREE="rockchip/rk3328-rock64"`. If a Dusun-free future
ever forces the issue, that is the pattern to copy: a mainline device tree with
the external TPL flipped back on.

### Updates are the thing that breaks this board

Not a device tree problem, but the one that ends with a box that does not come
back. Armbian's `linux-dtb-current-rockchip64` ships 255 device trees and none of
them is this board — the Giada DTB exists only in the locally built package of
the same name. `unattended-upgrades` is enabled by default and Armbian's own
`/etc/apt/apt.conf.d/02-armbian-periodic` allows `origin=Armbian`, so the first
time `apt.armbian.com` publishes a version above the locally built one, the DTB
is replaced by a package without it, U-Boot stops resolving
`fdtfile=rockchip/rk3328-giada-dn73.dtb`, and the board fails to boot with
nobody watching. Locally built `26.08.0-trunk` currently outranks the repository's
`26.5.1`, which is the only reason this has not happened yet.

Two mechanisms, both Armbian's own, and both needed:

- **New images**: `BSPFREEZE=yes` in `userpatches/config-giada-dn73.conf`.
  `lib/functions/rootfs/distro-agnostic.sh:423` `apt-mark hold`s every locally
  built package installed into the image, from inside the chroot. It works off
  the build's own list, so it cannot miss one the way a hand-written list would.
- **A machine already running**: `armbian-config --api module_armbian_firmware
  hold`, with `... hold status` to check.

**The two are not equivalent, and the difference is deliberate on Armbian's part.**
Measured on a real build, `BSPFREEZE` holds eight packages:

```
base-files  linux-image-current-rockchip64  linux-dtb-current-rockchip64
armbian-firmware  armbian-zsh  armbian-plymouth-theme
armbian-bsp-cli-giada-dn73-current  linux-u-boot-giada-dn73-current
```

The runtime hold covers two, `linux-image-current-rockchip64` and
`linux-dtb-current-rockchip64` — precisely the pair whose names are generic but
whose contents are ours, which is the minimum that keeps the board bootable.
`BSPFREEZE` additionally pins the board-agnostic Armbian layer, so an image built
this way stops receiving `armbian-firmware` and friends from `apt.armbian.com`
too. That is consistent with the update path below rather than a side effect, but
it does mean the whole Armbian layer moves only when you rebuild. Debian's own
packages are untouched either way, so security updates keep flowing.

The two board-named packages, `linux-u-boot-giada-dn73-current` and
`armbian-bsp-cli-giada-dn73-current`, are belt-and-braces: no package of that
name exists upstream to overwrite them.

`unattended-upgrade` skips `SELSTATE_HOLD` packages outright (`/usr/bin/unattended-upgrade`,
lines 431 and 1261), so the hold is enough. Note that `apt-mark hold` does not
stop an **explicit** `apt install pkg=version` — verified, apt will happily
downgrade past the hold when asked by name. That is fine for this threat model
and worth knowing before doing it by hand.

So the update path for this board is: rebuild from this repository and install
the packages it produces. Not `apt upgrade` from `apt.armbian.com`.

### The bump procedure

`scripts/check-upstream.sh` reports all of this without building anything, and
`.github/workflows/upstream-drift.yml` runs it weekly and files an issue. When
it says the kernel version moved:

1. `git mv userpatches/kernel/archive/rockchip64-<old>/ .../rockchip64-<new>/`,
   for whichever of `current` and `edge` moved. Keep the copies identical.
2. Diff the new `rk3328.dtsi` against the old one for the nodes this board
   overrides — `opp-table-0` (the DTS deletes it), `opp-table-gpu` (its 1075000
   µV is why `vdd_logic` needs a 712500 floor), `gmac2io`, `i2s1`, `codec`,
   `tsadc`. The checker watches the first two; the rest need eyes.
3. Re-run `scripts/check-upstream.sh` — it should come back clean.
4. Build, install, and run the smoke test in `TESTING.md`. The
   `customize-image.sh` assertion catches a wrong device tree, but only booting
   the board catches a wrong *value* in the right device tree.
5. Update the reference platform table in `TESTING.md` with what was actually
   tested. If only `current` was booted, say so.

## Why the board needs each thing it needs

### Ethernet: three conditions that must hold simultaneously

The RJ45 goes through an external RTL8211E on `gmac2io` (`ff540000`). Stock
Armbian disables it and enables `gmac2phy` (`ff550000`, internal 100M) instead,
which on this board is connected to nothing.

1. **`vcc_phy` is switched by GPIO0_A0.** It is not a permanently powered rail;
   the vendor exposes it through a pinctrl group named, literally,
   `eth-power-gpio`. Stock Armbian models `vcc_phy` as a plain always-on
   regulator with no GPIO *and* at 1.8 V instead of 3.3 V. This was the primary
   cause — the PHY never started.
2. **Reset on GPIO1_D0 must be actively driven,** active low. Nothing else holds
   the line and the board pulls it down, so without an explicit `reset-gpios` the
   PHY stays silent even once its supply is on.
3. **The PHY must be declared as an `mdio` child** at address 1.
   `of_mdiobus_register()` sets `phy_mask = ~0`, so:
   - no `mdio` node → full autoscan of all 32 addresses
   - `mdio` node with PHY children → those children are registered
   - `mdio` node with no children → **nothing is scanned, nothing is registered**

   The middle-ground intuition ("the node just configures the bus, scanning still
   happens") is wrong, and the resulting `no phy found` is indistinguishable from
   a genuinely absent PHY. The vendor DT sidesteps this by having no `mdio` node.

Symptom of any of the three: MDIO reads return `0x00000000` and the RJ45 link
LEDs never light. A brute-force GPIO sweep cannot find this, because testing one
pin at a time can never satisfy a two-pin precondition — see `docs/`.

The RGMII pin group `rgmiim1_pins` is the only one RK3328 has for `gmac2io`, and
it collides with `sdio`, `sdio_pwrseq` and `uart0`. All three are disabled here;
none of them serves anything on this board (no SDIO chip — the WiFi is USB — and
the console is on `ttyS2` / `ff130000`).

### The MAC address, and why an alias fixes it

Rockchip U-Boot derives a stable MAC from the SoC cpuid and writes it into
`local-mac-address` on whatever node **`ethernet0`** aliases. On the dusun device
tree that is `gmac2phy`, so `gmac2io` got nothing and the kernel invented a random
address on every boot — a different DHCP lease each time. Setting
`ethernet0 = &gmac2io` fixes both that and the interface name (`end0`, because
udev then sees it as onboard device 0). Verified stable across a reinstall.

WiFi gets no such treatment: the RTL8821CU is a USB device with no DT node, so
udev has no onboard index and names it `wlx<mac>`. That one is not fixable from
the device tree, only with a `systemd.link` file.

Unrelated to the board but it bites every image built here:
`systemd-networkd-wait-online` waits for `systemd-networkd`, which manages nothing
because netplan's global renderer in `armbian.yaml` is NetworkManager (merged
after `10-dhcp-all-interfaces.yaml`, so it wins). It alone added two minutes to
every boot, and `network-online.target` waits for it.
`userpatches/customize-image.sh` masks the unit; `NetworkManager-wait-online`
covers the target correctly.

### WiFi: a vendor binding that does not exist in mainline

The RTL8821CU hangs off the GL850G hub but has its own supply pin, **GPIO3_B0**.
The vendor drives it from a `wireless-wlan` node with a `WIFI,poweren_gpio`
property — a Rockchip vendor-kernel binding with no mainline equivalent. Holding
the line high with a `gpio-hog` is enough; `rtw88_8821cu` and `btusb` both then
appear, and the firmware ships with Armbian.

### The USB VBUS pins that cost the serial port

The dusun profile models the VBUS enables on **GPIO3_A5** and **GPIO3_A7** and
drives them high at boot. On this board those are **uart1 RTS and CTS** — the DB9
on the back panel. Pinctrl hands them to the regulators, uart1 can never claim
them, and the serial port silently does not exist. The real enables are GPIO0_A2
(OTG) and GPIO2_C5 (host).

Two things generalise from this. The damage from a wrong pin surfaces on a
peripheral unrelated to the node that got it wrong — nobody investigating a
missing serial port starts by reading the USB regulators. And the wrong pins were
*harmless in their own right*: measured with both driven low, all four USB
connectors still enumerate, because VBUS is not gated on this revision at all. **A
GPIO assignment that appears to work is not evidence that it is correct; it may
simply be connected to nothing.**

### The RTC, and the interrupt that is deliberately absent

An HYM8563 sits on i2c1 at 0x51 next to the PMIC, with a CR2032 on the `BAT CON`
connector. Stock Armbian never looks for it and falls back to the RK805's RTC.

The vendor points `irq_gpio` at GPIO2_C4, but nothing on the SoC moves when the
alarm fires: with the alarm flag latched in the chip, every GPIO bank's
`EXT_PORT` register reads the same as before. The INT line goes to the power
circuitry instead, which is the only way the datasheet's *"RTC: set up
independently every day, a week as a cycle"* can work — scheduled power-on has to
act while the SoC is off.

So the interrupt is omitted on purpose. Describing it would produce a `wakealarm`
that accepts a time and never fires, which is worse than no `wakealarm`.
Implementation notes for the chip, if anyone revisits it: the alarm has **minute
granularity**, and in `CTRL2` bit 1 is AIE and bit 3 is AF.

### The IR receiver

The vendor runs it from PWM3 in capture mode through `rockchip,remotectl-pwm`, a
vendor-kernel driver with no mainline counterpart — presumably why nobody bothers
with IR on RK3328 boards.

It is not needed. The part on GPIO2_A2 is a *demodulating* receiver, so rc-core
handles it directly via `gpio-ir-receiver`. Measured with a random remote: a
8.92 ms leader mark, a 4.42 ms space, ~560 µs bit marks, with both the address and
the command inversion bytes checking out — textbook NEC. One capture gave
scancode `0x0472` plus two 9 ms + 2.25 ms repeat frames.

No keymap is set, since the machine ships without a remote, and the active
protocol is therefore `[lirc]` (raw). Getting key events needs `ir-keytable -p nec`
and a keymap.

### The GPU, and a regulator floor that silently disabled it

`vdd_logic` is `mali-supply`. `opp-table-gpu` in `rk3328.dtsi` asks for
1 075 000 µV at 200, 300 and 400 MHz. The dusun profile bounds the rail at
1 100 000 µV, so all three fall outside the permitted range, `_opp_add` drops
them, devfreq init fails and `lima` never binds:

Worth knowing that upstream's `rk3328-dusun-dsom-010r.dts` carries
`//regulator-min-microvolt = <712500>;` commented out on the line directly above
the `1100000` that replaced it. Somebody raised the floor deliberately, so the
value is a decision rather than a typo — and a `//` comment will fool any tool
that greps device trees without stripping comments first.

```
lima ff300000.gpu: Fatal error during devfreq init
lima ff300000.gpu: probe with driver lima failed with error -34
```

The floor is now 712 500, the RK805 DCDC1 minimum and what upstream RK3328
boards with the same PMIC use.

This is the same shape of failure as the USB VBUS pins that took away the serial
port: **the damage lands on a peripheral unrelated to the node that carries the
wrong value.** Nobody debugging a missing GPU starts by reading regulator
constraints, and the log names no regulator — the only clue is the bare
`-34` (`ERANGE`) from a driver that has no obvious connection to the PMIC.

What makes it worse than the VBUS case is that `/dev/dri/card0` exists either
way. That node is `rockchip-drm`, the display controller, and it probes fine
regardless. The test "is there a DRM device" answers yes on a machine with no
GPU. The thing to check is **the render node**, `/dev/dri/renderD128`.

Verified after the change: `lima` binds, `GL_RENDERER` is `Mali450` on Mesa
25.0.7 with OpenGL ES 2.0, an offscreen GBM/EGL benchmark renders 672 fps at
512×512 with correct pixel readback, and devfreq steps 200 → 400 MHz under load.

`vdd_logic` is also `vcodec-supply` for `&vpu`, so lowering its floor was
validated under combined CPU, GPU and VPU load rather than at idle — ten minutes
of four-thread `stress-ng` plus a 4K HEVC decode loop plus a GLES2 render loop,
peaking at 75.8 °C with no throttling and no errors. The rail does sit at
1.075 V for that whole time, since every available GPU OPP asks for it.

The 500 MHz OPP is still dropped, for an unrelated reason: `lima` reports the
clock parent at 491.52 MHz, below what that OPP asks for.

### Video decode: two blocks, and a userspace that has to be GStreamer

Both are stateless V4L2 request-API decoders — their coded formats are named
"Parsed Slice Data", which is how you tell. Debian's `ffmpeg` cannot drive them:
no `v4l2request` hwaccel, and its `h264_v4l2m2m` / `hevc_v4l2m2m` are the
*stateful* wrappers for a different kind of device. GStreamer 1.26's
`v4l2codecs` plugin does, with no configuration.

`rkvdec` (`platform:rkvdec`) handles HEVC, H.264 and VP9; the Hantro block at
`ff350000` handles MPEG-2 and VP8. Both output NV12. Nothing in the device tree
needed changing — this is all inherited from `rk3328.dtsi` and was simply never
exercised.

**The `/dev/videoN` numbering is not stable across boots.** It swapped between
two reboots during testing, and `/dev/video-dec2` / `-dec3` are plain symlinks
to `videoN`, so they swap too. Match on the driver name from `v4l2-ctl --info`.

Measured against software decode of the same clips, the case for the hardware is
entirely in the CPU column: 4K HEVC at 92 fps and 2.6 ms of CPU per frame,
versus 17 fps and 202 ms in software. At 1080p H.264 the wall-clock times are
the same and only the CPU cost differs, so a benchmark that watches only fps
will conclude the hardware does nothing.

## Working on the device tree

**The vendor device tree is evidence, not truth.** Board values here come from
the Android DT `GIADA JHS557 ANDROID Q`, recovered with
`scripts/extract-dtb.py`. Its bindings are Rockchip vendor-kernel ones
(`WIFI,poweren_gpio`, `wlan-platdata`) that mainline does not implement —
translate the intent, not the binding. And as the RTC interrupt and the mic input
both show, the vendor DT also describes things that are not there.

**Do not describe an interrupt, or any peripheral, you have not seen work.**

**When measuring GPIO levels, sample each state more than once.** A one-shot
before/after diff of `GPIO_EXT_PORT` produced a convincing false positive on
GPIO1_B5, which is `mac_rxclk` in `rgmiim1_pins` — a 125 MHz clock. Repeating the
snapshot eight times per state showed it and its neighbours flipping at random in
*both* states. Any pin carrying a clock or fast data will manufacture a difference
for you.

Faster iteration than rebooting: the stmmac driver can be unbound and rebound,
which re-runs MDIO registration and the bus scan in ~2.5 s.

```sh
echo ff540000.ethernet > /sys/bus/platform/drivers/rk_gmac-dwmac/unbind
echo ff540000.ethernet > /sys/bus/platform/drivers/rk_gmac-dwmac/bind
```

### Hardware that is not there

Settled, so it does not get re-investigated:

- **The ES7243 mic ADC is not populated.** The RK3328's internal codec is playback
  only, so capture needs a separate ADC; the vendor DT declares one on i2c0 at
  0x13 and nothing answers. Scanning every i2c controller on the SoC finds only
  the PMIC (0x18) and the RTC (0x51), both on i2c1 — note that **i2c3 ACKs all
  112 addresses because SDA is stuck low**, which is not a bus full of devices.
  Consistently, the vendor DT leaves i2s2 and the PDM controller disabled and
  never references the ES7243 from any DAI link, so even Android had no capture
  path. Mainline has no driver for the part either (`sound/soc/codecs/` ships
  es7134 and es7241, neither compatible). Use USB audio.
- **There is no PCIe.** RK3328 has none, so the full-size mini-PCIe slot is USB,
  on the hub's fourth downstream port. The advertised 3G/4G is a USB modem in a
  mini-PCIe form factor and needs nothing in the device tree.

### Two boot stages, two different preference orders

Conflating these wastes an evening. The boot ROM picks the *bootloader* and
prefers eMMC. That U-Boot then picks the *operating system*, and its
`boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi` puts the SD card first (in
the U-Boot DT, `mmc0` is eMMC at `ff520000` and `mmc1` is SD at `ff500000`).

So a box with an existing eMMC install runs the old bootloader with the new
kernel, even though the card carries a complete bootloader of its own — verified
by finding the card's sector 64 byte-identical to the built image. Always read
`/proc/device-tree/chosen/u-boot,version` before concluding anything about a
card-booted system. After `armbian-install` writes the bootloader to eMMC, the
card becomes a fallback at both stages, and it is worth removing it afterwards so
that "testing eMMC" is not silently testing the card.

Rockchip's idbloader at sector 64 is RC4-obfuscated, which is why that area looks
like random bytes rather than anything greppable.

## Conventions

- Prose and DTS comments are **English**. `overlay/gmac2io-rtl8211.dts` is Czech
  for historical reasons; new work is English, and touching that file is a chance
  to convert it.
- Kernel style in the DTS: tabs, SPDX header, `GPL-2.0+ OR MIT` (it derives from
  `rk3328-dusun-dsom-010r.dts`).
- Comments carry the *reason* a value is what it is, especially where it
  contradicts the vendor or upstream. This repo is largely a record of why, and
  that is the point of it.
- Commit messages likewise: imperative subject, body explaining what was measured
  and what it ruled out.
- `README.md`'s Status table and Known quirks sections are the project's status
  record, updated when hardware verification happens, not separately.

## The repository is public

It was scrubbed before publication and must stay that way:

- **No internal addresses** (`10.0.0.x`, Tailscale IPs, internal apt repos), **no
  per-unit MAC addresses and no SoC serial numbers** — those belong to one box,
  not in a shared profile. `overlay/gmac2io-rtl8211.dts` shows the derivation from
  `/proc/device-tree/serial-number` with placeholder hex instead.
- **Do not commit vendor firmware or Giada's PDFs.** They are third-party
  copyrighted material; the archives are large and live outside this repo.
