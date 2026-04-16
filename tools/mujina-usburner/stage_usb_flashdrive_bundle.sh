#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_SCRIPT="${BUILD_SCRIPT:-${SCRIPT_DIR}/build_stock_signed_mujina_image.sh}"
STOCK_IMAGE="${STOCK_IMAGE:-${ROOT_DIR}/tools/stock_fw_restore/images/aml_upgrade_package_enc.img}"
PACKER="${PACKER:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/aml_image_v2_packer}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
USB_BUNDLE_DIR="${USB_BUNDLE_DIR:-${OUTPUT_DIR}/usb-flashdrive}"
OUTPUT_IMAGE_BASENAME="${OUTPUT_IMAGE_BASENAME:-aml_upgrade_package_enc.img}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_armhf_base.img}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-usb-stick.XXXXXX")"
UNPACK_DIR="${WORK_DIR}/stock-unpacked"

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
}

build_payload_image() {
  "${BUILD_SCRIPT}"
  [[ -f "${OUTPUT_IMAGE}" ]] || die "Expected builder output missing: ${OUTPUT_IMAGE}"
}

extract_stock_burn_helpers() {
  mkdir -p "${UNPACK_DIR}"
  "${PACKER}" -d "${STOCK_IMAGE}" "${UNPACK_DIR}" >/dev/null
  [[ -f "${UNPACK_DIR}/aml_sdc_burn.UBOOT.ENC" ]] || die "Stock image did not unpack aml_sdc_burn.UBOOT.ENC"
}

write_bundle_notes() {
  cat > "${USB_BUNDLE_DIR}/README.txt" <<EOF
Mujina USB flashdrive staging bundle

Copy these files to the root of a FAT32 USB flash drive:
- aml_sdc_burn.ini
- aml_sdc_burn.UBOOT.ENC
- ${OUTPUT_IMAGE_BASENAME}

This bundle targets the Amlogic cold-boot removable-media burn path that probes
for aml_sdc_burn.ini on usb 0.

Important limitation:
- The current proven Mujina flow also imports nand_env.bin after flashing.
- The USB flashdrive path staged here does not yet perform that env import.
- So this bundle is suitable for testing whether the board accepts and flashes
  the Mujina stock-signed package from USB media, but it may still boot the
  stock U-Boot preference afterward unless the environment is changed by some
  other step.

Related artifacts left in ${OUTPUT_DIR}:
- nand_env.bin
- mujina-uboot-env.txt
- manifest.txt
- SHA256SUMS
EOF
}

stage_bundle() {
  rm -rf "${USB_BUNDLE_DIR}"
  mkdir -p "${USB_BUNDLE_DIR}"

  cp "${UNPACK_DIR}/aml_sdc_burn.UBOOT.ENC" "${USB_BUNDLE_DIR}/aml_sdc_burn.UBOOT.ENC"
  cp "${ROOT_DIR}/tools/stock_fw_restore/reference/aml_sdc_burn.ini" "${USB_BUNDLE_DIR}/aml_sdc_burn.ini"
  cp "${OUTPUT_IMAGE}" "${USB_BUNDLE_DIR}/${OUTPUT_IMAGE_BASENAME}"

  write_bundle_notes
}

main() {
  verify_inputs
  build_payload_image
  extract_stock_burn_helpers
  stage_bundle

  echo "Staged USB flashdrive bundle at ${USB_BUNDLE_DIR}"
  find "${USB_BUNDLE_DIR}" -maxdepth 1 -type f | sort
}

main "$@"
