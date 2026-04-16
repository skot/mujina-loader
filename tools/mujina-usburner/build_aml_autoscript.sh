#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV_BIN="${ENV_BIN:-${SCRIPT_DIR}/output/nand_env.bin}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
OUTPUT_SOURCE="${OUTPUT_SOURCE:-${OUTPUT_DIR}/aml_autoscript.txt}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_autoscript}"
ENV_LOAD_ADDR="${ENV_LOAD_ADDR:-0x01300000}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-autoscript.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

verify_inputs() {
  [[ -f "${ENV_BIN}" ]] || die "Missing env blob: ${ENV_BIN}"
  need_cmd docker
  need_cmd mkdir
}

write_source() {
  mkdir -p "${OUTPUT_DIR}"
  cat > "${OUTPUT_SOURCE}" <<EOF
echo "Mujina USB env handoff: trying aml_autoscript"
if usb start 0; then
  if fatload usb 0 ${ENV_LOAD_ADDR} nand_env.bin; then
    echo "Loaded nand_env.bin from usb 0"
    env import -b ${ENV_LOAD_ADDR} \${filesize}
    save
    echo "nand_env imported; resetting"
    reset
  fi
fi
echo "aml_autoscript did not finish handoff; falling through"
EOF
}

build_image() {
  docker run --rm \
    -v "${OUTPUT_DIR}:/work" \
    "${DOCKER_IMAGE}" \
    bash -lc "set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y u-boot-tools >/dev/null
      mkimage -A arm -T script -C none -n 'Mujina USB env handoff' -d /work/$(basename "${OUTPUT_SOURCE}") /work/$(basename "${OUTPUT_IMAGE}") >/dev/null
    "
}

main() {
  verify_inputs
  write_source
  build_image
  echo "Built ${OUTPUT_IMAGE}"
}

main "$@"
