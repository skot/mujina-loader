#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-compat"
OUT_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-armhf-net"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-armhf-net.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/rootfs"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ubuntu:22.04}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-mujina-armhf}"
TELNET_PORT="${TELNET_PORT:-2323}"
HTTP_PORT="${HTTP_PORT:-80}"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./build_armhf_network_payload.sh [options]

Options:
  --busybox-version VER  BusyBox version to build (default: ${BUSYBOX_VERSION})
  --hostname NAME        Hostname to announce (default: ${HOSTNAME_VALUE})
  --telnet-port PORT     Telnet port (default: ${TELNET_PORT})
  --http-port PORT       HTTP port (default: ${HTTP_PORT})
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
    --hostname) HOSTNAME_VALUE="${2:-}"; shift 2 ;;
    --telnet-port) TELNET_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
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

mkdir -p \
  "${ROOTFS_DIR}/bin" \
  "${ROOTFS_DIR}/sbin" \
  "${ROOTFS_DIR}/proc" \
  "${ROOTFS_DIR}/sys" \
  "${ROOTFS_DIR}/dev" \
  "${ROOTFS_DIR}/dev/pts" \
  "${ROOTFS_DIR}/tmp" \
  "${ROOTFS_DIR}/etc" \
  "${ROOTFS_DIR}/run" \
  "${ROOTFS_DIR}/var/tmp" \
  "${ROOTFS_DIR}/var/volatile" \
  "${ROOTFS_DIR}/www"
chmod 1777 "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/var/tmp" "${ROOTFS_DIR}/var/volatile"
ln -sfn pts/ptmx "${ROOTFS_DIR}/dev/ptmx"

cat > "${ROOTFS_DIR}/etc/hostname" <<EOF
${HOSTNAME_VALUE}
EOF

cat > "${ROOTFS_DIR}/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

cat > "${ROOTFS_DIR}/etc/group" <<'EOF'
root:x:0:
EOF

cat > "${ROOTFS_DIR}/www/index.html" <<EOF
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Mujina armhf bring-up</title>
</head>
<body>
  <h1>Mujina armhf network payload</h1>
  <p>Waiting for DHCP...</p>
</body>
</html>
EOF

cat > "${ROOTFS_DIR}/etc/udhcpc.script" <<EOF
#!/bin/sh
set -eu

BB=/bin/busybox
SERIAL=/dev/ttyS0
WWW=/www/index.html

log() {
  echo "\$*" >&2
  if [ -c "\${SERIAL}" ]; then
    echo "\$*" >"\${SERIAL}" 2>/dev/null || true
  fi
}

case "\${1:-}" in
  deconfig)
    \$BB ifconfig "\${interface}" 0.0.0.0
    ;;
  bound|renew)
    \$BB ifconfig "\${interface}" "\${ip}" netmask "\${subnet:-255.255.255.0}" up
    if [ -n "\${router:-}" ]; then
      \$BB route del default gw 0.0.0.0 "\${interface}" 2>/dev/null || true
      for r in \$router; do
        \$BB route add default gw "\$r" dev "\${interface}" 2>/dev/null || true
        break
      done
    fi
    : > /etc/resolv.conf
    for d in \${dns:-}; do
      echo "nameserver \$d" >> /etc/resolv.conf
    done
    cat > "\${WWW}" <<HTML
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Mujina armhf bring-up</title>
</head>
<body>
  <h1>Mujina armhf network payload</h1>
  <p>Interface: \${interface}</p>
  <p>Address: \${ip}</p>
  <p>Router: \${router:-none}</p>
  <p>Telnet: telnet \${ip} ${TELNET_PORT}</p>
</body>
</html>
HTML
    log "DHCP \${1}: \${interface}=\${ip} telnet=${TELNET_PORT} http=${HTTP_PORT}"
    ;;
esac

exit 0
EOF
chmod 0755 "${ROOTFS_DIR}/etc/udhcpc.script"

cat > "${ROOTFS_DIR}/sbin/init" <<EOF
#!/bin/sh
BB=/bin/busybox
SERIAL=/dev/ttyS0
HOSTNAME_FILE=/etc/hostname

