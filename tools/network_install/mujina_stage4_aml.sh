#!/bin/sh
set -eu

SRC_DIR="${1:-/tmp/mujina}"
VOLUME_NAME="${VOLUME_NAME:-mujina_rootfs}"
UBI_INDEX="${UBI_INDEX:-2}"
MTD_INDEX="${MTD_INDEX:-6}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/mujina}"
ENV_DEVICE="${ENV_DEVICE:-/dev/nand_env}"
READY_MARKER="${READY_MARKER:-/tmp/mujina-ready-for-reboot}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

[ "$(id -u)" = "0" ] || die "Run as root"
[ -d "${SRC_DIR}" ] || die "Missing source dir: ${SRC_DIR}"
[ -f "${SRC_DIR}/nand_env.bin" ] || die "Missing env blob: ${SRC_DIR}/nand_env.bin"

HAVE_KERNEL_ASSETS="0"
if [ -f "${SRC_DIR}/Image" ] && [ -f "${SRC_DIR}/axg_s400_antminer.dtb" ]; then
  HAVE_KERNEL_ASSETS="1"
fi

ROOTFS_ARCHIVE=""
for candidate in rootfs.tar.gz rootfs.tgz rootfs.tar; do
  if [ -f "${SRC_DIR}/${candidate}" ]; then
    ROOTFS_ARCHIVE="${SRC_DIR}/${candidate}"
    break
  fi
done
[ -n "${ROOTFS_ARCHIVE}" ] || die "Missing rootfs archive in ${SRC_DIR}"

need_cmd ubiformat
need_cmd ubiattach
need_cmd ubidetach
need_cmd ubimkvol
need_cmd mount
need_cmd tar
need_cmd dd
need_cmd sync

kill_matching_pids() {
  pattern="$1"
  ps | grep "${pattern}" | grep -v grep | awk '{print $1}' | while read -r pid; do
    [ -n "${pid}" ] || continue
    kill -9 "${pid}" >/dev/null 2>&1 || true
  done
}

echo "[1/8] Stopping stock services"
for svc in /etc/init.d/S70cgminer /etc/init.d/S71monitorcg /etc/init.d/S52miner_act /etc/init.d/S50lighttpd /etc/init.d/S59nginx; do
  if [ -x "${svc}" ]; then
    "${svc}" stop >/dev/null 2>&1 || true
  fi
done
sleep 1
killall -9 cgminer bmminer daemons monitor-ipsig monitor-recobtn lighttpd nginx 2>/dev/null || true
for _attempt in 1 2 3 4 5; do
  kill_matching_pids '/etc/init.d/S70cgminer'
  kill_matching_pids '/etc/init.d/S71monitorcg'
  kill_matching_pids '/etc/init.d/S52miner_act'
  if ps | grep -E '[[:space:]](cgminer|bmminer|daemons|lighttpd|nginx)([[:space:]]|$)' >/dev/null 2>&1 || \
     ps | grep -E '/etc/init.d/S70cgminer|/etc/init.d/S71monitorcg|/etc/init.d/S52miner_act' >/dev/null 2>&1; then
    killall -9 cgminer bmminer daemons monitor-ipsig monitor-recobtn lighttpd nginx 2>/dev/null || true
    sleep 1
  else
    break
  fi
done
sync

echo "[2/8] Unmounting old nvdata/config overlays if present"
umount /nvdata >/dev/null 2>&1 || true
umount -l /nvdata >/dev/null 2>&1 || true
umount "${MOUNT_POINT}" >/dev/null 2>&1 || true
sync
sleep 1

detach_mtd_ubi() {
  ubidetach /dev/ubi_ctrl -d "${UBI_INDEX}" >/dev/null 2>&1 || true
  if [ -d /sys/class/ubi ]; then
    for ubi_path in /sys/class/ubi/ubi[0-9]*; do
      [ -d "${ubi_path}" ] || continue
      [ -f "${ubi_path}/mtd_num" ] || continue
      mtd_num="$(cat "${ubi_path}/mtd_num" 2>/dev/null || true)"
      case "${mtd_num}" in
        "${MTD_INDEX}")
          ubi_dev="$(basename "${ubi_path}" | sed 's/^ubi//')"
          ubidetach /dev/ubi_ctrl -d "${ubi_dev}" >/dev/null 2>&1 || true
          ;;
      esac
    done
  fi
  ubidetach /dev/ubi_ctrl -m "${MTD_INDEX}" >/dev/null 2>&1 || true
}

