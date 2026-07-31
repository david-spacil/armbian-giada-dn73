#!/usr/bin/env bash
#
# Check that every hardware fix exists in both places.
#
# A new image gets the fixes from the board DTS; a machine already running a
# dusun-dsom-010r image gets them from the overlays. The two are written in
# different dialects - the DTS uses RK_PA2-style macros and plain node
# references, the overlays use raw pin numbers and fragment/__overlay__ pairs,
# because plugin sources here include no bindings headers - so a value fixed on
# one side and forgotten on the other cannot be found by diffing them.
#
# The trick is to normalise both dialects into one, and then state each fact
# once. Normalisation strips comments, expands RK_Pxn to a pin number,
# GPIO_ACTIVE_LOW to 1 and RK_FUNC_GPIO to 0, rewrites
# "fragment@N { target = <&x>; __overlay__ {" into "&x {", and flattens
# whitespace. After that the two forms of, say, the PHY reset are the same
# string, and the check is a grep.
#
# Not a device tree parser: it proves a value is present, not that it sits in
# the right node, and it only knows about the facts listed below. It exists to
# catch the one mistake this repository is shaped to make - fixing one copy.
#
# Needs no network. Exit status: 0 in sync, 1 a fact is missing somewhere.
#
# Usage: scripts/check-overlay-parity.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS="${REPO_ROOT}/userpatches/kernel/archive/rockchip64-6.18/dt/rk3328-giada-dn73.dts"
OVERLAYS=("${REPO_ROOT}/overlay/gmac2io-rtl8211.dts" "${REPO_ROOT}/overlay/dn73-peripherals.dts")

