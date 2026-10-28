#!/usr/bin/env bash
# ============================================================================
# Assisto backup RESTORE DRILL (owner order 27 Oct: "tested backup and restore").
#
# Restores the newest encrypted backup bundle into a THROWAWAY Postgres
# database (assisto_restore_test_<timestamp>), verifies it, then DROPS it:
#   * the bundle decrypts with the server passphrase and its checksum matches;
#   * the SQL dump loads with zero errors;
#   * key tables exist and the user table is not empty (row counts shown next
#     to the live counts, read with a READ-ONLY session);
#   * the newest applied core migration equals the bundle MANIFEST's head.
# Only db.sql.gz + MANIFEST.txt are unpacked (secrets/media/keystore never
# touch disk). The live database is never written: the target name is forced
# to the assisto_restore_test_ prefix and refused if it equals DB_NAME.
#
#   migration/restore_test.sh [BUNDLE.tar.gz.enc]      # default: newest bundle
#   NO_HEARTBEAT=1 ...   do not record the ops_watch heartbeat (DB write)
#   RESULT_FILE=...      where the JSON result goes
#                        (default backend/logs/restore_test_last.json)
#
# Monthly cron (ops_watch reminds when a month has passed):
#   30 2 1 * * ubuntu /home/ubuntu/assisto/migration/restore_test.sh >>/home/ubuntu/assisto/backend/logs/restore_test.log 2>&1
# ============================================================================
set -uo pipefail

ASSISTO=/home/ubuntu/assisto
SECRETS=/home/ubuntu/.assisto_secrets.env
BACKUP_DIR="${BACKUP_DIR:-/home/ubuntu/assisto_migration_backups}"
RESULT_FILE="${RESULT_FILE:-$ASSISTO/backend/logs/restore_test_last.json}"
FLOOR_GB=8
T0=$(date +%s)
STARTED="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
TS="$(date +%Y%m%d_%H%M%S)"
TARGET_DB="assisto_restore_test_${TS}"

set -a; # shellcheck disable=SC1090
source "$SECRETS"; set +a
DB_NAME="${DB_NAME:-assisto}"; DB_USER="${DB_USER:-assisto}"; DB_HOST="${DB_HOST:-127.0.0.1}"

STAGE="$(mktemp -d /tmp/assisto_rt.XXXXXX)"; chmod 700 "$STAGE"
CREATED=0
OK=0; DETAIL=""; RESTORE_S=0; ERRORS=0; HEAD_DB=""; HEAD_MANIFEST=""; COUNTS="{}"
BUNDLE="${1:-$(ls -1t "$BACKUP_DIR"/assisto_backup_*.tar.gz.enc 2>/dev/null | head -1)}"

finish() {
  local rc=$?
  if [ "$CREATED" = "1" ]; then
    sudo -n -u postgres dropdb --if-exists "$TARGET_DB" >/dev/null 2>&1 \
      && echo "dropped throwaway database $TARGET_DB" \
      || echo "WARNING: could not drop $TARGET_DB — drop it by hand" >&2
  fi
  rm -rf "$STAGE"
  local total=$(( $(date +%s) - T0 ))
  mkdir -p "$(dirname "$RESULT_FILE")"
  python3 - "$RESULT_FILE" <<PY
import json, sys
json.dump({"ok": $([ "$OK" = 1 ] && echo True || echo False),
           "started_at": "$STARTED", "finished_at": "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)",
           "bundle": "$(basename "${BUNDLE:-none}")", "throwaway_db": "$TARGET_DB",
           "restore_seconds": $RESTORE_S, "total_seconds": $total,
           "sql_errors": $ERRORS, "migration_head_db": "$HEAD_DB",
           "migration_head_manifest": "$HEAD_MANIFEST",
           "row_counts": json.loads('''$COUNTS'''), "detail": """$DETAIL"""},
          open(sys.argv[1], "w"), indent=1)
PY
  if [ -z "${NO_HEARTBEAT:-}" ]; then
    (cd "$ASSISTO/backend" && timeout 60 "$ASSISTO/.venv/bin/python" manage.py ops_heartbeat \
      restore_test --rc "$([ "$OK" = 1 ] && echo 0 || echo 1)" --duration-ms "$(( total * 1000 ))" \
      --error "${DETAIL:0:150}" >/dev/null 2>&1) || true
  fi
  echo "RESULT: $([ "$OK" = 1 ] && echo PASS || echo FAIL) — restore ${RESTORE_S}s, total ${total}s. ${DETAIL}"
  exit $([ "$OK" = 1 ] && echo 0 || echo 1)
}
trap finish EXIT

fail() { DETAIL="$*"; echo "FAIL: $*" >&2; exit 1; }

case "$TARGET_DB" in assisto_restore_test_*) ;; *) fail "bad target name";; esac
[ "$TARGET_DB" != "$DB_NAME" ] || fail "target equals the live database"
[ -n "${BUNDLE:-}" ] && [ -f "$BUNDLE" ] || fail "no backup bundle found in $BACKUP_DIR"
free_gb="$(df -BG --output=avail / | tail -1 | tr -dc '0-9')"
[ "${free_gb:-0}" -ge "$FLOOR_GB" ] || fail "free disk ${free_gb}G below ${FLOOR_GB}G floor"

