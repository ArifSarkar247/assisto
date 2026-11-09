#!/usr/bin/env bash
# gboxlinux — build the Linux Guard Box INSIDE python:3.11-slim-bullseye
# (glibc 2.31: the bundle then runs on Debian 11+, Ubuntu 20.04+, Raspberry Pi
# OS bullseye/bookworm). Run on an amd64 or arm64 machine (CI: guardbox-linux.yml):
#   docker run --rm -v "$PWD:/src" -w /src/edge/shopbox -e VERSION=0.2.0-1 \
#     python:3.11-slim-bullseye bash linux/build_linux.sh
# Output in edge/shopbox/dist-linux/: assisto-guardbox_<arch>.deb,
# assisto-guardbox-linux-<arch>.tar.gz
set -euo pipefail
VERSION="${VERSION:?set VERSION}"
# Debian 11 left the main mirrors (security support ended): its packages
# live on archive.debian.org now. Only build tools come from apt.
if grep -qs bullseye /etc/os-release; then
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
    [ -f "$f" ] && sed -i -e 's|deb.debian.org/debian-security|archive.debian.org/debian-security|g' \
                          -e 's|deb.debian.org/debian|archive.debian.org/debian|g' \
                          -e 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' "$f"
  done
fi
apt-get -o Acquire::Check-Valid-Until=false update -qq
apt-get install -y -qq --no-install-recommends binutils gcc libc6-dev >/dev/null
ARCH="$(dpkg --print-architecture)"
python -m pip install -q --upgrade pip
python -m pip install -q -r requirements.txt -r requirements-dev.txt -r requirements-live.txt
python -m shopbox.model_fetch models/yolox_nano.onnx
rm -rf build dist
pyinstaller --noconfirm --clean linux/guardbox_linux.spec
APP=dist/assisto-guardbox
# smoke: the frozen program starts, loads the model and onnxruntime, has live view
"$APP/assisto-guardbox" --version
SHOPBOX_HOME="$(mktemp -d)" "$APP/assisto-guardbox" --self-test
SHOPBOX_HOME="$(mktemp -d)" "$APP/assisto-guardbox" --live-check || echo "WARNING: live view not in the bundle"

OUT=dist-linux; rm -rf "$OUT" pkg; mkdir -p "$OUT"
P=pkg/assisto-guardbox
mkdir -p "$P/DEBIAN" "$P/opt" "$P/usr/bin" "$P/usr/lib/assisto-guardbox" \
         "$P/lib/systemd/system" "$P/etc/default" "$P/usr/share/doc/assisto-guardbox"
cp -a "$APP" "$P/opt/assisto-guardbox"
install -m 755 linux/assisto-guardbox "$P/usr/bin/assisto-guardbox"
install -m 755 linux/assisto-guardbox-update "$P/usr/lib/assisto-guardbox/assisto-guardbox-update"
install -m 644 linux/assisto-guardbox.service linux/assisto-guardbox-update.service \
               linux/assisto-guardbox-update.timer "$P/lib/systemd/system/"
install -m 644 linux/default "$P/etc/default/assisto-guardbox"
install -m 644 README.md README_bn.md "$P/usr/share/doc/assisto-guardbox/"
install -m 755 linux/debian/postinst linux/debian/prerm linux/debian/postrm "$P/DEBIAN/"
install -m 644 linux/debian/conffiles "$P/DEBIAN/conffiles"
SIZE="$(du -sk "$P" | cut -f1)"
sed -e "s/@VERSION@/$VERSION/" -e "s/@ARCH@/$ARCH/" -e "s/@SIZE@/$SIZE/" \
    linux/debian/control.in > "$P/DEBIAN/control"
dpkg-deb --root-owner-group --build -Zxz "$P" "$OUT/assisto-guardbox_${ARCH}.deb"
tar -C dist -czf "$OUT/assisto-guardbox-linux-${ARCH}.tar.gz" assisto-guardbox
dpkg-deb --info "$OUT/assisto-guardbox_${ARCH}.deb" | sed -n '1,12p'
ls -la "$OUT"
