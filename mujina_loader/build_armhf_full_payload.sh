#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_TEMPLATE="${SCRIPT_DIR}/stock_env_template.txt"
ENV_GENERATOR="${SCRIPT_DIR}/generate_nand_env.py"
OUT_PAYLOAD="${OUT_PAYLOAD:-${SCRIPT_DIR}/mujina_armhf_full}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-armhf-full.XXXXXX")"
ROOTFS_DIR="${WORK_DIR}/rootfs"
PROVISION_SCRIPT="${WORK_DIR}/provision-armhf-full.sh"
DOCKER_IMAGE="${DOCKER_IMAGE:-debian:bookworm-slim}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-mujina-armhf}"
PROFILE_NAME="${PROFILE_NAME:-Mujina armhf development userspace}"
VERSION_VALUE="${VERSION_VALUE:-0.2.0 (armhf-lab)}"
VERSION_ID_VALUE="${VERSION_ID_VALUE:-0.2.0}"
TELNET_PORT="${TELNET_PORT:-2323}"
HTTP_PORT="${HTTP_PORT:-80}"
SSH_PORT="${SSH_PORT:-22}"
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"
ENABLE_SSH="${ENABLE_SSH:-1}"
ENABLE_TELNET="${ENABLE_TELNET:-1}"
ENABLE_HTTP="${ENABLE_HTTP:-1}"

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
  --profile-name NAME    Pretty profile name (default: ${PROFILE_NAME})
  --version STR          Version string (default: ${VERSION_VALUE})
  --version-id STR       Version id (default: ${VERSION_ID_VALUE})
  --telnet-port PORT     Telnet port (default: ${TELNET_PORT})
  --http-port PORT       HTTP port (default: ${HTTP_PORT})
  --ssh-port PORT        SSH port (default: ${SSH_PORT})
  --enable-ssh 0|1       Enable SSH service (default: ${ENABLE_SSH})
  --enable-telnet 0|1    Enable telnet service (default: ${ENABLE_TELNET})
  --enable-http 0|1      Enable HTTP status page (default: ${ENABLE_HTTP})
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
    --profile-name) PROFILE_NAME="${2:-}"; shift 2 ;;
    --version) VERSION_VALUE="${2:-}"; shift 2 ;;
    --version-id) VERSION_ID_VALUE="${2:-}"; shift 2 ;;
    --telnet-port) TELNET_PORT="${2:-}"; shift 2 ;;
    --http-port) HTTP_PORT="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-}"; shift 2 ;;
    --enable-ssh) ENABLE_SSH="${2:-}"; shift 2 ;;
    --enable-telnet) ENABLE_TELNET="${2:-}"; shift 2 ;;
    --enable-http) ENABLE_HTTP="${2:-}"; shift 2 ;;
    --root-password) ROOT_PASSWORD="${2:-}"; shift 2 ;;
    --out-dir) OUT_PAYLOAD="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd docker
need_cmd shasum
need_cmd tar
need_cmd python3

[[ -f "${ENV_TEMPLATE}" ]] || die "Missing env template at ${ENV_TEMPLATE}"
[[ -f "${ENV_GENERATOR}" ]] || die "Missing env generator at ${ENV_GENERATOR}"

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
mkdir -p /etc/dropbear /etc/init.d /etc/mujina/rc.d /root /run /var/log /var/volatile /www /dev/pts /tmp
chmod 1777 /tmp

cat >/etc/motd <<'EOF_MOTD'
${PROFILE_NAME}

Services:
- SSH on ${SSH_PORT} (enabled=${ENABLE_SSH})
- Telnet on ${TELNET_PORT} (enabled=${ENABLE_TELNET})
- HTTP status page on ${HTTP_PORT} (enabled=${ENABLE_HTTP})
EOF_MOTD

cat >/etc/os-release <<'EOF_OS'
NAME="Mujina"
VERSION="${VERSION_VALUE}"
ID=mujina
PRETTY_NAME="${PROFILE_NAME}"
VERSION_ID="${VERSION_ID_VALUE}"
HOME_URL="https://mujina.dev"
SUPPORT_URL="https://mujina.dev/support"
BUG_REPORT_URL="https://mujina.dev/issues"
EOF_OS

cat >/etc/mujina/release <<'EOF_RELEASE'
profile_name=${PROFILE_NAME}
version=${VERSION_VALUE}
version_id=${VERSION_ID_VALUE}
hostname=${HOSTNAME_VALUE}
EOF_RELEASE

cat >/etc/mujina/services.env <<'EOF_SERVICES'
ENABLE_SSH=${ENABLE_SSH}
ENABLE_TELNET=${ENABLE_TELNET}
ENABLE_HTTP=${ENABLE_HTTP}
SSH_PORT=${SSH_PORT}
TELNET_PORT=${TELNET_PORT}
HTTP_PORT=${HTTP_PORT}
EOF_SERVICES

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
  <h1>${PROFILE_NAME}</h1>
  <p>Interface: \${interface}</p>
  <p>Address: \${ip}</p>
  <p>Router: \${router:-none}</p>
  <p>SSH: ssh root@\${ip}</p>
  <p>Telnet: telnet \${ip} ${TELNET_PORT} (enabled=${ENABLE_TELNET})</p>
</body>
</html>
HTML
    log "DHCP \${1}: \${interface}=\${ip} ssh=${SSH_PORT} telnet=${TELNET_PORT} http=${HTTP_PORT}"
    ;;
esac

exit 0
EOF_UDHCPC
chmod 0755 /etc/udhcpc.script

