#!/usr/bin/env bash
# ============================================================================
# Assisto restore — unpack an encrypted backup bundle onto a server.
#
#   ./restore.sh BUNDLE.tar.gz.enc [--into-db DBNAME] [--dry-run]
#
#   --into-db DBNAME   restore the Postgres dump into DBNAME (default: the
#                      db_name from the bundle MANIFEST, usually "assisto").
#                      Use a TEMP db name to rehearse without touching live data.
#   --dry-run          unpack + show the manifest, do NOT write DB/media/secrets.
#
# BACKUP_PASSPHRASE=... for non-interactive. Refuses below the 8 GB disk floor.
# Never touches Asalify.
# ============================================================================
set -euo pipefail

ASSISTO=/home/ubuntu/assisto
SECRETS=/home/ubuntu/.assisto_secrets.env
FLOOR_GB=8
BUNDLE="${1:?usage: restore.sh BUNDLE.enc [--into-db NAME] [--dry-run]}"
shift || true
INTO_DB=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --into-db) INTO_DB="${2:?}"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

STAGE="$(mktemp -d /tmp/assisto_rs.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "${free_gb:-0}" -lt "$FLOOR_GB" ]; then
  echo "ABORT: free disk ${free_gb}G below ${FLOOR_GB}G floor." >&2; exit 1
fi

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  read -r -s -p "Backup passphrase: " BACKUP_PASSPHRASE; echo
fi

echo "[1/5] verify checksum (if present) ..."
[ -f "${BUNDLE}.sha256" ] && sha256sum -c "${BUNDLE}.sha256"

echo "[2/5] decrypt + unpack ..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass pass:"$BACKUP_PASSPHRASE" -in "$BUNDLE" \
  | tar -C "$STAGE" -xzf -
echo "---- MANIFEST ----"; cat "$STAGE/MANIFEST.txt"; echo "------------------"

# resolve target db
SRC_DB="$(grep -E '^db_name=' "$STAGE/MANIFEST.txt" | cut -d= -f2)"
TARGET_DB="${INTO_DB:-$SRC_DB}"

if [ "$DRY" = "1" ]; then
  echo "DRY-RUN: unpacked OK. Would restore DB -> '$TARGET_DB', media, secrets. Nothing written."
  exit 0
fi

# load current DB creds (role must already exist — provision.sh makes it)
set -a; source "$SECRETS" 2>/dev/null || true; set +a
DB_USER="${DB_USER:-assisto}"; DB_HOST="${DB_HOST:-127.0.0.1}"

echo "[3/5] restore Postgres -> $TARGET_DB ..."
# (Re)create the target DB owned by the app role. CREATE DATABASE needs a
# superuser, so prefer the local `postgres` peer login; fall back to the app
# role only if it happens to have CREATEDB (it usually does NOT — so provision
# on a fresh server, where this runs as root with postgres available).
if sudo -n -u postgres psql -tc "SELECT 1" >/dev/null 2>&1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$TARGET_DB\";" \
    -c "CREATE DATABASE \"$TARGET_DB\" OWNER \"$DB_USER\";"
else
  echo "  (postgres peer login unavailable — trying as $DB_USER; needs CREATEDB)"
  PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$TARGET_DB\";" \
    -c "CREATE DATABASE \"$TARGET_DB\" OWNER \"$DB_USER\";"
fi
gunzip -c "$STAGE/db.sql.gz" | PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" -q

echo "[4/5] restore media ..."
if [ -f "$STAGE/media.tar.gz" ]; then
  mkdir -p "$ASSISTO/backend"
  tar -C "$ASSISTO/backend" -xzf "$STAGE/media.tar.gz"
fi

echo "[5/5] restore secrets + keystore (only if target file is absent) ..."
if [ ! -f "$SECRETS" ]; then
  cp "$STAGE/secrets.env" "$SECRETS"; chmod 600 "$SECRETS"
  echo "  secrets.env restored."
else
  echo "  secrets file already present — left untouched. (Diff $STAGE/secrets.env if needed.)"
fi
[ -f "$STAGE/upload-keystore.jks" ] && echo "  upload-keystore.jks is in the bundle — place it on your BUILD host."

echo "DONE. Next: run migrations + smoke_test.sh."
echo "  cd $ASSISTO/backend && ../.venv/bin/python manage.py migrate"
