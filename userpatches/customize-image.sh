#!/bin/bash
#
# Runs inside the image chroot at the end of the build.
# Arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP $ARCH
#
# Shape follows config/templates/customize-image.sh.template. The positional
# assignments below are not decoration: without them $RELEASE is empty here, and
# the case statement in Main only appeared to work because its single arm is *).

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4
ARCH=$5

Main() {
	assert_correct_device_tree
	case $RELEASE in
		*)
			mask_networkd_wait_online
			;;
	esac
}

# The one failure in this port that is otherwise silent.
#
# The board DTS is picked up from userpatches/kernel/archive/<family>-<version>/dt/,
# and <version> has to equal KERNEL_MAJOR_MINOR for the branch being built. The
# copy that does it, lib/tools/common/dt_makefile_patcher.py, is:
#
#     if not os.path.isdir(full_path_source):
#         continue
#
# so a directory whose name no longer matches is skipped without an error, at
# debug log level only. The build then succeeds and ships the dusun-dsom-010r
# device tree instead - the board comes up with no ethernet, no WiFi, no serial
# port and no RTC, and nothing in the build log says why.
#
# Failing the build here converts that into something you cannot miss. It also
# catches the DTS failing to compile and the file being renamed.
assert_correct_device_tree() {
	local dtb

	# /boot/dtb is a symlink to /boot/dtb-<kernelversion> that the linux-dtb
	# package creates; glob both so this does not depend on the symlink being
	# in place yet. That package is installed by install_distribution_agnostic,
	# which runs before customize_image, so the file is there by now.
	dtb=$(ls -1 /boot/dtb*/rockchip/rk3328-giada-dn73.dtb 2>/dev/null | head -1)

	if [[ -z $dtb || ! -f $dtb ]]; then
		dtb=/boot/dtb/rockchip/rk3328-giada-dn73.dtb
		echo "ERROR: $dtb is missing from the built image." >&2
		echo "       The board DTS was not compiled in. Check that" >&2
		echo "       userpatches/kernel/archive/rockchip64-<version>/dt/ matches the" >&2
		echo "       KERNEL_MAJOR_MINOR of the branch being built - see CLAUDE.md," >&2
		echo "       'Keeping up with upstream'." >&2
		exit 1
	fi

	# Read the model out of the blob itself. Not /proc/device-tree - inside the
	# build chroot that belongs to the build host, which is usually x86 and has
	# none. The model string is what distinguishes our device tree from a copy
	# of the dusun one sitting under our filename.
	if ! grep -qa "Giada DN73" "$dtb"; then
		echo "ERROR: $dtb does not contain the model string 'Giada DN73'." >&2
		echo "       A device tree for a different board was built under our name." >&2
		exit 1
	fi

	echo "customize-image: $dtb present and reports model 'Giada DN73'."
}

# Armbian ships both systemd-networkd and NetworkManager enabled, while netplan
# renders everything through NetworkManager (the global renderer in
# armbian.yaml wins, being merged after 10-dhcp-all-interfaces.yaml). networkd
# therefore manages no link at all, and systemd-networkd-wait-online sits there
# until it times out - it alone added two minutes to every boot, and
# network-online.target waits for it, so anything ordered after that waits too.
# NetworkManager-wait-online covers network-online.target correctly.
mask_networkd_wait_online() {
	systemctl mask systemd-networkd-wait-online.service
}

Main "$@"
