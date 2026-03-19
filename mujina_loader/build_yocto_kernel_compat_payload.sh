#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PAYLOAD="${SCRIPT_DIR}/payload-stockboot-compat"
OUT_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-compat"
ENV_TEMPLATE="${SCRIPT_DIR}/stock_env_template.txt"
YOCTO_BUILD_VOLUME="${YOCTO_BUILD_VOLUME:-mujina-yocto-build}"
DEPLOY_SUBDIR="${DEPLOY_SUBDIR:-/mnt/tmp-glibc/deploy/images/mujina-s21-aml}"
IMAGE_NAME="${IMAGE_NAME:-Image-mujina-s21-aml.bin}"
DTB_NAME="${DTB_NAME:-axg_s400_antminer.dtb}"
VOLUME_NAME="${VOLUME_NAME:-mujina_rootfs}"
MTD_INDEX="${MTD_INDEX:-6}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

usage() {
  cat <<EOF
Usage:
  ./build_yocto_kernel_compat_payload.sh [options]

Options:
  --yocto-volume NAME     Docker volume with Yocto build state (default: ${YOCTO_BUILD_VOLUME})
  --deploy-subdir PATH    Deploy dir inside the Yocto volume (default: ${DEPLOY_SUBDIR})
  --image-name NAME       Kernel image filename inside deploy dir (default: ${IMAGE_NAME})
  --dtb-name NAME         DTB filename inside deploy dir (default: ${DTB_NAME})
  --out-dir PATH          Output directory (default: ${OUT_PAYLOAD})
  --volume-name NAME      UBI volume name for generated nand_env (default: ${VOLUME_NAME})
  --mtd-index NUM         MTD index for generated nand_env (default: ${MTD_INDEX})
  --help                  Show this message
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
    --yocto-volume) YOCTO_BUILD_VOLUME="${2:-}"; shift 2 ;;
    --deploy-subdir) DEPLOY_SUBDIR="${2:-}"; shift 2 ;;
    --image-name) IMAGE_NAME="${2:-}"; shift 2 ;;
    --dtb-name) DTB_NAME="${2:-}"; shift 2 ;;
    --out-dir) OUT_PAYLOAD="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    --mtd-index) MTD_INDEX="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd python3
need_cmd shasum

[ -f "${BASE_PAYLOAD}/rootfs.tar.gz" ] || die "Missing compat rootfs at ${BASE_PAYLOAD}/rootfs.tar.gz"
[ -f "${ENV_TEMPLATE}" ] || die "Missing env template at ${ENV_TEMPLATE}"

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}/reference"

copy_from_volume() {
  local src_name="$1"
  local dst_name="$2"
  docker run --rm \
    -v "${YOCTO_BUILD_VOLUME}:/mnt:ro" \
    -v "${OUT_PAYLOAD}:/out" \
    "${DOCKER_IMAGE}" \
    bash -lc "cp '${DEPLOY_SUBDIR}/${src_name}' '/out/${dst_name}'"
}

echo "Copying Yocto kernel artifacts into ${OUT_PAYLOAD}"
copy_from_volume "${IMAGE_NAME}" "Image"
copy_from_volume "${DTB_NAME}" "axg_s400_antminer.dtb"
cp "${BASE_PAYLOAD}/rootfs.tar.gz" "${OUT_PAYLOAD}/rootfs.tar.gz"

echo "Generating custom-kernel nand_env.bin"
python3 "${SCRIPT_DIR}/generate_nand_env.py" \
  --template "${ENV_TEMPLATE}" \
  --output "${OUT_PAYLOAD}/nand_env.bin" \
  --boot-mode ubifs-image \
  --volume-name "${VOLUME_NAME}" \
  --mtd-index "${MTD_INDEX}" \
  --dtb-filename "axg_s400_antminer.dtb"

cp "${BASE_PAYLOAD}/reference/"* "${OUT_PAYLOAD}/reference/"

cat > "${OUT_PAYLOAD}/manifest.txt" <<EOF
boot_mode=ubifs-image
boot_source=mtd6:${VOLUME_NAME} via U-Boot ubifsload + booti
kernel_source=yocto:${IMAGE_NAME}
dtb_source=yocto:${DTB_NAME}
rootfs_profile=stock-kernel-compat
rootfs_archive=rootfs.tar.gz
env_blob=nand_env.bin
reference_stock_boot_dump=reference/mtd4_boot_stock.bin.gz
reference_stock_env_dump=reference/nand_env_stock.bin.gz
reference_live_dtb=reference/axg_s400_antminer.dtb
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 Image axg_s400_antminer.dtb rootfs.tar.gz nand_env.bin manifest.txt reference/* > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 2 -type f | sort
