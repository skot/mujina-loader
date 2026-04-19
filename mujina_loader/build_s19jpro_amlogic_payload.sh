#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BASE_BUILDER="${SCRIPT_DIR}/build_armhf_base_payload.sh"
MINER_BUILDER="${SCRIPT_DIR}/build_mujina_minerd_armhf.sh"
MUJINA_DIR="${MUJINA_DIR:-${WORKSPACE_ROOT}/mujina}"
BASE_PAYLOAD_DIR="${BASE_PAYLOAD_DIR:-}"
OUT_PAYLOAD="${OUT_PAYLOAD:-${SCRIPT_DIR}/mujina_armhf_s19jpro_amlogic}"
HOSTNAME_VALUE="${HOSTNAME_VALUE:-mujina-s19jpro-aml}"
PROFILE_NAME="${PROFILE_NAME:-Mujina S19j Pro Amlogic payload}"
VERSION_VALUE="${VERSION_VALUE:-0.3.0 (s19jpro-amlogic)}"
VERSION_ID_VALUE="${VERSION_ID_VALUE:-0.3.0}"
RUST_LOG_VALUE="${RUST_LOG_VALUE:-debug}"
POOL_URL="${POOL_URL:-stratum+tcp://pool.256foundation.org:3333}"
POOL_USER="${POOL_USER:-npub1ql2zzp3g6yndgz05js7wdc4qkr88wkyne5nw2cc7csrtzqs0yeesgwrxya.mujina-jPro-amlogic}"
POOL_PASS="${POOL_PASS:-x}"
API_LISTEN="${API_LISTEN:-0.0.0.0:7785}"
MINER_BIN="${MINER_BIN:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mujina-s19jpro-payload.XXXXXX")"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./build_s19jpro_amlogic_payload.sh [options]

Options:
  --mujina-dir PATH         Mujina repo path (default: ${MUJINA_DIR})
  --base-payload-dir PATH   Existing payload dir to extend instead of rebuilding
  --miner-bin PATH          Use an existing mujina-minerd binary
  --out-dir PATH            Output payload dir (default: ${OUT_PAYLOAD})
  --hostname NAME           Hostname embedded into the payload (default: ${HOSTNAME_VALUE})
  --pool-url URL            Stratum URL for /home/root/mujina.env
  --pool-user USER          Stratum worker/user for /home/root/mujina.env
  --pool-pass PASS          Stratum password for /home/root/mujina.env
  --api-listen ADDR         API bind address (default: ${API_LISTEN})
  --rust-log LEVEL          RUST_LOG default written to /home/root/mujina.env
  --help                    Show this message

If --base-payload-dir is not provided, this wrapper calls build_armhf_base_payload.sh
first. That step still requires Docker, just like the existing loader flow.
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
    --mujina-dir) MUJINA_DIR="${2:-}"; shift 2 ;;
    --base-payload-dir) BASE_PAYLOAD_DIR="${2:-}"; shift 2 ;;
    --miner-bin) MINER_BIN="${2:-}"; shift 2 ;;
    --out-dir) OUT_PAYLOAD="${2:-}"; shift 2 ;;
    --hostname) HOSTNAME_VALUE="${2:-}"; shift 2 ;;
    --pool-url) POOL_URL="${2:-}"; shift 2 ;;
    --pool-user) POOL_USER="${2:-}"; shift 2 ;;
    --pool-pass) POOL_PASS="${2:-}"; shift 2 ;;
    --api-listen) API_LISTEN="${2:-}"; shift 2 ;;
    --rust-log) RUST_LOG_VALUE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

need_cmd python3
need_cmd shasum

[[ -d "${MUJINA_DIR}" ]] || die "Missing Mujina repo: ${MUJINA_DIR}"
for required in start.sh stop.sh mujina-hb2.toml mujina.env.example; do
  [[ -f "${MUJINA_DIR}/${required}" ]] || die "Missing ${required} in ${MUJINA_DIR}"
done

if [[ -z "${BASE_PAYLOAD_DIR}" ]]; then
  [[ -x "${BASE_BUILDER}" ]] || die "Missing base payload builder: ${BASE_BUILDER}"
  BASE_PAYLOAD_DIR="${WORK_DIR}/base-payload"
  OUT_PAYLOAD="${OUT_PAYLOAD}"

  OUT_PAYLOAD="${BASE_PAYLOAD_DIR}" \
  HOSTNAME_VALUE="${HOSTNAME_VALUE}" \
  PROFILE_NAME="${PROFILE_NAME}" \
  VERSION_VALUE="${VERSION_VALUE}" \
  VERSION_ID_VALUE="${VERSION_ID_VALUE}" \
  "${BASE_BUILDER}"
fi

