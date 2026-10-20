#!/usr/bin/env bash
# ============================================================================
# Assisto backup — encrypted bundle of EVERYTHING needed to restore on a new
# server: Postgres dump + media uploads + the secrets file + app_latest + the
# Android keystore (if present). Encrypted with a passphrase you choose.
#
#   ./backup.sh [OUTPUT_DIR]           # default: ~/assisto_migration_backups
#   BACKUP_PASSPHRASE=... ./backup.sh  # non-interactive (CI); else prompts.
#
# NEVER touches Asalify. Reads config from /home/ubuntu/.assisto_secrets.env.
# Refuses to run if free disk would drop below the 8 GB floor.
# ============================================================================
set -euo pipefail

ASSISTO=/home/ubuntu/assisto
SECRETS=/home/ubuntu/.assisto_secrets.env
OUT="${1:-/home/ubuntu/assisto_migration_backups}"
FLOOR_GB=8
TS="$(date +%Y%m%d_%H%M%S)"
STAGE="$(mktemp -d /tmp/assisto_bk.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# --- config ---
set -a; # shellcheck disable=SC1090
source "$SECRETS"; set +a
DB_NAME="${DB_NAME:-assisto}"
DB_USER="${DB_USER:-assisto}"
DB_HOST="${DB_HOST:-127.0.0.1}"

# --- disk floor guard ---
free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
if [ "${free_gb:-0}" -lt "$FLOOR_GB" ]; then
  echo "ABORT: free disk ${free_gb}G is below the ${FLOOR_GB}G floor. Enlarge the disk first." >&2
  exit 1
fi

# --- passphrase --- (env, else the server-only file, else prompt)
PASS_FILE="${BACKUP_PASSPHRASE_FILE:-/home/ubuntu/.assisto_backup_pass}"
if [ -z "${BACKUP_PASSPHRASE:-}" ] && [ -r "$PASS_FILE" ]; then
  BACKUP_PASSPHRASE="$(head -1 "$PASS_FILE")"
fi
if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
  read -r -s -p "Backup passphrase (remember it — the bundle can't be opened without it): " BACKUP_PASSPHRASE; echo
  [ -n "$BACKUP_PASSPHRASE" ] || { echo "ABORT: empty passphrase." >&2; exit 1; }
fi

export BACKUP_PASSPHRASE
mkdir -p "$OUT"
echo "[1/5] Postgres dump ($DB_NAME) ..."
PGPASSWORD="${DB_PASSWORD:-}" pg_dump -h "$DB_HOST" -U "$DB_USER" --no-owner --no-privileges "$DB_NAME" \
  | gzip -9 > "$STAGE/db.sql.gz"

echo "[2/5] media uploads ..."
if [ -d "$ASSISTO/backend/media" ]; then
  tar -C "$ASSISTO/backend" -czf "$STAGE/media.tar.gz" media
else
  : > "$STAGE/media.EMPTY"
fi

echo "[3/5] secrets + app meta + keystore ..."
cp "$SECRETS" "$STAGE/secrets.env"
[ -f "$ASSISTO/app_latest.json" ] && cp "$ASSISTO/app_latest.json" "$STAGE/app_latest.json" || true
# Android upload keystore (losing it = can never update the Play listing).
for ks in "$ASSISTO"/app/android/app/*.jks "$ASSISTO"/app/android/*.jks "$ASSISTO"/*.jks; do
  [ -f "$ks" ] && cp "$ks" "$STAGE/upload-keystore.jks" && break
done
# record the exact migration state so restore verifies the same version.
{
  echo "created=$TS"
  echo "db_name=$DB_NAME"
  echo "migration_head=$(ls "$ASSISTO"/backend/core/migrations/ | grep -E '^00' | tail -1)"
  echo "git_head=$(git -C "$ASSISTO" rev-parse --short HEAD 2>/dev/null || echo n/a)"
} > "$STAGE/MANIFEST.txt"

echo "[4/5] bundle + encrypt (AES-256) ..."
BUNDLE="$OUT/assisto_backup_${TS}.tar.gz.enc"
tar -C "$STAGE" -czf - . \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_PASSPHRASE \
  > "$BUNDLE"
chmod 600 "$BUNDLE"

echo "[5/5] checksum ..."
sha256sum "$BUNDLE" | tee "${BUNDLE}.sha256"

echo "DONE: $BUNDLE ($(du -h "$BUNDLE" | cut -f1))"

# --- retention: keep the newest $KEEP bundles locally ---
KEEP="${BACKUP_KEEP:-14}"
ls -1t "$OUT"/assisto_backup_*.tar.gz.enc 2>/dev/null | tail -n +"$((KEEP + 1))" | while read -r old; do
  rm -f "$old" "${old}.sha256"
done

# --- off-site copy (NEVER keep the only copy on this server) ---
# Configured by the owner in the server-only file /home/ubuntu/.assisto_offsite.env
# (RCLONE_CONFIG_OFFSITE_* vars for any S3-compatible store: AWS S3 /
# Cloudflare R2 / Backblaze B2) + OFFSITE_PATH=offsite:<bucket>/assisto.
OFFSITE_ENV=/home/ubuntu/.assisto_offsite.env
if [ -r "$OFFSITE_ENV" ] && command -v rclone >/dev/null; then
  set -a; # shellcheck disable=SC1090
  source "$OFFSITE_ENV"; set +a
  if rclone copy "$BUNDLE" "$OFFSITE_PATH/" && rclone copy "${BUNDLE}.sha256" "$OFFSITE_PATH/"; then
    echo "OFFSITE: uploaded to $OFFSITE_PATH"
  else
    echo "OFFSITE: upload FAILED" >&2; exit 2
  fi
else
  echo "OFFSITE: not configured — this backup exists ONLY on this server (see owner_actions/OWNER_UNLOCK_LIST.md)"
fi
echo "Keep this file AND the passphrase safe. restore.sh needs both."
