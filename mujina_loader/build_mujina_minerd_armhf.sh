#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MUJINA_DIR="${MUJINA_DIR:-${WORKSPACE_ROOT}/mujina}"
OUTPUT_BIN="${OUTPUT_BIN:-${SCRIPT_DIR}/output/mujina-minerd-armhf}"
DOCKER_IMAGE="${DOCKER_IMAGE:-messense/rust-musl-cross:armv7-musleabihf}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
GNU_TARGET="${GNU_TARGET:-armv7-unknown-linux-gnueabihf}"
MUSL_TARGET="${MUSL_TARGET:-armv7-unknown-linux-musleabihf}"

usage() {
  cat <<EOF
Usage:
  ./build_mujina_minerd_armhf.sh [options]

Options:
  --mujina-dir PATH   Mujina repo path (default: ${MUJINA_DIR})
  --out PATH          Output binary path (default: ${OUTPUT_BIN})
  --help              Show this message

Build methods:
  1. Docker cross-build to ${MUSL_TARGET} (preferred)
  2. cargo-zigbuild to ${MUSL_TARGET} (fallback)
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
    --mujina-dir) MUJINA_DIR="${2:-}"; shift 2 ;;
    --out) OUTPUT_BIN="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -d "${MUJINA_DIR}" ]] || die "Missing Mujina repo: ${MUJINA_DIR}"
[[ -f "${MUJINA_DIR}/Cargo.toml" ]] || die "Missing Cargo.toml in ${MUJINA_DIR}"
[[ -d "${MUJINA_DIR}/../amlogic-cb-tools" ]] || die "Missing sibling amlogic-cb-tools repo at ${MUJINA_DIR}/../amlogic-cb-tools"

mkdir -p "$(dirname "${OUTPUT_BIN}")"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm \
    --platform "${DOCKER_PLATFORM}" \
    -v "${WORKSPACE_ROOT}:/work" \
    -w /work/mujina \
    "${DOCKER_IMAGE}" \
    bash -lc "set -euo pipefail; cargo build --release --bin mujina-minerd --target ${MUSL_TARGET} --no-default-features"

  cp "${MUJINA_DIR}/target/${MUSL_TARGET}/release/mujina-minerd" "${OUTPUT_BIN}"
  chmod 0755 "${OUTPUT_BIN}"
  echo "Built ${OUTPUT_BIN} via Docker (${MUSL_TARGET})"
  exit 0
fi

if command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
  need_cmd rustup

  (
    cd "${MUJINA_DIR}"
    rustup target add "${MUSL_TARGET}" >/dev/null
    cargo-zigbuild --release --bin mujina-minerd --target "${MUSL_TARGET}" --no-default-features
  )

  cp "${MUJINA_DIR}/target/${MUSL_TARGET}/release/mujina-minerd" "${OUTPUT_BIN}"
  chmod 0755 "${OUTPUT_BIN}"
  echo "Built ${OUTPUT_BIN} via cargo-zigbuild (${MUSL_TARGET})"
  exit 0
fi

die "No supported cross-build path available. Start Docker Desktop for the repo's preferred build path, or install both zig and cargo-zigbuild for the musl fallback."
