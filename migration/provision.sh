#!/usr/bin/env bash
# ============================================================================
# Assisto provision — turn a FRESH Ubuntu 22.04/24.04 server into a complete
# Assisto backend host: Python + venv, Postgres, nginx + Let's Encrypt SSL,
# gunicorn systemd unit, coturn (same hard caps + security as production),
# Redis, nightly backup cron, cert auto-renew, and a watchdog.
#
# RUN AS ROOT on the NEW server (never on the shared Asalify box):
#   sudo DOMAIN=assisto.example.com REPO=https://github.com/you/assisto.git \
#        ADMIN_EMAIL=you@example.com bash provision.sh
#
# Then: copy your filled secrets to /home/ubuntu/.assisto_secrets.env (see
# .env.template) and run restore.sh (if migrating data) + smoke_test.sh.
# Idempotent where practical; safe to re-run.
# ============================================================================
set -euo pipefail

DOMAIN="${DOMAIN:?set DOMAIN=your.domain}"
REPO="${REPO:-}"                       # git URL; or pre-place code at /home/ubuntu/assisto
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@${DOMAIN#*.}}"
APP_USER="${APP_USER:-ubuntu}"
HOME_DIR="/home/${APP_USER}"
ASSISTO="${HOME_DIR}/assisto"
SECRETS="${HOME_DIR}/.assisto_secrets.env"
PORT=8700
FLOOR_GB=8

[ "$(id -u)" = "0" ] || { echo "run as root (sudo)"; exit 1; }
free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "${free_gb:-0}" -ge "$FLOOR_GB" ] || { echo "ABORT: <${FLOOR_GB}G free"; exit 1; }
id "$APP_USER" >/dev/null 2>&1 || { echo "create user $APP_USER first"; exit 1; }

echo "== [1/10] apt packages =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-dev build-essential \
  postgresql postgresql-contrib redis-server nginx certbot python3-certbot-nginx \
  coturn git curl openssl ufw

echo "== [2/10] code at $ASSISTO =="
if [ -n "$REPO" ] && [ ! -d "$ASSISTO/.git" ]; then
  sudo -u "$APP_USER" git clone "$REPO" "$ASSISTO"
fi
[ -d "$ASSISTO/backend" ] || { echo "ABORT: no code at $ASSISTO/backend (set REPO or copy it)"; exit 1; }

echo "== [3/10] python venv + deps =="
sudo -u "$APP_USER" python3 -m venv "$ASSISTO/.venv"
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install --upgrade pip wheel
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install -r "$ASSISTO/backend/requirements.txt"
sudo -u "$APP_USER" "$ASSISTO/.venv/bin/pip" install gunicorn

echo "== [4/10] secrets scaffold =="
if [ ! -f "$SECRETS" ]; then
  cp "$ASSISTO/migration/.env.template" "$SECRETS"
  # auto-generate the ones we safely can:
  DJ="$(python3 -c 'import secrets;print(secrets.token_urlsafe(50))')"
  FK="$($ASSISTO/.venv/bin/python -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())')"
  TS="$(openssl rand -hex 32)"
  DBP="$(openssl rand -hex 20)"
  sed -i "s#^DJANGO_SECRET_KEY=.*#DJANGO_SECRET_KEY=$DJ#; s#^INTEGRATIONS_FERNET_KEY=.*#INTEGRATIONS_FERNET_KEY=$FK#; s#^TURN_STATIC_SECRET=.*#TURN_STATIC_SECRET=$TS#; s#^DB_PASSWORD=.*#DB_PASSWORD=$DBP#; s#^TURN_HOST=.*#TURN_HOST=$DOMAIN#" "$SECRETS"
  chown "$APP_USER:$APP_USER" "$SECRETS"; chmod 600 "$SECRETS"
  echo "  generated DJANGO_SECRET_KEY / INTEGRATIONS_FERNET_KEY / TURN_STATIC_SECRET / DB_PASSWORD."
  echo "  ⚠ If MIGRATING existing data, OVERWRITE INTEGRATIONS_FERNET_KEY + DB_PASSWORD with the OLD values (restore.sh brings the old secrets.env)."
fi
# shellcheck disable=SC1090
set -a; source "$SECRETS"; set +a
DB_NAME="${DB_NAME:-assisto}"; DB_USER="${DB_USER:-assisto}"

echo "== [5/10] Postgres role + db =="
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE ROLE \"$DB_USER\" LOGIN PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "ALTER ROLE \"$DB_USER\" PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"

