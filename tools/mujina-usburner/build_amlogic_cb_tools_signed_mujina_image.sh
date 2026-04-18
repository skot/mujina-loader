#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AMLOGIC_CB_TOOLS_DIR="${AMLOGIC_CB_TOOLS_DIR:-${ROOT_DIR}/../amlogic-cb-tools}"
BASE_PAYLOAD_DIR="${BASE_PAYLOAD_DIR:-${ROOT_DIR}/mujina_loader/mujina_armhf_base}"
KERNEL_IMAGE="${KERNEL_IMAGE:-${AMLOGIC_CB_TOOLS_DIR}/usb/bin/Image-usb-storage}"
DTB_PATH="${DTB_PATH:-${AMLOGIC_CB_TOOLS_DIR}/usb/bin/axg_s400_antminer.usb-host-nand-clocks.dtb}"
PAYLOAD_OUT_DIR="${PAYLOAD_OUT_DIR:-${SCRIPT_DIR}/output/mujina_armhf_amlogic_cb_tools}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output/amlogic_cb_tools}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_amlogic_cb_tools.img}"
OUTPUT_ENV_TEXT="${OUTPUT_ENV_TEXT:-${OUTPUT_DIR}/mujina-uboot-env-amlogic-cb-tools.txt}"
OUTPUT_ENV_BIN="${OUTPUT_ENV_BIN:-${OUTPUT_DIR}/nand_env-amlogic-cb-tools.bin}"

KERNEL_PAYLOAD_BUILDER="${ROOT_DIR}/tools/kernel_build/build_custom_kernel_payload.sh"
USB_BURN_BUILDER="${SCRIPT_DIR}/build_stock_signed_mujina_image.sh"

usage() {
  cat <<EOF
Usage:
  ./build_amlogic_cb_tools_signed_mujina_image.sh [options]

Builds a stock-signed Mujina USB burn image that boots the custom kernel and
DTB from the sibling amlogic-cb-tools workspace.

Default sibling workspace:
  ${AMLOGIC_CB_TOOLS_DIR}

Default kernel artifact:
  ${KERNEL_IMAGE}

Default DTB artifact:
  ${DTB_PATH}

Options:
  --amlogic-cb-tools-dir PATH  Sibling amlogic-cb-tools workspace
  --base-payload-dir PATH      Base Mujina payload dir
  --kernel-image PATH          Kernel Image to embed into nvdata
  --dtb PATH                   DTB to embed into nvdata
  --payload-out-dir PATH       Prepared custom payload dir
  --output-dir PATH            Final USB burn output dir
  --output-image PATH          Final stock-signed .img path
  --output-env-text PATH       Human-readable env output
  --output-env-bin PATH        Binary env output
  --help                       Show this message
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --amlogic-cb-tools-dir) AMLOGIC_CB_TOOLS_DIR="${2:-}"; shift 2 ;;
    --base-payload-dir) BASE_PAYLOAD_DIR="${2:-}"; shift 2 ;;
    --kernel-image) KERNEL_IMAGE="${2:-}"; shift 2 ;;
    --dtb) DTB_PATH="${2:-}"; shift 2 ;;
    --payload-out-dir) PAYLOAD_OUT_DIR="${2:-}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --output-image) OUTPUT_IMAGE="${2:-}"; shift 2 ;;
    --output-env-text) OUTPUT_ENV_TEXT="${2:-}"; shift 2 ;;
    --output-env-bin) OUTPUT_ENV_BIN="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -x "${KERNEL_PAYLOAD_BUILDER}" ]] || die "Missing payload builder: ${KERNEL_PAYLOAD_BUILDER}"
[[ -x "${USB_BURN_BUILDER}" ]] || die "Missing USB burn builder: ${USB_BURN_BUILDER}"
[[ -d "${BASE_PAYLOAD_DIR}" ]] || die "Missing base payload dir: ${BASE_PAYLOAD_DIR}"
[[ -f "${KERNEL_IMAGE}" ]] || die "Missing kernel image: ${KERNEL_IMAGE}"
[[ -f "${DTB_PATH}" ]] || die "Missing DTB: ${DTB_PATH}"

echo "Preparing custom-kernel payload from sibling amlogic-cb-tools artifacts..."
"${KERNEL_PAYLOAD_BUILDER}" \
  --base-payload-dir "${BASE_PAYLOAD_DIR}" \
  --kernel-image "${KERNEL_IMAGE}" \
  --dtb "${DTB_PATH}" \
  --out-dir "${PAYLOAD_OUT_DIR}"

echo "Building stock-signed USB burn image around the prepared payload..."
PAYLOAD_DIR="${PAYLOAD_OUT_DIR}" \
OUTPUT_DIR="${OUTPUT_DIR}" \
OUTPUT_IMAGE="${OUTPUT_IMAGE}" \
OUTPUT_ENV_TEXT="${OUTPUT_ENV_TEXT}" \
OUTPUT_ENV_BIN="${OUTPUT_ENV_BIN}" \
  "${USB_BURN_BUILDER}"

echo
echo "Custom-kernel USB burn image ready:"
echo "  Payload: ${PAYLOAD_OUT_DIR}"
echo "  Image:   ${OUTPUT_IMAGE}"
echo "  Env txt: ${OUTPUT_ENV_TEXT}"
echo "  Env bin: ${OUTPUT_ENV_BIN}"
