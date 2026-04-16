#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

STOCK_IMAGE="${STOCK_IMAGE:-${ROOT_DIR}/tools/stock_fw_restore/images/aml_upgrade_package_enc.img}"
PACKER="${PACKER:-${ROOT_DIR}/tools/stock_fw_restore/tools/macos/aml_image_v2_packer}"
ENV_BIN="${ENV_BIN:-${SCRIPT_DIR}/output/nand_env.bin}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${OUTPUT_DIR}/recovery.img}"
OUTPUT_MANIFEST="${OUTPUT_MANIFEST:-${OUTPUT_DIR}/recovery-helper-manifest.txt}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-recovery-helper.XXXXXX")"
UNPACK_DIR="${WORK_DIR}/stock-unpacked"
RAMDISK_ROOT="${WORK_DIR}/ramdisk-root"

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
  [[ "$(uname -s)" == "Darwin" ]] || die "This workflow currently targets macOS hosts"
  [[ -f "${STOCK_IMAGE}" ]] || die "Missing stock image: ${STOCK_IMAGE}"
  [[ -x "${PACKER}" ]] || die "Missing packer: ${PACKER}"
  [[ -f "${ENV_BIN}" ]] || die "Missing env blob: ${ENV_BIN}"
  need_cmd docker
  need_cmd mkdir
  need_cmd cp
}

extract_stock_boot() {
  mkdir -p "${UNPACK_DIR}"
  "${PACKER}" -d "${STOCK_IMAGE}" "${UNPACK_DIR}" >/dev/null
  [[ -f "${UNPACK_DIR}/boot.PARTITION" ]] || die "Stock image did not unpack boot.PARTITION"
}

prepare_ramdisk() {
  mkdir -p \
    "${RAMDISK_ROOT}/bin" \
    "${RAMDISK_ROOT}/dev" \
    "${RAMDISK_ROOT}/etc/mujina" \
    "${RAMDISK_ROOT}/proc" \
    "${RAMDISK_ROOT}/sys" \
    "${RAMDISK_ROOT}/run" \
    "${RAMDISK_ROOT}/sbin"

  cp "${ENV_BIN}" "${RAMDISK_ROOT}/etc/mujina/nand_env.bin"

  cat > "${RAMDISK_ROOT}/sbin/init" <<'EOF'
#!/bin/busybox sh
set -eu

export PATH=/bin:/sbin

log() {
  echo "[mujina-recovery-helper] $*"
}

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
[ -c /dev/console ] || mknod /dev/console c 5 1
[ -c /dev/null ] || mknod /dev/null c 1 3
mount -t proc proc /proc
mount -t sysfs sysfs /sys

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -e /dev/nand_env ] && break
  sleep 1
done

if [ ! -e /dev/nand_env ]; then
  log "/dev/nand_env not found"
  exec /bin/busybox sh
fi

log "Writing embedded staging nand_env"
dd if=/etc/mujina/nand_env.bin of=/dev/nand_env bs=65536 count=1 conv=fsync
sync
log "nand_env written; rebooting"
/bin/busybox reboot -f || exec /bin/busybox sh
sleep 5
log "reboot returned unexpectedly"
exec /bin/busybox sh
EOF
  chmod 0755 "${RAMDISK_ROOT}/sbin/init"
}

build_image() {
  mkdir -p "${OUTPUT_DIR}"
  docker run --rm \
    -v "${UNPACK_DIR}:/input:ro" \
    -v "${RAMDISK_ROOT}:/ramdisk" \
    -v "${OUTPUT_DIR}:/output" \
    "${DOCKER_IMAGE}" \
    bash -lc "set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y abootimg busybox-static cpio gzip >/dev/null
      work=\$(mktemp -d)
      cp /input/boot.PARTITION \"\$work/boot.PARTITION\"
      cd \"\$work\"
      abootimg -x boot.PARTITION >/dev/null
      cp /bin/busybox \"\$work/busybox\"
      install -m 0755 \"\$work/busybox\" /ramdisk/bin/busybox
      (
        cd /ramdisk
        find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > \"\$work/initrd.img\"
      )
      abootimg --create /output/$(basename "${OUTPUT_IMAGE}") -f bootimg.cfg -k zImage -r initrd.img -s stage2.img >/dev/null
      rm -rf \"\$work\"
    "
}

write_manifest() {
  cat > "${OUTPUT_MANIFEST}" <<EOF
base_image=${STOCK_IMAGE}
kernel_source=stock boot.PARTITION
embedded_env=$(basename "${ENV_BIN}")
helper_image=$(basename "${OUTPUT_IMAGE}")
purpose=write staging nand_env from ramdisk and reboot
EOF
}

main() {
  verify_inputs
  extract_stock_boot
  prepare_ramdisk
  build_image
  write_manifest
  echo "Built ${OUTPUT_IMAGE}"
}

main "$@"
