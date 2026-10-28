#!/usr/bin/env bash
# ============================================================================
# Assisto provision — turn a FRESH Ubuntu 22.04/24.04 server into a complete
# Assisto backend host: Python+venv, Postgres, nginx + Let's Encrypt SSL for
# ALL app domains, gunicorn systemd unit, coturn (hard caps + security), the
# app's own crons, 4GB swap, ufw, fail2ban, SSH key-only, unattended security
# updates, nightly backup + watchdog. Idempotent where practical.
#
# RUN AS ROOT on the NEW server (NEVER on the shared Asalify box):
#   sudo APP_DOMAINS="lifeassisto.com www.lifeassisto.com api.lifeassisto.com track.lifeassisto.com" \
#        TURN_DOMAIN=turn.lifeassisto.com PRIMARY=api.lifeassisto.com \
#        REPO=https://github.com/ArifSarkar247/assisto.git \
#        ADMIN_EMAIL=owner@lifeassisto.com bash provision.sh
#
# Secrets come from /home/ubuntu/.assisto_secrets.env (SCP'd from the old box —
# KEEP the old INTEGRATIONS_FERNET_KEY). Then run restore.sh + smoke_test.sh.
# ============================================================================
set -euo pipefail

APP_DOMAINS="${APP_DOMAINS:?set APP_DOMAINS=\"lifeassisto.com www.lifeassisto.com api.lifeassisto.com track.lifeassisto.com\"}"
TURN_DOMAIN="${TURN_DOMAIN:-turn.${APP_DOMAINS#* }}"   # first www/api aside; override explicitly
PRIMARY="${PRIMARY:-${APP_DOMAINS%% *}}"               # cert's primary name; the app base host
REPO="${REPO:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${PRIMARY#*.}}"
APP_USER="${APP_USER:-ubuntu}"
HOME_DIR="/home/${APP_USER}"
ASSISTO="${HOME_DIR}/assisto"
SECRETS="${HOME_DIR}/.assisto_secrets.env"
PORT=8700
FLOOR_GB=8

[ "$(id -u)" = "0" ] || { echo "run as root (sudo)"; exit 1; }
id "$APP_USER" >/dev/null 2>&1 || { echo "create user $APP_USER first"; exit 1; }

echo "== [1/13] apt packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-dev build-essential \
  postgresql postgresql-contrib redis-server nginx certbot python3-certbot-nginx \
  coturn git curl openssl ufw fail2ban unattended-upgrades

echo "== [2/13] 4GB swap =="
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "== [3/13] code at $ASSISTO =="
if [ -n "$REPO" ] && [ ! -d "$ASSISTO/.git" ]; then
  sudo -u "$APP_USER" git clone "$REPO" "$ASSISTO"
fi
[ -d "$ASSISTO/backend" ] || { echo "ABORT: no code at $ASSISTO/backend (set REPO or copy it)"; exit 1; }

echo "== [4/13] python venv + deps =="
sudo -u "$APP_USER" python3 -m venv "$ASSISTO/.venv"
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install --upgrade pip wheel
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install -r "$ASSISTO/backend/requirements.txt"
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install gunicorn

echo "== [5/13] secrets (expect SCP'd $SECRETS; generate only if missing) =="
if [ ! -f "$SECRETS" ]; then
  cp "$ASSISTO/migration/.env.template" "$SECRETS"
  DJ="$(python3 -c 'import secrets;print(secrets.token_urlsafe(50))')"
  FK="$($ASSISTO/.venv/bin/python -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())')"
  TS="$(openssl rand -hex 32)"; DBP="$(openssl rand -hex 20)"
  sed -i "s#^DJANGO_SECRET_KEY=.*#DJANGO_SECRET_KEY=$DJ#; s#^INTEGRATIONS_FERNET_KEY=.*#INTEGRATIONS_FERNET_KEY=$FK#; s#^TURN_STATIC_SECRET=.*#TURN_STATIC_SECRET=$TS#; s#^DB_PASSWORD=.*#DB_PASSWORD=$DBP#" "$SECRETS"
  chown "$APP_USER:$APP_USER" "$SECRETS"; chmod 600 "$SECRETS"
  echo "  ⚠ FRESH secrets generated. If MIGRATING, STOP and SCP the OLD $SECRETS (same INTEGRATIONS_FERNET_KEY + DB_PASSWORD), then re-run."
fi
set -a; source "$SECRETS"; set +a
DB_NAME="${DB_NAME:-assisto}"; DB_USER="${DB_USER:-assisto}"; TURN_PORT="${TURN_PORT:-3478}"
# TURN host clients dial = the turn subdomain
sed -i "s#^TURN_HOST=.*#TURN_HOST=$TURN_DOMAIN#" "$SECRETS" || true

echo "== [6/13] backend/.env (ALLOWED_HOSTS + base) =="
cat > "$ASSISTO/backend/.env" <<ENV
DB_PASSWORD=$DB_PASSWORD
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY
INTEGRATIONS_FERNET_KEY=$INTEGRATIONS_FERNET_KEY
TURN_STATIC_SECRET=${TURN_STATIC_SECRET:-}
TURN_HOST=$TURN_DOMAIN
DJANGO_ALLOWED_HOSTS=$(echo "$APP_DOMAINS" | tr ' ' ','),assisto.asalify.com,127.0.0.1,localhost
DJANGO_DEBUG=0
ENV
chown "$APP_USER:$APP_USER" "$ASSISTO/backend/.env"; chmod 600 "$ASSISTO/backend/.env"

echo "== [7/13] Postgres role + db =="
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "ALTER ROLE \"$DB_USER\" PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"

