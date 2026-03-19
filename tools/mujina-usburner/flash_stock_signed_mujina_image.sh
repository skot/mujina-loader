#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FLASH_TOOL="${FLASH_TOOL:-${ROOT_DIR}/tools/stock_fw_restore/flash-tool}"
UPDATE_BIN="${UPDATE_BIN:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/update}"
IMAGE="${IMAGE:-${SCRIPT_DIR}/output/aml_upgrade_package_mujina_armhf_base.img}"
ENV_TEXT="${ENV_TEXT:-${SCRIPT_DIR}/output/mujina-uboot-env.txt}"
ENV_BIN="${ENV_BIN:-${SCRIPT_DIR}/output/nand_env.bin}"
ENV_LOAD_ADDR="${ENV_LOAD_ADDR:-0x01080000}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

verify_inputs() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This workflow currently targets macOS hosts"
  [[ -f "${IMAGE}" ]] || die "Missing generated image: ${IMAGE}"
  [[ -f "${ENV_TEXT}" ]] || die "Missing U-Boot env commands: ${ENV_TEXT}"
  [[ -f "${ENV_BIN}" ]] || die "Missing env blob: ${ENV_BIN}"
  [[ -x "${FLASH_TOOL}" ]] || die "Missing flash-tool: ${FLASH_TOOL}"
  [[ -x "${UPDATE_BIN}" ]] || die "Missing update binary: ${UPDATE_BIN}"
  [[ -e /usr/local/opt/libusb-compat/lib/libusb-0.1.4.dylib ]] || die "Missing libusb-compat. Run tools/stock_fw_restore/install_host_deps.sh first."
  need_cmd awk
}

check_usb_device() {
  echo "Checking for an Amlogic USB burn-mode device..."
  "${UPDATE_BIN}" identify 7 >/dev/null || die "No USB burn-mode board found"
}

flash_image_without_reset() {
  echo "Flashing stock-signed Mujina image with reset deferred..."
  "${FLASH_TOOL}" \
    --img="${IMAGE}" \
    --parts=all \
    --soc=axg \
    --wipe \
    --reset=n
}

program_env() {
  local env_size
  env_size="$(stat -f '%z' "${ENV_BIN}")"
  echo "Programming Mujina U-Boot environment from ${ENV_BIN}..."
  echo "  mwrite ${ENV_BIN} -> ${ENV_LOAD_ADDR}"
  "${UPDATE_BIN}" mwrite "${ENV_BIN}" mem "${ENV_LOAD_ADDR}" normal >/dev/null
  echo "  env import -b ${ENV_LOAD_ADDR} 0x$(printf '%x' "${env_size}")"
  "${UPDATE_BIN}" bulkcmd "env import -b ${ENV_LOAD_ADDR} 0x$(printf '%x' "${env_size}")" >/dev/null
  echo "  save"
  "${UPDATE_BIN}" bulkcmd "save" >/dev/null
}

complete_burn() {
  echo "Finalizing burn and rebooting board..."
  "${UPDATE_BIN}" bulkcmd "burn_complete 1" >/dev/null
}

main() {
  verify_inputs
  check_usb_device
  flash_image_without_reset
  program_env
  complete_burn
  echo "USB burn complete."
}

main "$@"
