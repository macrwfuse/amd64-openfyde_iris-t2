#!/bin/bash
# Re-check whether the two patches in this directory are still redundant.
#
# Both changes were merged upstream (v6.2) and backported to stable 6.1.2, so
# for any 6.1.y tree they are already present and the patches must NOT be
# applied. If a future kernel drops either change, that patch has to move back
# into ../files/ -- this script tells you that.
#
# Usage: verify-upstreamed.sh /path/to/linux[-6.1.y]

set -u

KERNEL_DIR="${1:-}"
if [[ -z "${KERNEL_DIR}" || ! -d "${KERNEL_DIR}" ]]; then
  echo "usage: $0 /path/to/linux" >&2
  exit 2
fi

APPLE_C="${KERNEL_DIR}/drivers/hid/hid-apple.c"
if [[ ! -f "${APPLE_C}" ]]; then
  echo "not a kernel tree, missing ${APPLE_C}" >&2
  exit 2
fi

# 4002: the chained-translation helper introduced by
# "HID: apple: fix key translations where multiple quirks attempt..."
MARK_4002="apple_find_translation(swapped_fn_leftctrl_keys, code)"

# 4003: every WELLSPRINGT2 row of the device table must carry
# APPLE_ISO_TILDE_QUIRK. Match the table rows specifically -- the same product
# IDs also appear in an unrelated product-ID check further up the file, so a
# bare ID match over-counts (16 instead of 8 on 6.1.25).
ROW='{ HID_USB_DEVICE(USB_VENDOR_ID_APPLE, USB_DEVICE_ID_APPLE_WELLSPRINGT2_'
T2_TOTAL=$(grep -F -c "${ROW}" "${APPLE_C}" 2>/dev/null || true)
T2_ISO=$(grep -F -A1 "${ROW}" "${APPLE_C}" 2>/dev/null | grep -c 'APPLE_ISO_TILDE_QUIRK' || true)

rc=0

echo "checking ${APPLE_C}"
echo

if grep -qF "${MARK_4002}" "${APPLE_C}"; then
  line=$(grep -nF "${MARK_4002}" "${APPLE_C}" | head -1 | cut -d: -f1)
  echo "  4002  already upstream   (line ${line})"
else
  echo "  4002  NOT upstream  <-- move the patch back into ../files/"
  rc=1
fi

if [[ "${T2_TOTAL}" -gt 0 && "${T2_ISO}" -eq "${T2_TOTAL}" ]]; then
  echo "  4003  already upstream   (${T2_ISO}/${T2_TOTAL} WELLSPRINGT2 table rows carry APPLE_ISO_TILDE_QUIRK)"
else
  echo "  4003  NOT upstream   (${T2_ISO}/${T2_TOTAL}) <-- move the patch back into ../files/"
  rc=1
fi

echo
if [[ ${rc} -eq 0 ]]; then
  echo "both changes present: the patches are correctly excluded from the build"
else
  echo "at least one change is missing: this directory is no longer valid"
fi
exit ${rc}
