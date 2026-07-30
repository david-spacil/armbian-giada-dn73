# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

An out-of-tree **Armbian board profile** for the Giada DN73 (RK3328, ODM JieHe
board JHS557). It is not an application: there is no build system, no test suite
and no CI. The content is device trees plus a board config file, consumed by the
separate [`armbian/build`](https://github.com/armbian/build) framework.

Correctness cannot be established by running anything locally. A device tree that
compiles, and even one that boots, says nothing about whether it describes *this*
board — see `docs/diagnosing-a-mismatched-board.md`, which is the writeup of
exactly that trap. Verification means booting the hardware and checking each
peripheral.

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
  the RK805 has already taken `rtc0` by the time it probes. The overlay leaves
  the RTC as `rtc1` and says so in a comment.

### The `userpatches` path is exact

`userpatches/kernel/archive/<family>-<version>/dt/` — the `archive/` component is
mandatory, and `<version>` must match what the board's `KERNEL_TARGET` resolves
to. `BRANCH=current` for `rockchip64` currently means 6.18, set as
`KERNEL_MAJOR_MINOR` in `config/sources/families/include/rockchip64_common.inc`
upstream. When upstream moves to 6.19 the directory has to be renamed, or the DTS
is **silently ignored** and the image builds against the wrong device tree.

`giada-dn73.csc` lists `KERNEL_TARGET="current,edge"`, but only `current` is
tested (`KERNEL_TEST_TARGET`), and only `current` has a `dt/` directory here.

## Why the board needs any of this

Four independent things, described in full in `README.md`. The short version,
because it shapes every change:

Ethernet needs three conditions satisfied **simultaneously** — `vcc_phy` gated on
GPIO0_A0, reset actively driven on GPIO1_D0, and the RTL8211E declared as an
`mdio` child at address 1. The last one is a driver trap:
`of_mdiobus_register()` sets `phy_mask = ~0`, so an `mdio` node with no PHY
children means no bus scan happens at all. The vendor DT has no `mdio` node and
so relied on autoscan.

Separately, the dusun profile modelled USB VBUS enables on GPIO3_A5/A7, which on
this board are uart1 RTS/CTS. One wrong pin cost the serial port entirely, and
the pins were harmless in their own right — measured, all four USB connectors
enumerate with both driven low, because VBUS is not gated on this revision.

U-Boot is borrowed from the Dusun DSOM 010R on purpose. The kernel loads its own
DTB, so the name in the bootloader has no functional effect.

## Working on the device tree

**The vendor device tree is evidence, not truth.** Board values here come from
the Android DT `GIADA JHS557 ANDROID Q`, recovered with
`scripts/extract-dtb.py`. Its bindings are Rockchip vendor-kernel ones
(`WIFI,poweren_gpio`, `wlan-platdata`) that mainline does not implement —
translate the intent, not the binding.

**Do not describe an interrupt you have not seen move.** The vendor points the
HYM8563's `irq_gpio` at GPIO2_C4 and no SoC pin moves when the alarm fires; the
line goes to the power circuitry, which is what makes scheduled power-on work
while the SoC is off. The interrupt is deliberately omitted, because describing
it would only produce a `wakealarm` that accepts a time and never fires. The same
applies to anything else taken from the vendor DT on faith.

**When measuring GPIO levels, sample each state more than once.** A one-shot
before/after diff of `GPIO_EXT_PORT` produced a convincing false positive on
GPIO1_B5, which is `mac_rxclk` — a 125 MHz clock. Any pin carrying a clock or
fast data will manufacture a difference.

Known-absent hardware, so it does not get re-investigated: the ES7243 mic ADC is
**not populated** (i2c scan finds only the PMIC at 0x18 and the RTC at 0x51), and
the RK3328 has no PCIe at all, so the mini-PCIe slot is USB and needs nothing in
the DT.

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
- `README.md` doubles as the project's status record — its Status table and Known
  quirks sections are updated when hardware verification happens, not separately.

## The repository is public

It was scrubbed before publication and must stay that way:

- **No internal addresses** (`10.0.0.x`, Tailscale IPs, internal apt repos) and
  **no per-unit MAC addresses** — a MAC belongs to one box, not in a shared
  profile. `overlay/gmac2io-rtl8211.dts` shows the derivation from
  `/proc/device-tree/serial-number` as a commented-out example instead.
- **Do not commit vendor firmware or Giada's PDFs.** They are third-party
  copyrighted material; the archives are large and live outside this repo.