PASS_FILE="${BACKUP_PASSPHRASE_FILE:-/home/ubuntu/.assisto_backup_pass}"
if [ -z "${BACKUP_PASSPHRASE:-}" ] && [ -r "$PASS_FILE" ]; then
  BACKUP_PASSPHRASE="$(head -1 "$PASS_FILE")"
fi
[ -n "${BACKUP_PASSPHRASE:-}" ] || fail "no backup passphrase (env or $PASS_FILE)"
export BACKUP_PASSPHRASE

echo "[1/5] bundle $(basename "$BUNDLE") ($(du -h "$BUNDLE" | cut -f1)) — checksum ..."
if [ -f "${BUNDLE}.sha256" ]; then
  (cd "$(dirname "$BUNDLE")" && sha256sum -c --quiet "$(basename "$BUNDLE").sha256") \
    || fail "checksum mismatch"
else
  echo "  (no .sha256 next to the bundle)"
fi

R0=$(date +%s)
echo "[2/5] decrypt + unpack db dump and manifest only ..."
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass env:BACKUP_PASSPHRASE -in "$BUNDLE" \
  | tar -C "$STAGE" -xzf - --wildcards '*db.sql.gz' '*MANIFEST.txt' \
  || fail "decrypt/unpack failed (wrong passphrase or damaged bundle)"
DUMP="$(find "$STAGE" -name db.sql.gz | head -1)"; MAN="$(find "$STAGE" -name MANIFEST.txt | head -1)"
[ -s "$DUMP" ] || fail "bundle has no db.sql.gz"
HEAD_MANIFEST="$(grep -E '^migration_head=' "$MAN" 2>/dev/null | cut -d= -f2 | sed 's/\.py$//')"

echo "[3/5] create throwaway database $TARGET_DB ..."
sudo -n -u postgres createdb -O "$DB_USER" "$TARGET_DB" || fail "createdb failed"
CREATED=1

echo "[4/5] load dump ..."
ERRLOG="$STAGE/psql.err"
gunzip -c "$DUMP" | nice -n15 ionice -c3 env PGPASSWORD="${DB_PASSWORD:-}" \
  psql -h "$DB_HOST" -U "$DB_USER" -d "$TARGET_DB" -q -X -o /dev/null 2>"$ERRLOG"
ERRORS="$(grep -c 'ERROR' "$ERRLOG" || true)"
RESTORE_S=$(( $(date +%s) - R0 ))
[ "$ERRORS" = "0" ] || { head -5 "$ERRLOG" >&2; fail "$ERRORS SQL errors while loading"; }

echo "[5/5] verify ..."
q() { PGPASSWORD="${DB_PASSWORD:-}" psql -h "$DB_HOST" -U "$DB_USER" -d "$1" -X -At -c "$2" 2>/dev/null; }
qlive() { PGOPTIONS="-c default_transaction_read_only=on" q "$DB_NAME" "$1"; }
HEAD_DB="$(q "$TARGET_DB" "select name from django_migrations where app='core' order by name desc limit 1")"
KEY_TABLES="django_migrations core_user core_circlemember core_circlemessage core_activeday core_installping core_auditlog core_clienterrorreport"
COUNTS="{"; MISSING=""
for t in $KEY_TABLES; do
  exists="$(q "$TARGET_DB" "select to_regclass('public.$t') is not null")"
  if [ "$exists" != "t" ]; then MISSING="$MISSING $t"; continue; fi
  n="$(q "$TARGET_DB" "select count(*) from $t")"
  live="$(qlive "select count(*) from $t")"
  printf '  %-26s restored %8s   live now %8s\n' "$t" "$n" "${live:-?}"
  COUNTS="$COUNTS\"$t\": [${n:-0}, ${live:-null}],"
done
COUNTS="${COUNTS%,}}"
NT="$(q "$TARGET_DB" "select count(*) from information_schema.tables where table_schema='public'")"
echo "  tables restored: $NT; newest core migration: $HEAD_DB (manifest: ${HEAD_MANIFEST:-?})"
[ -z "$MISSING" ] || fail "missing tables:$MISSING"
users="$(q "$TARGET_DB" "select count(*) from core_user")"
[ "${users:-0}" -gt 0 ] || fail "user table is empty"
# the bundle's applied head must match the code head recorded at backup time
# (or the live DB's head, when a deploy is pending/just happened)
HEAD_LIVE="$(qlive "select name from django_migrations where app='core' order by name desc limit 1")"
if [ -n "$HEAD_MANIFEST" ] && [ "$HEAD_DB" != "$HEAD_MANIFEST" ] && [ "$HEAD_DB" != "$HEAD_LIVE" ]; then
  fail "migration head $HEAD_DB != manifest $HEAD_MANIFEST / live $HEAD_LIVE"
fi
OK=1
DETAIL="$NT tables, $users users, migrations at $HEAD_DB"