mtd_still_attached() {
  [ -d /sys/class/ubi ] || return 1
  for ubi_path in /sys/class/ubi/ubi[0-9]*; do
    [ -d "${ubi_path}" ] || continue
    [ -f "${ubi_path}/mtd_num" ] || continue
    mtd_num="$(cat "${ubi_path}/mtd_num" 2>/dev/null || true)"
    case "${mtd_num}" in
      "${MTD_INDEX}")
        return 0
        ;;
    esac
  done
  return 1
}

for attempt in $(seq 1 20); do
  detach_mtd_ubi
  if ! mtd_still_attached; then
    echo "Detached mtd${MTD_INDEX} from UBI"
    break
  fi
  echo "Waiting for mtd${MTD_INDEX} to detach from UBI (attempt ${attempt}/20)"
  sleep 2
done

if mtd_still_attached; then
  die "mtd${MTD_INDEX} is still attached to UBI after waiting"
fi

echo "[3/8] Reformatting mtd${MTD_INDEX}"
ubiformat "/dev/mtd${MTD_INDEX}" -y >/dev/null

echo "[4/8] Creating Mujina UBI volume"
ubiattach /dev/ubi_ctrl -m "${MTD_INDEX}" -b 2 -d "${UBI_INDEX}" >/dev/null
ubimkvol "/dev/ubi${UBI_INDEX}" -m -N "${VOLUME_NAME}" >/dev/null

echo "[5/8] Mounting Mujina root volume"
mkdir -p "${MOUNT_POINT}"
mount -t ubifs "/dev/ubi${UBI_INDEX}_0" "${MOUNT_POINT}"

echo "[6/8] Installing rootfs"
case "${ROOTFS_ARCHIVE}" in
  *.tar.gz|*.tgz)
    tar -xzf "${ROOTFS_ARCHIVE}" -C "${MOUNT_POINT}"
    ;;
  *)
    tar -xf "${ROOTFS_ARCHIVE}" -C "${MOUNT_POINT}"
    ;;
esac

echo "[7/8] Installing boot assets"
if [ "${HAVE_KERNEL_ASSETS}" = "1" ]; then
  cp "${SRC_DIR}/Image" "${MOUNT_POINT}/Image"
  cp "${SRC_DIR}/axg_s400_antminer.dtb" "${MOUNT_POINT}/axg_s400_antminer.dtb"
  echo "Installed custom kernel and DTB into ${MOUNT_POINT}"
else
  echo "No Image/DTB provided; retaining stock boot partition kernel path"
fi
sync

[ -x "${MOUNT_POINT}/sbin/init" ] || [ -f "${MOUNT_POINT}/sbin/init" ] || die "Installed rootfs has no /sbin/init"

echo "[8/8] Writing boot env"
dd if="${SRC_DIR}/nand_env.bin" of="${ENV_DEVICE}" bs=65536 count=1 conv=fsync >/dev/null 2>&1
printf '%s\n' ready_for_reboot > "${READY_MARKER}"
sync

echo "Mujina payload installed to mtd${MTD_INDEX} (${VOLUME_NAME})"
if [ "${HAVE_KERNEL_ASSETS}" = "1" ]; then
  echo "Kernel: ${MOUNT_POINT}/Image"
  echo "DTB:    ${MOUNT_POINT}/axg_s400_antminer.dtb"
else
  echo "Kernel: stock boot partition (${ENV_DEVICE} boot env points at ${VOLUME_NAME} rootfs)"
fi
echo "Rootfs: ${ROOTFS_ARCHIVE}"
echo "Boot env written to ${ENV_DEVICE}"
echo "ready_for_reboot"
