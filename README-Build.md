# Building the image — self-hosted runner setup and first build

A step-by-step checklist for producing an `amd64-openfyde_iris-t2` image.
Everything here comes from openFyde's own getting-started guide plus this
board's specifics; see "What is verified" at the end for what has and has not
actually been run.

A full build is **150GB+ disk / 16GB+ RAM / 5-10+ hours**. That is why it
cannot run on GitHub-hosted runners and needs a machine of your own.

---

## Part 0 — Why not hosted runners

openFyde's documentation gives the floor: at least 150GB free disk (200GB+
recommended), 16GB+ RAM (Chromium alone needs 8-28GB to link), and 5-10+ hours
on a 4-core/16GB machine. `cros_sdk` additionally needs a privileged chroot
with bind mounts. A hosted `ubuntu-latest` runner has ~14GB free disk, 16GB
RAM and a 6-hour job limit, and cannot mount the chroot. There is no
configuration that makes this work on hosted runners.

So `.github/workflows/build-image.yml` targets `[self-hosted, linux, x64]` and
triggers on `workflow_dispatch` only. Until you register a runner it simply
never runs.

---

## Part 1 — Prepare the machine

- [ ] **x86_64 Linux host.** Ubuntu is what openFyde tests against.
- [ ] **Disk: 200GB+ free, SSD strongly preferred.** Check with `df -h`.
- [ ] **RAM: 16GB minimum, 32GB+ recommended.** Add swap if it is tight;
      linking Chromium can want up to 28GB.
- [ ] **4+ CPU cores.** The build parallelises well.
- [ ] **A non-root user with passwordless sudo.** The build must not run as
      root. Confirm `sudo -n true` succeeds.
- [ ] **umask 022.** Add `umask 022` to `~/.bash_profile`; a looser umask
      breaks the SDK.

```bash
sudo apt-get update
sudo apt-get install -y git-core gitk git-gui curl lvm2 thin-provisioning-tools \
     python3 python3-pip python3-venv xz-utils
```

- [ ] **Install depot_tools and put it on PATH.**

```bash
sudo mkdir -p /usr/local/repo
sudo chmod 777 /usr/local/repo
cd /usr/local/repo
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git

# then, in ~/.bash_profile:
export PATH=/usr/local/repo/depot_tools:$PATH
umask 022
```

- [ ] Re-login (or `source ~/.bash_profile`) and confirm `cros_sdk` resolves:

```bash
which cros_sdk
```

- [ ] **Configure git** — the SDK will complain otherwise.

```bash
git config --global user.email "you@example.com"
git config --global user.name  "Your Name"
```

---

## Part 2 — Fetch the SDK

This board tracks openFyde **R114**, whose ChromiumOS release is
`release-R114-15437.B` and whose openFyde manifest branch is `r114-dev`.

- [ ] **Create the SDK directory and init the ChromiumOS manifest.** Expect
      ~10GB of downloads from googlesource.com; this step alone can take 30+
      minutes.

```bash
mkdir -p ~/r114 && cd ~/r114

repo init -u https://chromium.googlesource.com/chromiumos/manifest.git \
          --repo-url https://chromium.googlesource.com/external/repo.git \
          -b release-R114-15437.B
```

- [ ] **Add the openFyde manifest** as a local manifest.

```bash
cd ~/r114
mkdir -p openfyde
git clone https://github.com/openFyde/manifest.git openfyde/manifest -b r114-dev
ln -snfr openfyde/manifest .repo/local_manifests
```

- [ ] **Sync, then fetch Chromium.**

```bash
cd ~/r114
repo sync -j8                 # raise -j on a fast connection

cd openfyde/chromium
gclient sync
```

- [ ] **Create the chroot.** This takes ~30 minutes the first time and only
      needs doing once.

```bash
cd ~/r114
cros_sdk
# ...then exit the chroot shell
exit
```

Sanity check: `~/r114/src/overlays/chromiumos-overlay/sys-kernel/chromeos-kernel-6_1/`
should exist and contain `chromeos-kernel-6_1-6.1.25-r227.ebuild`.

---

## Part 3 — Register the self-hosted runner

- [ ] In the GitHub repo: **Settings → Actions → Runners → New self-hosted
      runner**, pick Linux, and follow the generated `config.sh` commands.
      Run the runner as the **same non-root user** that owns the SDK, and
      install it as a service so it survives reboots (`./svc.sh install`,
      `./svc.sh start`).

