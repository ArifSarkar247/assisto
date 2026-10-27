#!/usr/bin/env bash
# CCTV watchman END-TO-END harness — real RTSP stream, simulated ONVIF camera,
# the real Shop Box edge client, the real Django backend on a scratch port, the
# real FCM code against a local mock. No secrets, no live DB, no network
# except the one-time pinned asset download (cached).
#
#   tools/e2e/cctv_e2e.sh                # full run (~2-3 min)
#   E2E_KEEP=1 tools/e2e/cctv_e2e.sh     # keep the scratch dir for debugging
#
# Env: PY (python with backend + edge deps; default ~/assisto/.venv/bin/python
#      or python3), E2E_CACHE (asset cache, default ~/.cache/assisto-e2e),
#      E2E_PORT_BASE (default 18700: +0 Django, +90 mock FCM; RTSP 18554,
#      ONVIF 18080 + UDP 3702 multicast on loopback).
# Exit 0 only when every check passed. Results: $E2E_DIR/cctv_results.json
#
# Pinned assets (sha256-verified):
#   mediamtx v1.21.1 linux_amd64 (MIT) — RTSP server
#   YOLOX-Nano ONNX 0.1.1rc0 (Apache-2.0) — the Shop Box's own person model
#   astronaut.png from scikit-image v0.19.3 — NASA portrait, public domain
#   PyAV 13.1.0 (pip --target into the cache) — H.264 publisher
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="${PY:-}"
if [ -z "$PY" ]; then
  if [ -x "$HOME/assisto/.venv/bin/python" ]; then PY="$HOME/assisto/.venv/bin/python"; else PY=python3; fi
fi
E2E_CACHE="${E2E_CACHE:-$HOME/.cache/assisto-e2e}"
PORT="${E2E_PORT_BASE:-18700}"
FCM_PORT=$((PORT + 90))
export E2E_DIR="${E2E_DIR:-$(mktemp -d /tmp/assisto-cctv-e2e.XXXXXX)}"
mkdir -p "$E2E_CACHE" "$E2E_DIR"
log() { echo "[cctv-e2e] $*"; }

fetch() {  # url sha256 dest
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  log "download $(basename "$3")"
  curl -fsSL --retry 3 -m 300 -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --quiet - || { log "SHA256 MISMATCH for $1"; exit 3; }
  mv "$3.part" "$3"
}
MTX_V=v1.21.1
fetch "https://github.com/bluenviron/mediamtx/releases/download/$MTX_V/mediamtx_${MTX_V}_linux_amd64.tar.gz" \
  653abc672a3e693f8d3b2717752492fdcfb8072291ec108d03d3dd857411b0ee "$E2E_CACHE/mediamtx.tar.gz"
[ -x "$E2E_CACHE/mediamtx" ] || tar -xzf "$E2E_CACHE/mediamtx.tar.gz" -C "$E2E_CACHE" mediamtx
fetch "https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx" \
  c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d "$E2E_CACHE/yolox_nano.onnx"
fetch "https://raw.githubusercontent.com/scikit-image/scikit-image/v0.19.3/skimage/data/astronaut.png" \
  88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5 "$E2E_CACHE/astronaut.png"
if [ ! -d "$E2E_CACHE/pydeps/av" ]; then
  log "pip install av==13.1.0 --target cache"
  "$PY" -m pip install -q --target "$E2E_CACHE/pydeps" av==13.1.0
fi

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  if [ -z "${E2E_KEEP:-}" ]; then rm -rf "$E2E_DIR"; else log "kept $E2E_DIR"; fi
}
trap cleanup EXIT

# ---- RTSP server (digest auth: publisher / viewer / ONVIF admin)
cat > "$E2E_DIR/mediamtx.yml" <<EOF
logLevel: warn
api: false
metrics: false
pprof: false
playback: false
rtmp: false
hls: false
webrtc: false
srt: false
rtspTransports: [tcp]
rtspAddress: 127.0.0.1:18554
authMethod: internal
authInternalUsers:
  - {user: pub, pass: pubpw, ips: [], permissions: [{action: publish, path: }]}
  - {user: viewer, pass: viewpw, ips: [], permissions: [{action: read, path: }]}
  - {user: admin, pass: onvifpw, ips: [], permissions: [{action: read, path: }]}
