# Tools

This directory contains the release-facing deployment and recovery tooling.

## Layout

- `network_install/`
  - in-place install path for a running stock board over the network
  - includes the stock bootstrap helper and `mujina_stage4_aml.sh`
- `kernel_build/`
  - direct Docker-based custom-kernel build/install path
  - seeded from the known-good `amlogic-cb-tools` kernel workflow
- `mujina-usburner/`
  - builds and flashes direct USB burn images for Mujina
- `stock_fw_restore/`
  - restores a board back to stock firmware over USB burn

## Typical workflows

Build the release payload first:

```bash
cd mujina_loader
./build_armhf_base_payload.sh
```

Flash a prepared Mujina image over USB burn:

```bash
cd tools/mujina-usburner
./flash_stock_signed_mujina_image.sh
```

Install over the network to a running stock board:

```bash
cd tools/network_install
./install_mujina_aml.sh --host 192.168.1.52
```

Restore stock firmware over USB burn:

```bash
cd tools/stock_fw_restore
./flash_stock_s21_aml_macos.sh
```
