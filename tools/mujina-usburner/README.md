# Mujina USB Burner

This directory contains the tooling to create direct USB burn images for the
S21 AML control board while keeping the stock signed boot chain intact.

The current proven workflow is:

- keep the stock signed `bootloader`, `boot`, `recovery`, and DTB partitions
- build a Mujina UBI image for `mtd6` / `nvdata`
- repack a new Amlogic burn image around the stock flashcard image
- flash it in USB burn mode
- import a staging Mujina `nand_env` so U-Boot boots Mujina first
- let Mujina finalize the steady-state `nand_env` on first boot and reboot once

This does not try to replace the secure boot chain with custom signed blobs.

## What this builds

- a stock-signed Amlogic USB burn image
- a prebuilt `nvdata.PARTITION` carrying the Mujina rootfs and a runtime env blob
- a staging `nand_env.bin`
- a steady-state `runtime_nand_env.bin`
- a human-readable `mujina-uboot-env.txt` reference file
- checksums and a small manifest

The default image uses the proven stock-kernel path from
`../../mujina_loader/mujina_armhf_base`:

- stock kernel from `mtd4`
- Mujina rootfs from `mtd6`
- U-Boot boot preference changed to Mujina first

## Files

- `build_stock_signed_mujina_image.sh`
  - unpacks the stock flashcard image, builds `nvdata.PARTITION`, injects it
    into `image.cfg`, exports the staging and runtime env blobs, and repacks a
    new burn image
- `stage_usb_flashdrive_bundle.sh`
  - builds the stock-signed Mujina burn image, extracts the stock
    `aml_sdc_burn.UBOOT.ENC` helper, and stages a FAT-root USB-stick directory
    for the board's cold-boot `aml_sdc_burn.ini` probe
- `build_aml_autoscript.sh`
  - generates an experimental `aml_autoscript` that loads `nand_env.bin`,
    imports it with `env import`, saves it, and resets
- `build_recovery_handoff_image.sh`
  - builds an experimental `recovery.img` helper from the stock boot image
    kernel plus a tiny ramdisk that writes an embedded staging `nand_env.bin`
    to `/dev/nand_env` and reboots
- `stage_usb_handoff_bundle.sh`
  - stages an experimental FAT-root USB-stick directory that combines the
    stock-signed burn image with both the `aml_autoscript` and `recovery.img`
    handoff paths
- `build_boot_handoff_partition.sh`
  - builds the same one-shot helper image as `build_recovery_handoff_image.sh`
    but emits it as `boot.PARTITION` so the stock boot slot itself performs the
    first Linux-side `nand_env` handoff
- `stage_usb_boothelper_bundle.sh`
  - stages an experimental FAT-root USB-stick directory whose flashed image
    replaces `boot.PARTITION` with the one-shot helper, avoiding any dependence
    on post-burn `aml_autoscript` or `recovery_from_udisk`
- `flash_stock_signed_mujina_image.sh`
  - flashes the generated image with `flash-tool --reset=n`, uploads the
    generated `nand_env.bin` over USB, imports it into U-Boot, saves it, then
    finishes the burn with `burn_complete 1`
- `ubinize-nvdata.ini.in`
  - template used to build the `nvdata` UBI image

## Create An Image

From the repo root:

```bash
cd tools/mujina-usburner
./build_stock_signed_mujina_image.sh
```

That script does all of the following:

1. Unpacks the stock flashcard image from `../stock_fw_restore/images/aml_upgrade_package_enc.img`
2. Builds a UBI image for `mtd6` from the Mujina payload rootfs
3. Adds `nvdata.PARTITION` to the unpacked `image.cfg`
4. Generates a matching Mujina `nand_env.bin`
5. Exports `runtime_nand_env.bin` for the in-rootfs first-boot finalizer
6. Repacks a new stock-signed burn image
7. Validates that the repacked image really contains `nvdata.PARTITION`

The builder uses Docker to run `mkfs.ubifs` and `ubinize`, so Docker needs to
be installed and working on the host.

### Default Inputs

- stock flash image:
  `../stock_fw_restore/images/aml_upgrade_package_enc.img`
