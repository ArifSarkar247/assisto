#!/usr/bin/env bash
# d1-photo v2 — install the Photo Studio worker on the live box. IDEMPOTENT.
# Backs up everything it changes to ~/assisto/db_backups/photo_worker_<ts>/
# (rollback.sh restores it). Run as ubuntu from the repo root AFTER the
# backend code + migration 0075_d1_photo_v2 are deployed:
#   bash deploy/photo_worker/install.sh [--ddcolor /path/ddcolor_tiny_512.onnx]
set -euo pipefail
ROOT=/home/ubuntu/assisto
BE=$ROOT/backend
VENV=$ROOT/.venv
MODELS=$BE/core/photo_models
UNIT=/etc/systemd/system/assisto-photo-worker.service
TS=$(date +%Y%m%d_%H%M%S)
BK=$ROOT/db_backups/photo_worker_$TS
DDC=""
[ "${1:-}" = "--ddcolor" ] && DDC="${2:-}"
YUNET_URL=https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
YUNET_SHA=8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
# AuraFace-v1 recognition weights (Apache-2.0, commercial training data). ONLY
# glintr100.onnx — the same HF repo also holds byte-identical copies of
# InsightFace's NON-commercial scrfd/2d106det/genderage files: never fetched.
AURA_URL=https://huggingface.co/fal/AuraFace-v1/resolve/main/glintr100.onnx
AURA_SHA=a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60

mkdir -p "$BK"
cp -a "$BE/.env" "$BK/env.bak" 2>/dev/null || true
cp -a "$MODELS/manifest.json" "$BK/manifest.json.bak" 2>/dev/null || true
[ -f "$UNIT" ] && sudo cp -a "$UNIT" "$BK/unit.bak" || true
"$VENV/bin/pip" freeze > "$BK/pip_freeze.txt"
echo "backup -> $BK"

# 1. runtime (MIT / Apache-2.0)
"$VENV/bin/pip" install -q "onnxruntime==1.19.2" "opencv-python-headless==4.10.0.84"

# 2. models: U2-Net-p (phone) + DDColor (server) via the d1 installer
ARGS=(--dir "$MODELS")
[ -n "$DDC" ] && ARGS+=(--ddcolor "$DDC")
python3 "$ROOT/tools/photo_model/install_d1_models.py" "${ARGS[@]}"

# 3. YuNet face detector (MIT) for FACE LOCK, sha256-checked, manifest role server_face
if [ ! -f "$MODELS/yunet_2023mar.onnx" ]; then
  curl -sSL -o "$MODELS/yunet_2023mar.onnx.download" "$YUNET_URL"
  echo "$YUNET_SHA  $MODELS/yunet_2023mar.onnx.download" | sha256sum -c -
  mv "$MODELS/yunet_2023mar.onnx.download" "$MODELS/yunet_2023mar.onnx"
fi
if [ ! -f "$MODELS/auraface_glintr100.onnx" ]; then
  curl -sSL -o "$MODELS/auraface_glintr100.onnx.download" "$AURA_URL"
  echo "$AURA_SHA  $MODELS/auraface_glintr100.onnx.download" | sha256sum -c -
  mv "$MODELS/auraface_glintr100.onnx.download" "$MODELS/auraface_glintr100.onnx"
fi
python3 - "$MODELS" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]; p = os.path.join(d, "manifest.json"); m = json.load(open(p))
m["files"] = [f for f in m["files"] if f.get("role") not in ("server_face", "server_face_id")]
for role, name, lic in (("server_face", "yunet_2023mar.onnx", "MIT (OpenCV Zoo YuNet, Shiqi Yu)"),
                        ("server_face_id", "auraface_glintr100.onnx",
                         "Apache-2.0 (fal.ai AuraFace-v1, commercial training data)")):
    f = os.path.join(d, name)
    m["files"].append({"role": role, "name": name,
                       "sha256": hashlib.sha256(open(f, "rb").read()).hexdigest(),
                       "size": os.path.getsize(f), "licence": lic})
json.dump(m, open(p + ".tmp", "w"), indent=2); os.replace(p + ".tmp", p)
print("manifest roles:", [x["role"] for x in m["files"]])
PY

# 4. switch the API to "enqueue only" (PHOTO_WORKER=1)
grep -q '^PHOTO_WORKER=' "$BE/.env" 2>/dev/null \
  && sed -i 's/^PHOTO_WORKER=.*/PHOTO_WORKER=1/' "$BE/.env" \
  || echo 'PHOTO_WORKER=1' >> "$BE/.env"

# 5. the service
sudo cp "$ROOT/deploy/photo_worker/assisto-photo-worker.service" "$UNIT"
sudo systemctl daemon-reload
sudo systemctl enable --now assisto-photo-worker
sudo systemctl restart assisto        # API picks up PHOTO_WORKER=1
sleep 3
systemctl is-active assisto-photo-worker assisto
echo "OK. Rollback: bash deploy/photo_worker/rollback.sh $BK"
