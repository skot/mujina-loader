# Amlogic Bitmain Control Board Notes

Target PCB silkscreen: `MINER_CTRL_BOARD_A113D_V1_1`

This file is the board notebook for the Bitmain/Amlogic control board used in this repo. This first pass focuses on the firmware stack from reset through Linux, and on the practical question: what is covered by the stock secure boot chain, and what can we change freely?

## Scope And Confidence

- "Observed" means we have direct evidence from this repo's dumps, scripts, or logs.
- "Inferred" means it matches the normal A113D / AXG boot architecture and the evidence we have, but we have not yet proven it from a full dump of every bootloader stage on this exact board.

## Observed Board Facts

- SoC family appears to be Amlogic `A113D` / `AXG`.
- Early boot log begins with `AXG:BL1:...`, confirming AXG-family ROM naming on this board.
- `BL2` reports: `BL2 Built : 10:38:43, Apr 14 2020. axg gf27ed33`.
- `BL31` reports:
  - `BL31: v1.3(release):3edeb02`
  - `BL31: Built : 16:43:54, Apr 14 2020`
  - `BL31: AXG secure boot!`
  - `BL31: BL33 decompress pass`
- `bl30` reports: `bl30:axg ver: 9 mode: 0`.
- Stock U-Boot identifies itself as `U-Boot 2015.01`.
- Stock Linux observed on the board is `4.9.113`, built `Fri Feb 2 17:23:53 CST 2024`.
- The stock env uses `bootcmd=run storeboot`, `boot_part=boot`, and `imgread kernel ${boot_part} ${loadaddr}; bootm ${loadaddr};`.
- The repo's proven stock-compatible path keeps the stock signed `bootloader`, `boot`, `recovery`, and DTB partitions, and only changes `mtd6` / `nvdata` plus the U-Boot environment.
- NAND partitions exposed by stock U-Boot are:
  - `bootloader` at `0x000000000000-0x000000200000`
  - `tpl` at `0x000000800000-0x000001000000`
  - `misc` at `0x000001000000-0x000001200000`
  - `recovery` at `0x000001200000-0x000002200000`
  - `boot` at `0x000002200000-0x000004200000`
  - `config` at `0x000004200000-0x000004700000`
  - `nvdata` at `0x000004700000-0x000010000000`
- Reserved NAND regions used by U-Boot include:
  - `nenv` starting at block 24
  - `ndtb` starting at block 40
  - `nkey` starting at block 32
  - `nddr` starting at block 44

Local evidence:

- `local/bootlog.txt`
- `local/stock-boot/nand_env_stock.bin`
- `local/stock-boot/mtd4_boot_stock.bin`
- `tools/mujina-usburner/README.md`
- `tools/kernel_build/README.md`

## Firmware Stack

### 0. BootROM / BL1

Observed behavior:

- First code after reset is the SoC's internal BootROM.
- This is mask ROM inside the A113D, so it is not field-modifiable.
- The board's boot log starts with:
  - `AXG:BL1:d1dbf2:a4926f;FEAT:F0DC31BC:2000;POC:F;EMMC:800;NAND:0;READ:0;0.0;0.0;CHK:0;`
- For GX/AXG-family chips, the BootROM chooses a boot source in a fixed order. U-Boot's Amlogic boot-flow docs list `A113D` under the AXG family with boot attempts from SPI NOR, eMMC, NAND, then USB depending on board wiring and recovery conditions.
- The BootROM also implements the Amlogic USB burn protocol, which is why this board can be recovered with USB burn mode.

What can we change?

- Nothing directly. BootROM is fixed in silicon.

Signing / trust impact:

- BootROM is the root of trust.
- If secure boot efuses are burned, BootROM decides whether the next stage is valid.

### 1. BL2

Observed behavior:

- BL2 is the first external bootloader stage loaded by BootROM.
- On Amlogic AXG-family systems, BL2 handles early SoC init and DDR bring-up.
- On this board we see:
  - `BL2 Built : 10:38:43, Apr 14 2020. axg gf27ed33 - jenkins@walle02-sh`
  - DDR init and training
  - `NAND init`
  - `Load FIP HDR from NAND, src: 0x0000c000, des: 0x01700000, size: 0x00004000, part: 0`
  - `Load BL3x from NAND, src: 0x00010000, des: 0x01704000, size: 0x000b7c00, part: 0`
- The USB burn tooling in this repo treats secured AXG boards specially: if the board is secured, it insists on encrypted/signed bootloader blobs and refuses to flash an unsigned bootloader.

Why we believe this board uses the secured path:

- `tools/stock_fw_restore/flash-tool` explicitly checks for a "secured" board and errors out if the image lacks signed bootloader pieces.
- Independent A113X/A113D boot-chain research shows secured boards validate and decrypt BL2 before execution.

