#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This helper is for macOS only." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install libusb-compat." >&2
  exit 1
fi

if brew list --versions libusb-compat >/dev/null 2>&1; then
  echo "libusb-compat is already installed."
  exit 0
fi

brew install libusb-compat
