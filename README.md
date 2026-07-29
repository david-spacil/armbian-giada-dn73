# Armbian board support for the Giada DN73

Device tree and Armbian board profile for the **Giada DN73**, a fanless RK3328
ARM digital signage player. Armbian has no profile for this board — the closest
one, `dusun-dsom-010r`, matches only the SoC and leaves the machine without
working ethernet or WiFi.

With this profile everything works out of the box: gigabit ethernet, WiFi,
Bluetooth, HDMI console.

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
| — | Haoyu **HYM8563** | battery-backed RTC, i2c1 @ 0x51 |
| — | Everest ES7243 | mic-in ADC, i2c0 @ 0x13 — see *Known quirks* |
| U1800/U1801 | Samsung DDR3 | |

The four USB connectors are one USB 3.2 Gen1 on the xHCI, one USB 2.0 OTG on
the dwc2 (wired `dr_mode = "host"`), and two USB 2.0 behind the GL850G hub.
The hub's fourth downstream port goes to the full-size mini-PCIe slot — the
RK3328 has no PCIe at all, so the advertised 3G/4G support is a USB modem
(Quectel EC25) in a mini-PCIe form factor. Nothing in the device tree is
needed for it.

Board photos are in [`foto_desky/`](foto_desky/). The diagnostic method — recovering
the vendor device tree, reading MDIO without the driver — is written up in
[docs/diagnosing-a-mismatched-board.md](docs/diagnosing-a-mismatched-board.md).

> The RK3328 model is the **DN73**. Giada's DN72 is a different machine built
> around an RK3288 — its datasheet does not describe this board.

## What the board needs that stock Armbian does not do

Three independent things have to be right at the same time, which is what makes
this board look dead rather than merely misconfigured.

### 1. The PHY supply is switched by a GPIO

`vcc_phy` is not a permanently powered rail. It is gated by **GPIO0_A0**, which
the vendor device tree exposes through a pinctrl group named, literally,
`eth-power-gpio`. Stock Armbian models `vcc_phy` as a plain always-on regulator
with no GPIO (and at 1.8 V instead of 3.3 V), so the RTL8211E never starts.

Symptom: MDIO reads return `0x00000000` and the RJ45 link LEDs never light.

### 2. The PHY reset has to be actively driven

**GPIO1_D0**, active low. Nothing else holds this line and the board pulls it
down, so without an explicit `reset-gpios` the PHY stays silent even once its
supply is on.

### 3. The PHY must be declared in the device tree

`of_mdiobus_register()` sets `phy_mask = ~0`. Once an `mdio` node exists, **no
bus scan happens at all** — only PHYs described as child nodes get registered.
An `mdio` node without children therefore ends in `no phy found`, even though
the PHY is powered, out of reset and answering. The RTL8211E sits at address 1.

The vendor device tree has no `mdio` node at all, which is why the autoscan path
worked for it.

### 4. Two GPIOs that belong to the serial port

The Dusun profile models the USB VBUS enables on **GPIO3_A5** and **GPIO3_A7**
and drives them high at boot. On this board those two pins are **uart1 RTS and
CTS** — the DB9 RS232 connector on the back panel. Pinctrl hands them to the
regulators, uart1 can never claim them, and the serial port silently does not
exist.

The real enables are GPIO0_A2 (OTG) and GPIO2_C5 (host). Correcting them costs
nothing electrically — all four USB connectors were measured to enumerate with
both pins held low, so VBUS is not gated on this revision — but it gives the
COM port back.

### 5. There is a real RTC

An HYM8563 sits on i2c1 at 0x51 next to the PMIC, with a backup cell. Stock
Armbian never looks for it and falls back to the RK805's RTC.

Its interrupt is deliberately left out. The vendor device tree points `irq_gpio`
at GPIO2_C4, but nothing on the SoC moves when the alarm fires — with the alarm
flag latched in the chip, every GPIO bank's `EXT_PORT` register reads the same
as before. The INT line goes to the power circuitry instead, which is the only
way the datasheet's *"RTC: set up independently every day, a week as a cycle"*
can work: scheduled power-on has to act while the SoC is off. Describing the
interrupt would only produce a `wakealarm` that accepts a time and never fires.

### And the WiFi

