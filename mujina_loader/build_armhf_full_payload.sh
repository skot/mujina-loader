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
  findutils grep gawk iproute2 iputils-ping kmod less nano net-tools procps \
  sed tar tzdata util-linux vim-tiny wget wpasupplicant >/dev/null

echo 'root:${ROOT_PASSWORD}' | chpasswd
mkdir -p /config /etc/dropbear /etc/init.d /etc/mujina/rc.d /etc/udhcpc /root /run /usr/local/bin /var/log /var/volatile /www /dev/pts /tmp
chmod 1777 /tmp

for tool in wpa_supplicant wpa_cli wpa_passphrase; do
  tool_path="$(command -v "${tool}" || true)"
  [ -n "${tool_path}" ] && ln -sf "${tool_path}" "/usr/local/bin/${tool}"
done
ln -sf /bin/busybox /sbin/udhcpc
ln -sf /bin/busybox /usr/sbin/udhcpc

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
PUBLIC_DNS_FALLBACKS="1.1.1.1 8.8.8.8"

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
    if [ "\${interface}" = "wlan0" ]; then
      ip route del default dev eth0 2>/dev/null || true
    fi
    : > /etc/resolv.conf
    for d in \$PUBLIC_DNS_FALLBACKS; do
      echo "nameserver \$d" >> /etc/resolv.conf
    done
    for d in \${dns:-}; do
      [ "\$d" = "1.1.1.1" ] && continue
      [ "\$d" = "8.8.8.8" ] && continue
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
ln -sf /etc/udhcpc.script /etc/udhcpc/default.script

cat >/etc/init.d/wifi-autostart <<'EOF_WIFI'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LD_LIBRARY_PATH=/lib

WIFI_IFACE=wlan0
WIFI_CONFIG_PATH=
WIFI_ROUTE_TABLE=101
ETH_IFACE=eth0
USB_WIFI_ID=

if [ -f /config/wifi-autostart.conf ]; then
  . /config/wifi-autostart.conf
fi

if [ -z "$WIFI_CONFIG_PATH" ]; then
  WIFI_CONFIG_PATH="/config/wpa_supplicant-$WIFI_IFACE.conf"
fi

WPA_PID="/var/run/wpa_supplicant-$WIFI_IFACE.pid"
DHCP_PID="/var/run/udhcpc.$WIFI_IFACE.pid"
MODULE_PATH="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/realtek/rtl8821cu/8821cu.ko"
MODULE_PATH_ALT="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/realtek/rtl8812au/88XXau.ko"

log() {
  echo "wifi-autostart: $*"
}

usb_wifi_id() {
  if [ -n "$USB_WIFI_ID" ]; then
    printf '%s\n' "$USB_WIFI_ID"
    return 0
  fi

  for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] || continue
    vendor=$(cat "$dev/idVendor" 2>/dev/null || true)
    product=$(cat "$dev/idProduct" 2>/dev/null || true)
    if [ -n "$vendor" ] && [ -n "$product" ]; then
      printf '%s:%s\n' "$vendor" "$product"
    fi
  done
}

load_wifi_module() {
  for id in $(usb_wifi_id); do
    case "$id" in
      2357:011e|2357:011f|2357:0120)
        log "loading 88XXau for USB ID $id"
        modprobe 88XXau >/dev/null 2>&1 || insmod "$MODULE_PATH_ALT" >/dev/null 2>&1 || true
        return 0
        ;;
      0bda:c811|0bda:c82b|0bda:c82a|0bda:c820|0bda:c821|0bda:b820|0bda:b82b)
        log "loading 8821cu for USB ID $id"
        modprobe 8821cu >/dev/null 2>&1 || insmod "$MODULE_PATH" >/dev/null 2>&1 || true
        return 0
        ;;
    esac
  done

  log "no known USB Wi-Fi ID found, trying 8821cu then 88XXau"
  modprobe 8821cu >/dev/null 2>&1 || insmod "$MODULE_PATH" >/dev/null 2>&1 || true
  modprobe 88XXau >/dev/null 2>&1 || insmod "$MODULE_PATH_ALT" >/dev/null 2>&1 || true
}

