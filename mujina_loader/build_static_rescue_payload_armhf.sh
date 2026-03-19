#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-compat"
OUT_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-rescue-armhf"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-static-rescue-armhf.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/rootfs"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./build_static_rescue_payload_armhf.sh [options]

Options:
  --busybox-version VER  BusyBox version to build (default: ${BUSYBOX_VERSION})
  --out-dir PATH         Output directory (default: ${OUT_PAYLOAD})
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
    --busybox-version) BUSYBOX_VERSION="${2:-}"; shift 2 ;;
    --out-dir) OUT_PAYLOAD="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd shasum

[ -f "${BASE_PAYLOAD}/Image" ] || die "Missing base kernel at ${BASE_PAYLOAD}/Image"
[ -f "${BASE_PAYLOAD}/axg_s400_antminer.dtb" ] || die "Missing base DTB at ${BASE_PAYLOAD}/axg_s400_antminer.dtb"
[ -f "${BASE_PAYLOAD}/nand_env.bin" ] || die "Missing base env at ${BASE_PAYLOAD}/nand_env.bin"

mkdir -p "${ROOTFS_DIR}/bin" "${ROOTFS_DIR}/sbin" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev" "${ROOTFS_DIR}/tmp"
chmod 1777 "${ROOTFS_DIR}/tmp"

cat > "${ROOTFS_DIR}/sbin/init" <<'EOF'
#!/bin/sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
echo "Mujina armhf rescue init started"
echo "Kernel: $(uname -a 2>/dev/null || true)"
echo "Cmdline: $(cat /proc/cmdline 2>/dev/null || true)"
echo "Mounts:"
mount 2>/dev/null || true
echo
echo "BusyBox:"
/bin/busybox | head -n 1 2>/dev/null || true
echo
echo "Dropping to rescue shell on /dev/ttyS0"
exec /bin/sh </dev/ttyS0 >/dev/ttyS0 2>&1
EOF
chmod 0755 "${ROOTFS_DIR}/sbin/init"

docker run --rm \
  -v "${ROOTFS_DIR}:/out" \
  "${DOCKER_IMAGE}" \
  bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates flex wget xz-utils \
      gcc-arm-linux-gnueabihf libc6-dev-armhf-cross make >/dev/null
    cd /tmp
    wget -q https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
    tar -xf busybox-${BUSYBOX_VERSION}.tar.bz2
    cd busybox-${BUSYBOX_VERSION}
    make defconfig >/dev/null
    sed -ri 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' .config
    sed -ri 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config
    set +o pipefail
    yes '' | make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- oldconfig >/dev/null
    set -o pipefail
    make -j\"\$(nproc)\" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- busybox >/dev/null
    cp busybox /out/bin/busybox
    chmod 0755 /out/bin/busybox
    ln -sf busybox /out/bin/sh
  "

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}/reference"
cp "${BASE_PAYLOAD}/Image" "${OUT_PAYLOAD}/Image"
cp "${BASE_PAYLOAD}/axg_s400_antminer.dtb" "${OUT_PAYLOAD}/axg_s400_antminer.dtb"
cp "${BASE_PAYLOAD}/nand_env.bin" "${OUT_PAYLOAD}/nand_env.bin"
cp "${BASE_PAYLOAD}/reference/"* "${OUT_PAYLOAD}/reference/"

docker run --rm \
  -v "${ROOTFS_DIR}:/src:ro" \
  -v "${OUT_PAYLOAD}:/out" \
  "${DOCKER_IMAGE}" \
  bash -lc 'set -euo pipefail; cd /src; tar --format=ustar --numeric-owner --owner=0 --group=0 -czf /out/rootfs.tar.gz .'

cat > "${OUT_PAYLOAD}/manifest.txt" <<EOF
boot_mode=ubifs-image
boot_source=mtd6:mujina_rootfs via U-Boot ubifsload + booti
kernel_source=yocto-custom-kernel
dtb_source=validated-prebuilt-dtb
rootfs_profile=static-busybox-rescue-armhf
rootfs_archive=rootfs.tar.gz
env_blob=nand_env.bin
busybox_version=${BUSYBOX_VERSION}
entrypoint=/sbin/init
userspace_arch=armhf
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 Image axg_s400_antminer.dtb rootfs.tar.gz nand_env.bin manifest.txt reference/* > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 2 -type f | sort
