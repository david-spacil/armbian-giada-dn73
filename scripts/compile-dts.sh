#!/usr/bin/env bash
#
# Compile the board DTS without building an image.
#
# The board DTS cannot be compiled standalone - it #includes rk3328.dtsi,
# rk3328-dram-default-timing.dtsi and dt-bindings headers, so it only builds
# inside a kernel tree. Until this script existed, the only thing that ever
# compiled it was a full Armbian build: a typo cost ~42 minutes to discover, and
# the edge kernel had never been compiled against at all.
#
# What it does, for the kernel of every branch in our KERNEL_TARGET (read from
# upstream's rockchip64_common.inc, the same versions the .csc hook stages
# userpatches/dt/ into at build time):
#
#   1. shallow sparse-clone torvalds/linux at tag v<ver> - just the arm64 device
#      trees and the bindings headers, ~60 MiB
#   2. apply the device-tree half of armbian/build's rockchip64-<ver> patches.
#      Mainline is not enough: rk3328-dram-default-timing.dtsi does not exist
#      upstream at all (Armbian's rk3328-add-dmc-driver.patch creates it), and
#      the DTS references spdif_out and spdif_sound, which come from another
#      patch in the same directory
#   3. cpp + dtc, then assert the blob carries the model string
#
# This is the same tree the build compiles, minus the patches that touch only
# drivers, so it catches syntax errors, dangling &label references and a DTS
# that quietly stops describing this board. It is *not* proof that the image
# will be correct - only booting the hardware is that, see TESTING.md.
#
# Exit status: 0 it compiles for every branch, 1 it did not for one, 2 a branch
# could not be checked (no matching kernel tag yet) and wants a human.
#
# Usage: scripts/compile-dts.sh [--ref <armbian-git-ref>] [--work <dir>]
#
#   --work  reuse (and keep) the kernel trees in <dir> instead of a temporary
#           directory. Second and later runs then take seconds - but they test
#           whatever upstream looked like when the directory was filled, so use
#           it while iterating on the DTS and never in CI.

set -uo pipefail

ARMBIAN_REF="main"
WORK=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--ref)  ARMBIAN_REF="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 1 ;;
	esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DTS_NAME="rk3328-giada-dn73.dts"
MODEL="Giada DN73"
SRC_DTS="${REPO_ROOT}/userpatches/dt/${DTS_NAME}"

# shellcheck source=scripts/kernel-versions.sh
source "${REPO_ROOT}/scripts/kernel-versions.sh"

fail=0
warn=0

red() { printf '\033[31m%s\033[0m\n' "$*"; }
ylw() { printf '\033[33m%s\033[0m\n' "$*"; }
grn() { printf '\033[32m%s\033[0m\n' "$*"; }

ERROR() { red "  FAIL  $*"; fail=1; }
WARN()  { ylw "  WARN  $*"; warn=1; }
OK()    { grn "  ok    $*"; }
NOTE()  { echo "        $*"; }

for t in git curl cpp dtc; do
	command -v "$t" > /dev/null && continue
	red "$t is required but not installed."
	[[ $t == dtc ]] && NOTE "it is in the 'dtc' / 'device-tree-compiler' package"
	exit 1
done

if [[ -n $WORK ]]; then
	mkdir -p "$WORK" || exit 1
	WORK="$(cd "$WORK" && pwd)"
else
	WORK="$(mktemp -d)"
	trap 'rm -rf "$WORK"' EXIT
fi

# Armbian's patches, once for all versions. A sparse clone is ~9 MiB and two
# seconds, against 180-odd separate downloads through the GitHub API - which is
# also rate limited to 60 requests an hour for anonymous callers.
ABUILD="${WORK}/armbian-build"
if [[ ! -d ${ABUILD}/.git ]]; then
	echo "Fetching armbian/build @ ${ARMBIAN_REF} (patches only)"
	git clone --quiet --depth 1 --filter=blob:none --sparse \
		--branch "$ARMBIAN_REF" https://github.com/armbian/build.git "$ABUILD" || {
		red "could not clone armbian/build"; exit 1; }
fi
# Outside the clone, so a --work tree from before this file was needed gets it.
git -C "$ABUILD" sparse-checkout set --no-cone /patch/kernel/archive/ \
	/config/sources/families/include/rockchip64_common.inc > /dev/null || exit 1

# Everything the kernel needs to preprocess a board DTS, and nothing else.
SPARSE_PATHS=(arch/arm64/boot/dts include/dt-bindings include/uapi/linux)

