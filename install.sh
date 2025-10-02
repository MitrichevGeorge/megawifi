#!/usr/bin/env bash

# Usage:
#   curl -sSL https://raw.githubusercontent.com/MitrichevGeorge/megawifi/main/install.sh | sh

set -euo pipefail
export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

REPO_RAW_BASE="https://raw.githubusercontent.com/MitrichevGeorge/megawifi/main"
MEGAFILE="megawifi.sh"
TARGET="/usr/local/bin/megawifi.sh"

info(){ echo "==> $*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

pacman -Syu --noconfirm
pacman -Sy --noconfirm hostapd dnsmasq mitmproxy iptables-nft python || true

curl -fsSL "$REPO_RAW_BASE/$MEGAFILE" -o "$TARGET.tmp" || die "Не удалось скачать $MEGAFILE"

chmod +x "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"

info "Установка завершена. Пример запуска:"
echo "  sudo $TARGET \"MyTestHotspot\" \"MyStrongPass\""
