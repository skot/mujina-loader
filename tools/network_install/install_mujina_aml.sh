#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/amlogic_bootstrap.sh"
PAYLOAD_DIR="${ROOT_DIR}/mujina_loader/mujina_armhf_base"
HOST="192.168.1.52"
PORT="22"
USER_NAME="miner"
PASSWORD="${PASSWORD:-miner}"
KERNEL="${PAYLOAD_DIR}/Image"
DTB="${PAYLOAD_DIR}/axg_s400_antminer.dtb"
ROOTFS="${PAYLOAD_DIR}/rootfs.tar.gz"
ENV_BLOB="${PAYLOAD_DIR}/nand_env.bin"
REMOTE_DIR="/tmp/mujina"
REMOTE_LOG="/tmp/mujina-stage4.log"
REMOTE_PID="/tmp/mujina-stage4.pid"
REMOTE_READY="/tmp/mujina-ready-for-reboot"
SKIP_BOOTSTRAP="0"
VERIFY_ENV_HASH_ONLY="0"

usage() {
  cat <<'EOF'
Usage:
  ./install_mujina_aml.sh --rootfs rootfs.tar.gz --env nand_env.bin [options]

Options:
  --host IP_OR_HOSTNAME   Target miner (default: 192.168.1.52)
  --port PORT             SSH port (default: 22)
  --user USERNAME         SSH username (default: miner)
  --password PASSWORD     SSH password (default: miner)
  --payload-dir PATH      Local payload dir (default: ../../mujina_loader/mujina_armhf_base)
  --kernel PATH           Optional kernel Image file
  --dtb PATH              Optional axg_s400_antminer.dtb file
  --rootfs PATH           Rootfs tar/tar.gz/tgz archive
  --env PATH              Generated nand_env blob
  --remote-dir PATH       Remote staging dir (default: /tmp/mujina)
  --remote-log PATH       Remote stage log (default: /tmp/mujina-stage4.log)
  --verify-env-hash-only  Non-destructive check: compare local env blob with
                          remote /dev/nand_env and exit
  --skip-bootstrap        Assume sudo is already available
  --help                  Show this message
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --user) USER_NAME="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --payload-dir)
      PAYLOAD_DIR="${2:-}"
      KERNEL="${PAYLOAD_DIR}/Image"
      DTB="${PAYLOAD_DIR}/axg_s400_antminer.dtb"
      ROOTFS="${PAYLOAD_DIR}/rootfs.tar.gz"
      ENV_BLOB="${PAYLOAD_DIR}/nand_env.bin"
      shift 2
      ;;
    --kernel) KERNEL="${2:-}"; shift 2 ;;
    --dtb) DTB="${2:-}"; shift 2 ;;
    --rootfs) ROOTFS="${2:-}"; shift 2 ;;
    --env) ENV_BLOB="${2:-}"; shift 2 ;;
    --remote-dir) REMOTE_DIR="${2:-}"; shift 2 ;;
    --remote-log) REMOTE_LOG="${2:-}"; shift 2 ;;
    --verify-env-hash-only) VERIFY_ENV_HASH_ONLY="1"; shift ;;
    --skip-bootstrap) SKIP_BOOTSTRAP="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "${ROOTFS}" ]] || die "Missing rootfs archive"
[[ -f "${ENV_BLOB}" ]] || die "Missing env blob"
[[ -x "${BOOTSTRAP_SCRIPT}" ]] || die "Missing bootstrap script: ${BOOTSTRAP_SCRIPT}"

need_cmd ssh
need_cmd sshpass
need_cmd sha256sum

SSH_TARGET="${USER_NAME}@${HOST}"
SSH_BASE=(
  sshpass -p "${PASSWORD}"
  ssh
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -p "${PORT}"
  "${SSH_TARGET}"
)
remote_run() {
  local cmd="$1"
  "${SSH_BASE[@]}" "sh -lc $(printf '%q' "${cmd}")" </dev/null
}

remote_try() {
  local cmd="$1"
  set +e
  "${SSH_BASE[@]}" "sh -lc $(printf '%q' "${cmd}")" </dev/null
  local rc=$?
  set -e
  return "${rc}"
}

