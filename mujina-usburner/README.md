# Mujina USB Burner

This directory contains the tooling to create direct USB burn images for the
S21 AML control board while keeping the stock signed boot chain intact.

The current proven workflow is:

- keep the stock signed `bootloader`, `boot`, `recovery`, and DTB partitions
- build a Mujina UBI image for `mtd6` / `nvdata`
- repack a new Amlogic burn image around the stock flashcard image
- flash it in USB burn mode
- import a Mujina `nand_env` so U-Boot boots Mujina first

This does not try to replace the secure boot chain with custom signed blobs.

## What this builds

- a stock-signed Amlogic USB burn image
- a prebuilt `nvdata.PARTITION` carrying the Mujina rootfs
- a Mujina `nand_env.bin`
- a human-readable `mujina-uboot-env.txt` reference file
- checksums and a small manifest

The default image uses the proven stock-kernel path from
[payload-stockboot-compat](mujina_loader/payload-stockboot-compat):

- stock kernel from `mtd4`
- Mujina rootfs from `mtd6`
- U-Boot boot preference changed to Mujina first

## Files

- `build_stock_signed_mujina_image.sh`
  - unpacks the stock flashcard image, builds `nvdata.PARTITION`, injects it
    into `image.cfg`, generates `nand_env.bin`, and repacks a new burn image
- `flash_stock_signed_mujina_image.sh`
  - flashes the generated image with `flash-tool --reset=n`, uploads the
    generated `nand_env.bin` over USB, imports it into U-Boot, saves it, then
    finishes the burn with `burn_complete 1`
- `ubinize-nvdata.ini.in`
  - template used to build the `nvdata` UBI image

## Create An Image

From the repo root:

```bash
cd mujina-usburner
./build_stock_signed_mujina_image.sh
```

That script does all of the following:

1. Unpacks the stock flashcard image from [aml_upgrade_package_enc.img](stock_fw_restore/images/aml_upgrade_package_enc.img)
2. Builds a UBI image for `mtd6` from the Mujina payload rootfs
3. Adds `nvdata.PARTITION` to the unpacked `image.cfg`
4. Generates a matching Mujina [nand_env.bin](mujina-usburner/output/nand_env.bin)
5. Repacks a new stock-signed burn image
6. Validates that the repacked image really contains `nvdata.PARTITION`

The builder uses Docker to run `mkfs.ubifs` and `ubinize`, so Docker needs to
be installed and working on the host.

### Default Inputs

- stock flash image:
  [aml_upgrade_package_enc.img](stock_fw_restore/images/aml_upgrade_package_enc.img)
- packer:
  [aml_image_v2_packer](stock_fw_restore/tools/macos/aml_image_v2_packer)
- Mujina payload:
  [payload-stockboot-compat](mujina_loader/payload-stockboot-compat)
- env template:
  [stock_env_template.txt](mujina_loader/stock_env_template.txt)

### Default Outputs

- burn image:
  [aml_upgrade_package_mujina_stock_signed.img](mujina-usburner/output/aml_upgrade_package_mujina_stock_signed.img)
- Mujina `nvdata` partition:
  [nvdata.PARTITION](mujina-usburner/output/nvdata.PARTITION)
- Mujina env blob:
  [nand_env.bin](mujina-usburner/output/nand_env.bin)
- human-readable env reference:
  [mujina-uboot-env.txt](mujina-usburner/output/mujina-uboot-env.txt)
- manifest:
  [manifest.txt](mujina-usburner/output/manifest.txt)
- checksums:
  [SHA256SUMS](mujina-usburner/output/SHA256SUMS)

### Customizing The Image

The simplest customization point is `PAYLOAD_DIR`. For example, to build a
burn image from a different prepared payload:

```bash
cd mujina-usburner
PAYLOAD_DIR=/path/to/another/payload ./build_stock_signed_mujina_image.sh
```

Other useful overrides:

- `STOCK_IMAGE`
- `OUTPUT_IMAGE`
- `VOLUME_NAME`
- `PARTITION_SIZE`
- `UBI_RESERVED_PEBS`

## Flash An Image

Put the board into Amlogic USB burn mode, then run:

```bash
cd mujina-usburner
./flash_stock_signed_mujina_image.sh
```

The flasher intentionally uses `--reset=n` first so the board stays under USB
U-Boot control while the script:

1. flashes the repacked stock-signed image
2. uploads [nand_env.bin](mujina-usburner/output/nand_env.bin) into RAM
3. runs `env import -b ...`
4. runs `save`

and only then completes the burn with:

- `burn_complete 1`

This split is important. The original long `setenv mujinaboot ...` USB command
path was too fragile for this U-Boot build; binary env import is the reliable
path.

If the board does not enter USB burn mode automatically after a bad boot, the
serial fallback that worked on this board is:

```text
run usb_burning
```

or:

```text
update 1000
```

## Notes

- This workflow currently targets the proven stock-kernel Mujina path.
- It preinstalls Mujina onto `mtd6` as a UBI image with the volume name
  `mujina_rootfs`.
- It does not currently attempt to flash a custom kernel or DTB via USB burn.
- The generated [mujina-uboot-env.txt](mujina-usburner/output/mujina-uboot-env.txt) is now mainly a reference file; the flasher uses [nand_env.bin](mujina-usburner/output/nand_env.bin) for the actual U-Boot import step.
