#!/usr/bin/env bash
# b3-group: install the LiveKit SFU for Assisto group calls on the lifeassisto
# box. IDEMPOTENT (safe to run again), backs up everything it touches first.
#
#   sudo bash deploy/livekit/install.sh            # asks before restarting coturn
#   sudo bash deploy/livekit/install.sh --yes      # no questions
#   sudo bash deploy/livekit/install.sh --skip-coturn
#
# What it does (each step is skipped when already done):
#   1. backup  nginx site, turnserver.conf, backend .env, /etc/livekit
#   2. download livekit-server (pinned version, sha256 checked) -> /opt/livekit
#   3. system user `livekit`; API key + secret generated ONCE into
#      /etc/livekit/livekit.env (0640 root:livekit) — never printed in full
#   4. render /etc/livekit/livekit.yaml (TURN secret from the backend .env)
#   5. coturn relay ports 49152-65535 -> 49152-63999 (LiveKit gets 64000-65535)
#   6. backend .env: LIVEKIT_URL / _HTTP_URL / _API_KEY / _API_SECRET +
#      TURN_RELAY_PORT_MAX=63999 (so the TURN monitor doesn't count LiveKit)
#   7. nginx: /livekit/ location (snippet + one include line), nginx -t, reload
#   8. systemd unit, enable + start, health check; ufw 7881/tcp if ufw is on
#   9. restart the Assisto API so it reads the new env (group calls appear)
# Rollback: sudo bash deploy/livekit/rollback.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/VERSION"
BACKEND_ENV="${BACKEND_ENV:-/home/ubuntu/assisto/backend/.env}"
NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/assisto}"
TURN_CONF="${TURN_CONF:-/etc/turnserver.conf}"
PUBLIC_HOST="${PUBLIC_HOST:-api.lifeassisto.com}"
APP_SERVICE="${APP_SERVICE:-assisto}"
LK_PORT_MIN=64000
COTURN_MAX=63999
YES=0; SKIP_COTURN=0
for a in "$@"; do
  case "$a" in
    --yes|-y) YES=1 ;;
    --skip-coturn) SKIP_COTURN=1 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$(uname -m)" = x86_64 ] || die "this pin is the linux_amd64 build; the box is $(uname -m)"
[ -f "$BACKEND_ENV" ] || die "backend env not found: $BACKEND_ENV"

