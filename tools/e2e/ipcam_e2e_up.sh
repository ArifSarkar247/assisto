#!/usr/bin/env bash
# cctvbox — host side of the Guard Box emulator E2E (.github/workflows/ipcam-e2e.yml):
# a real RTSP camera (mediamtx, pinned + sha256-checked) publishing the
# synthetic scene of tools/e2e/rtsp_publisher.py (a public-domain person photo
# walks in every 12 s), a throw-away Django on 0.0.0.0:18700 (scratch sqlite,
# settings_e2e) and the control server on :18799. The emulator reaches all of
# them as 10.0.2.2. Leaves the processes running; logs in $E2E_DIR.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PY="${PY:-python3}"
E2E_CACHE="${E2E_CACHE:-$HOME/.cache/assisto-e2e}"
export E2E_DIR="${E2E_DIR:-/tmp/assisto-ipcam-e2e}"
mkdir -p "$E2E_CACHE" "$E2E_DIR"
log() { echo "[ipcam-e2e] $*"; }
fetch() {  # url sha256 dest
  if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --quiet - 2>/dev/null; then return 0; fi
  curl -fsSL --retry 3 -m 300 -o "$3.part" "$1"
  echo "$2  $3.part" | sha256sum -c --quiet - || { log "SHA256 MISMATCH for $1"; exit 3; }
  mv "$3.part" "$3"
}
MTX_V=v1.21.1
fetch "https://github.com/bluenviron/mediamtx/releases/download/$MTX_V/mediamtx_${MTX_V}_linux_amd64.tar.gz" \
  653abc672a3e693f8d3b2717752492fdcfb8072291ec108d03d3dd857411b0ee "$E2E_CACHE/mediamtx.tar.gz"
[ -x "$E2E_CACHE/mediamtx" ] || tar -xzf "$E2E_CACHE/mediamtx.tar.gz" -C "$E2E_CACHE" mediamtx
fetch "https://raw.githubusercontent.com/scikit-image/scikit-image/v0.19.3/skimage/data/astronaut.png" \
  88431cd9653ccd539741b555fb0a46b61558b301d4110412b5bc28b5e3ea6cb5 "$E2E_CACHE/astronaut.png"
[ -d "$E2E_CACHE/pydeps/av" ] || "$PY" -m pip install -q --target "$E2E_CACHE/pydeps" av==13.1.0

cat > "$E2E_DIR/mediamtx.yml" <<YML
logLevel: info
api: false
metrics: false
pprof: false
playback: false
rtmp: false
hls: false
webrtc: false
srt: false
rtspTransports: [tcp]
rtspAddress: 0.0.0.0:18554
authMethod: internal
authInternalUsers:
  - {user: pub, pass: pubpw, ips: [], permissions: [{action: publish, path: }]}
  - {user: viewer, pass: viewpw, ips: [], permissions: [{action: read, path: }]}
paths:
  all_others:
YML
(cd "$E2E_DIR" && nohup "$E2E_CACHE/mediamtx" mediamtx.yml > mediamtx.log 2>&1 &)
sleep 1
PYTHONPATH="$E2E_CACHE/pydeps" nohup "$PY" "$HERE/rtsp_publisher.py" \
  --url rtsp://pub:pubpw@127.0.0.1:18554/cam1 --person "$E2E_CACHE/astronaut.png" \
  > "$E2E_DIR/publisher.log" 2>&1 &

export DJANGO_SETTINGS_MODULE=assisto_backend.settings_e2e
export E2E_DB="$E2E_DIR/e2e.sqlite3" E2E_MEDIA="$E2E_DIR/media" E2E_EXTRA_HOSTS=10.0.2.2
log "migrate scratch DB"
(cd "$ROOT/backend" && timeout 900 "$PY" manage.py migrate --noinput -v 0)
"$PY" "$HERE/ipcam_ctl.py" seed
(cd "$ROOT/backend" && nohup "$PY" manage.py runserver 0.0.0.0:18700 --noreload \
  > "$E2E_DIR/django.log" 2>&1 &)
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:18700/api/v1/legal && break; sleep 1; done
nohup "$PY" "$HERE/ipcam_ctl.py" serve > "$E2E_DIR/ctl.log" 2>&1 &
sleep 2
curl -fsS http://127.0.0.1:18799/mint | sed 's/"code": "[^"]*"/"code": "***"/'
# the RTSP stream is really there (a host-side probe with ffprobe-free PyAV)
PYTHONPATH="$E2E_CACHE/pydeps" "$PY" - <<'PYX'
import av, sys
c = av.open("rtsp://viewer:viewpw@127.0.0.1:18554/cam1", options={"rtsp_transport": "tcp"}, timeout=10)
s = c.streams.video[0]
print("[ipcam-e2e] rtsp ok:", s.codec_context.name, s.codec_context.width, "x", s.codec_context.height)
PYX
log "up"
