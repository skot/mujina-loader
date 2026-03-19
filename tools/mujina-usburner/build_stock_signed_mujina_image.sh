#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

STOCK_IMAGE="${STOCK_IMAGE:-${ROOT_DIR}/tools/stock_fw_restore/images/aml_upgrade_package_enc.img}"
PACKER="${PACKER:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/aml_image_v2_packer}"
PAYLOAD_DIR="${PAYLOAD_DIR:-${ROOT_DIR}/mujina_loader/mujina_armhf_base}"
ENV_TEMPLATE="${ENV_TEMPLATE:-${ROOT_DIR}/mujina_loader/stock_env_template.txt}"
ENV_GENERATOR="${ENV_GENERATOR:-${ROOT_DIR}/mujina_loader/generate_nand_env.py}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/aml_upgrade_package_mujina_armhf_base.img}"
OUTPUT_ENV_TEXT="${OUTPUT_ENV_TEXT:-${OUTPUT_DIR}/mujina-uboot-env.txt}"
OUTPUT_ENV_BIN="${OUTPUT_ENV_BIN:-${OUTPUT_DIR}/nand_env.bin}"
VOLUME_NAME="${VOLUME_NAME:-mujina_rootfs}"
MTD_INDEX="${MTD_INDEX:-6}"
MIN_IO_SIZE="${MIN_IO_SIZE:-2048}"
SUB_PAGE_SIZE="${SUB_PAGE_SIZE:-2048}"
PEB_SIZE="${PEB_SIZE:-131072}"
PARTITION_SIZE="${PARTITION_SIZE:-0x0b900000}"
UBI_RESERVED_PEBS="${UBI_RESERVED_PEBS:-20}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-usb-burn.XXXXXX")"
UNPACK_DIR="${WORK_DIR}/stock-unpacked"
UBI_WORK_DIR="${WORK_DIR}/ubi"
TEMPLATE_FILE="${SCRIPT_DIR}/ubinize-nvdata.ini.in"
IMAGE_CFG="${UNPACK_DIR}/image.cfg"
NV_PARTITION_NAME="nvdata.PARTITION"
OUTPUT_NV_PARTITION="${OUTPUT_DIR}/${NV_PARTITION_NAME}"

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

partition_size_dec() {
  printf '%d\n' "$((PARTITION_SIZE))"
}

calc_total_pebs() {
  echo "$(( $(partition_size_dec) / PEB_SIZE ))"
}

calc_max_leb_cnt() {
  local total_pebs
  total_pebs="$(calc_total_pebs)"
  if (( total_pebs <= UBI_RESERVED_PEBS + 4 )); then
    die "Reserved PEB count ${UBI_RESERVED_PEBS} is too large for partition size ${PARTITION_SIZE}"
  fi
  echo "$(( total_pebs - UBI_RESERVED_PEBS ))"
}

calc_leb_size() {
  echo "$(( PEB_SIZE - (2 * MIN_IO_SIZE) ))"
}

verify_inputs() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This workflow currently targets macOS hosts"
  [[ -f "${STOCK_IMAGE}" ]] || die "Missing stock image: ${STOCK_IMAGE}"
  [[ -x "${PACKER}" ]] || die "Missing packer: ${PACKER}"
  [[ -d "${PAYLOAD_DIR}" ]] || die "Missing payload dir: ${PAYLOAD_DIR}"
  [[ -f "${PAYLOAD_DIR}/rootfs.tar.gz" ]] || die "Missing payload rootfs: ${PAYLOAD_DIR}/rootfs.tar.gz"
  [[ -f "${ENV_TEMPLATE}" ]] || die "Missing env template: ${ENV_TEMPLATE}"
  [[ -f "${ENV_GENERATOR}" ]] || die "Missing env generator: ${ENV_GENERATOR}"
  [[ -f "${TEMPLATE_FILE}" ]] || die "Missing ubinize template: ${TEMPLATE_FILE}"
  need_cmd docker
  need_cmd shasum
  need_cmd sed
  need_cmd python3
}

build_nvdata_partition() {
  local max_leb_cnt leb_size
  max_leb_cnt="$(calc_max_leb_cnt)"
  leb_size="$(calc_leb_size)"

  mkdir -p "${UBI_WORK_DIR}" "${OUTPUT_DIR}"
  sed \
    -e "s,@UBIFS_IMAGE@,/work/mujina_rootfs.ubifs,g" \
    -e "s,@VOLUME_NAME@,${VOLUME_NAME},g" \
    "${TEMPLATE_FILE}" > "${UBI_WORK_DIR}/ubinize.ini"

  docker run --rm \
    -v "${PAYLOAD_DIR}:/input:ro" \
    -v "${UBI_WORK_DIR}:/work" \
    "${DOCKER_IMAGE}" \
    bash -lc "set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y mtd-utils python3 >/dev/null
      mkdir -p /work/rootfs
      python3 - <<'PY'
import tarfile

with tarfile.open('/input/rootfs.tar.gz', 'r:gz') as tar:
    tar.extractall('/work/rootfs')
PY
      mkfs.ubifs \
        -r /work/rootfs \
        -m ${MIN_IO_SIZE} \
        -e ${leb_size} \
        -c ${max_leb_cnt} \
        -F \
        -o /work/mujina_rootfs.ubifs >/dev/null
      ubinize \
        -m ${MIN_IO_SIZE} \
        -p ${PEB_SIZE} \
        -s ${SUB_PAGE_SIZE} \
        -o /work/${NV_PARTITION_NAME} \
        /work/ubinize.ini >/dev/null
    "

  cp "${UBI_WORK_DIR}/${NV_PARTITION_NAME}" "${OUTPUT_NV_PARTITION}"
}