prepare_tree() {
	local ver=$1 tree="${WORK}/linux-${ver}"

	[[ -f ${tree}/.prepared ]] && { echo "$tree"; return 0; }

	# Armbian names its kernel directories after the upstream version, so the
	# tag follows directly. A missing tag means the branch is on an -rc that
	# has not been released yet.
	if ! git ls-remote --tags --exit-code \
		https://github.com/torvalds/linux.git "refs/tags/v${ver}" > /dev/null 2>&1; then
		return 2
	fi

	rm -rf "$tree"
	git clone --quiet --depth 1 --filter=blob:none --sparse \
		--branch "v${ver}" https://github.com/torvalds/linux.git "$tree" > /dev/null 2>&1 || return 1
	git -C "$tree" sparse-checkout set "${SPARSE_PATHS[@]}" > /dev/null 2>&1 || return 1

	# Apply only the device-tree half of each patch. --include leaves the
	# hunks that touch drivers/, Makefiles and the like alone, so the sparse
	# checkout stays valid; patches for other SoCs that then fail to apply
	# (helios64, rk3399) do not matter here and are counted, not fatal.
	local pdir="${ABUILD}/patch/kernel/archive/rockchip64-${ver}"
	[[ -d $pdir ]] || return 3

	local applied=0 skipped=()
	local p
	for p in $(find "$pdir" -maxdepth 1 -name '*.patch' | sort); do
		if git -C "$tree" apply \
			--include='arch/arm64/boot/dts/*' \
			--include='include/dt-bindings/*' "$p" 2> /dev/null; then
			applied=$((applied + 1))
		else
			# Only a patch touching rk3328 could make our compile lie.
			grep -qE '^\+\+\+ b/arch/arm64/boot/dts/rockchip/rk3328' "$p" \
				&& skipped+=("$(basename "$p")")
		fi
	done

	printf '%s\n' "$applied" > "${tree}/.applied"
	printf '%s\n' "${skipped[@]+"${skipped[@]}"}" > "${tree}/.skipped"
	touch "${tree}/.prepared"
	echo "$tree"
}

echo "Compiling the board DTS against mainline + armbian/build @ ${ARMBIAN_REF}"
echo

if [[ ! -f $SRC_DTS ]]; then
	ERROR "userpatches/dt/${DTS_NAME} does not exist"
	exit 1
fi

common="${ABUILD}/config/sources/families/include/rockchip64_common.inc"
[[ -f $common ]] || { red "armbian/build has no rockchip64_common.inc"; exit 1; }

versions=()
while read -r branch; do
	[[ -z $branch ]] && continue
	ver=$(kernel_version_for_branch "$(cat "$common")" "$branch")
	if [[ -z $ver ]]; then
		ERROR "BRANCH=${branch} is in KERNEL_TARGET but upstream no longer defines it"
		continue
	fi
	[[ " ${versions[*]} " == *" ${ver} "* ]] || versions+=("$ver")
done < <(our_branches "${REPO_ROOT}/userpatches/config/boards/giada-dn73.csc")

for ver in "${versions[@]}"; do
	d="rockchip64-${ver}"
	src="$SRC_DTS"

	echo "[${ver}]"
	tree=$(prepare_tree "$ver"); rc=$?
	case $rc in
		2) WARN "linux has no v${ver} tag yet - cannot compile this copy"
		   NOTE "expected while a branch tracks an -rc kernel; re-run after the release"
		   echo; continue ;;
		3) ERROR "armbian/build has no patch/kernel/archive/rockchip64-${ver}"
		   NOTE "upstream points a branch at a kernel it ships no patches for"
		   echo; continue ;;
		0) ;;
		*) ERROR "could not prepare a linux-${ver} tree"; echo; continue ;;
	esac

	mapfile -t skipped < <(grep -v '^$' "${tree}/.skipped")
	if [[ ${#skipped[@]} -gt 0 ]]; then
		WARN "${#skipped[@]} rk3328 patch(es) did not apply: ${skipped[*]}"
		NOTE "the tree is less patched than the build's, so a failure below may not be ours"
	fi

	rk="${tree}/arch/arm64/boot/dts/rockchip"
	cp "$src" "${rk}/${DTS_NAME}"
	pp="${WORK}/${d}.pp.dts"
	dtb="${WORK}/${d}.dtb"

	# The same invocation the kernel's own dtc rule uses: cpp with the kernel
	# include paths, then dtc on the result.
	if ! cpp -nostdinc -I "${tree}/include" -I "$rk" -undef -D__DTS__ \
		-x assembler-with-cpp -o "$pp" "${rk}/${DTS_NAME}"; then
		ERROR "preprocessing failed - a missing or misspelled #include"
		echo; continue
	fi

	if ! dtc -I dts -O dtb -o "$dtb" "$pp"; then
		ERROR "dtc rejected the device tree"
		NOTE "'Label or path X not found' means the DTS references a node that"
		NOTE "neither rk3328.dtsi nor Armbian's patches define at this version"
		echo; continue
	fi

	if ! grep -qa "$MODEL" "$dtb"; then
		ERROR "the blob does not contain the model string '${MODEL}'"
		NOTE "this is the check customize-image.sh makes at build time"
		echo; continue
	fi

	OK "compiles, and reports model '${MODEL}' ($(stat -c%s "$dtb") bytes)"
	echo
done

if [[ $fail -ne 0 ]]; then
	red "The board DTS does not compile. A build would fail, or ship the wrong tree."
	exit 1
elif [[ $warn -ne 0 ]]; then
	ylw "Compiled what could be compiled; something above wants a human."
	exit 2
else
	grn "The board DTS compiles for every branch."
	exit 0
fi
