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
