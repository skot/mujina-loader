#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-compat"
OUT_PAYLOAD="${SCRIPT_DIR}/payload-yocto-kernel-armhf-full"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-armhf-full.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/rootfs"
PROVISION_SCRIPT="${WORK_DIR}/provision-armhf-full.sh"
DOCKER_IMAGE="${DOCKER_IMAGE:-debian:bookworm-slim}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-mujina-armhf}"
TELNET_PORT="${TELNET_PORT:-2323}"
HTTP_PORT="${HTTP_PORT:-80}"
SSH_PORT="${SSH_PORT:-22}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"

cleanup() {
  if [[ -n "${CONTAINER_ID:-}" ]]; then
    docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./build_armhf_full_payload.sh [options]

Options:
  --hostname NAME        Hostname to announce (default: ${HOSTNAME_VALUE})
  --telnet-port PORT     Telnet port (default: ${TELNET_PORT})
  --http-port PORT       HTTP port (default: ${HTTP_PORT})
  --ssh-port PORT        SSH port (default: ${SSH_PORT})
  --root-password PASS   Root password (default: ${ROOT_PASSWORD})
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
    --hostname) HOSTNAME_VALUE="${2:-}"; shift 2 ;;
    --telnet-port) TELNET_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --root-password) ROOT_PASSWORD="${2:-}"; shift 2 ;;
    --out-dir) OUT_PAYLOAD="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd shasum
need_cmd tar

[[ -f "${BASE_PAYLOAD}/Image" ]] || die "Missing base kernel at ${BASE_PAYLOAD}/Image"
[[ -f "${BASE_PAYLOAD}/axg_s400_antminer.dtb" ]] || die "Missing base DTB at ${BASE_PAYLOAD}/axg_s400_antminer.dtb"
[[ -f "${BASE_PAYLOAD}/nand_env.bin" ]] || die "Missing base env at ${BASE_PAYLOAD}/nand_env.bin"

mkdir -p "${ROOTFS_DIR}"
cat > "${PROVISION_SCRIPT}" <<EOF
#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
chmod 0755 /usr/sbin/policy-rc.d

apt-get update >/dev/null
apt-get install -y --no-install-recommends \
  bash busybox-static ca-certificates coreutils curl dropbear-bin file \
  findutils grep gawk iproute2 iputils-ping less nano net-tools procps \
  sed tar tzdata util-linux vim-tiny wget >/dev/null

echo 'root:${ROOT_PASSWORD}' | chpasswd
mkdir -p /etc/dropbear /root /run /var/log /var/volatile /www /dev/pts /tmp
chmod 1777 /tmp

cat >/etc/motd <<'EOF_MOTD'
Mujina armhf development userspace

Services:
- SSH on ${SSH_PORT}
- Telnet on ${TELNET_PORT}
- HTTP status page on ${HTTP_PORT}
EOF_MOTD

cat >/etc/os-release <<'EOF_OS'
NAME="Mujina"
VERSION="0.2.0 (armhf-lab)"
ID=mujina
PRETTY_NAME="Mujina armhf development userspace"
VERSION_ID="0.2.0"
HOME_URL="https://mujina.dev"
SUPPORT_URL="https://mujina.dev/support"
BUG_REPORT_URL="https://mujina.dev/issues"
EOF_OS

cat >/etc/udhcpc.script <<'EOF_UDHCPC'
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
    cat >"\${WWW}" <<HTML
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Mujina armhf</title>
</head>
<body>
  <h1>Mujina armhf development userspace</h1>
  <p>Interface: \${interface}</p>
  <p>Address: \${ip}</p>
  <p>Router: \${router:-none}</p>
  <p>SSH: ssh root@\${ip}</p>
  <p>Telnet: telnet \${ip} ${TELNET_PORT}</p>
</body>
</html>
HTML
    log "DHCP \${1}: \${interface}=\${ip} ssh=${SSH_PORT} telnet=${TELNET_PORT} http=${HTTP_PORT}"
    ;;
esac

exit 0
EOF_UDHCPC
chmod 0755 /etc/udhcpc.script

cat >/www/index.html <<'EOF_WWW'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Mujina armhf</title>
</head>
<body>
  <h1>Mujina armhf development userspace</h1>
  <p>Waiting for DHCP...</p>
</body>
</html>
EOF_WWW

