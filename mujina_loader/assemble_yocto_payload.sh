#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PAYLOAD_DIR="${SCRIPT_DIR}/payload"
YOCTO_VOLUME="${YOCTO_VOLUME:-mujina-yocto-build}"
DEPLOY_SUBDIR="${DEPLOY_SUBDIR:-/mnt/tmp-glibc/deploy/images/mujina-s21-aml}"
IMAGE_NAME="${IMAGE_NAME:-Image-mujina-s21-aml.bin}"
DTB_NAME="${DTB_NAME:-axg_s400_antminer.dtb}"
ROOTFS_NAME="${ROOTFS_NAME:-mujina-image-dev-mujina-s21-aml.rootfs.tar.gz}"
ENV_TEMPLATE="${SCRIPT_DIR}/stock_env_template.txt"
ENV_BLOB="${PAYLOAD_DIR}/nand_env.bin"
VOLUME_NAME="${VOLUME_NAME:-mujina_rootfs}"

usage() {
  cat <<EOF
Usage:
  ./assemble_yocto_payload.sh [options]

Options:
  --payload-dir PATH      Output directory (default: ${PAYLOAD_DIR})
  --yocto-volume NAME     Docker volume with Yocto build state (default: ${YOCTO_VOLUME})
  --deploy-subdir PATH    Deploy dir inside the Yocto volume (default: ${DEPLOY_SUBDIR})
  --image-name NAME       Kernel image filename inside deploy dir (default: ${IMAGE_NAME})
  --dtb-name NAME         DTB filename inside deploy dir (default: ${DTB_NAME})
  --rootfs-name NAME      Rootfs tarball filename inside deploy dir (default: ${ROOTFS_NAME})
  --volume-name NAME      UBI volume name for generated nand_env (default: ${VOLUME_NAME})
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
    --payload-dir) PAYLOAD_DIR="${2:-}"; ENV_BLOB="${PAYLOAD_DIR}/nand_env.bin"; shift 2 ;;
    --yocto-volume) YOCTO_VOLUME="${2:-}"; shift 2 ;;
    --deploy-subdir) DEPLOY_SUBDIR="${2:-}"; shift 2 ;;
    --image-name) IMAGE_NAME="${2:-}"; shift 2 ;;
    --dtb-name) DTB_NAME="${2:-}"; shift 2 ;;
    --rootfs-name) ROOTFS_NAME="${2:-}"; shift 2 ;;
    --volume-name) VOLUME_NAME="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd python3
[[ -f "${ENV_TEMPLATE}" ]] || die "Missing env template: ${ENV_TEMPLATE}"

mkdir -p "${PAYLOAD_DIR}"

copy_from_volume() {
  local src_name="$1"
  local dst_path="$2"
  docker run --rm \
    -v "${YOCTO_VOLUME}:/mnt:ro" \
    -v "${PAYLOAD_DIR}:/out" \
    ubuntu:22.04 \
    bash -lc "cp '${DEPLOY_SUBDIR}/${src_name}' '/out/${dst_path}'"
}

echo "Exporting Yocto artifacts into ${PAYLOAD_DIR}"
copy_from_volume "${IMAGE_NAME}" "Image"
copy_from_volume "${DTB_NAME}" "axg_s400_antminer.dtb"
copy_from_volume "${ROOTFS_NAME}" "rootfs.tar.gz"

echo "Generating nand_env.bin"
python3 "${SCRIPT_DIR}/generate_nand_env.py" \
  --template "${ENV_TEMPLATE}" \
  --output "${ENV_BLOB}" \
  --volume-name "${VOLUME_NAME}"

echo "Writing manifest and checksums"
cat > "${PAYLOAD_DIR}/manifest.txt" <<EOF
Image=Image
DTB=axg_s400_antminer.dtb
Rootfs=rootfs.tar.gz
Env=nand_env.bin
SourceVolume=${YOCTO_VOLUME}
SourceDeploy=${DEPLOY_SUBDIR}
UBIVolume=${VOLUME_NAME}
EOF

(cd "${PAYLOAD_DIR}" && shasum -a 256 Image axg_s400_antminer.dtb rootfs.tar.gz nand_env.bin > SHA256SUMS)

echo "Payload ready in ${PAYLOAD_DIR}"
