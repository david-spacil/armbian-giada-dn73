#!/usr/bin/env bash
#
# Check that a set of kernel packages is safe to put on this board.
#
# A linux-dtb package without our device tree installs cleanly and then leaves
# U-Boot with no fdtfile to load: the board does not come back. That is what an
# apt.armbian.com upgrade would do (see CLAUDE.md, "Updates are the thing that
# breaks this board"), and it is also what a build would produce if the .csc
# staging hook ever stopped running. So nothing gets published, or installed,
# without passing this first.
#
# Checks, on exactly one linux-image-<branch>-rockchip64 and one
# linux-dtb-<branch>-rockchip64 in <dir>:
#   - both carry the same Version, and it equals --version when given
#   - the dtb package contains rockchip/rk3328-giada-dn73.dtb
#   - that blob contains the model string "Giada DN73"
#   - the image package contains a kernel, whose version it prints
#
# Prints KEY=value lines on stdout (kernel_version, deb_version, image, dtb) so
# CI can append them to $GITHUB_OUTPUT. Diagnostics go to stderr.
#
# Exit status: 0 safe, 1 not.
#
# Usage: scripts/verify-kernel-debs.sh <dir> [--branch current] [--version <deb version>]

set -euo pipefail

DIR=""
BRANCH="current"
WANT_VERSION=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--branch) BRANCH="$2"; shift 2 ;;
		--version) WANT_VERSION="$2"; shift 2 ;;
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		*) [[ -z $DIR ]] && { DIR="$1"; shift; } || { echo "unknown argument: $1" >&2; exit 1; } ;;
	esac
done
[[ -d $DIR ]] || { echo "usage: $0 <dir> [--branch current] [--version <v>]" >&2; exit 1; }

DTB_PATH="rockchip/rk3328-giada-dn73.dtb"
MODEL="Giada DN73"

die() { echo "FAIL: $*" >&2; exit 1; }

# Exactly one of each. Two linux-image packages would leave it to chance which
# one gets published, or installed.
one() {
	local pkg=$1 found
	mapfile -t found < <(find "$DIR" -maxdepth 1 -name "${pkg}_*_arm64*.deb" | sort)
	[[ ${#found[@]} -eq 1 ]] || die "expected one ${pkg} package in ${DIR}, found ${#found[@]}"
	echo "${found[0]}"
}
image=$(one "linux-image-${BRANCH}-rockchip64")
dtb=$(one "linux-dtb-${BRANCH}-rockchip64")

v_image=$(dpkg-deb -f "$image" Version)
v_dtb=$(dpkg-deb -f "$dtb" Version)
[[ $v_image == "$v_dtb" ]] || die "version mismatch: image ${v_image}, dtb ${v_dtb}"
[[ -z $WANT_VERSION || $v_image == "$WANT_VERSION" ]] \
	|| die "built version ${v_image}, expected ${WANT_VERSION}"

# The dtb package installs under /boot/dtb-<kernel version>/.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
dpkg-deb -x "$dtb" "$tmp/dtb"
blob=$(find "$tmp/dtb/boot" -path "*/${DTB_PATH}" | head -1)
[[ -n $blob ]] || die "${dtb##*/} does not contain ${DTB_PATH}"
grep -qa "$MODEL" "$blob" || die "${DTB_PATH} does not report model '${MODEL}'"

# The kernel version is the suffix of /boot/vmlinuz-<version>.
kver=$(dpkg-deb -c "$image" | sed -n 's|.*\./boot/vmlinuz-\(.*\)$|\1|p' | head -1)
[[ -n $kver ]] || die "${image##*/} contains no /boot/vmlinuz-*"

echo "OK: ${DTB_PATH} present, model '${MODEL}', kernel ${kver}, package version ${v_image}" >&2
echo "kernel_version=${kver}"
echo "deb_version=${v_image}"
echo "image=${image}"
echo "dtb=${dtb}"
