#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This helper is for macOS only." >&2
  exit 1
fi

ioreg -p IOUSB -l -w 0 | awk '
  /"idVendor" = 7054/ { vendor=1; block=$0 "\n"; next }
  vendor { block=block $0 "\n" }
  vendor && /"idProduct" = 49155/ { product=1 }
  vendor && /"USB Address" =/ { addr=$0 }
  vendor && /^  |^\t/ { next }
  vendor {
    if (product) {
      print "Amlogic USB burn-mode device detected."
      print block
      if (addr != "") print addr
      found=1
    }
    vendor=0
    product=0
    block=""
    addr=""
  }
  END {
    if (!found) exit 1
  }
'
