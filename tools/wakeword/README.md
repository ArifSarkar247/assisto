# "Hey Assisto" wake-word training (k1-wake)

On-device wake word on the openWakeWord recipe with **our own** model. Training runs **only**
in GitHub Actions (`.github/workflows/wakeword-train.yml`, manual). Never train on the Assisto
server — it is a 2-CPU box that also runs the live backend.

## Run it (integrator)
1. Push the branch, then GitHub → Actions → **Wake word train (Hey Assisto)** → *Run workflow*.
   - First try `tiny = true` (~3 min): checks the plumbing; its model is never shippable.
   - Then the real run: `features = e2e`, `steps = 6000`, `n_pos_train = 6000` (≈ 70 min cold,
     ≈ 45 min with warm caches; `stage = data` only fills the caches).
2. Download the artifact `wakeword-model-<run>` and read `eval_report.md` (the real measured
   false accepts / 10 h and false-reject rates). The job summary shows the same table.
3. If `manifest.json` says `"ship_ready": true` (= licence cleared **and** the Bangla false-accept + far-field false-reject targets met), copy
   `manifest.json`, `assisto_wake.onnx`, `assisto_embed_e2e.onnx`, `MODEL_CARD.md`,
   `eval_report.md` into `backend/core/wakeword_models/`, commit, deploy. The app then shows
   "Hey Assisto" as available (GET /api/v1/voice/config → `available: true`).
4. If the `e2e` rebuild step fails, the fallback `features = oww` trains fine but produces
   `licence_cleared: false` (openWakeWord's feature files have no confirmed commercial licence);
   the server will then refuse to serve it (`reason: licence_pending`).

## Local (tiny smoke only)
```
python3 -m venv /tmp/wwenv && /tmp/wwenv/bin/pip install numpy scipy onnx onnxruntime soundfile
HEAVY_TIMEOUT=1200 ~/assisto/bin/heavy.sh nice -n 15 /tmp/wwenv/bin/python -m unittest discover -s tools/wakeword/tests
```

## Layout
- `pipeline.py` — stages features → synth → prepare → windows → train → evaluate → package.
- `rebuild_features.py` — Google speech_embedding (Apache-2.0) → ONNX (CI, own TF venv).
- `ww/features.py` — streaming extractor = the phone's algorithm (`OwwEngine.kt`).
- `ww/detector.py` — threshold + patience + cooldown (= `OwwEngine.kt` `WakeDecider` and
  `app/lib/voice/va_wake_logic.dart`).
- `ww/synth.py`, `ww/datasets.py` — commercially usable TTS / audio only (see
  `.phaseB/MODEL_LICENSES.md`).
- `MODEL_CARD.md` — appended with the build's thresholds + licence status on package.

Real recordings (optional, improves Bangla accents): put 16 kHz wavs of real people saying
"Hey Assisto" (with their written consent) in a folder and set `real_positive_dir`. Never
commit them.