What can we change?

- Practically: not freely.
- Replacing BL2 on a secured board means generating a correctly signed/encrypted BL2 for this device family and fuse configuration. We do not currently have that path in this repo.

Signing / trust impact:

- Treat BL2 as signed-required.
- If secure boot is active, an arbitrary BL2 replacement should be assumed non-bootable.

### 2. FIP / BL3x Package

Observed behavior:

- After BL2, Amlogic systems load a Firmware Image Package (FIP).
- On AXG/A113D, the normal contents are:
  - `BL30`: SCP firmware for system management
  - `BL301`: board-specific SCP plug-in
  - `BL31`: Arm Trusted Firmware EL3 runtime / PSCI
  - optional `BL32`: secure payload / TEE
  - `BL33`: non-secure bootloader, usually U-Boot
- The updated boot log now shows this directly on our board:
  - `Load FIP HDR from NAND ...`
  - `Load BL3x from NAND ...`
  - `NOTICE:  BL31: AXG secure boot!`
  - `NOTICE:  BL31: BL33 decompress pass`
  - `bl30:axg ver: 9 mode: 0`

What we have directly observed on this board:

- `BL31` is definitely present and running.
- `BL33` is definitely being decompressed and launched.
- `bl30` is definitely present and running.
- Linux logs show a reserved `linux,secmon` region and working PSCI, which matches the active `BL31` stage.
- The board drops into a stock Amlogic U-Boot prompt (`axg_s400_v1_sbr#`), which fits the normal `BL33 = U-Boot` stage.
- There is also `ERROR:   Error initializing runtime service opteed_fast`, which strongly suggests the firmware expected an OP-TEE-related runtime hook but did not fully initialize one. That makes `BL32` uncertain on this board: there may be no usable `BL32`, or there may be a partially configured secure payload path.

What can we change?

- `BL30` / `BL301`: effectively no, not freely.
- `BL31`: not freely on a secured board, even though open-source `BL31` exists for AXG.
- `BL33` as the flash-resident stock U-Boot: also treat as not freely replaceable in place, because it sits inside the signed/encrypted Amlogic bootloader package.

Signing / trust impact:

- Treat the full flash-resident FIP and bootloader package as signed-required.
- Even if some components have open-source implementations, a secured board still needs a package the ROM/BL2 will accept.
- The latest log removes most doubt here: this board itself prints `BL31: AXG secure boot!`, so secure boot is not just a generic possibility, it is active in the observed boot path.

### 3. Flash-Resident U-Boot Environment (`nand_env`)

Observed behavior:

- This board stores a writable U-Boot environment in `/dev/nand_env`.
- We have already read, generated, and rewritten this environment successfully in this repo.
- The stock environment contains the normal Bitmain/Amlogic boot flow plus recovery commands such as `usb_burning=update 1000`.
- Stock U-Boot logs show the env coming from reserved NAND info:
  - `uboot env amlnf_env_read : ####`
  - `read nenv info to 310000`

What can we change?

- Freely, as long as we preserve the expected env format and CRC.
- This is the main escape hatch the current repo uses.

Why this matters:

- We can leave the stock signed boot chain intact and still redirect boot behavior.
- Current repo flows set `bootcmd=run mujinaboot || run storeboot`, which lets us try custom boot logic first and fall back to stock.

Signing / trust impact:

- This environment does not appear to be signature-protected by the secure boot chain.
- It is writable at runtime from Linux and importable from USB/U-Boot.
- So this is currently in the "safe to modify" bucket.

### 4. Stock `boot` Partition (`mtd4`)

Observed behavior:

- The stock `boot` partition contains an Android boot image.
- Our sample `local/stock-boot/mtd4_boot_stock.bin` starts with `ANDROID!`.
- The same image also contains an `AMLSECU!` structure at offset `0x400`, strongly suggesting an Amlogic secure wrapper / metadata around the boot payload.
- The stock environment boots this partition using `imgread kernel ${boot_part} ${loadaddr}; bootm ${loadaddr};`.

What can we change?

- Conservatively: do not treat the stock `boot` partition as freely replaceable.
- The repo's default workflows intentionally keep the stock `boot` partition untouched.

Practical nuance:

- We can still boot a custom kernel without replacing `mtd4` at all.
- The repo's custom-kernel path uploads `Image` and a DTB as regular files and changes `nand_env` so U-Boot loads them from UBIFS instead of from the stock `boot` partition.

Signing / trust impact:

- Replacing the stock flash `boot` image probably requires preserving or regenerating the expected Amlogic secure wrapper.
- We do not currently have enough proof to say whether runtime U-Boot enforces a signature on every `imgread kernel` load, or whether the secure wrapper is mostly for packaging/update acceptance. Until proven otherwise, treat it as signed-sensitive.

