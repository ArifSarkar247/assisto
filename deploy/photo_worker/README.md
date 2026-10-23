# Photo Studio worker (d1-photo v2)

Separate systemd service `assisto-photo-worker` that runs every heavy Photo
Studio job (HD enhance, old-photo restore, colorize, GPU deblur, cloud prompt
edits) and the FACE LOCK, from the Postgres queue `core.PhotoWorkItem`. The
API (`assisto.service`) only enqueues — it never slows down.

* Limits: `Nice=15`, `CPUWeight=20`, `CPUQuota=100%` (≤ 1 of 2 vCPU), `MemoryMax=3G`,
  idle I/O class, one job at a time; paid jobs first.
* Install (after the backend + migration `0075_d1_photo_v2` are deployed):
  `bash deploy/photo_worker/install.sh --ddcolor /path/ddcolor_tiny_512.onnx`
  — backs up `.env`, `manifest.json`, the unit and `pip freeze` first; installs
  `onnxruntime==1.19.2` + `opencv-python-headless==4.10.0.84`, U²-Net-p,
  DDColor, YuNet (MIT) and AuraFace glintr100 (Apache-2.0) with sha256 checks;
  sets `PHOTO_WORKER=1`; enables the unit; restarts the API.
* Rollback: `bash deploy/photo_worker/rollback.sh <backup dir printed by install>`
  (worker off, `.env`/manifest restored, queued jobs back to "funded").
* Check: `systemctl status assisto-photo-worker`, Owner Admin → Photo Studio
  (queue counts), `journalctl -u assisto-photo-worker -n 50`.
* Without `PHOTO_WORKER=1` the worker-only features stay hidden in the app and
  prompt edits keep the old inline path — safe to deploy the code first.