envget() {  # value of KEY in the backend .env (last one wins), quotes stripped
  grep -E "^$1=" "$BACKEND_ENV" | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# ---------------------------------------------------------------- 1 backup
TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/assisto-livekit/$TS"
say "1/9 backup -> $BK"
mkdir -p "$BK"
cp -a "$NGINX_SITE" "$BK/" 2>/dev/null || true
cp -a "$TURN_CONF" "$BK/" 2>/dev/null || true
cp -a "$BACKEND_ENV" "$BK/backend.env"
[ -d /etc/livekit ] && cp -a /etc/livekit "$BK/etc-livekit" || true
chmod -R go-rwx "$BK"
echo "$BK" > /var/backups/assisto-livekit/LAST

# ---------------------------------------------------------------- 2 binary
say "2/9 livekit-server $LIVEKIT_VERSION"
DEST="/opt/livekit/$LIVEKIT_VERSION"
if [ ! -x "$DEST/livekit-server" ]; then
  TMP="$(mktemp -d)"
  curl -fsSL -o "$TMP/lk.tgz" "$LIVEKIT_URL"
  echo "$LIVEKIT_SHA256  $TMP/lk.tgz" | sha256sum -c - || die "sha256 mismatch — not installing"
  mkdir -p "$DEST"
  tar -xzf "$TMP/lk.tgz" -C "$DEST" livekit-server LICENSE
  chmod 0755 "$DEST/livekit-server"
  rm -rf "$TMP"
fi
ln -sfn "$DEST" /opt/livekit/current
/opt/livekit/current/livekit-server --version || true

# ---------------------------------------------------------------- 3 user + keys
say "3/9 user + API key"
id livekit >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent \
  --shell /usr/sbin/nologin livekit
install -d -m 0750 -o root -g livekit /etc/livekit
if [ ! -s /etc/livekit/livekit.env ]; then
  KEY="AS$(openssl rand -hex 6)"
  SECRET="$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-48)"
  umask 027
  printf 'LIVEKIT_KEYS="%s: %s"\n' "$KEY" "$SECRET" > /etc/livekit/livekit.env
  chown root:livekit /etc/livekit/livekit.env; chmod 0640 /etc/livekit/livekit.env
  echo "new key generated: $KEY (secret stays in /etc/livekit/livekit.env)"
fi
KEY="$(sed -n 's/^LIVEKIT_KEYS="\([^:]*\): .*"$/\1/p' /etc/livekit/livekit.env)"
SECRET="$(sed -n 's/^LIVEKIT_KEYS="[^:]*: \(.*\)"$/\1/p' /etc/livekit/livekit.env)"
[ -n "$KEY" ] && [ -n "$SECRET" ] || die "/etc/livekit/livekit.env is not in the expected format"

# ---------------------------------------------------------------- 4 config
say "4/9 /etc/livekit/livekit.yaml"
TURN_SECRET="$(envget TURN_STATIC_SECRET)"
TURN_HOST="$(envget TURN_HOST)"; TURN_HOST="${TURN_HOST:-turn.lifeassisto.com}"
[ -n "$TURN_SECRET" ] || die "TURN_STATIC_SECRET is empty in $BACKEND_ENV"
LK_TURN_HOST="$TURN_HOST" LK_TURN_SECRET="$TURN_SECRET" LK_KEY="$KEY" \
LK_WEBHOOK="https://$PUBLIC_HOST/api/v1/livekit/webhook" \
python3 - "$HERE/livekit.yaml.template" /etc/livekit/livekit.yaml.new <<'PY'
import os, sys
s = open(sys.argv[1]).read()
e = os.environ
for k, v in {"TURN_HOST": e["LK_TURN_HOST"], "TURN_STATIC_SECRET": e["LK_TURN_SECRET"],
             "LIVEKIT_API_KEY": e["LK_KEY"], "WEBHOOK_URL": e["LK_WEBHOOK"]}.items():
    if '"' in v or "\\" in v or "\n" in v:
        sys.exit("refusing a value with quotes/backslashes/newlines for " + k)
    s = s.replace("@@%s@@" % k, v)
assert "@@" not in s, "unfilled placeholder"
open(sys.argv[2], "w").write(s)
PY
chown root:livekit /etc/livekit/livekit.yaml.new; chmod 0640 /etc/livekit/livekit.yaml.new
mv -f /etc/livekit/livekit.yaml.new /etc/livekit/livekit.yaml

# ---------------------------------------------------------------- 5 coturn
say "5/9 coturn relay ports (LiveKit uses $LK_PORT_MIN-65535)"
if [ "$SKIP_COTURN" = 1 ]; then
  echo "skipped (--skip-coturn): coturn keeps 49152-65535; ports are shared (both retry on a busy port)"
elif [ ! -f "$TURN_CONF" ]; then
  echo "no $TURN_CONF — skipped"
else
  CUR="$(grep -E '^\s*max-port\s*=' "$TURN_CONF" | tail -n1 | sed 's/[^0-9]//g' || true)"
  if [ -n "$CUR" ] && [ "$CUR" -le "$COTURN_MAX" ]; then
    echo "already max-port=$CUR"
  else
    if [ "$YES" != 1 ]; then
      echo "coturn must RESTART to change its relay ports. Calls relayed through TURN"
      echo "right now will drop (they redial). Do this at a quiet hour."
      read -r -p "Type yes to restart coturn now: " ok
      [ "$ok" = yes ] || die "stopped before touching coturn (nothing else changed after the backup/config steps)"
    fi
    if grep -qE '^\s*max-port\s*=' "$TURN_CONF"; then
      sed -i -E "s/^\s*max-port\s*=.*/max-port=$COTURN_MAX/" "$TURN_CONF"
    else
      printf '\n# b3-group: 64000-65535/udp belong to LiveKit\nmax-port=%s\n' "$COTURN_MAX" >> "$TURN_CONF"
    fi
    systemctl restart coturn
    sleep 2
    systemctl is-active --quiet coturn || { cp -a "$BK/$(basename "$TURN_CONF")" "$TURN_CONF"; systemctl restart coturn; die "coturn did not come back — restored its config"; }
    echo "coturn max-port=$COTURN_MAX"
  fi
fi

# ---------------------------------------------------------------- 6 backend env
say "6/9 backend env"
setenv() {  # add KEY=VALUE when KEY is missing (never overwrites)
  grep -qE "^$1=" "$BACKEND_ENV" || printf '%s=%s\n' "$1" "$2" >> "$BACKEND_ENV"
}
# a re-run after rollback: re-enable the lines rollback.sh commented out
sed -i -E 's/^#b3off# //' "$BACKEND_ENV"
grep -q '^# b3-group' "$BACKEND_ENV" || printf '\n# b3-group: LiveKit SFU (deploy/livekit)\n' >> "$BACKEND_ENV"
setenv LIVEKIT_URL "wss://$PUBLIC_HOST/livekit"
setenv LIVEKIT_HTTP_URL "http://127.0.0.1:7880"
setenv LIVEKIT_API_KEY "$KEY"
setenv LIVEKIT_API_SECRET "$SECRET"
[ "$SKIP_COTURN" = 1 ] || setenv TURN_RELAY_PORT_MAX "$COTURN_MAX"

# ---------------------------------------------------------------- 7 nginx
say "7/9 nginx /livekit/"
install -m 0644 "$HERE/nginx-livekit.conf" /etc/nginx/snippets/assisto-livekit.conf
if ! grep -q 'assisto-livekit.conf' "$NGINX_SITE"; then
  python3 - "$NGINX_SITE" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
# the FIRST server block that listens on 443 (the api/lifeassisto TLS block)
m = re.search(r"^[ \t]*listen 443 ssl;", s, re.M)
if not m:
    sys.exit("no 'listen 443 ssl;' block in " + p)
line = "    include /etc/nginx/snippets/assisto-livekit.conf;  # b3-group\n"
s = s[:m.start()] + line + s[m.start():]
open(p, "w").write(s)
PY
fi
if ! nginx -t; then
  cp -a "$BK/$(basename "$NGINX_SITE")" "$NGINX_SITE"
  die "nginx -t failed — restored the site file, nothing reloaded"
fi
systemctl reload nginx

# ---------------------------------------------------------------- 8 service
say "8/9 livekit.service"
install -m 0644 "$HERE/livekit.service" /etc/systemd/system/livekit.service
systemctl daemon-reload
systemctl enable livekit >/dev/null
systemctl restart livekit
for i in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS http://127.0.0.1:7880/ >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:7880/ >/dev/null || { journalctl -u livekit -n 40 --no-pager; die "LiveKit is not answering on 127.0.0.1:7880"; }
echo "local: OK"
curl -fsS "https://$PUBLIC_HOST/livekit/" >/dev/null && echo "public: OK (https://$PUBLIC_HOST/livekit/)" \
  || echo "WARNING: https://$PUBLIC_HOST/livekit/ did not answer — check nginx"
if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
  ufw allow 7881/tcp >/dev/null && echo "ufw: 7881/tcp allowed"
  ufw status | grep -q '64000:65535/udp\|49152:65535/udp' || { ufw allow 64000:65535/udp >/dev/null; echo "ufw: 64000:65535/udp allowed"; }
fi

# ---------------------------------------------------------------- 9 API
say "9/9 restart the Assisto API (reads LIVEKIT_* -> group calls appear)"
systemctl restart "$APP_SERVICE"
sleep 3
systemctl is-active --quiet "$APP_SERVICE" || die "$APP_SERVICE did not restart — see journalctl -u $APP_SERVICE"
echo
echo "DONE. LiveKit $LIVEKIT_VERSION is running. Backup: $BK"
echo "Check: curl -s https://$PUBLIC_HOST/api/v1/circle/calls/group/config -H 'Authorization: Token <any user token>'"
echo "       -> {\"available\": true, ...}"
echo "Optional (better on UDP-blocking networks): AWS security group inbound TCP 7881."
