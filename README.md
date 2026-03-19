# Mujina Loader

This repo is organized around one release goal:

- build the `mujina_armhf_base` rootfs image
- flash it onto Amlogic S21 control boards
- restore boards back to stock when needed

## Layout

- `mujina_loader/`
  - source for building `mujina_armhf_base`
  - includes the configurable `armhf` rootfs builders and boot env generator
  - docs: [`mujina_loader/README.md`](mujina_loader/README.md)
- `tools/network_install/`
  - installs Mujina onto a running stock board over the network
  - uses the stock `miner` bootstrap path and rewrites `mtd6`
  - docs: [`tools/README.md`](tools/README.md)
- `tools/mujina-usburner/`
  - builds stock-signed USB burn images that preload Mujina
  - docs: [`tools/mujina-usburner/README.md`](tools/mujina-usburner/README.md)
- `tools/stock_fw_restore/`
  - restores a board back to stock firmware over USB burn
  - docs: [`tools/stock_fw_restore/README.md`](tools/stock_fw_restore/README.md)
- `local/`
  - reverse engineering notes, experiments, logs, and legacy bring-up work

## Typical Workflow

Build the release image:

```bash
cd mujina_loader
./build_armhf_base_payload.sh
```

Flash it over USB burn:

```bash
cd tools/mujina-usburner
./build_stock_signed_mujina_image.sh
./flash_stock_signed_mujina_image.sh
```

Or install it onto a running stock board:

```bash
cd tools/network_install
./install_mujina_aml.sh --host 192.168.1.52
```
