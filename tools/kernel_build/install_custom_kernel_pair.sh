#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD_DIR="${PAYLOAD_DIR:-${SCRIPT_DIR}/output/mujina_armhf_custom_kernel}"
BOARD_PASSWORD="${BOARD_PASSWORD:-root}"
REMOTE_IMAGE_PATH="${REMOTE_IMAGE_PATH:-/Image}"
REMOTE_DTB_DIR="${REMOTE_DTB_DIR:-/}"
REMOTE_ENV_TMP="${REMOTE_ENV_TMP:-/tmp/nand_env.mujina-custom.bin}"
REBOOT_AFTER_INSTALL="${REBOOT_AFTER_INSTALL:-1}"

usage() {
  cat <<EOF
Usage:
  ./install_custom_kernel_pair.sh <board-ip> [payload-dir]

Default payload dir:
  ${PAYLOAD_DIR}

This installs:
  - Image -> ${REMOTE_IMAGE_PATH}
  - DTB   -> ${REMOTE_DTB_DIR}<dtb filename>
  - nand_env.bin -> /dev/nand_env
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

[[ ${1:-} == "-h" || ${1:-} == "--help" ]] && { usage; exit 0; }
[[ $# -lt 1 || $# -gt 2 ]] && { usage >&2; exit 2; }

need_cmd sshpass
need_cmd shasum

BOARD_IP="$1"
PAYLOAD_DIR="${2:-${PAYLOAD_DIR}}"

IMAGE_PATH="${PAYLOAD_DIR}/Image"
ENV_BLOB="${PAYLOAD_DIR}/nand_env.bin"
DTB_PATH="$(find "${PAYLOAD_DIR}" -maxdepth 1 -name '*.dtb' | head -n 1)"
[[ -f "${IMAGE_PATH}" ]] || die "Missing Image in payload: ${IMAGE_PATH}"
[[ -f "${ENV_BLOB}" ]] || die "Missing env blob in payload: ${ENV_BLOB}"
[[ -n "${DTB_PATH}" && -f "${DTB_PATH}" ]] || die "Missing DTB in payload: ${PAYLOAD_DIR}/*.dtb"

DTB_BASENAME="$(basename "${DTB_PATH}")"
REMOTE_DTB_PATH="${REMOTE_DTB_DIR%/}/${DTB_BASENAME}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

remote_ssh() {
  sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "$@"
}

copy_to_remote() {
  local src="$1"
  local dst="$2"
  sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "cat > '${dst}'" < "${src}"
}

echo "== local payload =="
shasum -a 256 "${IMAGE_PATH}" "${DTB_PATH}" "${ENV_BLOB}"

echo "== backup current kernel, dtb, env =="
remote_ssh "set -e; if [ -f '${REMOTE_IMAGE_PATH}' ]; then cp -a '${REMOTE_IMAGE_PATH}' '${REMOTE_IMAGE_PATH}.pre-mujina-custom'; fi; if [ -f '${REMOTE_DTB_PATH}' ]; then cp -a '${REMOTE_DTB_PATH}' '${REMOTE_DTB_PATH}.pre-mujina-custom'; fi; dd if=/dev/nand_env of=/tmp/nand_env.pre-mujina-custom.bin bs=65536 count=1 >/dev/null 2>&1"

echo "== install kernel image =="
copy_to_remote "${IMAGE_PATH}" "${REMOTE_IMAGE_PATH}"
remote_ssh "sha256sum '${REMOTE_IMAGE_PATH}'"

echo "== install dtb =="
copy_to_remote "${DTB_PATH}" "${REMOTE_DTB_PATH}"
remote_ssh "sha256sum '${REMOTE_DTB_PATH}'"

echo "== install boot env =="
copy_to_remote "${ENV_BLOB}" "${REMOTE_ENV_TMP}"
remote_ssh "set -e; dd if='${REMOTE_ENV_TMP}' of=/dev/nand_env bs=65536 count=1 conv=fsync >/dev/null 2>&1; dd if=/dev/nand_env of=/tmp/nand_env.verify.bin bs=65536 count=1 >/dev/null 2>&1"

LOCAL_ENV_SHA="$(shasum -a 256 "${ENV_BLOB}" | awk '{print $1}')"
REMOTE_ENV_SHA="$(remote_ssh "sha256sum /tmp/nand_env.verify.bin | cut -d' ' -f1")"
[[ "${LOCAL_ENV_SHA}" == "${REMOTE_ENV_SHA}" ]] || die "Live nand_env hash mismatch: ${LOCAL_ENV_SHA} != ${REMOTE_ENV_SHA}"
echo "Boot env verified: ${REMOTE_ENV_SHA}"

if [[ "${REBOOT_AFTER_INSTALL}" == "1" ]]; then
  echo "== reboot =="
  remote_ssh "sync; /sbin/reboot || /bin/busybox reboot || busybox reboot || true" || true
  echo "Reboot requested."
else
  echo "Reboot not requested. Set REBOOT_AFTER_INSTALL=1 to reboot automatically."
fi
