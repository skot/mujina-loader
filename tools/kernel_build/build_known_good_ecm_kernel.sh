#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${SCRIPT_DIR}/Antminer-4.9.241.ecm-minimal.config}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
ARTIFACT_BASENAME="${ARTIFACT_BASENAME:-Image-mujina-ecm-minimal}"
FINAL_CONFIG_NAME="${FINAL_CONFIG_NAME:-.config.ecm-minimal.final}"
LOCALVERSION_VALUE="${LOCALVERSION_VALUE:--v2023.11.1-u0-58-g9f143660-ecm-minimal}"
KERNEL_GIT_URL="${KERNEL_GIT_URL:-https://github.com/LineageOS/android_kernel_amlogic_linux-4.9.git}"
KERNEL_GIT_REF="${KERNEL_GIT_REF:-lineage-20}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

usage() {
  cat <<EOF
Usage:
  ./build_known_good_ecm_kernel.sh

Build the GT Touch ECM experiment kernel from a clean source checkout every run.

This path is intentionally strict:
  - starts from ${CONFIG_PATH}
  - clones the kernel into a fresh temporary directory inside Docker
  - sets only the requested localversion override
  - explicitly forces broader USB-net and wireless symbols off after olddefconfig
  - fails if the final .config does not match the ECM-only expectations

Required final options:
  CONFIG_USB_NET_DRIVERS=y
  CONFIG_USB_USBNET=y
  CONFIG_USB_NET_CDCETHER=y

Forbidden final options:
  CONFIG_USB_NET_CDC_EEM
  CONFIG_USB_NET_CDC_NCM
  CONFIG_USB_NET_RNDIS_HOST
  CONFIG_WLAN
  CONFIG_CFG80211
  CONFIG_RFKILL

Outputs:
  ${OUTPUT_DIR}/${ARTIFACT_BASENAME}
  ${OUTPUT_DIR}/${ARTIFACT_BASENAME}.sha256
  ${OUTPUT_DIR}/${FINAL_CONFIG_NAME}
  ${OUTPUT_DIR}/olddefconfig-ecm-minimal.log
  ${OUTPUT_DIR}/build-ecm-minimal.log
  ${OUTPUT_DIR}/ecm-minimal-build-manifest.txt
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

need_cmd docker
need_cmd shasum

[[ -f "${CONFIG_PATH}" ]] || die "Missing config: ${CONFIG_PATH}"
mkdir -p "${OUTPUT_DIR}"
rm -f \
  "${OUTPUT_DIR}/${ARTIFACT_BASENAME}" \
  "${OUTPUT_DIR}/${ARTIFACT_BASENAME}.sha256" \
  "${OUTPUT_DIR}/${FINAL_CONFIG_NAME}" \
  "${OUTPUT_DIR}/olddefconfig-ecm-minimal.log" \
  "${OUTPUT_DIR}/build-ecm-minimal.log" \
  "${OUTPUT_DIR}/ecm-minimal-build-manifest.txt"

docker run --rm \
  -v "${SCRIPT_DIR}:/work/kernel_build" \
  -v "${CONFIG_PATH}:/tmp/baseline.config:ro" \
  "${DOCKER_IMAGE}" \
  bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates flex git kmod libelf-dev \
      libncurses-dev libssl-dev make perl python3 rsync \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross xz-utils >/dev/null

    tmpdir=\$(mktemp -d)
    trap 'rm -rf \"\$tmpdir\"' EXIT
    git clone --depth 1 --branch '${KERNEL_GIT_REF}' --single-branch '${KERNEL_GIT_URL}' \"\$tmpdir/linux\" >/dev/null 2>&1

    cd \"\$tmpdir/linux\"
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
      > /work/kernel_build/output/olddefconfig-ecm-minimal.log 2>&1

    python3 - <<'PY'
from pathlib import Path

cfg = Path('.config')
lines = cfg.read_text().splitlines()

force_on = {
    'CONFIG_USB_NET_DRIVERS',
    'CONFIG_USB_USBNET',
    'CONFIG_USB_NET_CDCETHER',
}
force_off = {
    'CONFIG_USB_NET_CDC_EEM',
    'CONFIG_USB_NET_CDC_NCM',
    'CONFIG_USB_NET_RNDIS_HOST',
    'CONFIG_WLAN',
    'CONFIG_CFG80211',
    'CONFIG_RFKILL',
}

seen = set()
out = []
for line in lines:
    replaced = False
    for key in force_on:
        if line.startswith(f'{key}=') or line == f'# {key} is not set':
            out.append(f'{key}=y')
            seen.add(key)
            replaced = True
            break
    if replaced:
        continue
    for key in force_off:
        if line.startswith(f'{key}=') or line == f'# {key} is not set':
            out.append(f'# {key} is not set')
            seen.add(key)
            replaced = True
            break
    if not replaced:
        out.append(line)

for key in sorted(force_on):
    if key not in seen:
        out.append(f'{key}=y')
for key in sorted(force_off):
    if key not in seen:
        out.append(f'# {key} is not set')

cfg.write_text('\\n'.join(out) + '\\n')
PY

    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig \
      >> /work/kernel_build/output/olddefconfig-ecm-minimal.log 2>&1

    python3 - <<'PY'
from pathlib import Path
import sys

cfg = Path('.config').read_text().splitlines()
values = {}
for line in cfg:
    if line.startswith('CONFIG_') and '=' in line:
        key, value = line.split('=', 1)
        values[key] = value
    elif line.startswith('# CONFIG_') and line.endswith(' is not set'):
        key = line[2:-11]
        values[key] = 'n'

required = {
    'CONFIG_USB_NET_DRIVERS': 'y',
    'CONFIG_USB_USBNET': 'y',
    'CONFIG_USB_NET_CDCETHER': 'y',
}
forbidden = [
    'CONFIG_USB_NET_CDC_EEM',
    'CONFIG_USB_NET_CDC_NCM',
    'CONFIG_USB_NET_RNDIS_HOST',
    'CONFIG_WLAN',
    'CONFIG_CFG80211',
    'CONFIG_RFKILL',
]

problems = []
for key, expected in required.items():
    actual = values.get(key, 'missing')
    if actual != expected:
        problems.append(f'{key} expected {expected} but found {actual}')
for key in forbidden:
    actual = values.get(key, 'n')
    if actual != 'n':
        problems.append(f'{key} expected n but found {actual}')

if problems:
    for problem in problems:
        print(problem, file=sys.stderr)
    raise SystemExit(1)
PY

    cp .config /work/kernel_build/output/${FINAL_CONFIG_NAME}

    make -j\"\$(nproc)\" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
      KCFLAGS=-Wno-error Image \
      > /work/kernel_build/output/build-ecm-minimal.log 2>&1

    cp arch/arm64/boot/Image /work/kernel_build/output/${ARTIFACT_BASENAME}

    cat > /work/kernel_build/output/ecm-minimal-build-manifest.txt <<EOF
git_url=${KERNEL_GIT_URL}
git_ref=${KERNEL_GIT_REF}
config_path=${CONFIG_PATH}
artifact=${ARTIFACT_BASENAME}
final_config=${FINAL_CONFIG_NAME}
localversion=${LOCALVERSION_VALUE}
required=CONFIG_USB_NET_DRIVERS,CONFIG_USB_USBNET,CONFIG_USB_NET_CDCETHER
forbidden=CONFIG_USB_NET_CDC_EEM,CONFIG_USB_NET_CDC_NCM,CONFIG_USB_NET_RNDIS_HOST,CONFIG_WLAN,CONFIG_CFG80211,CONFIG_RFKILL
EOF
  "

(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "${ARTIFACT_BASENAME}" > "${ARTIFACT_BASENAME}.sha256"
)

echo "Build complete."
echo "Image: ${OUTPUT_DIR}/${ARTIFACT_BASENAME}"
echo "Config: ${OUTPUT_DIR}/${FINAL_CONFIG_NAME}"
echo "Logs: ${OUTPUT_DIR}/olddefconfig-ecm-minimal.log and ${OUTPUT_DIR}/build-ecm-minimal.log"