- [ ] **Labels.** A new runner gets `self-hosted`, `Linux`, `X64` by default,
      which is exactly what `build-image.yml` asks for (`self-hosted, linux,
      x64` — GitHub matches labels case-insensitively). If you prefer to keep
      this runner from picking up unrelated jobs, add a custom label such as
      `cros-sdk` and change the `runs-on` line in `build-image.yml` to match.

- [ ] **Set the SDK path as a repository variable.** The workflow reads
      `vars.SDK_ROOT`, defaulting to `/mnt/cros-sdk`:

      Settings → Secrets and variables → Actions → Variables → New variable
      - Name:  `SDK_ROOT`
      - Value: `/home/<user>/r114`   (absolute path to the SDK checkout)

---

## Part 4 — Install the board overlay

The overlay **must** be at `src/overlays/overlay-<board>`, and the directory
name must match the path baked into `make.conf`'s `CHROMEOS_KERNEL_CONFIG`.
`build-image.yml` does this step for you; do it by hand if you are building
manually.

- [ ] Clone this repo and copy it into place:

```bash
cd ~/r114
git clone https://github.com/macrwfuse/amd64-openfyde_iris-t2 /tmp/iris-t2
rm -rf src/overlays/overlay-amd64-openfyde_iris-t2
mkdir -p src/overlays/overlay-amd64-openfyde_iris-t2
cp -a /tmp/iris-t2/. src/overlays/overlay-amd64-openfyde_iris-t2/
rm -rf src/overlays/overlay-amd64-openfyde_iris-t2/.git
```

- [ ] **Check the overlay is where `make.conf` expects.** This mismatch is
      silent and produces an image with no T2 support:

```bash
grep CHROMEOS_KERNEL_CONFIG \
  src/overlays/overlay-amd64-openfyde_iris-t2/make.conf
# must read:
# CHROMEOS_KERNEL_CONFIG="/mnt/host/source/src/overlays/overlay-amd64-openfyde_iris-t2/kconfig/kernel-6_1-def-t2"
ls src/overlays/overlay-amd64-openfyde_iris-t2/kconfig/kernel-6_1-def-t2
```

---

## Part 5 — Smoke-test before the long build

Do not start a 6-hour build without these. Each takes minutes and catches the
failure modes that only show up as a silent lack of T2 support.

- [ ] **Let CI verify the patch stack.** Push a commit, open a PR, or run the
      `Verify T2 patch stack` workflow manually. It applies all 28 patches to
      a pristine 6.1.25 tree at fuzz 2, checks the five config symbols and
      five driver sources, and fails if upstream has moved past 6.1.25.

- [ ] **Confirm the SDK has not moved past 6.1.25.**

```bash
cd ~/r114/src/overlays/chromiumos-overlay/sys-kernel/chromeos-kernel-6_1
ls chromeos-kernel-6_1-*.ebuild | grep -v -- '-9999' | sort -V | tail -1
# must be chromeos-kernel-6_1-6.1.25-r227.ebuild
```

      If the SDK ships 6.1.26 or later, portage will prefer it over this
      board's r228 override, `FILESDIR` will point at upstream's empty
      `files/`, and **the T2 patches will silently not apply**. Re-copy the
      upstream ebuild into the board overlay, bump its revision by one, and
      re-verify the patch stack before continuing.

- [ ] **Initialise the board.**

```bash
cros_sdk
# inside the chroot:
setup_board --board=amd64-openfyde_iris-t2
```

---

## Part 6 — First build

- [ ] **Build just the kernel first.** This is the cheapest way to find out
      whether the T2 patches actually compile, and it is worth doing before
      committing to a full image build.

```bash
# inside the chroot
equery-amd64-openfyde_iris-t2 which sys-kernel/chromeos-kernel-6_1
# MUST print .../overlay-amd64-openfyde_iris-t2/sys-kernel/chromeos-kernel-6_1/
#          chromeos-kernel-6_1-6.1.25-r228.ebuild
# If it prints chromiumos-overlay/... then the override is not winning and
# the T2 patches are not being applied. Stop and fix that first.

emerge-amd64-openfyde_iris-t2 sys-kernel/chromeos-kernel-6_1
```

