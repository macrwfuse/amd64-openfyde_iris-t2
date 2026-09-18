# amd64-openfyde_iris-t2 — Apple T2 Mac support

Derived board overlay bringing Apple T2-chip Mac support to the openFyde
`amd64-openfyde_iris` image. The stock `iris` board is unchanged; this board
adds the kernel patch stack, T2 kernel config, and board identity.

Building an image needs a self-hosted runner with the ChromiumOS SDK;
see [`README-Build.md`](README-Build.md).

## Kernel baseline

openFyde R114 builds **`chromeos-kernel-6_1-6.1.25-r227`** — Linux **6.1.25**,
sourced from ChromiumOS's own `chromiumos/third_party/kernel` at branch
`chromeos-6.1`, commit `6a8a0d28`. That tree is the real target; "6.1" alone
is not specific enough to build against.

t2linux's `main` branch tracks 7.2.3, so this board uses the 6.1-era commit:

    t2linux/linux-t2-patches @ 1918b48  ("6.1 wifi patches")

That patch set was authored against ~6.1.7 and needed two adaptations to work
on 6.1.25 — see "Upstream drift" below. Verified on a pristine 6.1.25 tree:

    28 patches   clean 23   fuzz<=2 5   failed 0

## Fuzz tolerance is not a detail

`eapply` runs `patch` at GNU patch's **default fuzz of 2** and does not pass
`--forward`. Two consequences:

- A patch needing fuzz 3 **aborts the build**.
- A patch whose changes are already upstream is **not** skipped — it aborts
  the build too.

Five patches (1005, 1012, 7001, 8001, 8002) apply at fuzz 1-2. That is
tolerated but fragile: re-check whenever the kernel revision moves.

Any verification that uses a looser tolerance than the real build is worse
than useless, because it reports green while the build fails. Both
`scripts/apply_t2_kernel_patches.sh` and the CI workflow use fuzz 2 and no
`--forward`, matching `eapply` exactly.

## Upstream drift

Three patches conflict with changes that were already merged upstream by
6.1.25. Handling differs by case.

**4002, 4003** — wholly redundant. Both changes are in 6.1.25 verbatim, so the
patches moved to `obsolete-upstream/`, which records their full upstream trace
(merge commit, backport commit, first release, and evidence in the build
tree) alongside `verify-upstreamed.sh` to re-check them after a kernel bump.
See `obsolete-upstream/README`.

**8002** — partially redundant, so it was **trimmed in place** rather than
dropped. The BCM4377 Bluetooth patchset is a concatenation of seven asahilinux
patches; three of its hunks add `HCI_QUIRK_BROKEN_EXT_SCAN` and
`HCI_QUIRK_BROKEN_MWS_TRANSPORT_CONFIG` to `include/net/bluetooth/hci.h` and
wire them into `use_ext_scan()` — and 6.1.25 already has all of that (hci.h
lines 286 and 296, hci_core.h lines 1692-1694). Those three hunks are removed;
everything else, including the 2514-line `hci_bcm4377.c` driver that actually
consumes those quirks, is kept.

Trimming 8002 is what makes the difference between a green check and a broken
build. Before the trim it hard-failed:

    checking file include/net/bluetooth/hci.h
    Hunk #1 FAILED at 263.
    1 out of 1 hunk FAILED
    ... patch exit 1

Superficially that looked like the benign "already applied" case, because the
same run also skipped two reversed hunks. A verifier that tests for
"previously applied" before testing for hard failures mislabels it as
harmless. That bug was in this repo's own tooling and is fixed — hence the
ordering note in both `apply_t2_kernel_patches.sh` and the CI workflow.

## Layout

    kconfig/t2                            T2 config fragment (5 new symbols)
    kconfig/kernel-6_1-def-t2             base defconfig + fragment
    sys-kernel/chromeos-kernel-6_1/
        chromeos-kernel-6_1-6.1.25-r228.ebuild   override; see below
        files/                                   28 T2 patches (LF)
        metadata.xml
        obsolete-upstream/                       excluded patches + upstream
                                                 provenance record
    scripts/apply_t2_kernel_patches.sh    apply + verify the series
    chromeos-base/amd64-openfyde-iris-t2-spec/
    chromeos-base/chromeos-config-bsp/files/model.yaml
                                          device name: amd64-openfyde_iris-t2
    .github/workflows/

`make.conf` points `CHROMEOS_KERNEL_CONFIG` at `kernel-6_1-def-t2`.

## The five new config symbols

