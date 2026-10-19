# The kernel repository

`.github/workflows/kernel-repo.yml` builds this board's two kernel packages on
GitHub's runners and publishes them as a signed apt repository on GitHub Pages:

```
https://david-spacil.github.io/armbian-giada-dn73/
```

It exists because the board cannot take kernel updates from `apt.armbian.com`
(CLAUDE.md, *Updates are the thing that breaks this board*), so without it the
kernel only moves when somebody rebuilds an image by hand.

Nothing about it is automatic on the board. The box is the house's DNS server;
a kernel that does not boot takes the network with it, so every install is a
person running a command and watching it.

## What gets published

| | |
|---|---|
| Packages | `linux-image-current-rockchip64`, `linux-dtb-current-rockchip64` — the two the board holds, nothing else. `build-apt-repo.sh` refuses any other package. The build also produces `linux-headers` and `linux-libc-dev`; they are not published, so anything on the board that builds kernel modules (DKMS) would be left behind by an upgrade. |
| Size | ~52 MB `linux-image` and a few MB `linux-dtb` per build, xz-compressed. Pages caps a site at 1 GB; `build-apt-repo.sh` fails at 900 MB. |
| Suite / component | `giada` / `main`, `arm64` only |
| `Origin` / `Label` | `armbian-giada-dn73` |
| Version | `<Armbian VERSION base>-giada.<UTC YYYYMMDDHHMM>`, e.g. `26.11.0-giada.202610191900`. Unique per build and always increasing. Armbian stamps every build with the same `REVISION`, so without this two builds would collide. |
| Signed by | the key in the `github-pages` environment secret `APT_SIGNING_KEY`. Its public half is published next to the repository as `giada-dn73-archive-keyring.gpg` (and `.asc`). |
| History | every build is a GitHub release `kernel-<version>`, kept forever. Pages carries the newest `KEEP` (5) of them. |

A build is only published if `verify-kernel-debs.sh` passes on it, twice — once
in the job that built it and once in the job that signs it. That script is the
check that matters for this board: the `dtb` package must contain
`rockchip/rk3328-giada-dn73.dtb`, and that blob must report the model
`Giada DN73`. A `linux-dtb` without it installs cleanly and leaves U-Boot with
nothing to boot.

### When it builds

Weekly (Tuesday 04:37 UTC) and on demand from the Actions tab. Each run first
computes Armbian's kernel `artifact_version`, which hashes the kernel source,
every patch — our DTS included — and the kernel config, and skips the build if a
release already records that value. So a quiet week publishes nothing.

That hash also covers Armbian's own build scripts, so occasionally a new
version is published whose kernel is the same as the last one. The release
title carries the kernel version; an unchanged one needs no install.

### Who can publish

The build runs Armbian's code as root, and that code is not ours. So the job
that runs it has a read-only token and no secrets. Signing happens in a second
job that runs only this repository's scripts and receives only the built
packages. It is the only one bound to the `github-pages` environment, which
deploys from `main` alone.

That protects the key. It does not make the packages more trustworthy than a
local build: whatever `armbian/build` puts into the kernel is in it either way.
Each release records the `armbian/build` commit it was built from.

## One-time setup (owner)

1. **Signing key**, on a trusted machine. No passphrase: the secret store is the
   protection, and a passphrase would sit next to it.

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-gen-key "armbian-giada-dn73 apt repository" ed25519 sign never
   gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}'   # the fingerprint
   gpg --armor --export-secret-keys > apt-signing-key.asc
   ```

   Keep `apt-signing-key.asc` offline, or delete it and accept that losing the
   secret means a new key and re-trusting it on the board.

2. **Pages**: Settings → Pages → Source: *GitHub Actions*. This creates the
   `github-pages` environment, restricted to `main`.

3. **Secret**: Settings → Environments → `github-pages` → add secret
   `APT_SIGNING_KEY` with the contents of `apt-signing-key.asc`. Check that the
   environment's deployment branches still say `main` only.

4. Run the workflow from the Actions tab. The run summary prints the signing
   fingerprint; it must match step 1. Record it here:

   ```
   Signing key fingerprint: <fill in after step 1>
   ```

## Installing on the board

This section is the contract for whatever runs on the board. It is
deliberately a description rather than a script: the board's setup lives with
the rest of its configuration, not here.

### Once

- Fetch `giada-dn73-archive-keyring.gpg` from the repository URL into
  `/usr/share/keyrings/`, and **compare its fingerprint with the one recorded
  above** before trusting it. Pages serves the key and the repository from the
  same place, so the fingerprint is the only independent check.
- `/etc/apt/sources.list.d/giada-dn73.sources`:

  ```
  Types: deb
  URIs: https://david-spacil.github.io/armbian-giada-dn73/
  Suites: giada
  Components: main
  Signed-By: /usr/share/keyrings/giada-dn73-archive-keyring.gpg
  ```

- `/etc/apt/preferences.d/giada-dn73` — Armbian's copies of the two packages
  must never be candidates, held or not:

  ```
  Package: linux-image-current-rockchip64 linux-dtb-current-rockchip64
  Pin: release o=Armbian
  Pin-Priority: -1
  ```

- Keep `apt-mark hold` on both packages. The hold is the gate that makes every
  install deliberate. Do **not** add this origin to `unattended-upgrades`.

### Each upgrade

1. `apt update`, then list what is available:
   `apt-cache policy linux-image-current-rockchip64`. Use `policy`, not
   `madison`: `madison` ignores pins and keeps listing Armbian's copies as if
   they were candidates. In `policy` they show at priority `-1`.
2. Download the chosen version of both packages (`apt-get download pkg=<ver>`)
   and run `scripts/verify-kernel-debs.sh <dir> --version <ver>` on them — the
   same check CI ran, now on the bytes that will actually be installed.
3. If the kernel's major.minor differs from `uname -r` (a new LTS, not a patch
   release), stop and require explicit confirmation. That is a different kernel,
   not an update to this one, and nobody has booted it on this board.
4. **Back up the running kernel**: `/boot/Image`, `/boot/uInitrd`, the
   `/boot/dtb-<running version>/` directory, `/boot/config-*` and
   `/boot/System.map-*` of the running version, and `/lib/modules/$(uname -r)`.
   Both packages have the same name in every version, so dpkg removes the old
   kernel's files on upgrade and nothing older remains to boot from. Rollback
   from this backup needs no network, which matters when the box that is down
   is the DNS server.
5. `apt-mark unhold` both, `apt-get install` both at the exact version, `apt-mark
   hold` both — the hold goes back on even if the install fails.
6. Before rebooting: `/boot/dtb/rockchip/rk3328-giada-dn73.dtb` exists and
   reports `Giada DN73`, and `fdtfile` in `/boot/armbianEnv.txt` still names it.
7. Reboot by hand. After it: `/proc/device-tree/model` is `Giada DN73`,
   `uname -r` is the new version, `end0` is up with its usual address,
   `/dev/dri/renderD128` exists (the GPU check that `card0` cannot do, see
   CLAUDE.md), and Pi-hole answers DNS. Report; do not roll back automatically.

### Rolling back

- **Board boots, new kernel misbehaves**: install the previous version from
  the repository the same way (`pkg=<older version>`; apt asks to confirm the
  downgrade). Versions older than the newest five are on the releases page.
- **Board does not boot**: boot from the SD card (U-Boot prefers it, see
  CLAUDE.md, *Two boot stages*), mount the eMMC root and copy the backup from
  step 4 back. Worth rehearsing once before it is needed.
