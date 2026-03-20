#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_DTB_PATH="${SCRIPT_DIR}/reference/axg_s400_antminer.usb-host-nand-clocks.dtb"
BOARD_PASSWORD="${BOARD_PASSWORD:-root}"
REMOTE_DTB_PATH="${REMOTE_DTB_PATH:-/axg_s400_antminer.dtb}"
REMOTE_TMP_PATH="${REMOTE_TMP_PATH:-/tmp/axg_s400_antminer.mujina-custom.dtb}"
REBOOT_AFTER_INSTALL="${REBOOT_AFTER_INSTALL:-0}"

usage() {
  cat <<EOF
Usage:
  ./install_companion_dtb.sh <board-ip> [dtb-path]

Default DTB:
  ${DEFAULT_DTB_PATH}

If that file is not present locally, pass an explicit dtb path.
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
DTB_PATH="${2:-${DEFAULT_DTB_PATH}}"
[[ -f "${DTB_PATH}" ]] || die "DTB file not found: ${DTB_PATH}"

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
REMOTE_BACKUP_PATH="${REMOTE_DTB_PATH}.pre-mujina-custom"
LOCAL_SHA="$(shasum -a 256 "${DTB_PATH}" | awk '{print $1}')"
ROLLBACK_NEEDED="0"

remote_ssh() {
  sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "$@"
}

rollback() {
  if [[ "${ROLLBACK_NEEDED}" == "1" ]]; then
    echo "Install failed after backup; restoring ${REMOTE_BACKUP_PATH}" >&2
    remote_ssh "set -e; cp '${REMOTE_BACKUP_PATH}' '${REMOTE_DTB_PATH}'; sync" || true
  fi
}
trap rollback EXIT

echo "== local artifact =="
echo "DTB: ${DTB_PATH}"
echo "SHA256: ${LOCAL_SHA}"

echo "== remote preflight =="
remote_ssh "set -e; ls -l '${REMOTE_DTB_PATH}'; sha256sum '${REMOTE_DTB_PATH}'"

echo "== backup current DTB =="
remote_ssh "set -e; cp -a '${REMOTE_DTB_PATH}' '${REMOTE_BACKUP_PATH}'; sha256sum '${REMOTE_BACKUP_PATH}'"
ROLLBACK_NEEDED="1"

echo "== upload replacement DTB =="
sshpass -p "${BOARD_PASSWORD}" ssh "${SSH_OPTS[@]}" "root@${BOARD_IP}" "cat > '${REMOTE_TMP_PATH}'" < "${DTB_PATH}"

echo "== verify uploaded DTB =="
REMOTE_TMP_SHA="$(remote_ssh "sha256sum '${REMOTE_TMP_PATH}' | awk '{print \\$1}'")"
[[ "${REMOTE_TMP_SHA}" == "${LOCAL_SHA}" ]] || die "Uploaded DTB checksum mismatch"

echo "== install replacement DTB =="
remote_ssh "set -e; cp '${REMOTE_TMP_PATH}' '${REMOTE_DTB_PATH}'; sync"

echo "== verify installed DTB =="
REMOTE_INSTALLED_SHA="$(remote_ssh "sha256sum '${REMOTE_DTB_PATH}' | awk '{print \\$1}'")"
[[ "${REMOTE_INSTALLED_SHA}" == "${LOCAL_SHA}" ]] || die "Installed DTB checksum mismatch"

ROLLBACK_NEEDED="0"
echo "Install complete. Backup saved as ${REMOTE_BACKUP_PATH}."

if [[ "${REBOOT_AFTER_INSTALL}" == "1" ]]; then
  echo "== reboot =="
  remote_ssh "/sbin/reboot || /bin/busybox reboot || busybox reboot || true" || true
  echo "Reboot requested."
else
  echo "Reboot not requested. Set REBOOT_AFTER_INSTALL=1 to reboot automatically."
fi
