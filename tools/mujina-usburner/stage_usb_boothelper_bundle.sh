#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_SCRIPT="${BUILD_SCRIPT:-${SCRIPT_DIR}/build_stock_signed_mujina_image.sh}"
STOCK_IMAGE="${STOCK_IMAGE:-${ROOT_DIR}/tools/stock_fw_restore/images/aml_upgrade_package_enc.img}"
PACKER="${PACKER:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/aml_image_v2_packer}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
USB_BUNDLE_DIR="${USB_BUNDLE_DIR:-${OUTPUT_DIR}/usb-boothelper-flashdrive}"
OUTPUT_IMAGE_BASENAME="${OUTPUT_IMAGE_BASENAME:-aml_upgrade_package_enc.img}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_armhf_base.img}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-usb-boothelper-stick.XXXXXX")"
UNPACK_DIR="${WORK_DIR}/stock-unpacked"
CUSTOM_INI="${WORK_DIR}/aml_sdc_burn.ini"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

verify_inputs() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This workflow currently targets macOS hosts"
  [[ -x "${BUILD_SCRIPT}" ]] || die "Missing builder script: ${BUILD_SCRIPT}"
  [[ -f "${STOCK_IMAGE}" ]] || die "Missing stock image: ${STOCK_IMAGE}"
  [[ -x "${PACKER}" ]] || die "Missing packer: ${PACKER}"
  need_cmd cp
  need_cmd rm
  need_cmd mkdir
  need_cmd sed
}

build_payload_image() {
  REPLACE_BOOT_WITH_HELPER=1 "${BUILD_SCRIPT}"
  [[ -f "${OUTPUT_IMAGE}" ]] || die "Expected builder output missing: ${OUTPUT_IMAGE}"
}

extract_stock_burn_helpers() {
  mkdir -p "${UNPACK_DIR}"
  "${PACKER}" -d "${STOCK_IMAGE}" "${UNPACK_DIR}" >/dev/null
  [[ -f "${UNPACK_DIR}/aml_sdc_burn.UBOOT.ENC" ]] || die "Stock image did not unpack aml_sdc_burn.UBOOT.ENC"
}

write_custom_ini() {
  LC_ALL=C sed 's/^\([[:space:]]*reboot[[:space:]]*=[[:space:]]*\).*/\10/' \
    "${ROOT_DIR}/tools/stock_fw_restore/reference/aml_sdc_burn.ini" > "${CUSTOM_INI}"
}

write_bundle_notes() {
  cat > "${USB_BUNDLE_DIR}/README.txt" <<EOF
Mujina USB boot-helper staging bundle

Copy these files to the root of a FAT32 USB flash drive:
- aml_sdc_burn.ini
- aml_sdc_burn.UBOOT.ENC
- ${OUTPUT_IMAGE_BASENAME}

This experimental bundle replaces boot.PARTITION inside the flashed image with
a one-shot stock-kernel helper. On the first normal boot after the USB burn,
that helper writes the embedded staging nand_env to /dev/nand_env and reboots.
The next boot should then hand off into Mujina, whose own first-boot finalizer
rewrites nand_env to the steady-state runtime env and reboots once more.

Current expectation:
- burn succeeds from USB media
- user removes the USB stick
- user power-cycles the board once
- helper boot writes nand_env and reboots
- Mujina boots and finalizes its runtime env

Related artifacts left in ${OUTPUT_DIR}:
- boot.PARTITION
- boot-helper-manifest.txt
- nand_env.bin
- runtime_nand_env.bin
- manifest.txt
- SHA256SUMS
EOF
}

stage_bundle() {
  rm -rf "${USB_BUNDLE_DIR}"
  mkdir -p "${USB_BUNDLE_DIR}"

  cp "${UNPACK_DIR}/aml_sdc_burn.UBOOT.ENC" "${USB_BUNDLE_DIR}/aml_sdc_burn.UBOOT.ENC"
  cp "${CUSTOM_INI}" "${USB_BUNDLE_DIR}/aml_sdc_burn.ini"
  cp "${OUTPUT_IMAGE}" "${USB_BUNDLE_DIR}/${OUTPUT_IMAGE_BASENAME}"

  write_bundle_notes
}

main() {
  verify_inputs
  build_payload_image
  extract_stock_burn_helpers
  write_custom_ini
  stage_bundle

  echo "Staged USB boot-helper bundle at ${USB_BUNDLE_DIR}"
  find "${USB_BUNDLE_DIR}" -maxdepth 1 -type f | sort
}

main "$@"