kill_pidfile() {
  pidfile=$1
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

wait_for_iface() {
  count=0
  while [ "$count" -lt 20 ]; do
    if ip link show "$WIFI_IFACE" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

wait_for_assoc() {
  count=0
  while [ "$count" -lt 20 ]; do
    if wpa_cli -i "$WIFI_IFACE" status 2>/dev/null | grep -q '^wpa_state=COMPLETED$'; then
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  return 1
}

apply_arp_policy() {
  for key in all default "$ETH_IFACE" "$WIFI_IFACE"; do
    [ -d "/proc/sys/net/ipv4/conf/$key" ] || continue
    echo 1 > "/proc/sys/net/ipv4/conf/$key/arp_ignore"
    echo 2 > "/proc/sys/net/ipv4/conf/$key/arp_announce"
    echo 1 > "/proc/sys/net/ipv4/conf/$key/arp_filter"
  done
}

apply_wifi_routing() {
  wifi_cidr=$(ip -4 addr show dev "$WIFI_IFACE" | awk '/inet / {print $2; exit}')
  [ -n "$wifi_cidr" ] || return 0

  wifi_src=${wifi_cidr%/*}
  wifi_subnet=$(ip -4 route show dev "$WIFI_IFACE" scope link | awk 'NR==1 {print $1; exit}')
  wifi_gw=$(ip route show default | awk 'NR==1 {print $3; exit}')

  ip rule del from "$wifi_src/32" table "$WIFI_ROUTE_TABLE" 2>/dev/null || true
  ip route flush table "$WIFI_ROUTE_TABLE" 2>/dev/null || true

  if [ -n "$wifi_subnet" ]; then
    ip route add "$wifi_subnet" dev "$WIFI_IFACE" src "$wifi_src" table "$WIFI_ROUTE_TABLE"
  fi

  if [ -n "$wifi_gw" ]; then
    ip route add default via "$wifi_gw" dev "$WIFI_IFACE" table "$WIFI_ROUTE_TABLE" 2>/dev/null || true
  fi

  ip rule add from "$wifi_src/32" table "$WIFI_ROUTE_TABLE" priority 10000 2>/dev/null || true
  apply_arp_policy
}

cleanup_stale_eth_ipv4() {
  carrier=$(cat "/sys/class/net/$ETH_IFACE/carrier" 2>/dev/null || echo 0)
  if [ "$carrier" = "0" ]; then
    ip -4 addr flush dev "$ETH_IFACE" scope global 2>/dev/null || true
  fi
}

start_wifi() {
  if [ ! -s "$WIFI_CONFIG_PATH" ]; then
    log "skip: missing $WIFI_CONFIG_PATH"
    return 0
  fi

  mkdir -p /var/run/wpa_supplicant
  load_wifi_module

  if ! wait_for_iface; then
    log "skip: $WIFI_IFACE did not appear"
    return 0
  fi

  kill_pidfile "$WPA_PID"
  kill_pidfile "$DHCP_PID"
  rm -f "/var/run/wpa_supplicant/$WIFI_IFACE"

  ifconfig "$WIFI_IFACE" down >/dev/null 2>&1 || true
  ifconfig "$WIFI_IFACE" up >/dev/null 2>&1 || true

  wpa_supplicant -B -D nl80211,wext -i "$WIFI_IFACE" -c "$WIFI_CONFIG_PATH" -P "$WPA_PID"
  wait_for_assoc || true
  /bin/busybox udhcpc -n -q -t 10 -T 3 -p "$DHCP_PID" -i "$WIFI_IFACE" || true
  apply_wifi_routing
  cleanup_stale_eth_ipv4
  log "$WIFI_IFACE ready"
  return 0
}

stop_wifi() {
  kill_pidfile "$DHCP_PID"
  kill_pidfile "$WPA_PID"
  rm -f "/var/run/wpa_supplicant/$WIFI_IFACE"
  ip rule del priority 10000 2>/dev/null || true
  ip route flush table "$WIFI_ROUTE_TABLE" 2>/dev/null || true
  ifconfig "$WIFI_IFACE" down >/dev/null 2>&1 || true
}

case "${1:-start}" in
  start)
    start_wifi
    ;;
  stop)
    stop_wifi
    ;;
  restart|force-reload)
    stop_wifi
    start_wifi
    ;;
  status)
    wpa_cli -i "$WIFI_IFACE" status 2>/dev/null || true
    ip route show table "$WIFI_ROUTE_TABLE" 2>/dev/null || true
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|force-reload|status}" >&2
    exit 2
    ;;
esac

exit 0
EOF_WIFI
chmod 0755 /etc/init.d/wifi-autostart

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

ln -sf ../../init.d/wifi-autostart /etc/mujina/rc.d/S25-wifi-autostart

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
