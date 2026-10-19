# Sourced by check-upstream.sh and compile-dts.sh, not run on its own.
#
# Which kernel each branch in our KERNEL_TARGET builds, read from upstream's
# config/sources/families/include/rockchip64_common.inc. That is the version
# the .csc hook stages the board DTS for (KERNELPATCHDIR is
# archive/rockchip64-<KERNEL_MAJOR_MINOR>), so it is also the version both
# scripts have to check against. Nothing in this repository names a version.

# kernel_version_for_branch <rockchip64_common.inc contents> <branch>
# Prints KERNEL_MAJOR_MINOR for the branch, or nothing if upstream has no such
# branch.
kernel_version_for_branch() {
	awk -v b="$2" '
		$0 ~ "^[[:space:]]*"b"\\)" {found=1}
		found && /KERNEL_MAJOR_MINOR=/ {
			match($0, /"[0-9.]+"/); print substr($0, RSTART+1, RLENGTH-2); exit
		}' <<< "$1"
}

# our_branches <path to giada-dn73.csc>
# Prints the branches in KERNEL_TARGET, one per line.
our_branches() {
	sed -n 's/^KERNEL_TARGET="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$1" | head -1 | tr ',' '\n'
}
