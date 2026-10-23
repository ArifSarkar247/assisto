#!/usr/bin/env bash
# b3-group: undo deploy/livekit/install.sh. Group calls disappear from the
# app at once (the API reports available=false); 1:1 calls are not touched.
#
#   sudo bash deploy/livekit/rollback.sh             # stop LiveKit, hide group calls
#   sudo bash deploy/livekit/rollback.sh --coturn    # ALSO restore coturn's old
#                                                    # port range (restarts coturn)
# Keeps /opt/livekit and /etc/livekit (keys) so install.sh can bring it back.
set -euo pipefail
BACKEND_ENV="${BACKEND_ENV:-/home/ubuntu/assisto/backend/.env}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/assisto}"
TURN_CONF="${TURN_CONF:-/etc/turnserver.conf}"
APP_SERVICE="${APP_SERVICE:-assisto}"
COTURN=0
[ "${1:-}" = "--coturn" ] && COTURN=1
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/assisto-livekit/rollback-$TS"
mkdir -p "$BK"
cp -a "$NGINX_SITE" "$BACKEND_ENV" "$BK/" 2>/dev/null || true
cp -a "$TURN_CONF" "$BK/" 2>/dev/null || true
chmod -R go-rwx "$BK"

echo "== 1 hide group calls (comment out LIVEKIT_* in the backend env)"
sed -i -E 's/^(LIVEKIT_(URL|HTTP_URL|API_KEY|API_SECRET)=)/#b3off# \1/' "$BACKEND_ENV"
systemctl restart "$APP_SERVICE"

echo "== 2 stop LiveKit"
systemctl disable --now livekit 2>/dev/null || true

echo "== 3 nginx: remove the /livekit/ include"
if grep -q 'assisto-livekit.conf' "$NGINX_SITE"; then
  sed -i '/assisto-livekit.conf/d' "$NGINX_SITE"
  if nginx -t; then systemctl reload nginx; else cp -a "$BK/$(basename "$NGINX_SITE")" "$NGINX_SITE"; echo "nginx -t failed; restored"; fi
fi

if [ "$COTURN" = 1 ]; then
  echo "== 4 coturn: back to max-port=65535 (restart; relayed calls redial)"
  sed -i -E 's/^\s*max-port\s*=\s*63999\s*$/max-port=65535/' "$TURN_CONF"
  sed -i -E 's/^TURN_RELAY_PORT_MAX=63999$/TURN_RELAY_PORT_MAX=65535/' "$BACKEND_ENV"
  systemctl restart coturn
  systemctl restart "$APP_SERVICE"
else
  echo "== 4 coturn untouched (keeps 49152-63999; fine without LiveKit). Use --coturn to restore 65535."
fi
echo "DONE. Backup of the files before rollback: $BK"