The patch set introduces exactly these; all are absent from
`kernel-6_1-def-r1` and all five resolve in the patched tree:

    CONFIG_APPLE_BCE=m
    CONFIG_HID_APPLE_IBRIDGE=m
    CONFIG_HID_APPLE_TOUCHBAR=m
    CONFIG_HID_APPLE_MAGIC_BACKLIGHT=m
    CONFIG_BT_HCIBCM4377=m

Trackpad, SMC, Broadcom Wi-Fi/Bluetooth and i915 fbdev emulation are already
enabled in the base defconfig — see the comment block in `kconfig/t2`.

## How the patches actually reach the build

This is the part that is easy to get wrong, so it is spelled out.

`cros-kernel2.eclass` applies board patches from **FILESDIR**:

    apply_private_patches() {
        local patches=( "${FILESDIR}"/*.patch )
        [[ ${#patches[@]} -gt 0 ]] && eapply "${patches[@]}"
    }

    cros-kernel2_src_prepare() {
        if [[ "${PV}" != "9999" ]] || use apply_patches; then
            apply_private_patches
        fi
    }

FILESDIR resolves to the `files/` directory of the package dir holding the
**selected** ebuild. The upstream ebuild lives in `chromiumos-overlay`, whose
`files/` holds no patches — so dropping patches into a board overlay's
`sys-kernel/chromeos-kernel-6_1/files/` does nothing on its own.

The override ebuild raises the revision so portage selects *this* copy:

    upstream : chromeos-kernel-6_1-6.1.25-r227.ebuild
    board    : chromeos-kernel-6_1-6.1.25-r228.ebuild   <- selected

It is a verbatim copy of the upstream ebuild with only the revision bumped;
the kernel source, branch and commit are unchanged. That makes FILESDIR point
at this overlay's `files/`, and the 28 patches apply automatically.

Notes:
- Glob order is alphabetical, which matches the 1001..8002 numbering.
- `obsolete-upstream/` is a subdirectory, so `*.patch` never descends into it.
- If portage ever selects upstream's r227 instead, the patches silently do
  not apply and you get a kernel with no T2 support. The CI check
  `upstream-drift` fails when upstream publishes a version above 6.1.25, and
  `build-image.yml` re-checks the selected revision inside the build.
- When upstream bumps chromeos-kernel-6_1, re-copy its ebuild here, bump the
  revision by one again, and re-verify the patch stack.

## Verifying locally

    ./scripts/apply_t2_kernel_patches.sh /path/to/linux-6.1.25
    ./scripts/apply_t2_kernel_patches.sh /path/to/linux-6.1.25 --check
    ./sys-kernel/chromeos-kernel-6_1/obsolete-upstream/verify-upstreamed.sh /path/to/linux

`--check` is only meaningful for spot checks: a sequential series cannot be
dry-run patch-by-patch, because later patches depend on earlier ones.

## CI

`.github/workflows/verify-patch-stack.yml` runs on hosted runners (push, PR,
weekly). It applies the patch stack to a pristine 6.1.25 tree at fuzz 2, asserts
the five config symbols resolve and the five driver sources exist, fails if
upstream ships a kernel above 6.1.25, and checks repo hygiene (LF everywhere,
executable scripts, shellcheck, and that the override body still matches
upstream's ebuild).

`.github/workflows/build-image.yml` is the full image build — see
[`README-Build.md`](README-Build.md) for the runner setup and a step-by-step
first-build checklist. It **cannot** run on hosted runners: openFyde's own
docs require 150GB+ disk (200GB+ recommended), 16GB+ RAM and 5-10+ hours, and
`cros_sdk` needs a privileged chroot. It targets a self-hosted runner
(`self-hosted, linux, x64`) with a pre-initialised SDK, and only triggers
manually, so it simply never runs until you register one.

## Build prerequisites and known gaps

- **T2 firmware is not redistributable.** Wi-Fi, Bluetooth and some audio on
  these Macs need firmware extracted from the machine's own macOS install via
  the t2linux `apple-t2-firmware` tooling, then placed in the image under
  `/lib/firmware`. It cannot be vendored into this overlay.

- **APFS is not available at 6.1.** t2linux's APFS driver lands in later
  patch sets only, so mounting the macOS partition read-only is not supported
  by this board. Use a later kernel if that matters.

- **Touch Bar input** needs `CONFIG_HID_APPLE_TOUCHBAR` (set) plus the
  userspace `appletbdrm` display driver; only the input side is wired here.

- **Secure Boot / startup chime / Touch ID** are out of scope — the T2's
  Secure Enclave is not accessible from Linux.

- **No image has been built yet.** Patch application is verified against a
  pristine 6.1.25 tree, but nothing has been compiled or booted. The BCE
  driver in particular is a large patchset and has not been through a
  compiler.
