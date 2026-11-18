#!/usr/bin/env bash
# cctv-accuracy — host side of the Wi-Fi live grid measurement
# (.github/workflows/cctv-grid.yml): mediamtx (pinned + sha256) serving 9
# test cameras, each with a MAIN (1280x720, 15 fps, ~1.5 Mbit/s) and a SUB
# (640x360, 15 fps, ~400 kbit/s) H.264 stream — like a Dahua / Hikvision DVR
# channel. The clips are encoded ONCE (ffmpeg test pattern, moving) and then
# looped with -c copy, so 18 publishers cost almost no CPU. The emulator
# reaches the server as 10.0.2.2:18554.
set -euo pipefail
E2E_CACHE="${E2E_CACHE:-$HOME/.cache/assisto-e2e}"
export E2E_DIR="${E2E_DIR:-/tmp/assisto-grid-e2e}"
CAMS="${GRID_CAMS:-9}"
mkdir -p "$E2E_CACHE" "$E2E_DIR"
log() { echo "[grid-e2e] $*"; }
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

cat > "$E2E_DIR/mediamtx.yml" <<YML
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

# one 60 s loop per stream size (a moving test pattern + a moving box: real
# P-frames, not a still picture), GOP 2 s, baseline profile (any decoder)
enc() {  # size kbit/s out
  [ -f "$3" ] || ffmpeg -hide_banner -loglevel error -f lavfi \
    -i "testsrc2=size=$1:rate=15,drawbox=x='mod(t*80,iw)':y=ih/3:w=iw/8:h=ih/4:color=red@0.8:t=fill" \
    -t 60 -c:v libx264 -profile:v baseline -level 4.0 -pix_fmt yuv420p -g 30 -keyint_min 30 \
    -b:v "$2k" -maxrate "$2k" -bufsize "$(( $2 * 2 ))k" -an "$3"
}
enc 1280x720 1500 "$E2E_DIR/main.mp4"
enc 640x360 400 "$E2E_DIR/sub.mp4"
ls -la "$E2E_DIR"/*.mp4
for i in $(seq 1 "$CAMS"); do
  for k in main sub; do
    nohup ffmpeg -hide_banner -loglevel error -re -stream_loop -1 -i "$E2E_DIR/$k.mp4" -c copy \
      -f rtsp -rtsp_transport tcp "rtsp://pub:pubpw@127.0.0.1:18554/cam${i}_$k" \
      > "$E2E_DIR/pub_${i}_$k.log" 2>&1 &
  done
done
sleep 4
for k in main sub; do
  timeout 20 ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
    -show_entries stream=codec_name,width,height -of csv=p=0 \
    "rtsp://viewer:viewpw@127.0.0.1:18554/cam1_$k" | sed "s/^/[grid-e2e] cam1_$k: /"
done
log "up: $CAMS cameras x (main + sub)"
