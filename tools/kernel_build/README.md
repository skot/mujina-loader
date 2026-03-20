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