cat >/etc/mujina/lib.sh <<'EOF_LIB'
#!/bin/sh

BB=/bin/busybox
SERIAL=/dev/ttyS0
[ -f /etc/mujina/services.env ] && . /etc/mujina/services.env

log() {
  echo "\$*"
  if [ -c "\${SERIAL}" ]; then
    echo "\$*" >"\${SERIAL}" 2>/dev/null || true
  fi
}
EOF_LIB
chmod 0755 /etc/mujina/lib.sh

cat >/etc/inittab <<'EOF_INITTAB'
::sysinit:/etc/init.d/rcS
ttyS0::respawn:/bin/busybox cttyhack /bin/bash -il
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
EOF_INITTAB

cat >/etc/init.d/rcS <<'EOF_RCS'
#!/bin/sh
set -eu

for script in /etc/mujina/rc.d/S*; do
  [ -x "\${script}" ] || continue
  "\${script}"
done
EOF_RCS
chmod 0755 /etc/init.d/rcS

cat >/etc/mujina/rc.d/S00-mounts <<'EOF_S00'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

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
log "Mounted proc/sys/dev/run/tmp"
EOF_S00
chmod 0755 /etc/mujina/rc.d/S00-mounts

cat >/etc/mujina/rc.d/S10-hostname <<'EOF_S10'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

[ -f /etc/hostname ] && \$BB hostname -F /etc/hostname 2>/dev/null || true
log "Hostname: \$(\$BB hostname 2>/dev/null || true)"
log "Kernel: \$(uname -a 2>/dev/null || true)"
log "Cmdline: \$(cat /proc/cmdline 2>/dev/null || true)"
EOF_S10
chmod 0755 /etc/mujina/rc.d/S10-hostname

cat >/etc/mujina/rc.d/S20-network <<'EOF_S20'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

\$BB ifconfig lo 127.0.0.1 up 2>/dev/null || true
\$BB ifconfig eth0 up 2>/dev/null || true
log "Requesting DHCP on eth0"
\$BB udhcpc -i eth0 -s /etc/udhcpc.script -b -x hostname:${HOSTNAME_VALUE}
EOF_S20
chmod 0755 /etc/mujina/rc.d/S20-network

cat >/etc/mujina/rc.d/S30-dropbear <<'EOF_S30'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

[ "\${ENABLE_SSH:-1}" = "1" ] || exit 0
log "Starting SSH on \${SSH_PORT}"
/usr/sbin/dropbear -R -E -p "\${SSH_PORT}" </dev/null >>\${SERIAL} 2>&1 &
EOF_S30
chmod 0755 /etc/mujina/rc.d/S30-dropbear

cat >/etc/mujina/rc.d/S40-telnetd <<'EOF_S40'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

[ "\${ENABLE_TELNET:-0}" = "1" ] || exit 0
log "Starting telnetd on \${TELNET_PORT}"
\$BB telnetd -p "\${TELNET_PORT}" -l /bin/bash </dev/null >>\${SERIAL} 2>&1 || true
EOF_S40
chmod 0755 /etc/mujina/rc.d/S40-telnetd

cat >/etc/mujina/rc.d/S50-httpd <<'EOF_S50'
#!/bin/sh
set -eu
. /etc/mujina/lib.sh

[ "\${ENABLE_HTTP:-0}" = "1" ] || exit 0
log "Starting httpd on \${HTTP_PORT}"
\$BB httpd -p "\${HTTP_PORT}" -h /www
EOF_S50
chmod 0755 /etc/mujina/rc.d/S50-httpd

cat >/www/index.html <<'EOF_WWW'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Mujina armhf</title>
</head>
<body>
  <h1>${PROFILE_NAME}</h1>
  <p>Waiting for DHCP...</p>
</body>
</html>
EOF_WWW

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
mkdir -p "${ROOTFS_DIR}/sbin"
ln -sfn ../bin/busybox "${ROOTFS_DIR}/sbin/init"

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}"

docker run --rm \
  -v "${ROOTFS_DIR}:/src:ro" \
  -v "${OUT_PAYLOAD}:/out" \
  ubuntu:22.04 \
  bash -lc 'set -euo pipefail; cd /src; tar --format=ustar --numeric-owner --owner=0 --group=0 -czf /out/rootfs.tar.gz .'

python3 "${ENV_GENERATOR}" \
  --template "${ENV_TEMPLATE}" \
  --output "${OUT_PAYLOAD}/nand_env.bin" \
  --boot-mode stock-boot \
  --volume-name mujina_rootfs \
  --mtd-index 6

cat > "${OUT_PAYLOAD}/manifest.txt" <<EOF
boot_mode=stock-boot
boot_source=stock signed boot image + mujina_rootfs on mtd6
kernel_source=stock-bitmain-4.9.113
dtb_source=stock-bitmain
rootfs_source=debian-bookworm-armhf-with-busybox-init
hostname=${HOSTNAME_VALUE}
profile_name=${PROFILE_NAME}
version=${VERSION_VALUE}
ssh_port=${SSH_PORT}
enable_ssh=${ENABLE_SSH}
telnet_port=${TELNET_PORT}
enable_telnet=${ENABLE_TELNET}
http_port=${HTTP_PORT}
enable_http=${ENABLE_HTTP}
EOF

(
  cd "${OUT_PAYLOAD}"
  shasum -a 256 rootfs.tar.gz nand_env.bin manifest.txt > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Artifacts:"
find "${OUT_PAYLOAD}" -maxdepth 1 -type f | sort
