#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${SCRIPT_DIR}/images/aml_upgrade_package_enc.img"
FLASH_TOOL="${SCRIPT_DIR}/flash-tool"
UPDATE_BIN="${SCRIPT_DIR}/tools/macos/update"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This workflow is for macOS only." >&2
  exit 1
fi

if [[ ! -f "${IMAGE}" ]]; then
  echo "Missing image: ${IMAGE}" >&2
  exit 1
fi

if [[ ! -x "${FLASH_TOOL}" ]]; then
  echo "Missing flash-tool: ${FLASH_TOOL}" >&2
  exit 1
fi

if [[ ! -x "${UPDATE_BIN}" ]]; then
  echo "Missing update binary: ${UPDATE_BIN}" >&2
  exit 1
fi

if [[ ! -e /usr/local/opt/libusb-compat/lib/libusb-0.1.4.dylib ]]; then
  echo "Missing libusb-compat. Run ./install_host_deps.sh first." >&2
  exit 1
fi

echo "Checking for an Amlogic USB burn-mode device..."
if ! "${UPDATE_BIN}" identify 7; then
  echo "No USB burn-mode board found." >&2
  exit 1
fi

echo "Starting stock restore with the S21 AML flashcard image."
cd "${SCRIPT_DIR}"
exec "${FLASH_TOOL}" \
  --img="${IMAGE}" \
  --parts=all \
  --soc=axg \
  --wipe \
  --reset=y \
  "$@"