- packer:
  `../stock_fw_restore/tools/macos/aml_image_v2_packer`
- Mujina payload:
  `../../mujina_loader/mujina_armhf_base`
- env template:
  `../../mujina_loader/stock_env_template.txt`

### Default Outputs

- burn image:
  `output/aml_upgrade_package_mujina_armhf_base.img`
- Mujina `nvdata` partition:
  `output/nvdata.PARTITION`
- Mujina env blob:
  `output/nand_env.bin`
- Mujina runtime env blob:
  `output/runtime_nand_env.bin`
- human-readable env reference:
  `output/mujina-uboot-env.txt`
- manifest:
  `output/manifest.txt`
- checksums:
  `output/SHA256SUMS`

### Customizing The Image

The simplest customization point is `PAYLOAD_DIR`. For example, to build a
burn image from a different prepared payload:

```bash
cd tools/mujina-usburner
PAYLOAD_DIR=/path/to/another/payload ./build_stock_signed_mujina_image.sh
```

Other useful overrides:

- `STOCK_IMAGE`
- `OUTPUT_IMAGE`
- `VOLUME_NAME`
- `PARTITION_SIZE`
- `UBI_RESERVED_PEBS`
- `INCLUDE_NENV_PARTITION`

## Experimental: Include `nenv` In The Burn Image

There is now an experimental packaging mode that adds a `nenv.PARTITION`
payload to the burn image:

```bash
cd tools/mujina-usburner
INCLUDE_NENV_PARTITION=1 ./build_stock_signed_mujina_image.sh
```

That causes the repacked `image.cfg` to include:

- `nvdata.PARTITION` with `sub_type="nvdata"`
- `nenv.PARTITION` with `sub_type="nenv"`

The intent is to test whether the Amlogic burn path can write the reserved
U-Boot env area directly during the flash process, eliminating the later SSH
or USB-console `nand_env` import step.

This is still experimental:

- the proven workflow writes `/dev/nand_env` after the image flash
- we have not yet proven that `partition nenv ...` is accepted by this board's
  burn implementation
- if the board ignores or rejects `nenv`, the image should still behave like
  the current proven USB-stick flow and require a later env write

We have now tested this on the target board, and the result was negative. The
removable-media burn path parsed the image correctly and began burning, but
failed at the `nenv` stage with:

```text
[MSG]=====>To burn part [nenv]
[store]Err:do_store_size,L893:device(nenv) is err
Fail to get size for part nenv
Fail in burn part nenv
=====Burn Failed!!!!!
```

So on this board:

- `nvdata.PARTITION` is accepted by the burn engine
- `nenv.PARTITION` is not accepted as a normal `store` partition
- the USB-stick path cannot currently update `nand_env` by packaging it as
  `sub_type="nenv"`

That means the current reliable path remains:

1. flash the stock-signed image with Mujina `nvdata`
2. write the staging `nand_env.bin` afterward from USB burn console, SSH, or
   another handoff path
3. let Mujina rewrite `/dev/nand_env` to `runtime_nand_env.bin` on its first
   boot and reboot once

## Stage A USB Flashdrive Bundle

To stage a removable-media bundle for the board's cold-boot USB probe:

```bash
cd tools/mujina-usburner
./stage_usb_flashdrive_bundle.sh
```

That script:

1. Builds the stock-signed Mujina burn image
2. Unpacks the stock flash image to extract `aml_sdc_burn.UBOOT.ENC`
3. Copies the stock `aml_sdc_burn.ini`
4. Renames the generated Mujina package to `aml_upgrade_package_enc.img`
5. Stages a USB-stick directory under `output/usb-flashdrive/`

The staged directory is intended to be copied to the root of a `FAT32` flash
drive so U-Boot can find:

- `aml_sdc_burn.ini`
- `aml_sdc_burn.UBOOT.ENC`
- `aml_upgrade_package_enc.img`

Important limitation:

- the removable-media burn path still does not apply `nand_env` by itself
- this staged flashdrive bundle therefore still needs an initial env handoff
- after that initial handoff, the Mujina rootfs now contains a one-shot
  first-boot finalizer that writes the steady-state env and reboots once

