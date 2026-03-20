#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
CONFIG_PATH="${CONFIG_PATH:-${SCRIPT_DIR}/Antminer-4.9.241.config}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"
DOCKER_VOLUME="${DOCKER_VOLUME:-mujina-kernel-4_9-src}"
KERNEL_GIT_URL="${KERNEL_GIT_URL:-https://github.com/LineageOS/android_kernel_amlogic_linux-4.9.git}"
KERNEL_GIT_REF="${KERNEL_GIT_REF:-lineage-20}"
ARTIFACT_BASENAME="${ARTIFACT_BASENAME:-Image-mujina-custom}"
LOCALVERSION_VALUE="${LOCALVERSION_VALUE:--mujina-custom}"

usage() {
  cat <<EOF
Usage:
  ./build_custom_kernel.sh [options]

Builds an arm64 Amlogic 4.9 kernel in Docker using:
  ${CONFIG_PATH}

Default outputs:
  ${OUTPUT_DIR}/${ARTIFACT_BASENAME}
  ${OUTPUT_DIR}/${ARTIFACT_BASENAME}.sha256
  ${OUTPUT_DIR}/.config.final
  ${OUTPUT_DIR}/olddefconfig.log
  ${OUTPUT_DIR}/build.log

Options:
  --config PATH          Baseline kernel config
  --out-dir PATH         Output directory
  --artifact NAME        Kernel image filename
  --localversion STR     CONFIG_LOCALVERSION override
  --git-url URL          Kernel source git URL
  --git-ref REF          Kernel source git ref/branch/tag
  --help                 Show this message
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
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    --out-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    --artifact) ARTIFACT_BASENAME="${2:-}"; shift 2 ;;
    --localversion) LOCALVERSION_VALUE="${2:-}"; shift 2 ;;
    --git-url) KERNEL_GIT_URL="${2:-}"; shift 2 ;;
    --git-ref) KERNEL_GIT_REF="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd shasum

[[ -f "${CONFIG_PATH}" ]] || die "Missing config: ${CONFIG_PATH}"
mkdir -p "${OUTPUT_DIR}"

docker run --rm \
  -v "${SCRIPT_DIR}:/work/kernel_build" \
  -v "${CONFIG_PATH}:/tmp/baseline.config:ro" \
  -v "${DOCKER_VOLUME}:/src" \
  "${DOCKER_IMAGE}" \
  bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates flex git kmod libelf-dev \
      libncurses-dev libssl-dev make perl python3 rsync \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross xz-utils >/dev/null

    if [[ ! -d /src/linux/.git ]]; then
      git clone --branch '${KERNEL_GIT_REF}' --single-branch '${KERNEL_GIT_URL}' /src/linux >/dev/null 2>&1
    fi

    cd /src/linux
    cp /tmp/baseline.config .config

    python3 - <<'PY'
from pathlib import Path
cfg = Path('.config')
lines = cfg.read_text().splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('CONFIG_LOCALVERSION='):
        out.append('CONFIG_LOCALVERSION=\"${LOCALVERSION_VALUE}\"')
        seen = True
    else:
        out.append(line)
if not seen:
    out.append('CONFIG_LOCALVERSION=\"${LOCALVERSION_VALUE}\"')
cfg.write_text('\\n'.join(out) + '\\n')
PY

    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig \
      > /work/kernel_build/output/olddefconfig.log 2>&1

    make -j\"\$(nproc)\" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      KCFLAGS=-Wno-error Image \
      > /work/kernel_build/output/build.log 2>&1

    cp arch/arm64/boot/Image /work/kernel_build/output/${ARTIFACT_BASENAME}
    cp .config /work/kernel_build/output/.config.final
  "

(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "${ARTIFACT_BASENAME}" > "${ARTIFACT_BASENAME}.sha256"
)

echo "Build complete."
echo "Image: ${OUTPUT_DIR}/${ARTIFACT_BASENAME}"
echo "Config: ${OUTPUT_DIR}/.config.final"
echo "Logs: ${OUTPUT_DIR}/olddefconfig.log and ${OUTPUT_DIR}/build.log"
