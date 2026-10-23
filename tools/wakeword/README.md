# "Hey Assisto" wake-word training (k1-wake)

On-device wake word on the openWakeWord recipe with **our own** model. Training runs **only**
in GitHub Actions (`.github/workflows/wakeword-train.yml`, manual). Never train on the Assisto
server — it is a 2-CPU box that also runs the live backend.

## Run it (integrator)
1. Push the branch, then GitHub → Actions → **Wake word train (Hey Assisto)** → *Run workflow*.
   - First try `tiny = true` (~3 min): checks the plumbing; its model is never shippable.
   - Then the real run: `features = e2e`, `steps = 20000`, `seeds = 1234,2025,7` (cold: downloads
     + TTS + embeddings of ~95 h audio, then 3 seeds; warm embeddings cache: no downloads, only
     training + evaluation). `stage = data` only fills the caches.
2. Download the artifact `wakeword-model-<run>` and read `eval_report.md` (the real measured
   false accepts / 10 h and false-reject rates). The job summary shows the same table.
3. If `manifest.json` says `"ship_ready": true` (= licence cleared **and**, on the TEST sets,
   < 1 false accept / 10 h on plain Bangla (eval_bn, 10 h) **and** on TV-like Bangla + music
   (eval_tv, 10 h), far-field false rejects < 10 %, ≥ 20 h of test negatives), copy
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

## What a run does (ww3)
- **Data**: train negatives = FLEURS bn + hi, LibriSpeech, MUSAN speech/music/noise, TV-like mixes
  (speech + music/noise at 0–20 dB SNR, TV-speaker colouring, OpenSLR-26 simulated rooms) and TTS
  near-miss phrases. Validation (thresholds, checkpoint choice) = FLEURS bn dev raw + TV-mixed,
  MUSAN-speech val TV mix, held-out TTS near-misses. **Test (never used for any choice)** = OpenSLR-53
  shard 0 (10 h plain Bangla), shard 1 TV-mixed (10 h), LibriSpeech test (2 h), MUSAN-speech TV mix.
- **Embeddings** are computed once (exactly the phone's streaming extractor, 4 processes in
  parallel) and cached (`ww-emb-v3-<key>`), so extra seeds/steps cost minutes.
- **Training** per seed: cosine LR + warm-up, EMA weights, 3 rounds of hard-negative mining over
  the whole negative pool, checkpoint chosen on validation recall at the validation FA target.
- **Candidates**: every seed and the seed ensemble; thresholds per candidate on validation (logit
  space, no ceiling; a temperature keeps phone thresholds ≈ 0.95). The shipped candidate is chosen
  on validation; the report shows every candidate and the seed variance.
- **Classifier contract unchanged** ([N,16,96] → [N,1]); in-graph 2-position smoothing means the
  phrase must score high at two consecutive 80 ms positions (the app's decider code is untouched).

## Layout
- `pipeline.py` — stages features → synth → prepare → windows → train → evaluate → package.
- `rebuild_features.py` — Google speech_embedding (Apache-2.0) → ONNX (CI, own TF venv).
- `ww/features.py` — streaming extractor = the phone's algorithm (`OwwEngine.kt`).
- `ww/detector.py` — threshold + patience + cooldown (= `OwwEngine.kt` `WakeDecider` and
  `app/lib/voice/va_wake_logic.dart`).
- `ww/embed.py` — parallel, bit-exact embedding extraction (streams, clip windows, FRR clips).
- `ww/model.py` — member net, training (mining/EMA/selection), `Scorer` (ensemble + smoothing +
  temperature) and its ONNX export.
- `ww/synth.py`, `ww/datasets.py` — commercially usable TTS / audio only (see
  `.phaseB/MODEL_LICENSES.md`).
- `MODEL_CARD.md` — appended with the build's thresholds + licence status on package.

Real recordings (optional, improves Bangla accents + gives REAL false-reject numbers): see
`owner_actions/WAKEWORD_RECORDING_BN.md` (layout `real_clips/pos/<speaker>/<condition>/*.wav`,
`real_clips/neg/<speaker>/*.wav`; speakers split train/test). In CI: secret `WW_REAL_CLIPS_URL`
(+ `WW_REAL_CLIPS_SHA256`) and `real_clips = true`. Never committed, cached or uploaded
(`tools/wakeword/real_clips/` is gitignored).
