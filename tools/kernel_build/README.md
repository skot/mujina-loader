# Kernel Build

This directory is the non-Yocto custom-kernel path for `mujina-loader`.

It is based on the known-good kernel workflow validated earlier in the sibling
workspace project:

- source family: `LineageOS/android_kernel_amlogic_linux-4.9`
- baseline config: `Antminer-4.9.241.config`
- target board family: Bitmain Amlogic S21 / AXG / A113D

The goal here is to iterate on a custom kernel without changing the rest of the
release model:

- keep the stock signed boot chain
- keep the existing Mujina userspace/rootfs flow
- swap in a custom kernel and companion DTB deliberately

## Files

- `Antminer-4.9.241.config`
  - baseline config copied from the working `amlogic-cb-tools` flow
- `build_custom_kernel.sh`
  - builds an arm64 Amlogic 4.9 kernel in Docker and writes outputs under
    `output/`
- `build_known_good_ecm_kernel.sh`
  - builds the minimal GT Touch ECM experiment kernel from the exact
    `amlogic-cb-tools` baseline config copied into this repo, with only
    `USB_NET_DRIVERS`, `USB_USBNET`, and `USB_NET_CDCETHER` enabled
  - uses a fresh kernel clone on every run and fails if the final config
    contains broader USB-net, WLAN, cfg80211, or rfkill options
- `build_custom_kernel_payload.sh`
  - combines `mujina_armhf_base` with the custom `Image` and companion DTB
    into a custom-kernel payload directory
- `install_custom_kernel.sh`
  - uploads a built kernel image to a running board and verifies the checksum
- `install_companion_dtb.sh`
  - uploads a DTB to a running board and verifies the checksum
- `install_custom_kernel_pair.sh`
  - installs kernel + DTB + matching `nand_env` onto a running board and
    reboots into the custom-kernel path

## Build

From the repo root:

```bash
cd tools/kernel_build
./build_custom_kernel.sh
```

Default outputs:

- `output/Image-mujina-custom`
- `output/Image-mujina-custom.sha256`
- `output/.config.final`
- `output/olddefconfig.log`
- `output/build.log`

Build a custom-kernel payload:

```bash
cd tools/kernel_build
./build_custom_kernel_payload.sh
```

Build the minimal known-good-plus-ECM experiment kernel:

```bash
cd tools/kernel_build
./build_known_good_ecm_kernel.sh
```

That builder is intentionally strict. It verifies the post-`olddefconfig`
result before compiling and only succeeds when the final config is:

- required:
  `CONFIG_USB_NET_DRIVERS=y`
  `CONFIG_USB_USBNET=y`
  `CONFIG_USB_NET_CDCETHER=y`
- forbidden:
  `CONFIG_USB_NET_CDC_EEM`
  `CONFIG_USB_NET_CDC_NCM`
  `CONFIG_USB_NET_RNDIS_HOST`
  `CONFIG_WLAN`
  `CONFIG_CFG80211`
  `CONFIG_RFKILL`

## Install On A Running Board

Install the kernel:

```bash
cd tools/kernel_build
BOARD_PASSWORD=root REBOOT_AFTER_INSTALL=1 \
  ./install_custom_kernel.sh 192.168.1.52
```

Install a companion DTB:

```bash
cd tools/kernel_build
BOARD_PASSWORD=root REBOOT_AFTER_INSTALL=1 \
  ./install_companion_dtb.sh 192.168.1.52 /path/to/axg_s400_antminer.dtb
```

Or install the whole tested kernel pair in one step:

```bash
cd tools/kernel_build
BOARD_PASSWORD=root ./install_custom_kernel_pair.sh 192.168.1.52
```

## Notes

- This is intentionally separate from Yocto for now.
- The first goal is a reproducible custom-kernel build/install loop.
- Once that loop is stable, the next step is wiring a custom-kernel payload
  into the existing Mujina flash/install paths.