The RTL8821CU hangs off the GL850G hub but has its own supply pin, **GPIO3_B0**.
The vendor drives it from a `wireless-wlan` node with a `WIFI,poweren_gpio`
property — a Rockchip vendor-kernel binding that does not exist in mainline.
Holding the line high with a `gpio-hog` is enough; both the wlan interface
(`rtw88_8821cu`) and bluetooth (`btusb`) then appear. The firmware ships with
Armbian, nothing extra to install.

## Using it

### Building an image

The profile lives in `userpatches/`, so no fork of `armbian/build` is needed —
Armbian looks for board configs in `${USERPATCHES_PATH}/config/boards` and picks
up device trees from `userpatches/kernel/<family>/dt/`.

```sh
git clone --depth 1 https://github.com/armbian/build.git
cp -r userpatches/* build/userpatches/
cd build
./compile.sh build BOARD=giada-dn73 BRANCH=current RELEASE=trixie \
    BUILD_DESKTOP=no BUILD_MINIMAL=no KERNEL_CONFIGURE=no
```

Build hosts with less than ~6.5 GB of RAM need `KERNEL_BTF=no` added, otherwise
the kernel BTF link step runs out of memory.

### Fixing an existing install without reinstalling

If the machine already runs an Armbian image built for `dusun-dsom-010r`, two
overlays apply the same fixes without a reinstall —
[`overlay/gmac2io-rtl8211.dts`](overlay/gmac2io-rtl8211.dts) for ethernet and
WiFi, [`overlay/dn73-peripherals.dts`](overlay/dn73-peripherals.dts) for the
serial port and the RTC:

```sh
for o in gmac2io-rtl8211 dn73-peripherals; do
    dtc -@ -I dts -O dtb -o "/boot/overlay-user/$o.dtbo" "overlay/$o.dts"
done
# then in /boot/armbianEnv.txt:
#   user_overlays=gmac2io-rtl8211 dn73-peripherals
```

The overlays leave the RTC as `rtc1`: by the time it probes, the RK805 has
already taken `rtc0`, and an overlay cannot usefully reorder that. The board
DTS sets the alias properly.

## Known quirks

**MAC address.** U-Boot does not supply one for `gmac2io`, so the kernel
generates a random MAC on every boot and the machine gets a different DHCP lease
each time. The overlay has a commented-out `local-mac-address` with instructions
for deriving a stable value from the SoC eFuse serial.

**MIC-IN does not work and probably cannot.** The RK3328's internal codec is
playback only, so the microphone input goes through an Everest **ES7243** ADC on
i2c0 at 0x13. Mainline has no driver for it — `sound/soc/codecs/` ships es7134
and es7241, neither of which is compatible. Worse, the vendor device tree
declares the chip but leaves **i2s2 and the PDM controller disabled** and never
references it from any DAI link, so there is no working configuration to copy
either. Line-out, S/PDIF and HDMI audio all work.

**Two-minute boot.** Not board-specific, but it bites on every Armbian image
here: `systemd-networkd-wait-online` waits for `systemd-networkd`, which manages
nothing because netplan renders through NetworkManager. It times out after two
minutes and `network-online.target` waits for it. `userpatches/customize-image.sh`
masks the unit; `NetworkManager-wait-online` covers the target correctly.

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

Tested on Armbian with kernel 6.18 (`current`).

| | |
|---|---|
| Gigabit ethernet | 1 Gbps full duplex, 300 MB moved with no errors or drops |
| WiFi + Bluetooth | `rtw88_8821cu`, `hci0` |
| USB | all four connectors enumerate |
| RS232 (DB9) | `/dev/ttyS1` |
| RTC | HYM8563 as `rtc0` — timekeeping only, no wakealarm |
| Audio | line-out, S/PDIF, HDMI — **not** mic-in |
| microSD, eMMC, HDMI, watchdog | |

Not submitted upstream. U-Boot is borrowed from the Dusun DSOM 010R — same SoC,
same power design, and it boots this board fine; the kernel loads its own DTB, so
the name in the bootloader has no functional effect.

## License

Device tree sources are GPL-2.0+ OR MIT, matching the kernel sources they derive
from. `rk3328-giada-dn73.dts` started as a copy of `rk3328-dusun-dsom-010r.dts`
from the Armbian build framework.