echo "== [6/10] gunicorn systemd unit =="
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
# hard caps so one runaway worker can't take the box
MemoryMax=1200M
[Install]
WantedBy=multi-user.target
UNIT
# migrate + static + superuser
sudo -u "$APP_USER" bash -c "cd $ASSISTO/backend && ../.venv/bin/python manage.py migrate --noinput && ../.venv/bin/python manage.py collectstatic --noinput"
sudo -u "$APP_USER" DJANGO_SUPERUSER_USERNAME="${OWNER_ADMIN_LOGIN:-owner}" DJANGO_SUPERUSER_PASSWORD="${OWNER_ADMIN_PASSWORD:-}" \
  bash -c "cd $ASSISTO/backend && ../.venv/bin/python manage.py createsuperuser --noinput --phone ${OWNER_ADMIN_LOGIN:-owner} 2>/dev/null || true"
systemctl daemon-reload; systemctl enable --now assisto.service

echo "== [7/10] nginx + SSL ($DOMAIN) =="
cat > /etc/nginx/sites-available/assisto <<NGINX
server {
  listen 80; server_name $DOMAIN;
  client_max_body_size 20m;
  location / { proxy_pass http://127.0.0.1:$PORT; proxy_set_header Host \$host; proxy_set_header X-Forwarded-For \$remote_addr; proxy_set_header X-Forwarded-Proto \$scheme; }
  location /media/ { alias $ASSISTO/backend/media/; }
  location /static/ { alias $ASSISTO/backend/staticfiles/; }
}
NGINX
ln -sf /etc/nginx/sites-available/assisto /etc/nginx/sites-enabled/assisto
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
# SSL (needs the DNS A-record already pointing here). Safe to re-run.
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect || \
  echo "  certbot deferred — point DNS at this server then re-run: certbot --nginx -d $DOMAIN"

echo "== [8/10] coturn (same hard caps + security) =="
PUB="$(curl -s --max-time 5 https://api.ipify.org || true)"
PRIV="$(hostname -I | awk '{print $1}')"
cat > /etc/turnserver.conf <<TURN
listening-port=$TURN_PORT
listening-ip=$PRIV
external-ip=$PUB/$PRIV
realm=$DOMAIN
server-name=$DOMAIN
use-auth-secret
static-auth-secret=$TURN_STATIC_SECRET
min-port=49200
max-port=49300
total-quota=100
user-quota=6
max-bps=160000
no-loopback-peers
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
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
systemctl daemon-reload; systemctl enable --now coturn

echo "== [9/10] crons: nightly backup + cert renew + watchdog =="
# nightly encrypted backup at 03:15 (set BACKUP_PASSPHRASE in a root-only file)
cat > /etc/cron.d/assisto-backup <<CRON
15 3 * * * $APP_USER BACKUP_PASSPHRASE=\$(cat /root/.assisto_backup_pass 2>/dev/null) $ASSISTO/migration/backup.sh >/var/log/assisto-backup.log 2>&1
CRON
# watchdog every 5 min: restart assisto/coturn if down (systemd already retries;
# this catches a crash-loop giving up).
cat > /etc/cron.d/assisto-watchdog <<CRON
*/5 * * * * root systemctl is-active --quiet assisto || systemctl restart assisto; systemctl is-active --quiet coturn || systemctl restart coturn
CRON
# certbot has its own systemd timer; nothing to add.

echo "== [10/10] firewall (ufw) =="
ufw allow 22/tcp; ufw allow 80/tcp; ufw allow 443/tcp
ufw allow 3478/udp; ufw allow 3478/tcp; ufw allow 49200:49300/udp
yes | ufw enable || true
# NOTE: on a cloud host you ALSO must open these in the provider Security Group
# (see owner_actions/aws_ports.md). ufw alone is not enough behind a cloud firewall.

echo
echo "DONE. Assisto should be live at https://$DOMAIN"
echo "Next:"
echo "  1) DNS: point $DOMAIN (and TURN_HOST) A-record at this server's public IP."
echo "  2) If MIGRATING: ./restore.sh <bundle.enc>  (brings DB + media + the OLD secrets)."
echo "  3) Open provider Security-Group ports (owner_actions/aws_ports.md)."
echo "  4) Verify: ./smoke_test.sh https://$DOMAIN"
echo "  5) Paste feature keys in the in-app Integrations admin (see .env.template)."
