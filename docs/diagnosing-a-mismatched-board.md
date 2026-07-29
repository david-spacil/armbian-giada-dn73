# Diagnosing a board whose device tree does not match the hardware

Notes from getting the Giada DN73 working. The techniques generalise to any
Rockchip board running on a device tree written for something else — which is
the normal situation when a commercial appliance gets reflashed with Armbian.

## The trap

The board looked like a hardware failure for a long time. Ethernet reported
`NO-CARRIER`, the RJ45 LEDs never lit, and the internal PHY was demonstrably
alive (`phy_id = 0x1234d400`, autoneg on) but had no link. Every reading pointed
at a dead port.

It was pure configuration. Two lessons:

**A device tree that boots is not a device tree that matches.** The machine ran
fine — eMMC, HDMI, USB, console all worked — because those blocks are the same
across every RK3328 design. Only the board-specific glue was wrong. A booting
system says nothing about whether the DT describes *your* board.

**Symptoms of unpowered silicon look exactly like broken silicon.** No link
LEDs, no MDIO response, no carrier. Nothing distinguishes "the enable GPIO was
never asserted" from "the chip is dead" until you either measure the rails or
find out what the vendor did.

## Getting the vendor device tree

This is the single highest-value step, and it should come early rather than
after days of guessing.

Rockchip Android firmware is an `RKFW` container holding an `RKAF` update image,
which holds `boot.img`/`resource.img` with the kernel DTB inside — stored
uncompressed. You do not need to unpack the container format at all: scan the
whole file for the FDT magic `d00dfeed`, sanity-check each hit's header, and
carve out the blobs.

That is what [`../scripts/extract-dtb.py`](../scripts/extract-dtb.py) does. On a
1.6 GB image it found eight blobs; the 76 KB one was the kernel device tree,
`model = "GIADA JHS557 ANDROID Q"`.

Everything board-specific came from it in one go:

```dts
vcc-phy-regulator {
    gpio = <&gpio0 0 0>;          /* eth-power-gpio */
    enable-active-high;
};
&gmac2io {
    snps,reset-gpio = <&gpio1 24 1>;
    tx_delay = <0x26>;
    rx_delay = <0x11>;
};
wireless-wlan {
    WIFI,poweren_gpio = <&gpio3 8 0>;
};
```

Note the bindings are vendor-kernel ones (`wlan-platdata`, `WIFI,poweren_gpio`)
that mainline does not implement. They still tell you *which pin does what*,
which is all you need — translate the intent, not the binding.

Where to find firmware: the vendor's support channel, or third-party integrators
who redistribute flashing bundles for the same hardware.

## Reading MDIO without the driver

When the driver says `no phy found`, you cannot tell whether the bus is dead,
the PHY is unpowered, or the driver is simply not looking. Reading the MAC's
MDIO registers directly settles it —
[`../scripts/mdio-raw-scan.py`](../scripts/mdio-raw-scan.py) pokes
`GMAC_MII_ADDR`/`GMAC_MII_DATA` (offsets `0x10`/`0x14` on DWMAC1000) through
`/dev/mem`.

Three outcomes, three different problems:

| Read value | Meaning |
|---|---|
| `0xffff` | bus idles high, pull-up present, nobody answering |
| `0x0000` | line held low — typically an unpowered PHY whose pull-up rail is dead |
| anything else | the PHY is there and talking |

Requirements: `CONFIG_IO_STRICT_DEVMEM` disabled (common), and **leave the
driver bound** — unbinding gates the MAC clocks and MDC stops toggling.

This is what broke the deadlock here. The scan returned `0x001cc915` — an
RTL8211E, answering perfectly — at the exact moment the kernel insisted there
was no PHY. That single fact moved the problem from hardware to software and
pointed straight at `phy_mask`.

## Iterating without rebooting

The stmmac driver can be unbound and rebound, which re-runs the whole MDIO
registration and bus scan:

```sh
echo ff540000.ethernet > /sys/bus/platform/drivers/rk_gmac-dwmac/unbind
echo ff540000.ethernet > /sys/bus/platform/drivers/rk_gmac-dwmac/bind
```

Roughly 2.5 s per attempt instead of a 90 s reboot. Combined with
`/sys/class/gpio` for driving candidate pins, this makes brute-force search
practical.

## Where brute force fails

A sweep of all 80 free GPIOs, each driven both high and low with a rebind after
every attempt, found nothing — even though **both** pins it needed were in the
list.

The reason is worth remembering: the PHY needs its supply enabled *and* its
reset released *simultaneously*. Testing one pin at a time can never satisfy a
two-pin precondition. Before trusting a negative sweep result, ask how many
conditions have to hold at once.

The sweep also only covered *unclaimed* pins. Pins held by another driver are
invisible to it, and on a mismatched DT those claims are meaningless — a pin the
DT hands to some peripheral may do something entirely different on your board.

## Pin conflicts on RK3328

RK3328 has two MACs: `gmac2phy` (`ff550000`, internal 100M PHY) and `gmac2io`
(`ff540000`, RGMII for an external gigabit PHY). There is exactly one pin group
for `gmac2io`, `rgmiim1_pins`, and it overlaps with SDIO and `uart0`.

Enabling it therefore means disabling whatever else claims those pins, and the
kernel tells you one collision at a time:

```
pin gpio1-12 already requested by ff510000.mmc; cannot claim for ff540000.ethernet
```

Rather than rebooting per collision, dump the whole picture at once:

```sh
cat /sys/kernel/debug/pinctrl/pinctrl-rockchip-pinctrl/pinmux-pins
```

## A driver detail that costs hours

`of_mdiobus_register()` sets `phy_mask = ~0` before registering. The practical
consequence:

- **no `mdio` node** → full autoscan of all 32 addresses
- **`mdio` node with PHY children** → those children are registered
- **`mdio` node with no children** → nothing is scanned, nothing is registered

The middle-ground intuition — "the node just configures the bus, scanning still
happens" — is wrong, and the resulting `no phy found` is indistinguishable from
a genuinely absent PHY. The vendor DT sidestepped this by having no `mdio` node
at all.
