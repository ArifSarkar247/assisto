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
