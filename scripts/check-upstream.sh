#!/usr/bin/env bash
#
# Report where this board profile has drifted from armbian/build.
#
# The profile is an out-of-tree copy of upstream's dusun-dsom-010r board, so
# almost everything it depends on either lives in armbian/build or is inherited
# from that board's own config. Nothing here builds anything; it fetches a
# handful of files and compares them against what this repository assumes.
#
# Exit status: 0 clean, 1 something is broken, 2 something changed and wants a
# human. Run it before building an image, and on a schedule - see
# .github/workflows/upstream-drift.yml.
#
# Usage: scripts/check-upstream.sh [--ref <armbian-git-ref>]

set -uo pipefail

ARMBIAN_REF="main"
while [[ $# -gt 0 ]]; do
	case $1 in
		--ref) ARMBIAN_REF="$2"; shift 2 ;;
		-h|--help) sed -n '2,15p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW="https://raw.githubusercontent.com/armbian/build/${ARMBIAN_REF}"
API="https://api.github.com/repos/armbian/build/contents"

# Everything this profile inherits verbatim from upstream's dusun board.
INHERITED_FIELDS=(BOARDFAMILY KERNEL_TARGET KERNEL_TEST_TARGET BOOTCONFIG
                  BOOTBRANCH_BOARD BOOTPATCHDIR BOOT_SCENARIO)

OURS="${REPO_ROOT}/userpatches/config/boards/giada-dn73.csc"
DDR_BLOB_REPO="https://raw.githubusercontent.com/armbian/rkbin/master"

fail=0
warn=0

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }

ERROR() { red   "  FAIL  $*"; fail=1; }
WARN()  { ylw   "  WARN  $*"; warn=1; }
OK()    { grn   "  ok    $*"; }
NOTE()  { echo  "        $*"; }

fetch() { curl -fsSL --retry 2 --max-time 30 "$1" 2>/dev/null; }
exists() { curl -fsSL --retry 2 --max-time 30 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null; }

# Read a KEY="value" assignment out of a board config file (local or fetched).
csc_field() { sed -n "s/^${2}=\"\{0,1\}\([^\"]*\)\"\{0,1\}.*/\1/p" <<< "$1" | head -1; }

echo "Checking against armbian/build @ ${ARMBIAN_REF}"
echo

# ---------------------------------------------------------------------------
echo "[1] kernel versions vs our dt/ directories"
# The dt/ directory name must equal KERNEL_MAJOR_MINOR for the branch. A name
# that no longer matches is skipped silently by the patcher and the image gets
# the wrong device tree.

common=$(fetch "${RAW}/config/sources/families/include/rockchip64_common.inc")
if [[ -z $common ]]; then
	ERROR "could not fetch rockchip64_common.inc"