patch_image_cfg() {
  [[ -f "${IMAGE_CFG}" ]] || die "Missing unpacked image.cfg at ${IMAGE_CFG}"
  if rg -q 'sub_type="nvdata"' "${IMAGE_CFG}"; then
    echo "image.cfg already contains nvdata partition entry"
    return
  fi
  cat >> "${IMAGE_CFG}" <<EOF
file="${NV_PARTITION_NAME}"		main_type="PARTITION"		sub_type="nvdata"	file_type="normal"
EOF
}

generate_env_artifacts() {
  python3 "${ENV_GENERATOR}" \
    --template "${ENV_TEMPLATE}" \
    --output "${OUTPUT_ENV_BIN}" \
    --boot-mode stock-boot \
    --volume-name "${VOLUME_NAME}" \
    --mtd-index "${MTD_INDEX}"

  cat > "${OUTPUT_ENV_TEXT}" <<EOF
setenv mujinaboot 'run storeargs; setenv bootargs \${bootargs} root=ubi0:${VOLUME_NAME} rootfstype=ubifs rw ubi.mtd=${MTD_INDEX},2048 init=/sbin/init skip_initramfs; if imgread kernel \${boot_part} \${loadaddr}; then bootm \${loadaddr}; fi'
setenv bootcmd 'run mujinaboot || run storeboot'
save
EOF
}

repack_image() {
  mkdir -p "${OUTPUT_DIR}"
  rm -f "${OUTPUT_IMAGE}"
  "${PACKER}" -r "${IMAGE_CFG}" "${UNPACK_DIR}" "${OUTPUT_IMAGE}" >/dev/null
  "${PACKER}" -c "${OUTPUT_IMAGE}" >/dev/null
}

write_manifest() {
  cat > "${OUTPUT_DIR}/manifest.txt" <<EOF
base_image=${STOCK_IMAGE}
payload_dir=${PAYLOAD_DIR}
boot_mode=stock-boot
boot_source=mtd4:boot via imgread kernel \${boot_part} \${loadaddr}; bootm \${loadaddr}
rootfs_partition=nvdata (mtd${MTD_INDEX})
rootfs_volume=${VOLUME_NAME}
partition_size=${PARTITION_SIZE}
peb_size=${PEB_SIZE}
min_io_size=${MIN_IO_SIZE}
sub_page_size=${SUB_PAGE_SIZE}
max_leb_cnt=$(calc_max_leb_cnt)
nvdata_partition_file=${NV_PARTITION_NAME}
env_text_file=$(basename "${OUTPUT_ENV_TEXT}")
env_bin_file=$(basename "${OUTPUT_ENV_BIN}")
EOF

  (
    cd "${OUTPUT_DIR}"
    shasum -a 256 \
      "$(basename "${OUTPUT_IMAGE}")" \
      "${NV_PARTITION_NAME}" \
      "$(basename "${OUTPUT_ENV_TEXT}")" \
      "$(basename "${OUTPUT_ENV_BIN}")" \
      manifest.txt > SHA256SUMS
  )
}

validate_output_layout() {
  local validate_dir
  validate_dir="${WORK_DIR}/validate"
  mkdir -p "${validate_dir}"
  "${PACKER}" -d "${OUTPUT_IMAGE}" "${validate_dir}" >/dev/null
  rg -q 'sub_type="nvdata"' "${validate_dir}/image.cfg" || die "Repacked image is missing nvdata entry"
  [[ -f "${validate_dir}/${NV_PARTITION_NAME}" ]] || die "Repacked image is missing ${NV_PARTITION_NAME}"
}

clean_output_dir() {
  mkdir -p "${OUTPUT_DIR}"
  rm -f \
    "${OUTPUT_DIR}"/aml_upgrade_package_mujina_*.img \
    "${OUTPUT_DIR}/${NV_PARTITION_NAME}" \
    "${OUTPUT_DIR}/mujina-uboot-env.txt" \
    "${OUTPUT_DIR}/nand_env.bin" \
    "${OUTPUT_DIR}/manifest.txt" \
    "${OUTPUT_DIR}/SHA256SUMS"
}

main() {
  verify_inputs
  mkdir -p "${UNPACK_DIR}"
  clean_output_dir

  echo "Unpacking stock signed image..."
  "${PACKER}" -d "${STOCK_IMAGE}" "${UNPACK_DIR}" >/dev/null

  echo "Building Mujina nvdata UBI image..."
  build_nvdata_partition
  cp "${OUTPUT_NV_PARTITION}" "${UNPACK_DIR}/${NV_PARTITION_NAME}"

  echo "Patching image.cfg with nvdata partition..."
  patch_image_cfg

  echo "Generating Mujina boot env artifacts..."
  generate_env_artifacts

  echo "Repacking stock-signed Mujina image..."
  repack_image

  echo "Validating repacked image layout..."
  validate_output_layout

  write_manifest

  echo "Built ${OUTPUT_IMAGE}"
  echo "Artifacts:"
  find "${OUTPUT_DIR}" -maxdepth 1 -type f | sort
}

main "$@"
