#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PAYLOAD="${SCRIPT_DIR}/payload-stockboot"
OUT_PAYLOAD="${SCRIPT_DIR}/payload-stockboot-compat"
OVERLAY_DIR="${SCRIPT_DIR}/rootfs_overlays/stock-kernel-compat"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-stockboot-compat.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/rootfs"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

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

[ -f "${BASE_PAYLOAD}/rootfs.tar.gz" ] || die "Missing base rootfs at ${BASE_PAYLOAD}/rootfs.tar.gz"
[ -f "${BASE_PAYLOAD}/nand_env.bin" ] || die "Missing base env at ${BASE_PAYLOAD}/nand_env.bin"
[ -d "${OVERLAY_DIR}" ] || die "Missing overlay directory ${OVERLAY_DIR}"

need_cmd docker
need_cmd tar
need_cmd shasum

mkdir -p "${ROOTFS_DIR}"
tar -xzf "${BASE_PAYLOAD}/rootfs.tar.gz" -C "${ROOTFS_DIR}"

# Overlay the first-pass stock-kernel compatibility tweaks.
cp -R "${OVERLAY_DIR}/." "${ROOTFS_DIR}/"

# Keep the archive compatible with the stock BusyBox tar extractor by pruning
# long-link CA bundle entries that require GNU tar extensions.
rm -rf \
  "${ROOTFS_DIR}/usr/share/ca-certificates" \
  "${ROOTFS_DIR}/etc/ca-certificates.conf" \
  "${ROOTFS_DIR}/etc/ssl/certs"

# The UBIFS root is writable, so mask volatile/tmpfs remount behavior that is
# tripping emergency mode on the vendor 4.9 kernel.
mkdir -p "${ROOTFS_DIR}/etc/systemd/system"
for unit in \
  tmp.mount \
  var-volatile.mount \
  var-volatile-cache.service \
  var-volatile-lib.service \
  var-volatile-spool.service \
  var-volatile-srv.service \
  systemd-remount-fs.service \
  systemd-vconsole-setup.service \
  dev-mqueue.mount \
  sys-kernel-debug.mount \
  sys-kernel-tracing.mount \
  sys-fs-fuse-connections.mount \
  sys-kernel-config.mount
do
  ln -sfn /dev/null "${ROOTFS_DIR}/etc/systemd/system/${unit}"
done

# Create the common mountpoints explicitly so they exist even before tmpfiles
# runs. /dev and /sys will be overmounted, but these paths are still harmless.
mkdir -p \
  "${ROOTFS_DIR}/dev/mqueue" \
  "${ROOTFS_DIR}/sys/kernel/debug" \
  "${ROOTFS_DIR}/sys/kernel/tracing" \
  "${ROOTFS_DIR}/sys/kernel/config" \
  "${ROOTFS_DIR}/sys/fs/fuse/connections" \
  "${ROOTFS_DIR}/var/volatile"
chmod 1777 "${ROOTFS_DIR}/tmp"

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}/reference"
cp "${BASE_PAYLOAD}/nand_env.bin" "${OUT_PAYLOAD}/nand_env.bin"
cp "${BASE_PAYLOAD}/reference/"* "${OUT_PAYLOAD}/reference/"

docker run --rm \
  -v "${ROOTFS_DIR}:/src:ro" \
  -v "${OUT_PAYLOAD}:/out" \
  "${DOCKER_IMAGE}" \
  bash -lc 'set -euo pipefail; cd /src; tar --format=ustar --numeric-owner --owner=0 --group=0 -czf /out/rootfs.tar.gz .'

cat > "${OUT_PAYLOAD}/manifest.txt" <<'EOF'
boot_mode=stock-boot
boot_source=mtd4:boot via imgread kernel ${boot_part} ${loadaddr}; bootm ${loadaddr}
rootfs_profile=stock-kernel-compat
rootfs_archive=rootfs.tar.gz
env_blob=nand_env.bin
network=systemd-networkd DHCP on eth0
masked_units=tmp.mount,var-volatile.mount,var-volatile-*.service,systemd-remount-fs.service,systemd-vconsole-setup.service,dev-mqueue.mount,sys-kernel-debug.mount,sys-kernel-tracing.mount,sys-fs-fuse-connections.mount,sys-kernel-config.mount
reference_stock_boot_dump=reference/mtd4_boot_stock.bin.gz
reference_stock_env_dump=reference/nand_env_stock.bin.gz
reference_live_dtb=reference/axg_s400_antminer.dtb
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 rootfs.tar.gz nand_env.bin manifest.txt reference/* > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 2 -type f | sort
