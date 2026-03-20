#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE_PAYLOAD_DIR="${BASE_PAYLOAD_DIR:-${ROOT_DIR}/mujina_loader/mujina_armhf_base}"
KERNEL_IMAGE="${KERNEL_IMAGE:-${SCRIPT_DIR}/output/Image-mujina-custom}"
DTB_PATH="${DTB_PATH:-${SCRIPT_DIR}/reference/axg_s400_antminer.usb-host-nand-clocks.dtb}"
ENV_TEMPLATE="${ENV_TEMPLATE:-${ROOT_DIR}/mujina_loader/stock_env_template.txt}"
ENV_GENERATOR="${ENV_GENERATOR:-${ROOT_DIR}/mujina_loader/generate_nand_env.py}"
OUT_DIR="${OUT_DIR:-${SCRIPT_DIR}/output/mujina_armhf_custom_kernel}"
VOLUME_NAME="${VOLUME_NAME:-mujina_rootfs}"
MTD_INDEX="${MTD_INDEX:-6}"

usage() {
  cat <<EOF
Usage:
  ./build_custom_kernel_payload.sh [options]

Options:
  --base-payload-dir PATH  Base Mujina payload dir (default: ${BASE_PAYLOAD_DIR})
  --kernel-image PATH      Custom kernel Image (default: ${KERNEL_IMAGE})
  --dtb PATH               Companion DTB (default: ${DTB_PATH})
  --out-dir PATH           Output payload dir (default: ${OUT_DIR})
  --volume-name NAME       UBI rootfs volume name (default: ${VOLUME_NAME})
  --mtd-index N            MTD index for the rootfs volume (default: ${MTD_INDEX})
  --help                   Show this message
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
    --base-payload-dir) BASE_PAYLOAD_DIR="${2:-}"; shift 2 ;;
    --kernel-image) KERNEL_IMAGE="${2:-}"; shift 2 ;;
    --dtb) DTB_PATH="${2:-}"; shift 2 ;;
    --out-dir) OUT_DIR="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    --mtd-index) MTD_INDEX="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd python3
need_cmd shasum

[[ -f "${BASE_PAYLOAD_DIR}/rootfs.tar.gz" ]] || die "Missing base rootfs archive: ${BASE_PAYLOAD_DIR}/rootfs.tar.gz"
[[ -f "${KERNEL_IMAGE}" ]] || die "Missing kernel image: ${KERNEL_IMAGE}"
[[ -f "${DTB_PATH}" ]] || die "Missing DTB: ${DTB_PATH}"
[[ -f "${ENV_TEMPLATE}" ]] || die "Missing env template: ${ENV_TEMPLATE}"
[[ -f "${ENV_GENERATOR}" ]] || die "Missing env generator: ${ENV_GENERATOR}"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

cp "${BASE_PAYLOAD_DIR}/rootfs.tar.gz" "${OUT_DIR}/rootfs.tar.gz"
cp "${KERNEL_IMAGE}" "${OUT_DIR}/Image"
cp "${DTB_PATH}" "${OUT_DIR}/$(basename "${DTB_PATH}")"

python3 "${ENV_GENERATOR}" \
  --template "${ENV_TEMPLATE}" \
  --output "${OUT_DIR}/nand_env.bin" \
  --boot-mode ubifs-image \
  --volume-name "${VOLUME_NAME}" \
  --mtd-index "${MTD_INDEX}" \
  --dtb-filename "$(basename "${DTB_PATH}")"

cat > "${OUT_DIR}/manifest.txt" <<EOF
boot_mode=ubifs-image
kernel_image=Image
dtb_file=$(basename "${DTB_PATH}")
rootfs_archive=rootfs.tar.gz
env_blob=nand_env.bin
base_payload_dir=${BASE_PAYLOAD_DIR}
volume_name=${VOLUME_NAME}
mtd_index=${MTD_INDEX}
EOF

(
  cd "${OUT_DIR}"
  shasum -a 256 rootfs.tar.gz Image "$(basename "${DTB_PATH}")" nand_env.bin manifest.txt > SHA256SUMS
)

echo "Built ${OUT_DIR}"
echo "Artifacts:"
find "${OUT_DIR}" -maxdepth 1 -type f | sort
