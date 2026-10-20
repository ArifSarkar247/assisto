# Assisto Shop Box: edge client for Windows

The Shop Box is a small program that runs on a PC inside the shop. It sits on
the same local network as the CCTV cameras and does the following:

1. Pulls each camera's RTSP stream **on the local network** (OpenCV + FFmpeg,
   RTSP over TCP). It analyses about 3 frames per second, downscaled to 640 px.
2. Runs **on-device** detection: motion, a person in the cash-drawer zone, and
   activity after opening hours.
3. Sends **only** a small JSON signal plus **one** downscaled JPEG still
   (≤150 KB) to `POST <base>/shop/ingest`. Video is never streamed or uploaded.

The server (`backend/core/logic/shop_guard.py`) decides whether to alert the
owner. It raises an alert only when two signals combine, for example "person in
cash zone" with no matching POS sale. The owner always reads **"please check
camera X"** together with a confidence value, and never the word "theft".

## Network and privacy

* The client only makes **outbound HTTPS** requests. It opens no listening
  port, needs no port forwarding and does not use UPnP. The tkinter UI is a
  local window, not a web server.
* The base URL defaults to `https://api.lifeassisto.com/api/v1/`. It can be
  changed in the UI or with `--base-url`. Plain `http://` is refused, except
  for `localhost` during development.
* Secrets are encrypted at rest:
  * **Windows:** DPAPI (`CryptProtectData`, current-user scope, via ctypes).
    No key file exists.
  * **Linux/macOS:** Fernet with a random key in `secret.key` (mode `0600`).
  * Secrets include the enrollment token, RTSP username and password, and
    optional per-camera tokens. They are stored in `secrets.json` as
    ciphertext only.
  * `config.json` stores RTSP URLs with the credentials removed.
  * Every log line is redacted. `user:pass@` is masked, and so is every
    loaded secret value.
* Data lives in `%APPDATA%\AssistoShopBox` (Windows). It holds the config,
  encrypted secrets, logs, the bounded outbox and the event history.

## Detection: how it works

For each camera, `CameraWorker` keeps the decoder current with `grab()` and
calls `retrieve()` only at `sample_fps`. The sampled frame goes to
`CameraAnalyzer`:

| Shop state | Condition (on `confirm_frames` = 2 consecutive samples) | Event sent |
|---|---|---|
| Closed (outside hours / closed day) | motion blob ≥ min-area anywhere | `after_hours` with `{after_hours: true, multiple_frames: true, detector}` |
| Open, zone drawn, model loaded | motion inside zone **and** a YOLOX person box overlapping the zone | `hand_in_cash_zone` with `{detector: "yolox_nano", motion_in_zone: true[, lingering: true]}` |
| Open, zone drawn, **no model** | motion inside zone | `motion` with `{detector: "motion_only", zone_breach: true, motion_in_zone: true}` |
| Open, no zone / quiet zone | none | nothing (the server would only log `lone_motion`) |

* **Motion** uses a running-average background, a frame difference and a
  threshold on a 320 px grey image. Blobs below the minimum area are ignored.
  If more than 60% of the frame changes at once (lights switching, IR night
  mode, an exposure jump), the background is reset and **no** event is sent.
* **Person** detection uses YOLOX-Nano ONNX on the onnxruntime CPU provider,
  with 2 threads and about 40 ms per frame on a modest CPU. It runs only when
  the zone has already moved, so a quiet camera costs almost nothing.
* **Zone**: the owner clicks the polygon corners on a captured frame. The
  points are stored normalised to 0..1, so the zone survives a change of
  stream resolution.
* **Hours** are open/close `HH:MM` in the shop's IANA time zone (default
  `Asia/Dhaka`). Overnight hours (for example 18:00–02:00) and closed weekdays
  are supported. Setting open equal to close disables after-hours detection.

### Model

| | |
|---|---|
| Model | YOLOX-Nano (Megvii, Apache-2.0), COCO; only class 0 "person" is used |
| URL | `https://github.com/Megvii-BaseDetection/YOLOX/releases/download/0.1.1rc0/yolox_nano.onnx` |
| SHA-256 | `c789161ed43c8269fcd4e67c67eeeb4e80c622da2eb296a20bc6007bd18a0b7d` |
| Size | ~3.6 MB, input 1×3×416×416 |

The model is **never committed**. CI downloads it, verifies its SHA-256 and
bundles it next to the exe. If it is missing, the client tries one verified
download on first run (`--fetch-model`). If the file is missing, fails the
hash check, or onnxruntime cannot load it, the client **degrades to
motion-in-zone** and reports `detector: "motion_only"`. The UI also says that
person detection is not available.

## Sending, dedupe, offline

* **Cooldown:** one event per (camera, type) per 180 s.
* **Global budget:** at most 12 sends per minute. The server's anonymous DRF
  throttle is 30/min per IP, and ingest also rate-limits 10 raised events per
  site+type per 2 s.
* **Store-and-forward:** events go first to an on-disk outbox (atomic writes)
  and are then sent oldest-first. The outbox is bounded to 200 items, 40 MB
  and 12 h; when a limit is reached, the oldest items are dropped. Queued
  items hold **no tokens**; credentials are attached at send time.
* **Retries:** network errors, 5xx and 429 are retried with exponential
  backoff up to 5 min, honouring `Retry-After`. Other 4xx responses are
  dropped. A 401 pauses sending, keeps the queue and asks the owner to pair
  again.