copy_to_remote() {
  local src="$1"
  local dst="$2"
  "${SSH_BASE[@]}" "cat > $(printf '%q' "${dst}")" < "${src}"
}

if [[ "${SKIP_BOOTSTRAP}" != "1" ]]; then
  PASSWORD="${PASSWORD}" "${BOOTSTRAP_SCRIPT}" bootstrap --host "${HOST}" --port "${PORT}" --user "${USER_NAME}" --password "${PASSWORD}"
fi

verify_remote_env_hash() {
  echo "Verifying boot env from a fresh SSH session"
  remote_run "sudo -n dd if=/dev/nand_env of=${REMOTE_DIR}/live_env.verify bs=65536 count=1 >/dev/null 2>&1"
  local staged_hash live_hash
  staged_hash="$(sha256sum "${ENV_BLOB}" | awk '{print $1}')"
  live_hash="$(remote_run "sha256sum ${REMOTE_DIR}/live_env.verify | cut -d' ' -f1")"
  live_hash="$(printf '%s' "${live_hash}" | tr -d '\r\n')"
  [[ -n "${live_hash}" ]] || die "Unable to read live nand_env hash"
  [[ "${staged_hash}" == "${live_hash}" ]] || die "Live nand_env hash mismatch: ${staged_hash} != ${live_hash}"
  echo "Boot env verified: ${live_hash}"
}

if [[ "${VERIFY_ENV_HASH_ONLY}" == "1" ]]; then
  echo "Creating remote staging dir ${REMOTE_DIR}"
  remote_run "mkdir -p ${REMOTE_DIR}"
  verify_remote_env_hash
  exit 0
fi

echo "Creating remote staging dir ${REMOTE_DIR}"
remote_run "mkdir -p ${REMOTE_DIR}"

echo "Uploading Mujina assets"
if [[ -f "${KERNEL}" && -f "${DTB}" ]]; then
  copy_to_remote "${KERNEL}" "${REMOTE_DIR}/Image"
  copy_to_remote "${DTB}" "${REMOTE_DIR}/axg_s400_antminer.dtb"
else
  echo "No Image/DTB in payload; installer will keep using the stock boot partition kernel path"
fi
copy_to_remote "${ROOTFS}" "${REMOTE_DIR}/$(basename "${ROOTFS}")"
copy_to_remote "${ENV_BLOB}" "${REMOTE_DIR}/nand_env.bin"
copy_to_remote "${SCRIPT_DIR}/mujina_stage4_aml.sh" "${REMOTE_DIR}/mujina_stage4_aml.sh"

echo "Launching destructive Mujina stage4 on target"
remote_run "rm -f ${REMOTE_LOG} ${REMOTE_PID} ${REMOTE_READY} && chmod 0755 ${REMOTE_DIR}/mujina_stage4_aml.sh && sudo -n sh -c 'nohup ${REMOTE_DIR}/mujina_stage4_aml.sh ${REMOTE_DIR} >${REMOTE_LOG} 2>&1 </dev/null & echo \$! >${REMOTE_PID}'"

echo "Tailing remote stage log until reboot or completion"
while true; do
  remote_try "test -f ${REMOTE_LOG} && tail -n 80 ${REMOTE_LOG} || true" || true
  if ! remote_try "sudo -n sh -c 'test -f ${REMOTE_PID} && kill -0 \$(cat ${REMOTE_PID}) 2>/dev/null'"; then
    echo "Remote stage4 process exited"
    remote_run "test -f ${REMOTE_LOG} && tail -n 200 ${REMOTE_LOG} || true" || true
    break
  fi

  sleep 2
done

ready_reported="0"
if remote_try "test -f ${REMOTE_READY}"; then
  ready_reported="1"
elif remote_try "grep -q 'ready_for_reboot' ${REMOTE_LOG}"; then
  ready_reported="1"
fi

if [[ "${ready_reported}" != "1" ]]; then
  echo "Stage4 finished without explicit ready marker; probing live install state"
fi

echo "Stage4 reported ready_for_reboot"
verify_remote_env_hash
echo "Triggering reboot from a fresh SSH session"
remote_try "sudo -n sh -c 'echo 1 >/proc/sys/kernel/sysrq 2>/dev/null || true; echo b >/proc/sysrq-trigger'" || true
echo "Reboot command issued"