paths:
  all_others:
EOF
(cd "$E2E_DIR" && exec "$E2E_CACHE/mediamtx" mediamtx.yml > mediamtx.log 2>&1) & PIDS+=($!)
sleep 1
PYTHONPATH="$E2E_CACHE/pydeps" "$PY" "$HERE/rtsp_publisher.py" \
  --url rtsp://pub:pubpw@127.0.0.1:18554/cam1 --person "$E2E_CACHE/astronaut.png" \
  > "$E2E_DIR/publisher.log" 2>&1 & PIDS+=($!)

# ---- simulated ONVIF camera + mock FCM
"$PY" "$HERE/onvif_sim.py" --http-port 18080 --user admin --password onvifpw \
  --rtsp rtsp://127.0.0.1:18554/cam1 > "$E2E_DIR/onvif.log" 2>&1 & PIDS+=($!)
"$PY" "$HERE/mock_fcm.py" --make-sa "$E2E_DIR/fcm_sa.json" --port "$FCM_PORT"
"$PY" "$HERE/mock_fcm.py" --sa "$E2E_DIR/fcm_sa.json" --port "$FCM_PORT" \
  --log "$E2E_DIR/fcm_calls.jsonl" > "$E2E_DIR/fcm.log" 2>&1 & PIDS+=($!)

# ---- Django on a scratch port with a scratch sqlite DB
export DJANGO_SETTINGS_MODULE=assisto_backend.settings_e2e
export E2E_DB="$E2E_DIR/e2e.sqlite3" E2E_MEDIA="$E2E_DIR/media"
export E2E_BASE_URL="http://127.0.0.1:$PORT" E2E_FCM_URL="http://127.0.0.1:$FCM_PORT"
export E2E_FCM_SA="$E2E_DIR/fcm_sa.json"
export E2E_FCM_TOKEN_URI="http://127.0.0.1:$FCM_PORT/token"
export E2E_FCM_SEND_URL="http://127.0.0.1:$FCM_PORT/v1/projects/{project_id}/messages:send"
export SHOPBOX_HOME="$E2E_DIR/shopbox" SHOPBOX_MODEL="$E2E_CACHE/yolox_nano.onnx"
export SHOPBOX_DISCOVERY_IFACES=127.0.0.1
# migrated-DB template cached per migration set (first run ~minutes, then instant)
MIG_HASH=$(cat "$ROOT"/backend/*/migrations/*.py | sha256sum | cut -c1-16)
TPL="$E2E_CACHE/db_template_$MIG_HASH.sqlite3"
if [ ! -f "$TPL" ]; then
  log "migrate scratch DB (cached afterwards)"
  (cd "$ROOT/backend" && E2E_DB="$TPL.part" "$PY" manage.py migrate --noinput -v 0)
  "$PY" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute('PRAGMA wal_checkpoint(TRUNCATE)'); c.execute('PRAGMA journal_mode=DELETE'); c.close()" "$TPL.part"
  mv "$TPL.part" "$TPL"
fi
cp "$TPL" "$E2E_DB"
"$PY" "$HERE/cctv_e2e_driver.py" seed
(cd "$ROOT/backend" && exec "$PY" manage.py runserver "127.0.0.1:$PORT" --noreload --nothreading \
  > "$E2E_DIR/django.log" 2>&1) & PIDS+=($!)
for i in $(seq 1 60); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/api/v1/legal" && break; sleep 1
done
log "run driver"
set +e
"$PY" "$HERE/cctv_e2e_driver.py" run
RC=$?
set -e
[ $RC -ne 0 ] && { log "django.log tail:"; tail -n 40 "$E2E_DIR/django.log"; }
exit $RC
