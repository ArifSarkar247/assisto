#!/usr/bin/env bash
# gboxlinux — Linux Guard Box E2E (guardbox-linux.yml), one CPU arch per run:
#   bash tools/e2e/guardbox_linux_e2e.sh amd64|arm64 <dir with the .deb>
# Host side (ipcam_e2e_up.sh): a real RTSP camera (mediamtx + a synthetic scene
# with a public-domain person photo), a throw-away Django (scratch sqlite) and
# the owner-side control server. Box side: a clean debian:bookworm-slim
# container (arm64 through qemu) that installs the released-format .deb and
# runs the box exactly as the systemd unit would, as its own user.
#   1. pair with the owner's camera code (the same code as the phone)
#   2. person walks in -> alert WITH a picture at the backend
#   3. internet down 200 s (backend stopped) -> alerts wait on disk -> back:
#      the queued alerts arrive + the owner gets "internet was down from-to"
#   4. power cut (SIGKILL, then a start with a NEW boot id = simulated reboot)
#      -> the owner gets "power returned after X minutes"
# Made-up sample data; no secrets.
set -euo pipefail
ARCH="${1:?amd64|arm64}"
DEBDIR="$(cd "${2:?deb dir}" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="${PY:-python3}"
export E2E_DIR="${E2E_DIR:-/tmp/assisto-gbox-e2e}"
mkdir -p "$E2E_DIR"
log() { echo "[gbox-e2e $ARCH] $*"; }
SLOW=1; [ "$ARCH" = "arm64" ] && SLOW=4          # qemu: inference is ~4x slower

diag() {  # on any failure: what the box saw (logs hold no secrets: userinfo is masked)
  echo "----- box status.json"; docker exec gbox cat /var/lib/assisto-guardbox/status.json 2>/dev/null | head -c 3000; echo
  echo "----- box run.log (tail)"; docker exec gbox sh -c 'tail -60 /var/lib/assisto-guardbox/run.log; tail -80 /var/lib/assisto-guardbox/logs/*.log' 2>/dev/null | tail -120
  echo "----- box config.json (no secrets)"; docker exec gbox cat /var/lib/assisto-guardbox/config.json 2>/dev/null | head -c 2500; echo
  echo "----- django (tail)"; grep -E "shop/(ingest|heartbeat|config|phonecam)" "$E2E_DIR/django.log" | tail -25
}
trap 'rc=$?; [ $rc -ne 0 ] && diag; exit $rc' EXIT

bash "$HERE/ipcam_e2e_up.sh"

CODE="$(curl -fsS http://127.0.0.1:18799/mint | "$PY" -c 'import json,sys;print(json.load(sys.stdin)["code"])')"
log "pairing code minted from the owner API"

docker rm -f gbox >/dev/null 2>&1 || true
docker run -d --name gbox --network host --platform "linux/$ARCH" \
  -v "$DEBDIR:/pkg:ro" debian:bookworm-slim sleep infinity >/dev/null
docker exec gbox sh -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq procps /pkg/assisto-guardbox_${ARCH}.deb" \
  > "$E2E_DIR/install.log" 2>&1 || { tail -40 "$E2E_DIR/install.log"; exit 1; }
tail -6 "$E2E_DIR/install.log"
docker exec gbox assisto-guardbox version

BOX="runuser -u assisto-guardbox -- env SHOPBOX_HOME=/var/lib/assisto-guardbox SHOPBOX_PROFILE=lite"
docker exec -e SHOPBOX_RTSP_PASSWORD=viewpw gbox sh -c \
  "$BOX SHOPBOX_RTSP_PASSWORD=viewpw /opt/assisto-guardbox/assisto-guardbox --base-url http://127.0.0.1:18700/api/v1/ --add-camera 'Gate' --rtsp rtsp://viewer@127.0.0.1:18554/cam1"
docker exec gbox assisto-guardbox pair "$CODE"
# the camera password is on the box only, encrypted; never in config.json
if docker exec gbox grep -q viewpw /var/lib/assisto-guardbox/config.json; then
  log "FAIL: camera password in config.json"; exit 1; fi

start_box() {  # $1 = boot id + $2 = boot time (empty = the real machine's)
  docker exec -d gbox sh -c "$BOX SHOPBOX_BOOT_ID=$1 SHOPBOX_BOOT_TIME=$2 /opt/assisto-guardbox/assisto-guardbox --run >> /var/lib/assisto-guardbox/run.log 2>&1"
}
start_box "" ""
log "box running; waiting for the person alert"
"$PY" "$HERE/guardbox_ctl.py" wait_alert $((900 * SLOW / 2 + 300))

# ---- internet down: stop the backend for 200 s, alerts wait on the box
log "internet down (backend stopped)"
"$PY" "$HERE/guardbox_ctl.py" mark
pkill -f "runserver 0.0.0.0:18700" || true
sleep 200
docker exec gbox sh -c 'ls /var/lib/assisto-guardbox/outbox | wc -l' | sed 's/^/[gbox-e2e] alerts waiting on the box: /'
(cd "$ROOT/backend" && DJANGO_SETTINGS_MODULE=assisto_backend.settings_e2e \
  E2E_DB="$E2E_DIR/e2e.sqlite3" E2E_MEDIA="$E2E_DIR/media" \
  nohup "$PY" manage.py runserver 0.0.0.0:18700 --noreload >> "$E2E_DIR/django.log" 2>&1 &)
log "internet back"
"$PY" "$HERE/guardbox_ctl.py" wait_more $((300 * SLOW))
"$PY" "$HERE/guardbox_ctl.py" wait_notif net_back $((180 * SLOW))

# ---- power cut: no clean stop, then the machine "boots again"
log "power cut (kill -9) + simulated reboot"
docker exec gbox pkill -9 -f "assisto-guardbox --run" || true
sleep 45
start_box "ci-reboot-2" "$(date +%s)"
"$PY" "$HERE/guardbox_ctl.py" wait_notif power_back $((180 * SLOW))

"$PY" "$HERE/guardbox_ctl.py" proof
docker exec gbox cat /var/lib/assisto-guardbox/status.json > "$E2E_DIR/box_status.json" 2>/dev/null || true
docker exec gbox tail -80 /var/lib/assisto-guardbox/run.log > "$E2E_DIR/box_run.log" 2>/dev/null || true
log "PASS"