log() {
  echo "\$*"
  if [ -c "\${SERIAL}" ]; then
    echo "\$*" >"\${SERIAL}" 2>/dev/null || true
  fi
}

\$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
\$BB mkdir -p /dev/pts
\$BB mount -t proc proc /proc 2>/dev/null || true
\$BB mount -t sysfs sysfs /sys 2>/dev/null || true
\$BB mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts 2>/dev/null || true
\$BB ln -sf pts/ptmx /dev/ptmx 2>/dev/null || true
\$BB mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs /run 2>/dev/null || true
\$BB mount -t tmpfs tmpfs /var/volatile 2>/dev/null || true

[ -f "\${HOSTNAME_FILE}" ] && \$BB hostname -F "\${HOSTNAME_FILE}" 2>/dev/null || true
\$BB ifconfig lo 127.0.0.1 up 2>/dev/null || true
\$BB ifconfig eth0 up 2>/dev/null || true

log "Mujina armhf network init started"
log "Kernel: \$(uname -a 2>/dev/null || true)"
log "Cmdline: \$(cat /proc/cmdline 2>/dev/null || true)"
log "Starting telnetd on ${TELNET_PORT}"
\$BB telnetd -F -p ${TELNET_PORT} -l /bin/sh </dev/null >>\${SERIAL} 2>&1 &
sleep 1
log "Starting httpd on ${HTTP_PORT}"
\$BB httpd -p ${HTTP_PORT} -h /www
log "Requesting DHCP on eth0"
\$BB udhcpc -i eth0 -s /etc/udhcpc.script -b -x hostname:${HOSTNAME_VALUE}
log "Dropping to serial shell"
exec \$BB sh </dev/ttyS0 >/dev/ttyS0 2>&1
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
    for opt in CONFIG_IFCONFIG CONFIG_FEATURE_IFCONFIG_STATUS CONFIG_ROUTE CONFIG_UDHCPC CONFIG_FEATURE_UDHCPC_ARPING CONFIG_FEATURE_UDHCP_PORT CONFIG_TELNETD CONFIG_FEATURE_TELNETD_STANDALONE CONFIG_HTTPD CONFIG_FEATURE_HTTPD_RANGES CONFIG_FEATURE_IPV6 CONFIG_CTTYHACK CONFIG_FEATURE_SH_STANDALONE CONFIG_MOUNT CONFIG_HOSTNAME CONFIG_PS CONFIG_FEATURE_PS_WIDE CONFIG_NETSTAT; do
      if grep -q \"^# \${opt} is not set$\" .config; then
        sed -ri \"s/^# \${opt} is not set$/\${opt}=y/\" .config
      elif grep -q \"^\${opt}=\" .config; then
        sed -ri \"s/^\${opt}=.*/\${opt}=y/\" .config
      else
        echo \"\${opt}=y\" >> .config
      fi
    done
    if grep -q '^CONFIG_UDHCPC_DEFAULT_SCRIPT=' .config; then
      sed -ri 's|^CONFIG_UDHCPC_DEFAULT_SCRIPT=.*|CONFIG_UDHCPC_DEFAULT_SCRIPT=\"/etc/udhcpc.script\"|' .config
    else
      echo 'CONFIG_UDHCPC_DEFAULT_SCRIPT=\"/etc/udhcpc.script\"' >> .config
    fi
    set +o pipefail
    yes '' | make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- oldconfig >/dev/null
    set -o pipefail
    make -j\"\$(nproc)\" ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- busybox >/dev/null
    cp busybox /out/bin/busybox
    chmod 0755 /out/bin/busybox
    for applet in sh mount hostname ifconfig route udhcpc telnetd httpd cttyhack; do
      ln -sf busybox \"/out/bin/\${applet}\"
    done
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
rootfs_profile=armhf-network-bringup
rootfs_archive=rootfs.tar.gz
env_blob=nand_env.bin
busybox_version=${BUSYBOX_VERSION}
entrypoint=/sbin/init
userspace_arch=armhf
hostname=${HOSTNAME_VALUE}
telnet_port=${TELNET_PORT}
http_port=${HTTP_PORT}
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 Image axg_s400_antminer.dtb rootfs.tar.gz nand_env.bin manifest.txt reference/* > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 2 -type f | sort