cat >/sbin/init <<'EOF_INIT'
#!/bin/sh
set -eu

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
\$BB mkdir -p /dev/pts /dev/shm /run /tmp /var/volatile /var/log /var/run
\$BB mount -t proc proc /proc 2>/dev/null || true
\$BB mount -t sysfs sysfs /sys 2>/dev/null || true
\$BB mount -t devpts -o gid=5,mode=620,ptmxmode=666 devpts /dev/pts 2>/dev/null || true
\$BB ln -sf pts/ptmx /dev/ptmx 2>/dev/null || true
\$BB mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs /run 2>/dev/null || true
\$BB mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs /tmp 2>/dev/null || true
\$BB mount -t tmpfs tmpfs /var/volatile 2>/dev/null || true
\$BB mkdir -p /run/dropbear

[ -f "\${HOSTNAME_FILE}" ] && \$BB hostname -F "\${HOSTNAME_FILE}" 2>/dev/null || true
\$BB ifconfig lo 127.0.0.1 up 2>/dev/null || true
\$BB ifconfig eth0 up 2>/dev/null || true

log "Mujina armhf full init started"
log "Kernel: \$(uname -a 2>/dev/null || true)"
log "Cmdline: \$(cat /proc/cmdline 2>/dev/null || true)"
log "Starting SSH on ${SSH_PORT}"
/usr/sbin/dropbear -R -E -p ${SSH_PORT} </dev/null >>\${SERIAL} 2>&1 &
log "Starting telnetd on ${TELNET_PORT}"
\$BB telnetd -p ${TELNET_PORT} -l /bin/bash </dev/null >>\${SERIAL} 2>&1 || true
sleep 1
log "Starting httpd on ${HTTP_PORT}"
\$BB httpd -p ${HTTP_PORT} -h /www
log "Requesting DHCP on eth0"
\$BB udhcpc -i eth0 -s /etc/udhcpc.script -b -x hostname:${HOSTNAME_VALUE}
log "Dropping to serial shell"
exec \$BB cttyhack /bin/bash -il </dev/ttyS0 >/dev/ttyS0 2>&1
EOF_INIT
chmod 0755 /sbin/init

rm -f /usr/sbin/policy-rc.d
EOF
chmod 0755 "${PROVISION_SCRIPT}"

CONTAINER_ID="$(docker create \
  --platform linux/arm/v7 \
  -v "${PROVISION_SCRIPT}:/provision.sh:ro" \
  "${DOCKER_IMAGE}" \
  /bin/sh /provision.sh)"

docker start -a "${CONTAINER_ID}" >/dev/null
docker export "${CONTAINER_ID}" | tar -xf - -C "${ROOTFS_DIR}"

mkdir -p "${ROOTFS_DIR}/etc"
printf '%s\n' "${HOSTNAME_VALUE}" > "${ROOTFS_DIR}/etc/hostname"

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}/reference"
cp "${BASE_PAYLOAD}/Image" "${OUT_PAYLOAD}/Image"
cp "${BASE_PAYLOAD}/axg_s400_antminer.dtb" "${OUT_PAYLOAD}/axg_s400_antminer.dtb"
cp "${BASE_PAYLOAD}/nand_env.bin" "${OUT_PAYLOAD}/nand_env.bin"
cp "${BASE_PAYLOAD}/reference/"* "${OUT_PAYLOAD}/reference/"

docker run --rm \
  -v "${ROOTFS_DIR}:/src:ro" \
  -v "${OUT_PAYLOAD}:/out" \
  ubuntu:22.04 \
  bash -lc 'set -euo pipefail; cd /src; tar --format=ustar --numeric-owner --owner=0 --group=0 -czf /out/rootfs.tar.gz .'

cat > "${OUT_PAYLOAD}/manifest.txt" <<EOF
boot_mode=ubifs-image
boot_source=mtd6:mujina_rootfs via U-Boot ubifsload + booti
kernel_source=yocto-custom-kernel
dtb_source=yocto-deployed-validated-dtb
rootfs_source=debian-bookworm-armhf-with-busybox-init
hostname=${HOSTNAME_VALUE}
ssh_port=${SSH_PORT}
telnet_port=${TELNET_PORT}
http_port=${HTTP_PORT}
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 Image axg_s400_antminer.dtb rootfs.tar.gz nand_env.bin manifest.txt > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 2 -type f | sort