- [ ] **Confirm the T2 drivers were produced.**

```bash
find /build/amd64-openfyde_iris-t2 -name '*.ko' \
  \( -name 'apple_bce.ko' -o -name 'apple-ibridge.ko' \
     -o -name 'apple-touchbar.ko' -o -name 'apple-magic-backlight.ko' \
     -o -name 'hci_bcm4377.ko' \)
```

      All five should be listed. Missing ones mean the corresponding patch
      did not make it into the build.

- [ ] **Build the packages.**

```bash
# inside the chroot
sudo emerge capnproto
cd ~/trunk/src/scripts
./build_packages --board=amd64-openfyde_iris-t2 \
                 --nowithautotest --autosetgov --nouse_any_chrome
```

      The build is incremental — if it is interrupted, re-run the same command
      and it resumes. Per-package logs land in
      `/build/amd64-openfyde_iris-t2/tmp/portage/logs/`.

- [ ] **Build the image.**

```bash
./build_image --board=amd64-openfyde_iris-t2 --noenable_rootfs_verification
```

- [ ] **Collect it.**

```bash
ls -lh /mnt/host/source/src/build/images/amd64-openfyde_iris-t2/latest/chromiumos_image.bin
sha256sum /mnt/host/source/src/build/images/amd64-openfyde_iris-t2/latest/chromiumos_image.bin
```

      The same path from the host is
      `~/r114/src/build/images/amd64-openfyde_iris-t2/latest/chromiumos_image.bin`.

Or just trigger the `Build openFyde image (self-hosted)` workflow, which runs
exactly these steps, asserts the r228 override was selected, checks the five
`.ko` files, and uploads the image as an artifact.

---

## Part 7 — Before booting on a T2 Mac

- [ ] **Wi-Fi and Bluetooth firmware is not in the image and cannot be.** These
      Macs need firmware extracted from their own macOS install via t2linux's
      `apple-t2-firmware` tooling. Without it the Broadcom Wi-Fi/BT will not
      come up even though the drivers are built. See
      `obsolete-upstream/README` and the main `README.t2.md` for the other
      known gaps (no APFS at 6.1, Touch Bar needs userspace `appletbdrm`,
      Secure Boot / Touch ID out of scope).

- [ ] **Flash and boot.** Write to USB with `dd`, then follow the usual
      openFyde recovery flow.

---

## Troubleshooting

**The build produced no T2 drivers.** Almost always the override ebuild lost
selection. Run `equery-amd64-openfyde_iris-t2 which sys-kernel/chromeos-kernel-6_1`
— if it does not report `6.1.25-r228` from the board overlay, the patches were
never read. Check that the overlay directory name matches the
`CHROMEOS_KERNEL_CONFIG` path in `make.conf`.

**`eapply` aborted with "Hunk ... FAILED".** A patch no longer applies at
fuzz 2. Run `./scripts/apply_t2_kernel_patches.sh /path/to/linux-6.1.25` to
reproduce outside the SDK, then either rebase the offending patch or, if its
changes are already upstream, move it to `obsolete-upstream/` with its
provenance — as was done for 4002/4003 — or trim the redundant hunks in place,
as was done for 8002.

**`eapply` aborted with "previously applied".** A patch became redundant
because upstream caught up. Same treatment: `obsolete-upstream/`.

**Out of memory while linking Chromium.** Add swap or use more RAM. Nothing
else will help.

---

## What is verified

Verified by running it:

- The 28 patches apply to a pristine Linux 6.1.25 tree at fuzz 2 with zero
  hard failures and zero redundant patches (23 clean, 5 fuzz≤2).
- All five T2 config symbols resolve to their Kconfig files, and all five
  driver sources exist in the patched tree.
- The 4002/4003 provenance record, including that both changes are present in
  the ChromiumOS kernel tree this board pins.
- The patch-stack workflow's logic, executed end to end against a pristine
  tree outside GitHub.

Taken from openFyde's documentation but **not** executed:

- Every SDK setup and build command in Parts 1, 2, 4 and 6. They are quoted
  from openFyde's getting-started guide, but no image has been built here.

**Never run:** `build-image.yml` itself. It has never been executed against a
real SDK and self-hosted runner. Treat the first run as a debugging exercise,
not a formality.