[[ -d "${BASE_PAYLOAD_DIR}" ]] || die "Missing base payload dir: ${BASE_PAYLOAD_DIR}"
[[ -f "${BASE_PAYLOAD_DIR}/rootfs.tar.gz" ]] || die "Missing ${BASE_PAYLOAD_DIR}/rootfs.tar.gz"
[[ -f "${BASE_PAYLOAD_DIR}/nand_env.bin" ]] || die "Missing ${BASE_PAYLOAD_DIR}/nand_env.bin"

if [[ -z "${MINER_BIN}" ]]; then
  [[ -x "${MINER_BUILDER}" ]] || die "Missing miner build helper: ${MINER_BUILDER}"
  MINER_BIN="${WORK_DIR}/mujina-minerd"
  MUJINA_DIR="${MUJINA_DIR}" OUTPUT_BIN="${MINER_BIN}" "${MINER_BUILDER}"
fi

[[ -f "${MINER_BIN}" ]] || die "Missing miner binary: ${MINER_BIN}"

rm -rf "${OUT_PAYLOAD}"
mkdir -p "${OUT_PAYLOAD}" "${WORK_DIR}/rootfs/home/root"
cp -R "${BASE_PAYLOAD_DIR}/." "${OUT_PAYLOAD}/"

python3 - "${BASE_PAYLOAD_DIR}/rootfs.tar.gz" "${WORK_DIR}/rootfs" <<'PY'
import sys
import tarfile

rootfs_tar = sys.argv[1]
dest = sys.argv[2]

with tarfile.open(rootfs_tar, "r:*") as tar:
    kwargs = {}
    if hasattr(tarfile, "data_filter"):
        kwargs["filter"] = "fully_trusted"
    tar.extractall(dest, **kwargs)
PY

cp "${MINER_BIN}" "${WORK_DIR}/rootfs/home/root/mujina-minerd"
cp "${MUJINA_DIR}/start.sh" "${WORK_DIR}/rootfs/home/root/start.sh"
cp "${MUJINA_DIR}/stop.sh" "${WORK_DIR}/rootfs/home/root/stop.sh"
cp "${MUJINA_DIR}/mujina-hb2.toml" "${WORK_DIR}/rootfs/home/root/mujina-hb2.toml"
cp "${MUJINA_DIR}/mujina.env.example" "${WORK_DIR}/rootfs/home/root/mujina.env.example"

cat > "${WORK_DIR}/rootfs/home/root/mujina.env" <<EOF
MUJINA_LOG_LEVEL=${RUST_LOG_VALUE}
MUJINA_CONFIG=/home/root/mujina-hb2.toml
MUJINA_POOL_URL=${POOL_URL}
MUJINA_POOL_USER=${POOL_USER}
MUJINA_POOL_PASS=${POOL_PASS}
MUJINA_API_LISTEN=${API_LISTEN}
EOF

chmod 0755 "${WORK_DIR}/rootfs/home/root/mujina-minerd"
chmod 0755 "${WORK_DIR}/rootfs/home/root/start.sh"
chmod 0755 "${WORK_DIR}/rootfs/home/root/stop.sh"
chmod 0644 "${WORK_DIR}/rootfs/home/root/mujina-hb2.toml"
chmod 0644 "${WORK_DIR}/rootfs/home/root/mujina.env"
chmod 0644 "${WORK_DIR}/rootfs/home/root/mujina.env.example"

python3 - "${WORK_DIR}/rootfs" "${OUT_PAYLOAD}/rootfs.tar.gz" <<'PY'
import os
import sys
import tarfile

root = sys.argv[1]
output = sys.argv[2]

def normalize(ti: tarfile.TarInfo) -> tarfile.TarInfo:
    ti.uid = 0
    ti.gid = 0
    ti.uname = "root"
    ti.gname = "root"
    return ti

with tarfile.open(output, "w:gz", format=tarfile.USTAR_FORMAT) as tar:
    for entry in sorted(os.listdir(root)):
        tar.add(os.path.join(root, entry), arcname=entry, recursive=True, filter=normalize)
PY

miner_rev="$(git -C "${MUJINA_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
cat >> "${OUT_PAYLOAD}/manifest.txt" <<EOF
miner_binary=/home/root/mujina-minerd
miner_config=/home/root/mujina-hb2.toml
miner_env=/home/root/mujina.env
miner_start=/home/root/start.sh
miner_stop=/home/root/stop.sh
miner_source_rev=${miner_rev}
EOF

(
  cd "${OUT_PAYLOAD}"
  files=()
  while IFS= read -r file; do
    files+=("${file#./}")
  done < <(find . -maxdepth 1 -type f ! -name SHA256SUMS | sort)
  shasum -a 256 "${files[@]}" > SHA256SUMS
)

echo "Built ${OUT_PAYLOAD}"
echo "Ready-to-copy board assets baked into /home/root:"
echo "  mujina-minerd"
echo "  start.sh"
echo "  stop.sh"
echo "  mujina-hb2.toml"
echo "  mujina.env"
echo "  mujina.env.example"
