#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BUILD_SCRIPT="${BUILD_SCRIPT:-${SCRIPT_DIR}/build_stock_signed_mujina_image.sh}"
AUTOSCRIPT_BUILD="${AUTOSCRIPT_BUILD:-${SCRIPT_DIR}/build_aml_autoscript.sh}"
RECOVERY_BUILD="${RECOVERY_BUILD:-${SCRIPT_DIR}/build_recovery_handoff_image.sh}"
STOCK_IMAGE="${STOCK_IMAGE:-${ROOT_DIR}/tools/stock_fw_restore/images/aml_upgrade_package_enc.img}"
PACKER="${PACKER:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/aml_image_v2_packer}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
USB_BUNDLE_DIR="${USB_BUNDLE_DIR:-${OUTPUT_DIR}/usb-handoff-flashdrive}"
OUTPUT_IMAGE_BASENAME="${OUTPUT_IMAGE_BASENAME:-aml_upgrade_package_enc.img}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_armhf_base.img}"
AUTOSCRIPT_IMAGE="${AUTOSCRIPT_IMAGE:-${OUTPUT_DIR}/aml_autoscript}"
AUTOSCRIPT_SOURCE="${AUTOSCRIPT_SOURCE:-${OUTPUT_DIR}/aml_autoscript.txt}"
ENV_BIN="${ENV_BIN:-${OUTPUT_DIR}/nand_env.bin}"
RECOVERY_IMAGE="${RECOVERY_IMAGE:-${OUTPUT_DIR}/recovery.img}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-usb-handoff-stick.XXXXXX")"
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
  [[ -x "${AUTOSCRIPT_BUILD}" ]] || die "Missing autoscript builder: ${AUTOSCRIPT_BUILD}"
  [[ -x "${RECOVERY_BUILD}" ]] || die "Missing recovery helper builder: ${RECOVERY_BUILD}"
  [[ -f "${STOCK_IMAGE}" ]] || die "Missing stock image: ${STOCK_IMAGE}"
  [[ -x "${PACKER}" ]] || die "Missing packer: ${PACKER}"
  need_cmd cp
  need_cmd rm
  need_cmd mkdir
  need_cmd sed
}

build_artifacts() {
  "${BUILD_SCRIPT}"
  [[ -f "${OUTPUT_IMAGE}" ]] || die "Expected builder output missing: ${OUTPUT_IMAGE}"
  "${AUTOSCRIPT_BUILD}"
  [[ -f "${AUTOSCRIPT_IMAGE}" ]] || die "Expected autoscript output missing: ${AUTOSCRIPT_IMAGE}"
  "${RECOVERY_BUILD}"
  [[ -f "${RECOVERY_IMAGE}" ]] || die "Expected recovery helper output missing: ${RECOVERY_IMAGE}"
  [[ -f "${ENV_BIN}" ]] || die "Expected env blob missing: ${ENV_BIN}"
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
Mujina experimental USB handoff bundle

Copy these files to the root of a FAT32 USB flash drive:
- aml_sdc_burn.ini
- aml_sdc_burn.UBOOT.ENC
- ${OUTPUT_IMAGE_BASENAME}
- aml_autoscript
- nand_env.bin
- recovery.img

This bundle is intended to test a fully hands-off removable-media flow:
1. cold-boot USB burn flashes the stock-signed Mujina image
2. aml_sdc_burn.ini uses reboot=0 so U-Boot can keep executing update logic
3. recovery_from_udisk first tries aml_autoscript to import nand_env.bin
4. if that does not finish the handoff, recovery.img is present as a fallback
   one-shot helper that writes an embedded staging nand_env and reboots

This remains experimental. The proven paths today are:
- PC-side USB burn followed by nand_env import
- USB flashdrive burn followed by a later nand_env write from Linux

Related artifacts left in ${OUTPUT_DIR}:
- aml_autoscript
- aml_autoscript.txt
- nand_env.bin
- recovery-helper-manifest.txt
- recovery.img
- runtime_nand_env.bin
EOF
}

stage_bundle() {
  rm -rf "${USB_BUNDLE_DIR}"
  mkdir -p "${USB_BUNDLE_DIR}"

  cp "${UNPACK_DIR}/aml_sdc_burn.UBOOT.ENC" "${USB_BUNDLE_DIR}/aml_sdc_burn.UBOOT.ENC"
  cp "${CUSTOM_INI}" "${USB_BUNDLE_DIR}/aml_sdc_burn.ini"
  cp "${OUTPUT_IMAGE}" "${USB_BUNDLE_DIR}/${OUTPUT_IMAGE_BASENAME}"
  cp "${AUTOSCRIPT_IMAGE}" "${USB_BUNDLE_DIR}/aml_autoscript"
  cp "${AUTOSCRIPT_SOURCE}" "${USB_BUNDLE_DIR}/aml_autoscript.txt"
  cp "${ENV_BIN}" "${USB_BUNDLE_DIR}/nand_env.bin"
  cp "${RECOVERY_IMAGE}" "${USB_BUNDLE_DIR}/recovery.img"

  write_bundle_notes
}

main() {
  verify_inputs
  build_artifacts
  extract_stock_burn_helpers
  write_custom_ini
  stage_bundle

  echo "Staged USB handoff bundle at ${USB_BUNDLE_DIR}"
  find "${USB_BUNDLE_DIR}" -maxdepth 1 -type f | sort
}

main "$@"