else
	our_targets=$(csc_field "$(cat "$OURS")" KERNEL_TARGET | tr ',' ' ')
	for branch in $our_targets; do
		ver=$(awk -v b="$branch" '
			$0 ~ "^[[:space:]]*"b"\\)" {found=1}
			found && /KERNEL_MAJOR_MINOR=/ {
				match($0, /"[0-9.]+"/); print substr($0, RSTART+1, RLENGTH-2); exit
			}' <<< "$common")
		if [[ -z $ver ]]; then
			ERROR "BRANCH=$branch is in KERNEL_TARGET but upstream no longer defines it"
			continue
		fi
		dir="${REPO_ROOT}/userpatches/kernel/archive/rockchip64-${ver}/dt"
		if [[ -d $dir ]]; then
			OK "BRANCH=$branch -> kernel $ver, and rockchip64-${ver}/dt/ exists"
		else
			ERROR "BRANCH=$branch is now kernel $ver, but rockchip64-${ver}/dt/ does not exist"
			NOTE "the build would SILENTLY use the dusun device tree"
			NOTE "fix: git mv the newest rockchip64-*/dt directory to rockchip64-${ver}"
		fi
	done

	# Stale directories are harmless but mean we are carrying dead weight.
	for dir in "${REPO_ROOT}"/userpatches/kernel/archive/rockchip64-*/; do
		[[ -d $dir ]] || continue
		d=$(basename "$dir"); dver=${d#rockchip64-}
		if ! grep -q "KERNEL_MAJOR_MINOR=\"${dver}\"" <<< "$common"; then
			WARN "$d/ matches no branch upstream any more - stale, consider removing"
		fi
	done
fi
echo

# ---------------------------------------------------------------------------
echo "[2] the dt/ mechanism is still declared"
# Our DTS only gets copied because upstream's patching config asks for it.

for dir in "${REPO_ROOT}"/userpatches/kernel/archive/rockchip64-*/; do
	[[ -d $dir ]] || continue
	d=$(basename "$dir")
	yaml=$(fetch "${RAW}/patch/kernel/archive/${d}/0000.patching_config.yaml")
	if [[ -z $yaml ]]; then
		ERROR "$d has no 0000.patching_config.yaml upstream"
	elif grep -q 'source: *"dt".*target: *"arch/arm64/boot/dts/rockchip"' <<< "$yaml"; then
		OK "$d still declares dts-directories dt -> arch/arm64/boot/dts/rockchip"
	else
		ERROR "$d no longer declares the dt -> rockchip dts-directory we rely on"
	fi
done
echo

# ---------------------------------------------------------------------------
echo "[3] fields inherited from upstream's dusun-dsom-010r board"
# Our .csc is a copy of theirs apart from the board name and the DTB. When they
# bump the U-Boot pin or change the boot scenario, we almost certainly should
# follow - that is the single most useful thing to watch.

theirs=$(fetch "${RAW}/config/boards/dusun-dsom-010r.csc")
if [[ -z $theirs ]]; then
	ERROR "could not fetch dusun-dsom-010r.csc - has the board been removed?"
	NOTE "if it is gone, our BOOTCONFIG and the DTS our overlays target go with it"
else
	ours_txt=$(cat "$OURS")
	for f in "${INHERITED_FIELDS[@]}"; do
		a=$(csc_field "$ours_txt" "$f")
		b=$(csc_field "$theirs" "$f")
		if [[ -z $b ]]; then
			WARN "$f is no longer set on the dusun board (ours: ${a:-unset})"
		elif [[ $a == "$b" ]]; then
			OK "$f = $a"
		else
			WARN "$f differs - ours '$a', upstream dusun '$b'"
			NOTE "decide whether to follow; U-Boot pins in particular should track theirs"
		fi
	done
fi
echo

# ---------------------------------------------------------------------------
echo "[4] the things our .csc points at still exist"

ours_txt=$(cat "$OURS")
bootpatchdir=$(csc_field "$ours_txt" BOOTPATCHDIR)
bootconfig=$(csc_field "$ours_txt" BOOTCONFIG)
ddr_blob=$(csc_field "$ours_txt" DDR_BLOB)

code=$(exists "${API}/patch/u-boot/${bootpatchdir}?ref=${ARMBIAN_REF}")
[[ $code == 200 ]] && OK "patch/u-boot/${bootpatchdir}/ exists" \
	|| ERROR "patch/u-boot/${bootpatchdir}/ is gone (HTTP $code) - the build will fail"

# The defconfig moved from a patch to a bare file between v2025.10 and v2026.04,
# so check both shapes before calling it missing.
if fetch "${RAW}/patch/u-boot/${bootpatchdir}/defconfig/${bootconfig}" > /dev/null; then
	OK "${bootconfig} found as a bare defconfig"
elif fetch "${API}/patch/u-boot/${bootpatchdir}?ref=${ARMBIAN_REF}" | grep -q "board_dusun"; then
	OK "${bootconfig} supplied by a board_dusun* patch directory"
else
	ERROR "${bootconfig} not found under patch/u-boot/${bootpatchdir}/"
fi

code=$(exists "${DDR_BLOB_REPO}/${ddr_blob}")
[[ $code == 200 ]] && OK "DDR blob ${ddr_blob} exists in armbian/rkbin" \
	|| ERROR "DDR blob ${ddr_blob} is gone from armbian/rkbin (HTTP $code)"
echo

# ---------------------------------------------------------------------------
echo "[5] the dusun device tree our overlays are written against"
# The overlays exist to patch a running dusun-based install, so they target
# labels in upstream's rk3328-dusun-dsom-010r.dts. That file is not mainline -
# Armbian ships it as a bare DTS in the same dt/ directory mechanism we use.

# Only the board-level labels live in the dusun DTS. uart1, i2c1 and pinctrl
# come from rk3328.dtsi in the kernel and are checked separately - looking for
# them in the board file is meaningless, since the overlay resolves against
# __symbols__ in the compiled blob, where both sources end up together.
board_labels=(vdd_logic usb_otg_drv usb_host_drv vcc_otg_5v vcc_host_5v)
soc_labels=(uart1 i2c1 pinctrl)

found_dusun=0
for dir in "${REPO_ROOT}"/userpatches/kernel/archive/rockchip64-*/; do
	[[ -d $dir ]] || continue
	d=$(basename "$dir")
	dts=$(fetch "${RAW}/patch/kernel/archive/${d}/dt/rk3328-dusun-dsom-010r.dts")
	[[ -z $dts ]] && continue
	found_dusun=1
	missing=()
	for l in "${board_labels[@]}"; do
		grep -q "${l}\b" <<< "$dts" || missing+=("$l")
	done
	if [[ ${#missing[@]} -eq 0 ]]; then
		OK "$d: dusun DTS still defines every board label the overlays target"
	else
		WARN "$d: dusun DTS no longer defines: ${missing[*]}"
		NOTE "overlay/*.dts would fail to apply on a dusun-based install"
	fi
done
[[ $found_dusun -eq 0 ]] && WARN "rk3328-dusun-dsom-010r.dts not found in any dt/ directory upstream"

# The SoC-level labels, and the two things in rk3328.dtsi the board DTS leans
# on: the opp-table-0 node it deletes, and the GPU OPP voltage that dictates
# the vdd_logic floor.
dtsi=$(fetch "https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/rockchip/rk3328.dtsi")
if [[ -z $dtsi ]]; then
	WARN "could not fetch rk3328.dtsi from mainline - SoC-level labels unchecked"
else
	missing=()
	for l in "${soc_labels[@]}"; do
		grep -q "${l}:" <<< "$dtsi" || missing+=("$l")
	done
	[[ ${#missing[@]} -eq 0 ]] && OK "rk3328.dtsi still defines: ${soc_labels[*]}" \
		|| WARN "rk3328.dtsi no longer defines: ${missing[*]}"

	if grep -q 'opp-table-0\|opp_table0' <<< "$dtsi"; then
		OK "rk3328.dtsi still has the opp-table-0 our DTS deletes"
	else
		ERROR "rk3328.dtsi no longer has opp-table-0 - our /delete-node/ is now a no-op"
		NOTE "the CPU OPP table in rk3328-giada-dn73.dts would be added alongside, not instead of"
	fi

	if grep -q '1075000' <<< "$dtsi"; then
		OK "the GPU OPP table still asks for 1075000 uV - the vdd_logic floor is still needed"
	else
		WARN "1075000 uV no longer appears in rk3328.dtsi"
		NOTE "re-check why vdd_logic needs a 712500 floor; see CLAUDE.md on the GPU"
	fi
fi
echo

# ---------------------------------------------------------------------------
echo "[6] has this board landed upstream?"
# If Armbian ever ships the Giada, this whole repository becomes redundant and
# the build will start warning about overwriting their file with ours.

code=$(exists "${API}/config/boards/giada-dn73.csc?ref=${ARMBIAN_REF}")
if [[ $code == 200 ]]; then
	WARN "armbian/build now ships config/boards/giada-dn73.csc"
	NOTE "this profile may be redundant - compare and consider retiring it"
else
	OK "not upstream yet, this profile is still needed"
fi
echo

# ---------------------------------------------------------------------------
echo "[7] local consistency"

mapfile -t dts_copies < <(find "${REPO_ROOT}/userpatches/kernel/archive" -name 'rk3328-giada-dn73.dts' | sort)
if [[ ${#dts_copies[@]} -lt 2 ]]; then
	WARN "only ${#dts_copies[@]} copy of the board DTS - KERNEL_TARGET lists more than one branch"
else
	same=1
	for c in "${dts_copies[@]:1}"; do
		cmp -s "${dts_copies[0]}" "$c" || { ERROR "DTS copies differ: ${dts_copies[0]} vs $c"; same=0; }
	done
	[[ $same -eq 1 ]] && OK "all ${#dts_copies[@]} copies of the board DTS are identical"
fi

# This repository is public and was scrubbed before publication: no private
# addresses, no per-unit MACs, no SoC serials. Only the ranges CLAUDE.md
# actually forbids are matched, so version strings do not trip it. The
# placeholder MAC the ethernet overlay documents its derivation with is
# deliberately allowed.
hygiene=$(grep -rnEi \
	'\b(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01])|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7]))\.[0-9]{1,3}\.[0-9]{1,3}\b|\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b' \
	--include='*.md' --include='*.dts' --include='*.csc' --include='*.sh' --include='*.py' \
	--exclude='check-upstream.sh' "$REPO_ROOT" 2>/dev/null \
	| grep -viE '\b(02:)?aa:bb:cc:dd:ee\b|xx:xx:xx' || true)

if [[ -n $hygiene ]]; then
	ERROR "possible private address or per-unit MAC in a tracked file:"
	sed 's/^/          /' <<< "$hygiene"
else
	OK "no private addresses or per-unit MACs in tracked files"
fi
echo

# ---------------------------------------------------------------------------
if [[ $fail -ne 0 ]]; then
	red "Something is broken - a build would produce a wrong or failing image."
	exit 1
elif [[ $warn -ne 0 ]]; then
	ylw "Upstream moved. Nothing is broken, but the differences want a decision."
	exit 2
else
	grn "In sync with upstream."
	exit 0
fi