echo "== [8/13] gunicorn systemd unit =="
cat > /etc/systemd/system/assisto.service <<UNIT
[Unit]
Description=Assisto backend (Django/gunicorn)
After=network.target postgresql.service
[Service]
User=$APP_USER
WorkingDirectory=$ASSISTO/backend
EnvironmentFile=-$ASSISTO/backend/.env
ExecStart=$ASSISTO/.venv/bin/gunicorn assisto_backend.wsgi:application --workers 3 --bind 127.0.0.1:$PORT --timeout 60
Restart=on-failure
RestartSec=5
MemoryMax=2500M
[Install]
WantedBy=multi-user.target
UNIT
# NOTE: migrate/collectstatic happen in restore.sh AFTER the DB is restored, to
# avoid creating an empty schema that conflicts with a dump restore. If NOT
# migrating, run them manually.
systemctl daemon-reload; systemctl enable assisto.service

echo "== [9/13] nginx (all app domains) =="
SN="$(echo "$APP_DOMAINS" | tr '\n' ' ')"
cat > /etc/nginx/sites-available/assisto <<NGINX
server {
  listen 80; server_name $SN assisto.asalify.com;
  client_max_body_size 25m;
  location / { proxy_pass http://127.0.0.1:$PORT; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header X-Forwarded-Proto \$scheme; proxy_read_timeout 120; }
  location /media/ { alias $ASSISTO/backend/media/; }
  location /static/ { alias $ASSISTO/backend/staticfiles/; }
}
NGINX
ln -sf /etc/nginx/sites-available/assisto /etc/nginx/sites-enabled/assisto
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "== [10/13] SSL for app domains + turn (DNS must already point here) =="
CERT_D=""; for d in $APP_DOMAINS; do CERT_D="$CERT_D -d $d"; done
certbot --nginx $CERT_D --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect || \
  echo "  app-cert deferred — ensure DNS A-records resolve here, then re-run certbot."
certbot certonly --nginx -d "$TURN_DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" || \
  echo "  turn-cert deferred."

echo "== [11/13] coturn ($TURN_DOMAIN) =="
PUB="$(curl -s --max-time 5 https://api.ipify.org || true)"
PRIV="$(hostname -I | awk '{print $1}')"
cat > /etc/turnserver.conf <<TURN
listening-port=$TURN_PORT
listening-ip=$PRIV
external-ip=$PUB/$PRIV
realm=$TURN_DOMAIN
server-name=$TURN_DOMAIN
use-auth-secret
static-auth-secret=${TURN_STATIC_SECRET:-}
min-port=49200
max-port=49300
total-quota=100
user-quota=6
max-bps=160000
no-loopback-peers
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=::1
no-tcp-relay
no-cli
fingerprint
proc-user=turnserver
proc-group=turnserver
log-file=/var/log/turnserver/turn.log
simple-log
TURN
chown root:turnserver /etc/turnserver.conf; chmod 640 /etc/turnserver.conf
mkdir -p /var/log/turnserver && chown turnserver:turnserver /var/log/turnserver
sed -i 's/^#*TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true
mkdir -p /etc/systemd/system/coturn.service.d
cat > /etc/systemd/system/coturn.service.d/caps.conf <<CAPS
[Service]
MemoryMax=256M
MemoryHigh=192M
CPUQuota=40%
TasksMax=256
Nice=5
Restart=on-failure
RestartSec=5
CAPS
systemctl daemon-reload; systemctl enable coturn

echo "== [12/13] crons (app jobs + backup + cert + watchdog) =="
V="$ASSISTO/.venv/bin/python"; M="$ASSISTO/backend/manage.py"
cat > /etc/cron.d/assisto-app <<CRON
# Assisto application crons (idempotent management commands)
*/5 * * * * $APP_USER nice -n15 $V $M check_went_dark >/dev/null 2>&1
0 * * * * $APP_USER nice -n15 $V $M purge_deletions >> $ASSISTO/backend/logs/purge_deletions.log 2>&1
15 3 * * * $APP_USER nice -n15 $V $M storage_recompute >/dev/null 2>&1
30 3 * * * $APP_USER nice -n15 $V $M shop_prune_snapshots >/dev/null 2>&1
17 * * * * $APP_USER nice -n15 ionice -c3 $V $M shop_clip_purge >/dev/null 2>&1
CRON
mkdir -p "$ASSISTO/backend/logs"; chown -R "$APP_USER:$APP_USER" "$ASSISTO/backend/logs"
cat > /etc/cron.d/assisto-backup <<CRON
15 2 * * * $APP_USER BACKUP_PASSPHRASE=\$(cat /root/.assisto_backup_pass 2>/dev/null) $ASSISTO/migration/backup.sh >/var/log/assisto-backup.log 2>&1
CRON
cat > /etc/cron.d/assisto-watchdog <<CRON
*/5 * * * * root systemctl is-active --quiet assisto || systemctl restart assisto; systemctl is-active --quiet coturn || systemctl restart coturn
CRON

echo "== [13/13] firewall + fail2ban + ssh-key-only + auto-updates =="
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw allow 3478/udp; ufw allow 3478/tcp; ufw allow 49200:49300/udp; ufw allow 5023/tcp
yes | ufw enable || true
systemctl enable --now fail2ban || true
# SSH key-only (keep current session safe: only disable password auth)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd || true
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo
echo "DONE provisioning. App domains: $APP_DOMAINS ; TURN: $TURN_DOMAIN"
echo "NEXT: restore.sh <bundle.enc> (DB+media+old secrets) → then it migrates + collectstatic + starts assisto → smoke_test.sh https://$PRIMARY"
