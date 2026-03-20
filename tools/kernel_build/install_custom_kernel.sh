#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_PATH="${IMAGE_PATH:-${SCRIPT_DIR}/output/Image-mujina-custom}"
BOARD_PASSWORD="${BOARD_PASSWORD:-root}"
REMOTE_IMAGE_PATH="${REMOTE_IMAGE_PATH:-/Image}"
REMOTE_TMP_IMAGE_PATH="${REMOTE_TMP_IMAGE_PATH:-/tmp/Image.mujina-custom}"
REBOOT_AFTER_INSTALL="${REBOOT_AFTER_INSTALL:-0}"

usage() {
  cat <<EOF
Usage:
  ./install_custom_kernel.sh <board-ip> [image-path]

Environment:
  BOARD_PASSWORD        SSH password (default: root)
  REMOTE_IMAGE_PATH     Target kernel path on the board (default: /Image)
  REMOTE_TMP_IMAGE_PATH Temporary upload path (default: /tmp/Image.mujina-custom)
  REBOOT_AFTER_INSTALL  Set to 1 to reboot after install
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
IMAGE_PATH="${2:-${IMAGE_PATH}}"
[[ -f "${IMAGE_PATH}" ]] || die "Kernel image not found: ${IMAGE_PATH}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
REMOTE_BACKUP_PATH="${REMOTE_IMAGE_PATH}.pre-mujina-custom"
LOCAL_SHA="$(shasum -a 256 "${IMAGE_PATH}" | awk '{print $1}')"
ROLLBACK_NEEDED="0"

remote_ssh() {
  sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "$@"
}

rollback() {
  if [[ "${ROLLBACK_NEEDED}" == "1" ]]; then
    echo "Install failed after backup; restoring ${REMOTE_BACKUP_PATH}" >&2
    remote_ssh "set -e; cp '${REMOTE_BACKUP_PATH}' '${REMOTE_IMAGE_PATH}'; sync" || true
  fi
}
trap rollback EXIT

echo "== local artifact =="
echo "Image: ${IMAGE_PATH}"
echo "SHA256: ${LOCAL_SHA}"

echo "== remote preflight =="
remote_ssh "set -e; ls -l '${REMOTE_IMAGE_PATH}'; sha256sum '${REMOTE_IMAGE_PATH}'"

echo "== backup current Image =="
remote_ssh "set -e; cp -a '${REMOTE_IMAGE_PATH}' '${REMOTE_BACKUP_PATH}'; sha256sum '${REMOTE_BACKUP_PATH}'"
ROLLBACK_NEEDED="1"

echo "== upload replacement Image =="
sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "cat > '${REMOTE_TMP_IMAGE_PATH}'" < "${IMAGE_PATH}"

echo "== verify uploaded Image =="
REMOTE_TMP_SHA="$(remote_ssh "sha256sum '${REMOTE_TMP_IMAGE_PATH}' | awk '{print \\$1}'")"
[[ "${REMOTE_TMP_SHA}" == "${LOCAL_SHA}" ]] || die "Uploaded Image checksum mismatch"

echo "== install replacement Image =="
remote_ssh "set -e; cp '${REMOTE_TMP_IMAGE_PATH}' '${REMOTE_IMAGE_PATH}'; sync"

echo "== verify installed Image =="
REMOTE_INSTALLED_SHA="$(remote_ssh "sha256sum '${REMOTE_IMAGE_PATH}' | awk '{print \\$1}'")"
[[ "${REMOTE_INSTALLED_SHA}" == "${LOCAL_SHA}" ]] || die "Installed Image checksum mismatch"

ROLLBACK_NEEDED="0"
echo "Install complete. Backup saved as ${REMOTE_BACKUP_PATH}."

if [[ "${REBOOT_AFTER_INSTALL}" == "1" ]]; then
  echo "== reboot =="
  remote_ssh "/sbin/reboot || /bin/busybox reboot || busybox reboot || true" || true
  echo "Reboot requested."
else
  echo "Reboot not requested. Set REBOOT_AFTER_INSTALL=1 to reboot automatically."
fi
