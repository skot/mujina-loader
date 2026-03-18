#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
import zlib
from pathlib import Path


def parse_env_text(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key] = value
    return env


def build_mujinaboot_ubifs_image(volume: str, mtd_index: int, dtb_filename: str) -> str:
    return (
        f"ubi part nvdata; "
        f"ubifsmount ubi0:{volume}; "
        f"ubifsload ${{ker_addr}} Image; "
        f"ubifsload ${{dtb_addr}} {dtb_filename}; "
        f"setenv bootargs \"init=/sbin/init console=ttyS0,115200 "
        f"no_console_suspend earlycon=aml_uart,0xff803000 jtag=disable "
        f"root=ubi0:{volume} rootfstype=ubifs rw ubi.mtd={mtd_index},2048\"; "
        f"booti ${{ker_addr}} - ${{dtb_addr}}"
    )


def build_mujinaboot_stock_boot(volume: str, mtd_index: int) -> str:
    return (
        "run storeargs; "
        f"setenv bootargs ${{bootargs}} root=ubi0:{volume} rootfstype=ubifs rw "
        f"ubi.mtd={mtd_index},2048 init=/sbin/init skip_initramfs; "
        "if imgread kernel ${boot_part} ${loadaddr}; then bootm ${loadaddr}; fi"
    )


def render_env(env: dict[str, str], env_size: int, endian: str) -> bytes:
    items = [f"{k}={v}".encode("ascii") for k, v in env.items()]
    payload = b"\x00".join(items) + b"\x00\x00"
    if len(payload) > env_size - 4:
      raise ValueError("environment too large for target nand_env region")
    payload = payload.ljust(env_size - 4, b"\xff")
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    prefix = struct.pack("<I" if endian == "little" else ">I", crc)
    return prefix + payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate a Mujina nand_env blob")
    parser.add_argument("--template", required=True, help="Env text template file")
    parser.add_argument("--output", required=True, help="Output nand_env binary")
    parser.add_argument("--volume-name", default="mujina_rootfs", help="UBI volume name for the Mujina rootfs")
    parser.add_argument("--boot-mode", choices=("ubifs-image", "stock-boot"), default="ubifs-image", help="How mujinaboot should load the kernel")
    parser.add_argument("--mtd-index", type=int, default=6, help="MTD index backing the Mujina UBI volume")
    parser.add_argument("--dtb-filename", default="axg_s400_antminer.dtb", help="DTB filename when booting Image+DTB from UBIFS")
    parser.add_argument("--env-size", type=lambda x: int(x, 0), default=0x10000, help="nand_env size in bytes")
    parser.add_argument("--crc-endian", choices=("little", "big"), default="little", help="CRC endianness in the nand_env header")
    args = parser.parse_args()

    env = parse_env_text(Path(args.template))
    env["ker_addr"] = env.get("ker_addr", "1080000")
    env["dtb_addr"] = env.get("dtb_addr", "1000000")
    if args.boot_mode == "stock-boot":
        env["mujinaboot"] = build_mujinaboot_stock_boot(args.volume_name, args.mtd_index)
    else:
        env["mujinaboot"] = build_mujinaboot_ubifs_image(args.volume_name, args.mtd_index, args.dtb_filename)
    env["bootcmd"] = "run mujinaboot || run storeboot"

    blob = render_env(env, args.env_size, args.crc_endian)
    Path(args.output).write_bytes(blob)


if __name__ == "__main__":
    main()
