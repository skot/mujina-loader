#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export OUT_PAYLOAD="${OUT_PAYLOAD:-${SCRIPT_DIR}/mujina_armhf_base}"
export HOSTNAME_VALUE="${HOSTNAME_VALUE:-mujina-s21-aml}"
export PROFILE_NAME="${PROFILE_NAME:-Mujina armhf base userspace}"
export VERSION_VALUE="${VERSION_VALUE:-0.3.0 (armhf-base)}"
export VERSION_ID_VALUE="${VERSION_ID_VALUE:-0.3.0}"
export ENABLE_SSH="${ENABLE_SSH:-1}"
export ENABLE_TELNET="${ENABLE_TELNET:-0}"
export ENABLE_HTTP="${ENABLE_HTTP:-0}"

exec "${SCRIPT_DIR}/build_armhf_full_payload.sh" "$@"
