#!/bin/sh
# gboxlinux — one-line installer for the Assisto Guard Box:
#   curl -fsSL https://github.com/ArifSarkar247/assisto/releases/download/guardbox-linux/install.sh | sudo sh
# Works on Raspberry Pi OS / Debian / Ubuntu (64-bit: amd64 or arm64).
# Downloads the .deb for this CPU, checks its SHA-256, installs it (systemd
# service + daily auto-update), then tells you the next step.
set -eu
REPO="${GUARDBOX_REPO:-ArifSarkar247/assisto}"
CHANNEL="${CHANNEL:-guardbox-linux}"
BASE="https://github.com/$REPO/releases/download/$CHANNEL"
say() { printf '%s\n' "$@"; }
if [ "$(id -u)" != "0" ]; then say "Please run with sudo / sudo দিয়ে চালান"; exit 1; fi
command -v dpkg >/dev/null || { say "This installer needs a Debian / Ubuntu / Raspberry Pi OS system."; exit 1; }
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
  amd64|arm64) ;;
  armhf) say "This is a 32-bit system. Please install the 64-bit Raspberry Pi OS (Raspberry Pi 3/4/5)." \
             "৩২-বিট সিস্টেম। অনুগ্রহ করে ৬৪-বিট Raspberry Pi OS ইনস্টল করুন।"; exit 1 ;;
  *) say "No Guard Box build for $ARCH yet."; exit 1 ;;
esac
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl ca-certificates; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
DEB="assisto-guardbox_${ARCH}.deb"
say "Downloading / ডাউনলোড হচ্ছে: $DEB"
curl -fSL --retry 3 -o "$TMP/$DEB" "$BASE/$DEB"
curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"
WANT="$(awk -v f="$DEB" '$2==f || $2=="*"f {print $1}' "$TMP/SHA256SUMS")"
GOT="$(sha256sum "$TMP/$DEB" | cut -d' ' -f1)"
if [ -z "$WANT" ] || [ "$WANT" != "$GOT" ]; then say "SHA-256 check failed - not installing."; exit 1; fi
apt-get update -qq || true
apt-get install -y -qq "$TMP/$DEB"
mkdir -p /var/cache/assisto-guardbox && cp "$TMP/$DEB" /var/cache/assisto-guardbox/current.deb
say "" "Installed / ইনস্টল হয়েছে: $(dpkg-query -W -f='${Version}' assisto-guardbox)" \
    "Next / এরপর:  sudo assisto-guardbox setup" ""
