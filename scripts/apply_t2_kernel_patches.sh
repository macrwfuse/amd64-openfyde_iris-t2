#!/bin/bash
# Apply the t2linux T2-chip patch set to a Linux 6.1 kernel source tree.
#
# Baseline: t2linux/linux-t2-patches @ 1918b48 ("6.1 wifi patches"), authored
# against ~6.1.7. The kernel this board actually builds is 6.1.25 (openFyde
# R114's chromeos-kernel-6_1-6.1.25-r227, from chromiumos/third_party/kernel
# branch chromeos-6.1).
#
# Gentoo's eapply runs patch at GNU patch's DEFAULT FUZZ OF 2 and does not
# pass --forward, so a reversed patch aborts the build. This script mirrors
# that behaviour rather than being more permissive than the real build.
#
# Usage: apply_t2_kernel_patches.sh /path/to/linux-6.1 [--check]
#   --check   report what each patch would do, without modifying the tree

set -u

KERNEL_DIR="${1:-}"
MODE="${2:-apply}"

if [[ -z "${KERNEL_DIR}" || ! -d "${KERNEL_DIR}" ]]; then
  echo "usage: $0 /path/to/linux-6.1 [--check]" >&2
  exit 2
fi

CHECK_ONLY=0
[[ "${MODE}" == "--check" ]] && CHECK_ONLY=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/../sys-kernel/chromeos-kernel-6_1/files"
FUZZ=2

if [[ ! -d "${PATCH_DIR}" ]]; then
  echo "patch directory not found: ${PATCH_DIR}" >&2
  exit 2
fi

cd "${KERNEL_DIR}" || exit 2

clean=0; fuzzed=0; redundant=0; failed=0
redundant_list=""; failed_list=""

for patch in "${PATCH_DIR}"/*.patch; do
  name="$(basename "${patch}")"

  if [[ ${CHECK_ONLY} -eq 0 ]] && git apply "${patch}" 2>/dev/null; then
    echo "clean     ${name}"
    clean=$((clean + 1))
    continue
  fi

  dry=""
  [[ ${CHECK_ONLY} -eq 1 ]] && dry="--dry-run"
  # Deliberately no --forward: a reversed patch must fail here, exactly as it
  # does in the real build.
  out="$(patch -p1 --fuzz="${FUZZ}" ${dry} < "${patch}" 2>&1)"
  rc=$?

  # Check for hard hunk failures FIRST. A patch can skip an already-applied
  # hunk and hard-fail another in the same run -- 8002 did exactly that before
  # its redundant hunks were trimmed. Testing "previously applied" first hides
  # the real breakage behind a benign-looking label.
  if [[ ${rc} -ne 0 ]] || grep -qE "FAILED at|hunk.*FAILED|malformed|can't find file" <<<"${out}"; then
    echo "FAILED    ${name}"
    grep -E "FAILED|malformed|can't find file" <<<"${out}" | head -3 | sed 's/^/          /'
    failed=$((failed + 1)); failed_list="${failed_list}  ${name}\n"
  elif grep -q "previously applied" <<<"${out}"; then
    echo "redundant ${name}  (already upstream)"
    redundant=$((redundant + 1)); redundant_list="${redundant_list}  ${name}\n"
  elif grep -qE "offset|fuzz" <<<"${out}"; then
    echo "fuzz      ${name}"
    fuzzed=$((fuzzed + 1))
  else
    echo "applied   ${name}"
    clean=$((clean + 1))
  fi
done

echo "---"
echo "total: $(ls "${PATCH_DIR}"/*.patch | wc -l)  clean: ${clean}  fuzz<=${FUZZ}: ${fuzzed}  redundant: ${redundant}  failed: ${failed}"

if [[ ${failed} -gt 0 ]]; then
  echo
  echo "Hard failures. The real build calls eapply, which aborts on these:"
  echo -e "${failed_list}"
  exit 1
fi

if [[ ${redundant} -gt 0 ]]; then
  echo
  echo "Already upstream. eapply does not pass --forward, so the real build"
  echo "aborts rather than skipping these. Move them to obsolete-upstream/:"
  echo -e "${redundant_list}"
  exit 1
fi

exit 0
