# Mujina Loader for S21 AML

This directory contains a first-pass replacement for the Amlogic `stage4_aml`
flow used by LuxOS Commander.

The design goal is destructive boot replacement on stock Amlogic control boards:

- reformat `mtd6` / `nvdata`
- create a new UBI volume there
- install a bootable Mujina Linux environment
- write a new `nand_env` boot selection that prefers Mujina

This workflow does not preserve stock miner config.

## Files

- `mujina_stage4_aml.sh`
  - on-target destructive installer; expects to run as `root`
- `install_mujina_aml.sh`
  - host-side uploader/runner that uses `../amlogic_bootstrap.sh`
- `assemble_yocto_payload.sh`
  - exports the built Yocto artifacts from the Docker volume into `./payload`
    and generates `nand_env.bin`
- `generate_nand_env.py`
  - host-side generator for a U-Boot env blob with `mujinaboot`
- `stock_env_template.txt`
  - stock-like env text template used as a starting point
- `payload-stockboot`
  - conservative payload that keeps using the stock `mtd4` boot image and
    points it at the Mujina UBIFS rootfs on `mtd6`
- `payload-stockboot-compat`
  - current recommended payload for vendor-kernel bring-up; keeps the stock
    `mtd4` boot image, adds a simpler DHCP config for `eth0`, and masks the
    systemd units that were dropping the board into emergency mode

## Asset contract

`install_mujina_aml.sh` now defaults to the compatibility-tuned assets in
`./payload-stockboot-compat`:

- `rootfs.tar.gz`
- `nand_env.bin`

That stock-boot payload intentionally does not ship a custom kernel. Its
`nand_env.bin` tells U-Boot to:

- run `storeargs`
- set `root=ubi0:mujina_rootfs rootfstype=ubifs rw ubi.mtd=6,2048`
- boot the existing stock kernel from `mtd4` with
  `imgread kernel ${boot_part} ${loadaddr}; bootm ${loadaddr}`

The custom-kernel flow remains available in `./payload` and expects:

- `Image`
- `axg_s400_antminer.dtb`
- `rootfs.tar.gz`
- `nand_env.bin`

You can populate that directory from the successful Yocto build with:

```bash
cd /Users/skot/Bitcoin/Mujina/mujna-loader/mujina_loader
./assemble_yocto_payload.sh
```

That script exports:

- kernel from `yocto` deploy output
- board DTB from `yocto` deploy output
- `mujina-image-dev` rootfs tarball
- generated `nand_env.bin`
- `SHA256SUMS` and `manifest.txt`

The rootfs tarball must unpack into the UBI volume root and provide at least:

- `/sbin/init`
- a complete userspace for your target board

If `Image` and `axg_s400_antminer.dtb` are present, `mujina_stage4_aml.sh`
copies them into the UBI volume and uses the custom-kernel boot model. If they
are omitted, the installer keeps the stock kernel path and only replaces the
rootfs plus `nand_env`.

## Current boot model

There are now two supported `mujinaboot` styles:

1. Conservative stock-kernel mode:

- `run storeargs`
- `setenv bootargs ... root=ubi0:mujina_rootfs rootfstype=ubifs rw ubi.mtd=6,2048 init=/sbin/init skip_initramfs`
- `imgread kernel ${boot_part} ${loadaddr}`
- `bootm ${loadaddr}`

The compat variant keeps the same boot model but overlays:

- a minimal `/etc/fstab`
- `DHCP=yes` for `eth0`
- masks for `tmp.mount`, `var-volatile.mount`, `systemd-remount-fs.service`,
  and the kernel filesystem mounts that were failing on the vendor `4.9.113`
  kernel

2. Custom kernel mode:

- `ubi part nvdata`
- `ubifsmount ubi0:mujina_rootfs`
- `ubifsload ${ker_addr} Image`
- `ubifsload ${dtb_addr} axg_s400_antminer.dtb`
- `booti ${ker_addr} - ${dtb_addr}`

The kernel command line is set to boot the rootfs from:

- `root=ubi0:mujina_rootfs`
- `rootfstype=ubifs`
- `ubi.mtd=6,2048`

## Notes

- `mtd6` on the stock S21 AML board is `nvdata`.
- stock mounts it as UBIFS on `/nvdata`.
- this workflow repurposes `mtd6` as the live Mujina root volume.
- it assumes boot control is handled by writing `/dev/nand_env`.

## Status

This is an implementation scaffold built from reverse engineering and live board
validation of the bootstrap path. The conservative stock-kernel path is the
current recommended first-boot route because it reuses the board's known-good
`mtd4` Android boot image and only swaps in the Mujina UBIFS rootfs.

With a successful Yocto build, the next end-to-end installer step is:

```bash
cd /Users/skot/Bitcoin/Mujina/mujna-loader/mujina_loader
./install_mujina_aml.sh --host 192.168.1.52
```
