# S21 Amlogic Stock Restore from macOS

This folder contains the USB-burn workflow to return a Antminer S21 Amlogic control board to stock
Bitmain firmware.

## Procedure summary

1. Power off the controlboard.
2. Connect the controlboard USB micro to the Mac over USB.
3. Power on the controlboard.
3. Use the macOS Khadas `aml-flash-tool` bundle.
4. Burn the HashSource `S21-aml-flashcard` image with:

```bash
./flash-tool --img=images/aml_upgrade_package_enc.img --parts=all --soc=axg --wipe --reset=y
```

## What's here

- `flash-tool`
  - Khadas wrapper script, vendored from `khadas/utils`
- `tools/macos/update`
  - macOS Amlogic USB updater binary
- `tools/macos/aml_image_v2_packer`
  - image unpacker used by `flash-tool`
- `tools/datas/*`
  - DDR/FIP blobs needed by `flash-tool` for `axg`
- `images/aml_upgrade_package_enc.img`
  - the exact HashSource `S21-aml-flashcard` image we burned
- `reference/*`
  - supporting config and metadata from the flashcard image and Khadas repo

## Upstream sources

- Khadas utils:
  - repo: `https://github.com/khadas/utils.git`
  - commit: `be77ffc020f4e9766c62d409a8ab1804245d5ef4`
- HashSource S21x firmware repo:
  - repo: `https://github.com/HashSource/hashsource_antminer_S21x.git`
  - commit: `e239c99f98220cf252b1f9613fb00a538915a8e8`

## Notes from the successful burn

- The board enumerated on macOS in USB burn mode as:
  - `idVendor = 0x1b8e`
  - `idProduct = 0xc003`
- The serial console showed:

```text
InUsbBurn
[MSG]sof
Set Addr 37
Get DT cfg
Get DT cfg
set CFG
```

- `flash-tool` detected the board as secure and used the encrypted boot chain
  from the flashcard image.
- The flashcard package is invasive:
  - `erase_bootloader=1`
  - `erase_flash=1`
- The image contains only:
  - `_aml_dtb`
  - `boot`
  - `bootloader`
  - `recovery`

That is enough to get this board back to stock boot behavior.

## Prerequisites

- macOS
- Homebrew
- Amlogic board physically connected by USB in burn mode
- Optional but strongly recommended: serial console connected

Install the missing USB dependency with:

```bash
./install_host_deps.sh
```

Verify the bundle contents have not changed:

```bash
shasum -a 256 -c SHA256SUMS
```

## Burn workflow

1. Put the board into USB burn mode and attach it to the Mac.
2. Confirm macOS sees the Amlogic device:

```bash
./detect_amlogic_usb.sh
```

Or directly:

```bash
./tools/macos/update identify 7
```

3. Start the burn:

```bash
./flash_stock_s21_aml_macos.sh
```

4. Watch for the board to leave USB mode and reboot.
5. Check the expected IP first, then fall back to DHCP discovery if needed.

## Expected result

- USB device disappears after `burn_complete`
- board reboots
- stock services eventually return
- on the board tested here, SSH worked with `miner/miner`

## Caveats

- This is a full USB burn path, not a gentle in-place update.
- `--wipe` and the flashcard package reset the board much more aggressively
  than the stock `.bmu` web updater path.
- Because the board is secure, using the encrypted image matters.
