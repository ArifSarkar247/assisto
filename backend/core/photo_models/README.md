# Photo Studio on-device AI model (p2-photo)

Served to the app by `GET /api/v1/photo-studio/model` (manifest, login) and
`GET /api/v1/photo-studio/model/<name>` (file, public, HTTP Range). Nothing is
served unless `manifest.json` says `"licence_cleared": true` and every listed
file exists with the listed size.

Install (integrator, on the server, takes seconds, ~200 MB RAM, no torch):

    ~/assisto/.venv/bin/pip install numpy==1.26.4 onnx==1.16.2   # once
    ~/assisto/.venv/bin/python tools/photo_model/convert_realesrgan.py --out backend/core/photo_models

It downloads Real-ESRGAN `realesr-general-x4v3` + `realesr-general-wdn-x4v3`
from the official GitHub release (sha256-checked), blends them at
denoise 0.5 and writes `realesr_general_x4v3_dn050_t144.onnx` (~4.9 MB) +
`manifest.json` here. (Or set `PHOTO_MODEL_DIR` in settings to keep it outside
the repo.) The `.onnx` is git-ignored on purpose.

Licence: Real-ESRGAN is BSD-3-Clause, Copyright (c) 2021 Xintao Wang — keep
this notice (also listed in `.phaseB/MODEL_LICENSES.md` and the app's licence
page).

## d1-photo additions (23 Oct 2026)

The manifest can list more files by `role` (the upscaler stays FIRST):

| role | file | where | licence |
|---|---|---|---|
| `upscale` | `realesr_general_x4v3_dn050_t144.onnx` (4.9 MB, FIXED 1x3x144x144 input) | phone download | BSD-3-Clause |
| `segment` | `u2netp.onnx` (4.6 MB, FIXED 1x3x320x320) — background-blur mask | phone download | Apache-2.0 (U-2-Net) |
| `server_colorize` | `ddcolor_tiny_512.onnx` (~270 MB, FIXED 1x3x512x512) — colorize + old-photo colour | SERVER ONLY (never listed for phones, 404 on the file route) | Apache-2.0 (DDColor code + weights) |

Install (integrator, on the server):

    ~/assisto/.venv/bin/pip install onnxruntime==1.19.2          # server restore jobs
    python3 tools/photo_model/install_d1_models.py --dir backend/core/photo_models \
        --ddcolor /tmp/claude-1000/d1/models/ddcolor_tiny_512.onnx   # or re-run convert_ddcolor.py

`ddcolor_tiny_512.onnx` built on this box by `tools/photo_model/convert_ddcolor.py`
(DDColor commit 2adb63f2, HF `piddnad/ddcolor_paper_tiny`): sha256
`5b4396ff19dbc9729a39fbebd6d7857dee6ff58a35d8820467efa168ecf7b17b`.
Server restore jobs run in a short-lived worker process (`core/photo_restore_worker.py`),
one at a time (file lock), only when ≥ 1.6 GB RAM is free (DDColor peaks ~1.3 GB).