### 5. Stock DTB Partition (`_aml_dtb`)

Observed behavior:

- The USB burn image layout includes both plain and encrypted DTB representations:
  - `meson1.dtb`
  - `_aml_dtb.PARTITION`
  - and an encrypted DTB path used when the board is secured
- The flash tool writes an encrypted DTB blob for secured AXG boards.
- Stock U-Boot reads the live DTB from the reserved NAND DTB area, not from the main `boot` partition:
  - `amlnf dtb_read 0x1000000 0x40000`
  - `read ndtb info to 500000`
  - `Amlogic multi-DTB tool`
  - `Found DTB for "axg_s400_v03sbr"`

What can we change?

- Conservatively: do not treat the flash DTB partition as freely replaceable.
- The repo's stock-compatible path keeps the stock DTB partition intact.

Practical nuance:

- We can still use a custom DTB by loading it as a regular file from the filesystem and pointing `mujinaboot` at it.
- That is what the custom-kernel path is built around.

Signing / trust impact:

- Flash DTB partition: likely signed/encrypted-sensitive.
- DTB loaded later by U-Boot from a writable filesystem: freely changeable.

### 6. Linux Kernel

There are two distinct cases:

#### A. Stock kernel path

- Stock boot uses the kernel inside the stock `boot` partition.
- That kernel should be treated as part of the signed-sensitive stock image set.

#### B. Custom kernel path used by this repo

- We can upload a plain `Image` to `/Image`.
- We can upload a plain DTB to `/axg_s400_antminer.dtb`.
- We can then change `nand_env` so U-Boot runs:
  - `ubifsmount`
  - `ubifsload ${ker_addr} Image`
  - `ubifsload ${dtb_addr} <dtb>`
  - `booti ${ker_addr} - ${dtb_addr}`
- In this path, the kernel and DTB are not part of the original flash-resident signed bootloader package.

What can we change?

- Freely, in the custom-kernel path.
- This is the cleanest place to iterate on a new kernel without fighting the secure boot chain.

Signing / trust impact:

- Stock `boot` partition kernel: signed-sensitive.
- Kernel loaded as a plain file by already-running U-Boot: freely changeable.

Observed Linux outcomes from the updated log:

- U-Boot successfully attaches `mtd6` / `nvdata` as `ubi0`.
- The kernel command line in the updated log is:
  - `init=/sbin/init console=ttyS0,115200 no_console_suspend earlycon=aml_uart,0xff803000 jtag=disable root=ubi0:mujina_rootfs rootfstype=ubifs rw ubi.mtd=6,2048`
- The later userspace banner in the same log shows the current Mujina custom kernel path working:
  - `Linux mujina-s21-aml 4.9.337 #1 SMP PREEMPT Fri Mar 20 00:08:07 UTC 2026`

### 7. Root Filesystem

Observed behavior:

- This repo replaces `mtd6` / `nvdata` with a UBI/UBIFS volume named `mujina_rootfs`.
- The proven stock-kernel path keeps the stock kernel and DTB, then points the kernel at `root=ubi0:mujina_rootfs rootfstype=ubifs rw ubi.mtd=6,2048`.

What can we change?

- Freely.
- This is already the main supported modification path in the repo.

Signing / trust impact:

- No evidence that `mtd6` / `nvdata` is signature-enforced by the boot chain.
- Current workflows rewrite it routinely.

## Practical Signed vs Editable Map

### Treat As Signed / Not Freely Replaceable

- BootROM / BL1
- BL2
- Flash-resident Amlogic bootloader package / FIP
- `BL30`
- `BL301`
- `BL31`
- Flash-resident `BL33` / stock U-Boot
- Stock `bootloader` partition
- Stock flash `boot` partition
- Stock flash DTB partition
- Probably stock `recovery` too, by the same logic as `boot`

### Freely Replaceable In Our Current Workflow

- `nand_env` / U-Boot environment
- `mtd6` / `nvdata` rootfs contents
- Kernel loaded as a plain file from UBIFS
- DTB loaded as a plain file from UBIFS
- Userspace, init scripts, services, and everything above the kernel

## Boot Stage To Storage Map

This table is the current best map from named boot stages to on-flash storage on this board.

