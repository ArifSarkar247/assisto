#!/usr/bin/env bash
# FAMILY SOS end-to-end harness (fcsos) — the real Django backend on a scratch
# port + scratch sqlite, the REAL FCM v1 push code against mock_fcm.py (JWT
# verified, every message time-stamped on arrival). No secrets, no network.
#
#   tools/e2e/sos_e2e.sh                # ~2 min (first migrate is cached)
#   E2E_KEEP=1 tools/e2e/sos_e2e.sh     # keep the scratch dir
#
# Proves: SOS reaches 3 family accounts (one full-screen "sos" push each,
# nobody else), measured from the sender's request to each phone's receipt
# (target: all phones within 10 s, 20 rounds, p50 / p95 / max printed and
# written to $E2E_DIR/sos_results.json + the GitHub step summary); the
# receiver page (who / when / where / live location / 30 s sound / who is
# going); cancel after sending = "sent by mistake" to all 3; nothing is
# pushed while the phone's countdown is still running (the app sends only
# after it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="${PY:-}"
if [ -z "$PY" ]; then
  if [ -x "$HOME/assisto/.venv/bin/python" ]; then PY="$HOME/assisto/.venv/bin/python"; else PY=python3; fi
fi
E2E_CACHE="${E2E_CACHE:-$HOME/.cache/assisto-e2e}"
PORT="${E2E_PORT_BASE:-18800}"
FCM_PORT=$((PORT + 90))
export E2E_DIR="${E2E_DIR:-$(mktemp -d /tmp/assisto-sos-e2e.XXXXXX)}"
mkdir -p "$E2E_CACHE" "$E2E_DIR"
log() { echo "[sos-e2e] $*"; }

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ -z "${E2E_KEEP:-}" ]; then rm -rf "$E2E_DIR"; else log "kept $E2E_DIR"; fi
}
trap cleanup EXIT

"$PY" "$HERE/mock_fcm.py" --make-sa "$E2E_DIR/fcm_sa.json" --port "$FCM_PORT"
"$PY" "$HERE/mock_fcm.py" --sa "$E2E_DIR/fcm_sa.json" --port "$FCM_PORT" \
  --log "$E2E_DIR/fcm_calls.jsonl" > "$E2E_DIR/fcm.log" 2>&1 & PIDS+=($!)

export DJANGO_SETTINGS_MODULE=assisto_backend.settings_e2e
export E2E_DB="$E2E_DIR/e2e.sqlite3" E2E_MEDIA="$E2E_DIR/media"
export E2E_BASE_URL="http://127.0.0.1:$PORT" E2E_FCM_URL="http://127.0.0.1:$FCM_PORT"
export E2E_FCM_SA="$E2E_DIR/fcm_sa.json"
export E2E_FCM_TOKEN_URI="http://127.0.0.1:$FCM_PORT/token"
export E2E_FCM_SEND_URL="http://127.0.0.1:$FCM_PORT/v1/projects/{project_id}/messages:send"
MIG_HASH=$(cat "$ROOT"/backend/*/migrations/*.py | sha256sum | cut -c1-16)
TPL="$E2E_CACHE/db_template_$MIG_HASH.sqlite3"
if [ ! -f "$TPL" ]; then
  log "migrate scratch DB (cached afterwards)"
  (cd "$ROOT/backend" && E2E_DB="$TPL.part" "$PY" manage.py migrate --noinput -v 0)
  "$PY" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA wal_checkpoint(TRUNCATE)'); c.execute('PRAGMA journal_mode=DELETE'); c.close()" "$TPL.part"
  mv "$TPL.part" "$TPL"
fi
cp "$TPL" "$E2E_DB"
"$PY" "$HERE/sos_e2e_driver.py" seed
(cd "$ROOT/backend" && exec "$PY" manage.py runserver "127.0.0.1:$PORT" --noreload \
  > "$E2E_DIR/django.log" 2>&1) & PIDS+=($!)
for i in $(seq 1 60); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/legal" && break; sleep 1
done
log "run driver"
set +e
"$PY" "$HERE/sos_e2e_driver.py" run
RC=$?
set -e
[ $RC -ne 0 ] && { log "django.log tail:"; tail -n 40 "$E2E_DIR/django.log"; }
exit $RC