## Experimental: Fully Hands-Off USB Handoff Bundle

To stage an experimental bundle that tries both post-burn handoff paths:

```bash
cd tools/mujina-usburner
./stage_usb_handoff_bundle.sh
```

That script builds and stages:

- `aml_sdc_burn.ini` with `reboot=0`
- `aml_sdc_burn.UBOOT.ENC`
- `aml_upgrade_package_enc.img`
- `aml_autoscript`
- `nand_env.bin`
- `recovery.img`

The intended sequence is:

1. the cold-boot burn path flashes the Mujina image
2. U-Boot continues through `update` instead of rebooting immediately
3. `recovery_from_udisk` tries `aml_autoscript` first
4. if the autoscript does not complete the handoff, `recovery.img` is present
   as a fallback one-shot Linux helper that writes the embedded staging
   `nand_env.bin` and reboots

This bundle is still experimental. We have not yet proven on hardware that the
removable-media burn path falls through from `sdc_burn` into
`recovery_from_udisk` on success.

## Experimental: First-Boot Boot Helper Bundle

To stage an experimental bundle that performs the initial `nand_env` handoff
from the flashed `boot.PARTITION` itself:

```bash
cd tools/mujina-usburner
./stage_usb_boothelper_bundle.sh
```

This mode repacks the stock-signed image with:

- the usual Mujina `nvdata.PARTITION`
- the usual staging `nand_env.bin`
- a replacement `boot.PARTITION` built from the stock kernel plus a tiny
  BusyBox ramdisk that writes the embedded staging `nand_env` to `/dev/nand_env`
  and reboots

The intended sequence is:

1. flash the image from USB media
2. remove the USB stick
3. power-cycle once
4. the helper `boot.PARTITION` boots, writes `nand_env`, and reboots
5. U-Boot now follows the staging Mujina env into Mujina
6. Mujina rewrites `/dev/nand_env` to `runtime_nand_env.bin` on its first boot
   and reboots once more

This is currently the most promising path for a USB-stick workflow that avoids
SSH and does not depend on post-burn `aml_autoscript`.

## Enter USB Burn Mode

1. Unplug the Amlogic control board power
2. Attach a USB Serial cable (like FTDI) to your computer and the "Linux RX/TX" pinheader J4 on the amlogic control board as follows:

| FTDI Pin | Amlogic J4 Pin |
|----------|----------------|
| TX       | LINUX RX       |
| GND      | GND            |
| RX       | LINUX TX       |

3. Open a serial terminal to the USB Serial cable at 115200 baud 8N1
4. Attach a USB cable to your computer and the USB Micro port on the Amlogic control board
5. Attach controlboard power
6. Mash the space bar key several times in the serial terminal to stop auto boot and drop into U-Boot
7. You should now see a `axg_s400_v1_sbr#` prompt
8. Enter `run usb_burning` and press enter.
9. You should see the following if USB Burn mode successfully started:
```
InUsbBurn
[MSG]sof
Set Addr 62
Get DT cfg
Get DT cfg
set CFG
```

## Flash An Image

With the board into Amlogic USB burn mode, then run:

```bash
cd tools/mujina-usburner
./flash_stock_signed_mujina_image.sh
```

The flasher intentionally uses `--reset=n` first so the board stays under USB
U-Boot control while the script:

1. flashes the repacked stock-signed image
2. uploads `output/nand_env.bin` into RAM
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
- The generated `output/mujina-uboot-env.txt` is now mainly a reference file;
  the flasher uses `output/nand_env.bin` for the initial staging env import.
- `output/runtime_nand_env.bin` is the steady-state env blob embedded into the
  Mujina rootfs and applied by the first-boot finalizer.
- A failed USB-stick experiment that tries to burn unsupported `nenv` content
  can leave the board unable to boot U-Boot or enumerate automatically in USB
  burn mode. See [`../stock_fw_restore/README.md`](../stock_fw_restore/README.md)
  for the confirmed `JP2` hardware recovery path.
