#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/boot.PARTITION}"
OUTPUT_MANIFEST="${OUTPUT_MANIFEST:-${OUTPUT_DIR}/boot-helper-manifest.txt}"

OUTPUT_IMAGE="${OUTPUT_IMAGE}" \
OUTPUT_MANIFEST="${OUTPUT_MANIFEST}" \
exec "${SCRIPT_DIR}/build_recovery_handoff_image.sh" "$@"
