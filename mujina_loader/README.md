# Mujina Loader for S21 AML

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
- `build_yocto_kernel_compat_payload.sh`
  - assembles a custom-kernel test payload from the Yocto-built `Image`, the
    deployed validated DTB, and the already-working compat rootfs
- `payload-yocto-kernel-compat`
  - custom-kernel test payload that changes only kernel/DTB boot while keeping
    the known-good compat rootfs constant
- `build_static_rescue_payload.sh`
  - builds a minimal static BusyBox rescue rootfs and pairs it with the custom
    Yocto kernel for early-userspace debugging
- `payload-yocto-kernel-rescue`
  - custom-kernel rescue payload for debugging PID 1 crashes without the full
    glibc/systemd userspace
- `build_static_rescue_payload_armhf.sh`
  - builds a minimal static BusyBox rescue rootfs as `armhf` and pairs it with
    the custom Yocto kernel to test the same 32-bit userspace mode used by the
    known-good amlogic-cb-tools `4.9.337` board
- `payload-yocto-kernel-rescue-armhf`
  - custom-kernel rescue payload for testing whether the kernel reliably starts
    a 32-bit PID 1 even when the aarch64 rescue payload crashes
- `build_armhf_network_payload.sh`
  - builds a minimal `armhf` Mujina bring-up rootfs with DHCP on `eth0`,
    BusyBox `httpd`, and BusyBox `telnetd`, then pairs it with the custom Yocto
    kernel and DTB
- `payload-yocto-kernel-armhf-net`
  - custom-kernel `armhf` network bring-up payload intended to come up on the
    LAN instead of only dropping to a serial shell
- `build_armhf_full_payload.sh`
  - builds a fuller `armhf` Mujina development userspace from Debian Bookworm
    with SSH, telnet, common CLI tools, and the same proven custom-kernel boot
    path
- `payload-yocto-kernel-armhf-full`
  - fuller custom-kernel `armhf` payload for development on the LAN with
    password login as `root/root`

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
cd mujina_loader
./assemble_yocto_payload.sh
```

That script exports:

- kernel from `yocto` deploy output
- board DTB from `yocto` deploy output
- `mujina-image-dev` rootfs tarball
- generated `nand_env.bin`
- `SHA256SUMS` and `manifest.txt`

For the next lower-risk custom-kernel test, build the focused compat payload:

```bash
cd mujina_loader
./build_yocto_kernel_compat_payload.sh
```

That payload reuses the known-good compat rootfs from `payload-stockboot-compat`
and only changes:

- kernel: Yocto-built `Image`
- DTB: deployed validated `axg_s400_antminer.dtb`
- boot mode: `ubifs-image` / `booti`

For PID 1 / userspace crash debugging under the custom kernel, build the static
rescue payload:

```bash
cd mujina_loader
./build_static_rescue_payload.sh
```

That payload keeps:

- custom Yocto-built `Image`
- validated `axg_s400_antminer.dtb`

and replaces the rootfs with a tiny static BusyBox environment whose `/sbin/init`
mounts `/proc`, `/sys`, and `/dev`, prints a few diagnostics, tries
`/usr/bin/bash.bash` if present, and then drops to a serial shell.

To test the working hypothesis that the known-good `4.9.337` board is happiest
with a 32-bit userspace, build the `armhf` rescue payload:

```bash
cd mujina_loader
./build_static_rescue_payload_armhf.sh
```

That payload keeps the same custom kernel and DTB, but replaces the rootfs with
a statically linked `armhf` BusyBox userspace and a simple shell-script init.

To build the next-step `armhf` rootfs with DHCP and LAN access:

```bash
cd mujina_loader
./build_armhf_network_payload.sh
```

That payload currently:

- brings up `eth0` with `udhcpc`
- serves a small status page with BusyBox `httpd`
- exposes a shell with BusyBox `telnetd`
- keeps the same custom kernel and DTB that already reached a working `armhf`
  rescue shell

To build the fuller `armhf` development userspace:

```bash
cd mujina_loader
./build_armhf_full_payload.sh
```

That payload currently:

- keeps the proven custom kernel and DTB path
- uses a Debian Bookworm `armhf` userspace
- provides `root/root` login over Dropbear SSH
- keeps telnet and the HTTP status page for easy bring-up
- includes a broader CLI toolbox for experimentation directly on the board

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
cd mujina_loader
./install_mujina_aml.sh --host 192.168.1.52
```
