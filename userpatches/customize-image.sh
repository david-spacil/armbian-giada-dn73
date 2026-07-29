#!/bin/bash
#
# Runs inside the image chroot at the end of the build.
# Arguments: $1 RELEASE, $2 LINUXFAMILY, $3 BOARD, $4 BUILD_DESKTOP, $5 ARCH

Main() {
	case $RELEASE in
		*)
			mask_networkd_wait_online
			;;
	esac
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
