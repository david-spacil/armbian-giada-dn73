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
cp -r userpatches/* build/userpatches/
cd build
./compile.sh build BOARD=giada-dn73 BRANCH=current RELEASE=trixie \
    BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
```

Add `KERNEL_BTF=no` on hosts with less than ~6.5 GB RAM, or the BTF link step
runs out of memory. A full build with BTF takes ~36 min on 20 cores.

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
userpatches/kernel/archive/rockchip64-6.18/dt/    board DTS, for freshly built images
userpatches/customize-image.sh                     runs in the image chroot
overlay/*.dts                                      same fixes, for existing installs
scripts/                                           two diagnostic tools
docs/diagnosing-a-mismatched-board.md              method, and the dead ends
```

The two scripts generalise to any Rockchip board whose vendor firmware is
available. `extract-dtb.py` pulls device tree blobs out of a Rockchip `update.img`
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
to. `BRANCH=current` for `rockchip64` currently means 6.18, set as
`KERNEL_MAJOR_MINOR` in `config/sources/families/include/rockchip64_common.inc`
upstream. When upstream moves to 6.19 the directory has to be renamed, or the DTS
is **silently ignored** and the image builds against the wrong device tree.

`giada-dn73.csc` lists `KERNEL_TARGET="current,edge"`, but only `current` is
tested (`KERNEL_TEST_TARGET`), and only `current` has a `dt/` directory here.

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
