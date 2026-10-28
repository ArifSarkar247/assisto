#!/usr/bin/env bash
# VEHICLE TRACKING end-to-end harness — no secrets, no network, no live DB.
#   1. Django tests: protocol vectors (GT06 / H02 / TK103 / Teltonika), alert logic
#      (geofence, overspeed, OFF-ROUTE, long stop, night), idempotent ingest,
#      and REAL-TCP runs of tracker/server.py driven by tracker/sim.py with
#      every alert pushed through core.push (FCM HTTP seam mocked).
#   2. Real-process smoke: `python -m tracker` as its own process on a scratch
#      port + scratch SQLite, GT06 + H02 + Teltonika simulators, results read
#      back through the app HTTP API.
#
#   tools/e2e/vehicle_e2e.sh            # ~4 min (two SQLite migrations)
#   E2E_KEEP=1 tools/e2e/vehicle_e2e.sh # keep the scratch dir (tracker.log, results)
# Env: PY (python with backend deps), E2E_TRACKER_PORT (default 15026; 5023 refused)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="${PY:-}"
if [ -z "$PY" ]; then
  if [ -x "$HOME/assisto/.venv/bin/python" ]; then PY="$HOME/assisto/.venv/bin/python"; else PY=python3; fi
fi
PORT="${E2E_TRACKER_PORT:-15026}"
E2E_DIR="${E2E_DIR:-$(mktemp -d /tmp/assisto-vehicle-e2e.XXXXXX)}"
cleanup() { if [ -z "${E2E_KEEP:-}" ]; then rm -rf "$E2E_DIR"; else echo "[vehicle-e2e] kept $E2E_DIR"; fi; }
trap cleanup EXIT

echo "[vehicle-e2e] 1/2 django tests"
(cd "$ROOT/backend" && "$PY" manage.py test core.tests_e2e_vehicle core.tests_v1_vehicle core.tests_veh100 \
   --settings=assisto_backend.settings_test --parallel 1 --noinput)

echo "[vehicle-e2e] 2/2 real tracker process on 127.0.0.1:$PORT"
"$PY" "$HERE/vehicle_smoke.py" --dir "$E2E_DIR" --port "$PORT"
echo "[vehicle-e2e] ALL PASS"
