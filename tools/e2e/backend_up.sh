#!/usr/bin/env bash
# e2eproof: throw-away Django for the proof flows (settings_e2e = settings_ci
# + the ci_e2e fakes). Migrate, seed + self-check, then serve on :8700.
# Needs: REALITY_OUT, ASSISTO_CI_PG_* (the job's postgres service).
set -euo pipefail
cd "$(dirname "$0")/../../backend"
export E2E_OUTBOX="${E2E_OUTBOX:-$REALITY_OUT/outbox.jsonl}"
S=--settings=assisto_backend.settings_e2e
mkdir -p "$REALITY_OUT"
timeout 600 python manage.py migrate $S -v 0
timeout 300 python manage.py seed_e2e $S --out "$REALITY_OUT/seed_e2e.json" --reality-out "$REALITY_OUT/seed.json"
python3 - <<'PY'
import json, os, sys
d = json.load(open(os.environ["REALITY_OUT"] + "/seed_e2e.json"))
print(json.dumps(d["flags"]))
if d["failed_critical"]:
    print("::error::e2e seed self-check failed: %s" % d["failed_critical"]); sys.exit(1)
print("seed_e2e OK")
PY
nohup python manage.py runserver 0.0.0.0:8700 --noreload $S > "$REALITY_OUT/django.log" 2>&1 &
echo $! > "$REALITY_OUT/django.pid"
for i in $(seq 1 60); do
  curl -fsS -m 5 http://127.0.0.1:8700/api/v1/health >/dev/null && { echo "django up"; exit 0; }
  sleep 2
done
echo "::error::Django did not come up"; tail -50 "$REALITY_OUT/django.log"; exit 1