| Stage / artifact | Storage location on this board | Confidence | Why |
|---|---|---|---|
| `BL1` / BootROM | SoC internal ROM | Confirmed | Directly shown by the `AXG:BL1:...` banner and not flash-resident by design. |
| `BL2` | Flash-resident secure bootloader area, most likely within `bootloader` | High | `BL2` runs before normal partition discovery and then loads FIP from raw NAND `part: 0`. |
| FIP header | Flash-resident secure bootloader area, most likely within `bootloader` | High | Boot log: `Load FIP HDR from NAND ... part: 0`. |
| `BL30` | Inside the FIP / secure bootloader package | High | Boot log: `bl30:axg ver: 9 mode: 0`. |
| `BL31` | Inside the FIP / secure bootloader package | High | Boot log prints `BL31` version/build info and `AXG secure boot!`. |
| `BL33` | Inside the FIP / secure bootloader package, decompressed into RAM before U-Boot | High | Boot log: `BL31: BL33 decompress pass`, followed by U-Boot startup. |
| Stock U-Boot environment | Reserved NAND env area `nenv`; exposed to Linux as `/dev/nand_env` | Confirmed | Boot log shows `amlnf_env_read` / `read nenv info`; repo rewrites `/dev/nand_env` directly. |
| Stock flash DTB used during normal boot | Reserved NAND DTB area `ndtb` | Confirmed | Boot log shows `amlnf dtb_read`, `read ndtb info`, then `Found DTB for "axg_s400_v03sbr"`. |
| Stock kernel / boot image | `boot` partition (`mtd4`) | Confirmed | Stock env uses `imgread kernel ${boot_part}` with `boot_part=boot`; partition map matches `mtd4`. |
| Mujina rootfs | `nvdata` partition (`mtd6`) | Confirmed | U-Boot and Linux both attach/use `nvdata` as UBI with `mujina_rootfs`. |
| `tpl` partition | Bootloader-adjacent vendor storage; exact role still unclear | Medium | U-Boot exposes `tpl`, but the earlier BL2/FIP load is from raw NAND `part: 0`, before normal partition handling. |

### What USB Burn Replaces In This Map

When we flash a stock-signed image with this repo's USB burn workflow:

- `bootloader` is replaced with the stock signed bootloader package from the image.
- `_aml_dtb` is replaced with the stock signed/encrypted DTB payload from the image.
- `boot` is replaced with the stock signed boot image from the image.
- `recovery` is replaced with the stock signed recovery image from the image.
- `nvdata` is replaced with our generated Mujina UBI image.
- `nand_env` is rewritten afterward by `env import` + `save`, outside the packed partition image itself.

### Current Best Interpretation Of `bootloader` vs `tpl`

- `bootloader` should be treated as containing the critical secure early boot content, at least the material needed for `BL2` and FIP/BL3x handoff.
- `tpl` is clearly bootloader-related, but we do not yet have proof that it is itself part of the ROM-verified chain.
- So the safe operational rule is:
  - if it is needed before stock U-Boot is fully running, assume it is part of the signed boot chain
  - if we have not dumped and parsed it yet, do not assume `bootloader` alone equals every non-ROM stage

## Practical Takeaway For Mujina

The safest strategy on this board is:

1. Leave the stock secure boot chain alone.
2. Leave flash-resident `bootloader`, `boot`, `recovery`, and DTB partitions alone unless we have a proven signing path.
3. Use writable `nand_env` to redirect boot.
4. Store our rootfs, and optionally our kernel + DTB, in writable storage that U-Boot can read after the secure chain has already handed off to stock U-Boot.

That is already the direction reflected in this repo:

- stock-signed USB burn images
- stock `boot` / DTB preserved
- rootfs on `mtd6`
- optional custom kernel and DTB loaded as regular files after U-Boot starts

## Open Questions

- Confirm exactly how the raw bootloader area maps onto the flash-visible `bootloader` and `tpl` partitions. The boot log proves BL2 loads FIP from NAND `part: 0`, but we have not yet reconciled that with the later `tpl` partition exposed by U-Boot.
- Dump and parse the stock bootloader partition to identify the exact BL2/BL30/BL301/BL31/BL33 bundle.
- Determine whether stock U-Boot verifies `AMLSECU!` boot image signatures at runtime, or whether that wrapper is mainly needed for packaging / flash acceptance.
- Determine whether the reserved NAND DTB area (`ndtb`) is validated again at boot time or only accepted during flashing because the secured image package carries the expected encrypted DTB form.
- Check efuse state directly if we can safely do so from U-Boot or Linux.

## Source Pointers

Primary / upstream references:

- U-Boot Amlogic boot flow: https://docs.u-boot.org/en/latest/board/amlogic/boot-flow.html
- U-Boot Amlogic FIP notes: https://docs.u-boot.org/en/latest/board/amlogic/pre-generated-fip.html
- TF-A Meson AXG/A113D platform notes: https://trustedfirmware-a.readthedocs.io/en/v2.6/plat/meson-axg.html

Useful reverse-engineering reference:

- A113X BootROM / secure boot research: https://haxx.in/posts/dumping-the-amlogic-a113x-bootrom/
