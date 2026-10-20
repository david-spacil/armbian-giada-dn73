#!/usr/bin/env bash
#
# Turn a directory of kernel packages into a signed apt repository.
#
# The repository is what .github/workflows/kernel-repo.yml publishes to GitHub
# Pages, and what the board's upgrade script installs from. Layout:
#
#   pool/main/*.deb
#   dists/giada/main/binary-arm64/Packages{,.gz}
#   dists/giada/{Release,InRelease,Release.gpg}
#   giada-dn73-archive-keyring.gpg      the public key, binary, for signed-by=
#   giada-dn73-archive-keyring.asc      the same, armored, for reading
#
# apt-ftparchive rather than reprepro because reprepro keeps one version per
# package, and the point of this repository is that older kernels stay
# installable with apt install pkg=<version>.
#
# Only the two packages the board holds are accepted. Anything else in the
# input is an error, not something to publish silently.
#
# Signing uses whatever key --key names in the current GNUPGHOME. Without
# --key the repository is built unsigned, which apt refuses - only useful for
# testing the layout locally.
#
# Usage: scripts/build-apt-repo.sh <debs-dir> <out-dir> [--key <fingerprint>]

set -euo pipefail

DEBS=""
OUT=""
KEY=""
while [[ $# -gt 0 ]]; do
	case $1 in
		--key) KEY="$2"; shift 2 ;;
		-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
		*)
			if [[ -z $DEBS ]]; then DEBS="$1"
			elif [[ -z $OUT ]]; then OUT="$1"
			else echo "unknown argument: $1" >&2; exit 1
			fi
			shift ;;
	esac
done
[[ -d $DEBS && -n $OUT ]] || { echo "usage: $0 <debs-dir> <out-dir> [--key <fpr>]" >&2; exit 1; }

SUITE="giada"
COMPONENT="main"
ARCH="arm64"
ALLOWED=(linux-image-current-rockchip64 linux-dtb-current-rockchip64)

die() { echo "FAIL: $*" >&2; exit 1; }

command -v apt-ftparchive > /dev/null || die "apt-ftparchive is required (package apt-utils)"

mapfile -t debs < <(find "$DEBS" -name '*.deb' | sort)
[[ ${#debs[@]} -gt 0 ]] || die "no .deb files in ${DEBS}"

rm -rf "$OUT"
mkdir -p "${OUT}/pool/${COMPONENT}" "${OUT}/dists/${SUITE}/${COMPONENT}/binary-${ARCH}"

declare -A seen=()
for d in "${debs[@]}"; do
	pkg=$(dpkg-deb -f "$d" Package)
	ver=$(dpkg-deb -f "$d" Version)
	arch=$(dpkg-deb -f "$d" Architecture)

	allowed=0
	for a in "${ALLOWED[@]}"; do [[ $pkg == "$a" ]] && allowed=1; done
	[[ $allowed -eq 1 ]] || die "${d##*/}: package ${pkg} is not one this repository publishes"
	[[ $arch == "$ARCH" ]] || die "${d##*/}: architecture ${arch}, expected ${ARCH}"

	# Two different files claiming the same package and version would make
	# apt's choice depend on index order.
	[[ -z ${seen["${pkg}=${ver}"]:-} ]] || die "${pkg} ${ver} appears twice"
	seen["${pkg}=${ver}"]=1

	# Canonical pool name. Armbian's own file names carry the artifact hash
	# after a double underscore, which apt does not care about.
	cp "$d" "${OUT}/pool/${COMPONENT}/${pkg}_${ver}_${arch}.deb"
done

(
	cd "$OUT"
	apt-ftparchive packages "pool/${COMPONENT}" > "dists/${SUITE}/${COMPONENT}/binary-${ARCH}/Packages"
	gzip -9kn "dists/${SUITE}/${COMPONENT}/binary-${ARCH}/Packages"

	apt-ftparchive \
		-o "APT::FTPArchive::Release::Origin=armbian-giada-dn73" \
		-o "APT::FTPArchive::Release::Label=armbian-giada-dn73" \
		-o "APT::FTPArchive::Release::Suite=${SUITE}" \
		-o "APT::FTPArchive::Release::Codename=${SUITE}" \
		-o "APT::FTPArchive::Release::Architectures=${ARCH}" \
		-o "APT::FTPArchive::Release::Components=${COMPONENT}" \
		-o "APT::FTPArchive::Release::Description=Giada DN73 kernel and device tree" \
		release "dists/${SUITE}" > "dists/${SUITE}/Release.tmp"
	mv "dists/${SUITE}/Release.tmp" "dists/${SUITE}/Release"
)

if [[ -n $KEY ]]; then
	gpg --batch --yes --local-user "$KEY" --clearsign \
		-o "${OUT}/dists/${SUITE}/InRelease" "${OUT}/dists/${SUITE}/Release"
	gpg --batch --yes --local-user "$KEY" --armor --detach-sign \
		-o "${OUT}/dists/${SUITE}/Release.gpg" "${OUT}/dists/${SUITE}/Release"
	gpg --batch --export "$KEY" > "${OUT}/giada-dn73-archive-keyring.gpg"
	gpg --batch --armor --export "$KEY" > "${OUT}/giada-dn73-archive-keyring.asc"

	# Prove the signature verifies against exactly the key being published,
	# not merely against something in the signing keyring.
	gpgv --keyring "${OUT}/giada-dn73-archive-keyring.gpg" \
		"${OUT}/dists/${SUITE}/InRelease" 2> /dev/null \
		|| die "InRelease does not verify against the published key"
else
	echo "WARN: no --key, repository is unsigned" >&2
fi

# GitHub Pages refuses a site over 1 GB. One build is ~56 MB with xz, so this
# only trips if KEEP grows or compression silently stops (an uncompressed
# linux-image alone is 322 MB) - better here than as a failed deploy.
size_mb=$(du -sm "$OUT" | cut -f1)
[[ $size_mb -lt ${MAX_SITE_MB:-900} ]] || die "repository is ${size_mb} MB, over the ${MAX_SITE_MB:-900} MB budget for GitHub Pages"

# GitHub Pages runs Jekyll unless told not to, and Jekyll drops files it does
# not recognise.
touch "${OUT}/.nojekyll"

echo "built ${OUT}: ${#debs[@]} package(s)" >&2
