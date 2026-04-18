# Mujina Loader

`mujina_loader` contains the first-release Mujina rootfs builders for Amlogic
S21 control boards.

The current release path is:

- keep the stock signed Bitmain boot chain and stock `4.9.113` kernel
- replace `mtd6` / `nvdata` with a Mujina UBIFS rootfs
- boot that Mujina rootfs from `mtd6`

This directory now focuses on building the release image:

- `mujina_armhf_base`

## Main Files

- `generate_nand_env.py`
  - generates the boot environment blob used by the stock-kernel boot path
- `stock_env_template.txt`
  - stock-like U-Boot env template
- `build_armhf_full_payload.sh`
  - builds a fuller Debian Bookworm `armhf` userspace with SSH/telnet/HTTP
- `build_armhf_base_payload.sh`
  - builds the first release-oriented `armhf` base profile with SSH enabled and
    telnet/HTTP disabled by default
- `mujina_armhf_full/`
  - generated development-oriented output directory
- `mujina_armhf_base/`
  - generated first-release output directory

## Release Profiles

### `build_armhf_full_payload.sh`

Builds a development-oriented userspace:

- Debian Bookworm `armhf`
- BusyBox `init` with `inittab` and ordered `/etc/mujina/rc.d` scripts
- Dropbear SSH enabled
- BusyBox telnet enabled
- BusyBox HTTP status page enabled
- generated `udhcpc` hook writes `1.1.1.1` and `8.8.8.8` into
  `/etc/resolv.conf` before any DHCP-provided resolvers, so DNS still works if
  the router advertises a flaky local resolver
- generated image includes USB Wi-Fi userspace and boot hooks:
  `wpasupplicant`, `wifi-autostart`, `/config/wpa_supplicant-wlan0.conf`
  support, and a Mujina boot hook at `/etc/mujina/rc.d/S25-wifi-autostart`
- the rootfs still requires a Wi-Fi-capable kernel plus the matching external
  Realtek module (`88XXau.ko` or `8821cu.ko`) to actually expose `wlan0`

Default output:

```bash
mujina_loader/mujina_armhf_full
```

### `build_armhf_base_payload.sh`

Builds the first release-oriented base profile:

- Debian Bookworm `armhf`
- same Mujina boot/service layout
- SSH enabled
- telnet disabled
- HTTP disabled
- release metadata in `/etc/mujina/release`
- service ownership in `/etc/mujina/services.env`
- same DNS fallback behavior in the generated `udhcpc` hook
- same USB Wi-Fi userspace/autostart support as the full profile

Default output:

```bash
mujina_loader/mujina_armhf_base
```

## Example Commands

Build the development profile:

```bash
cd mujina_loader
./build_armhf_full_payload.sh
```

Build the first release-oriented base profile:

```bash
cd mujina_loader
./build_armhf_base_payload.sh
```

Run the stock-board SSH installer flow:

```bash
cd tools/network_install
./install_mujina_aml.sh --host 192.168.1.52
```

For direct USB burn packaging, use `tools/mujina-usburner/`.