fail=0
red() { printf '\033[31m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }
ERROR() { red "  FAIL  $*"; fail=1; }
OK()    { grn "  ok    $*"; }
NOTE()  { echo "        $*"; }

command -v perl > /dev/null || { red "perl is required but not installed."; exit 1; }

for f in "$DTS" "${OVERLAYS[@]}"; do
	[[ -f $f ]] && continue
	red "missing: ${f#$REPO_ROOT/}"
	exit 1
done

normalise() {
	perl -0777 -pe 's{/\*.*?\*/}{ }gs; s{//[^\n]*}{}g' "$@" \
		| perl -pe 's/RK_P([A-D])(\d)/(ord($1)-65)*8+$2/ge' \
		| sed -e 's/GPIO_ACTIVE_HIGH/0/g' \
		      -e 's/GPIO_ACTIVE_LOW/1/g' \
		      -e 's/RK_FUNC_GPIO/0/g' \
		| tr '\n\t' '  ' | tr -s ' ' \
		| perl -pe 's/fragment\@\d+ \{ target = <(&\w+)>; __overlay__ \{/$1 {/g'
}

dts_n=$(normalise "$DTS")
ovl_n=$(normalise "${OVERLAYS[@]}")

# Each fact is "what it is|the normalised form both sides must carry".
#
# Node-scoped patterns use <name>:? ?[^{]*\{[^}]*<value> so that they match the
# board DTS, where the node is written "vcc_phy: LDO_REG3 {", and the overlay,
# where normalisation has turned the fragment into "&vcc_phy {".
BOTH=(
	"PHY supply is switched by GPIO0_A0|gpio = <&gpio0 0 0>"
	"PHY supply is active high|enable-active-high"
	"PHY supply is 3.3 V, not the 1.8 V upstream models|vcc_phy:? ?[^{]*\{[^}]*3300000"
	"PHY reset is driven on GPIO1_D0, active low|reset-gpios = <&gpio1 24 1>"
	"PHY reset delays|reset-delay-us = <20000>; reset-post-delay-us = <100000>;"
	"the PHY is declared as an mdio child at address 1|ethernet-phy@1 \{ reg = <1>"
	"gmac2io takes its clock from the PHY|clock_in_out = \"input\""
	"gmac2io is RGMII|phy-mode = \"rgmii\""
	"RGMII tx delay|tx_delay = <0x26>"
	"RGMII rx delay|rx_delay = <0x11>"
	"the unconnected internal PHY is off|gmac2phy \{ status = \"disabled\""
	"sdio is off, it collides with rgmiim1_pins|sdio \{ status = \"disabled\""
	"uart0 is off, it collides with rgmiim1_pins|uart0 \{ status = \"disabled\""
	"WiFi power is hogged high on GPIO3_B0|gpio-hog; gpios = <8 0>; output-high;"
	"USB OTG VBUS is GPIO0_A2, not the dusun GPIO3_A5|gpio = <&gpio0 2 0>"
	"USB host VBUS is GPIO2_C5, not the dusun GPIO3_A7|gpio = <&gpio2 21 0>"
	"the OTG VBUS pin is claimed by pinctrl|rockchip,pins = <0 2 0 &pcfg_pull_none>"
	"the host VBUS pin is claimed by pinctrl|rockchip,pins = <2 21 0 &pcfg_pull_none>"
	"IR receiver on GPIO2_A2, active low|gpios = <&gpio2 2 1>"
	"IR is handled by rc-core, not the vendor PWM driver|compatible = \"gpio-ir-receiver\""
	"the IR pin is claimed by pinctrl|rockchip,pins = <2 2 0 &pcfg_pull_none>"
	"uart1 is a real port, with flow control|pinctrl-0 = <&uart1_xfer>, <&uart1_cts>, <&uart1_rts>"
	"uart1 is enabled|uart1 \{[^}]*status = \"okay\""
	"the HYM8563 is on i2c1 at 0x51|rtc@51 \{ compatible = \"haoyu,hym8563\"; reg = <0x51>;"
	"vdd_logic reaches 712500, or the GPU never probes|vdd_logic:? ?[^{]*\{[^}]*regulator-min-microvolt = <712500>"
)

# Asymmetries that are deliberate. Listed so that the absence is recorded as a
# decision rather than looking like a gap - and so that removing one from the
# side that does have it still fails.
DTS_ONLY=(
	"rtc0 points at the HYM8563|rtc0 = &hym8563|an overlay cannot reorder aliases; the RK805 has taken rtc0 by the time this probes"
	"ethernet0 points at gmac2io, which is what gives U-Boot a MAC to fill in|ethernet0 = &gmac2io|same reason: the overlay path leaves the random-MAC problem unfixed"
)

OVERLAY_ONLY=(
	"sdio_pwrseq is switched off|sdio_pwrseq \{ status = \"disabled\"|the label exists only in the dusun DTS; nothing defines it here, so there is nothing to disable"
)

echo "Board DTS vs overlays"
echo

for fact in "${BOTH[@]}"; do
	what=${fact%%|*}; pat=${fact#*|}
	in_dts=0; in_ovl=0
	grep -qE "$pat" <<< "$dts_n" && in_dts=1
	grep -qE "$pat" <<< "$ovl_n" && in_ovl=1

	if [[ $in_dts -eq 1 && $in_ovl -eq 1 ]]; then
		OK "$what"
	elif [[ $in_dts -eq 1 ]]; then
		ERROR "$what - in the board DTS, missing from the overlays"
		NOTE "a new image would have it and an existing dusun install would not"
	elif [[ $in_ovl -eq 1 ]]; then
		ERROR "$what - in the overlays, missing from the board DTS"
		NOTE "the images this profile builds would not have it"
	else
		ERROR "$what - in neither"
		NOTE "if the fix was dropped on purpose, drop it from this list too"
	fi
done
echo

echo "Deliberate asymmetries"
echo
for fact in "${DTS_ONLY[@]}"; do
	IFS='|' read -r what pat why <<< "$fact"
	if grep -qE "$pat" <<< "$dts_n"; then
		OK "$what (board DTS only)"
		NOTE "$why"
	else
		ERROR "$what - gone from the board DTS"
	fi
done
for fact in "${OVERLAY_ONLY[@]}"; do
	IFS='|' read -r what pat why <<< "$fact"
	if grep -qE "$pat" <<< "$ovl_n"; then
		OK "$what (overlays only)"
		NOTE "$why"
	else
		ERROR "$what - gone from the overlays"
	fi
done
echo

if [[ $fail -ne 0 ]]; then
	red "A hardware fix exists in only one of the two places."
	exit 1
fi
grn "Every fix listed is in both the board DTS and the overlays."
exit 0
