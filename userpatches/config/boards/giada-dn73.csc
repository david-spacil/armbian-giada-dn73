# Rockchip RK3328 quad core 2GB RAM SoC GBE eMMC USB3 WiFi/BT
BOARD_NAME="Giada DN73"
BOARD_VENDOR="giada"
BOARDFAMILY="rockchip64"
BOARD_MAINTAINER=""
KERNEL_TARGET="current,edge"
KERNEL_TEST_TARGET="current"
BOOT_FDT_FILE="rockchip/rk3328-giada-dn73.dtb"
DEFAULT_CONSOLE="both"

# U-Boot is borrowed from the Dusun DSOM 010R: same SoC, same RK805 power
# design and the same DDR blob, and it boots this board fine. The kernel loads
# its own DTB from /boot/dtb, so the board name in the bootloader has no
# functional effect. Replacing this with a dedicated defconfig is only needed
# if the profile is ever submitted upstream.
BOOTCONFIG="dusun-dsom-010r-rk3328_defconfig"
BOOTBRANCH_BOARD="tag:v2026.04"
BOOTPATCHDIR="v2026.04"
BOOT_SCENARIO="binman-atf-mainline"
DDR_BLOB="rk33/rk3328_ddr_933MHz_v1.16.bin"

# The board DTS is kept once, in userpatches/dt/, and copied into the kernel
# patch directory of whatever kernel the branch resolves to.
#
# Armbian only picks up a DTS from userpatches/kernel/<KERNELPATCHDIR>/dt/, and
# KERNELPATCHDIR is archive/rockchip64-<KERNEL_MAJOR_MINOR>. A directory name
# checked in here goes stale every time upstream moves a branch to a new kernel
# (edge does that every couple of months), and lib/tools/common/
# dt_makefile_patcher.py skips a non-matching directory silently: the image
# builds and ships the dusun device tree. Deriving the name at build time takes
# the version out of this repository altogether.
#
# late_family_config, because that is where common.conf defaults KERNELPATCHDIR
# (late_family_config__common_defaults_for_mainline_kernel). Unnumbered hooks
# sort as 500_, so 900_ runs after it. It runs before any artifact is hashed, and
# artifact-kernel.sh hashes userpatches/kernel/<KERNELPATCHDIR> by content, so a
# changed DTS still forces a kernel rebuild instead of a cache hit.
#
# userpatches/ is bind-mounted read-write into Armbian's Docker container, so
# the copy lands in the build tree's userpatches/, never in this repository.
function late_family_config__900_giada_dn73_stage_device_tree() {
	declare src="${USERPATCHES_PATH}/dt/rk3328-giada-dn73.dts" dir

	[[ -f ${src} ]] || exit_with_error "Giada DN73: ${src} is missing" "copy all of this profile's userpatches/"
	[[ -n ${KERNELPATCHDIR} ]] || exit_with_error "Giada DN73: KERNELPATCHDIR is empty" "the board DTS has nowhere to go"

	for dir in ${KERNELPATCHDIR}; do
		mkdir -p "${USERPATCHES_PATH}/kernel/${dir}/dt"
		cp "${src}" "${USERPATCHES_PATH}/kernel/${dir}/dt/"
		display_alert "Giada DN73: staged board DTS" "userpatches/kernel/${dir}/dt/" "info"
	done
}
