#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output/amlogic_cb_tools}"
IMAGE="${IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_amlogic_cb_tools.img}"
ENV_TEXT="${ENV_TEXT:-${OUTPUT_DIR}/mujina-uboot-env-amlogic-cb-tools.txt}"
ENV_BIN="${ENV_BIN:-${OUTPUT_DIR}/nand_env-amlogic-cb-tools.bin}"
FLASHER="${SCRIPT_DIR}/flash_stock_signed_mujina_image.sh"

usage() {
  cat <<EOF
Usage:
  ./flash_amlogic_cb_tools_signed_mujina_image.sh

Flashes the custom-kernel stock-signed Mujina image produced by:
  ./build_amlogic_cb_tools_signed_mujina_image.sh

Defaults:
  IMAGE=${IMAGE}
  ENV_TEXT=${ENV_TEXT}
  ENV_BIN=${ENV_BIN}

You can override these with the environment if needed.
EOF
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

[[ -x "${FLASHER}" ]] || {
  echo "ERROR: Missing flasher: ${FLASHER}" >&2
  exit 1
}

IMAGE="${IMAGE}" \
ENV_TEXT="${ENV_TEXT}" \
ENV_BIN="${ENV_BIN}" \
  "${FLASHER}" "$@"