* **Pairing check:** the client posts `{site_token, type: ""}`. The server
  resolves the token before it validates the type, so a valid token gets
  `422 bad_type`, a bad token gets `401`, and nothing is stored.

### Payload sample (what actually leaves the PC)

JSON (used when the server's decision depends on `signals`, or when snapshots are off):

```json
POST https://api.lifeassisto.com/api/v1/shop/ingest
{"site_token": "<enrollment token>", "type": "motion", "at": 1792524217.66,
 "signals": {"detector": "motion_only", "zone_breach": true, "motion_in_zone": true}}
```

Multipart (with the one snapshot):

```
site_token=<enrollment token>      (or camera_token=<camera token>)
type=after_hours
at=1792524217.6635048
signals={"after_hours":true,"detector":"yolox_nano","multiple_frames":true}
snapshot=<snapshot.jpg, image/jpeg, ~9-150 KB>
```

`snapshot_mode` in `config.json` takes one of these values:

* `auto` (default): JSON for `motion` (its raise depends on `zone_breach`);
  multipart with the snapshot for `after_hours` and `hand_in_cash_zone`.
* `always`
* `never`: privacy mode, no images at all.

## Honest limits

* **Not a hand detector.** The model detects *people*. "Hand in cash zone"
  means a person's box overlaps the drawn zone while there is movement inside
  it. A cashier working normally will trigger it. The server clears the event
  only if a POS sale or drawer-open is posted within ±45 s. Shops without a
  POS feed will see these as "please check" prompts.
* **Signals are dropped in multipart today.** The server reads `signals` only
  when it is a dict, and in a multipart upload it arrives as a string. The
  edge works around this with `snapshot_mode=auto`. See "Server gaps" below.
* **The detector key counts toward confidence.** For `hand_in_cash_zone`,
  `shop_guard` adds +0.1 confidence for *every* truthy key in `signals`,
  including the `detector` metadata key the owner asked for.
* **CPU.** FFmpeg decodes every frame the camera sends. Use each camera's
  **sub-stream** (for example 640×360 at 10–15 fps). On a 4-core PC, 4
  sub-streams are comfortable; 4 main streams at 1080p/25 fps are not.
* **Image limits.** Night, IR, glare, crowded counters, a camera pointed at
  the light, or a very small zone all reduce accuracy. Lighting jumps are
  suppressed by design, so motion during the jump frame itself is not seen.
* **Late delivery.** Delayed (queued) events keep their original `at`. The
  server correlates `hand_in_cash_zone` with POS rows from the last ~50 s
  *at receive time*, so an event delivered late can miss a matching sale.
* **Uptime.** The PC must stay on and awake: disable sleep and set Windows
  Update active hours. Nothing is detected while the PC is off.
* **Unsupported types.** `drawer_open` and `pose_possible` are not emitted,
  because there is no drawer-state or pose model. `void/refund/discount
  spikes` and `eod_mismatch` are POS-side types.
* **Applying changes.** Config changes apply when monitoring is restarted.

## Server gaps (what a complete edge client still needs)

`shop_views.py` has no device endpoint for the following, so the client
**invents none of them**:

1. **Heartbeat:** for example `POST shop/heartbeat {site_token, cameras:[{id,
   status, last_frame_at}], detector, queued, version}`. The app could then
   show "Shop Box offline / camera X unreachable" instead of silence.
2. **Device config pull:** for example `GET shop/device/config` with a device
   token, returning cameras, `zone_config` and hours, so zones drawn in the
   app sync to the PC. Today `ShopCamera.zone_config` is set only at create
   time and there is no device read path.
3. **Device camera registration:** so the box can create/claim its
   `ShopCamera` rows (and their `camera_token`) instead of the owner copying
   tokens by hand.
4. **Parse `signals` in multipart:** in `ShopIngestView`, add
   `if isinstance(signals, str): signals = json.loads(signals)`, guarded.
   This lets signals and the snapshot travel together.
5. **Ignore metadata keys in `shop_guard`:** keys such as `detector`,
   `edge_version` and `score` should not count as corroboration.
6. **A pairing-check endpoint:** the empty-type probe works, but it is
   implicit.
7. **Per-device throttle scope:** so several shops behind one ISP NAT/CGNAT do
   not share the 30/min anonymous bucket.

## Usage

```
AssistoShopBox.exe                    config UI (Bangla/English)
AssistoShopBox.exe --run              headless monitoring (put a shortcut in shell:startup)
AssistoShopBoxCLI.exe --pair          enter the enrollment token (hidden input)
AssistoShopBoxCLI.exe --verify | --list | --test-camera ID | --fetch-model | --self-test
```

## Development

```
cd edge/shopbox
python -m venv .venv && .venv/bin/pip install -r requirements.txt -r requirements-dev.txt
python -m shopbox.model_fetch models/yolox_nano.onnx   # optional: verified download
SHOPBOX_MODEL=models/yolox_nano.onnx python -m pytest
python -m shopbox                                      # UI (needs tkinter)
```

CI (`.github/workflows/shopbox.yml`) runs pytest on Ubuntu and Windows. It then
downloads the verified model and builds `AssistoShopBox.spec` with PyInstaller.
The output is an onedir bundle with `AssistoShopBox.exe` (windowed) and
`AssistoShopBoxCLI.exe` (console). CI smoke-tests the frozen build with
`--self-test` and uploads `AssistoShopBox-windows-x64.zip`.
