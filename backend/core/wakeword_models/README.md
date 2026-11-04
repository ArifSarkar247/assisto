# On-device "Hey Assisto" wake-word model (k1-wake / wakeword)

Installed 4 Nov 2026 from CI run 39903513961 (artifact `wakeword-model-16`, ww3 round 2,
candidate `reg_h128_lowneg_ensemble`). Files are served by `GET /api/v1/voice/wake-model/<name>`
and checked by sha256 on the phone. Licence: `licence_cleared: true` (Google speech_embedding,
Apache-2.0; training data in `licences.json`).

Release decision (wakeword agent, owner rule "decide recommended yourself", reversible by
deleting `manifest.json` → the app hides the card again):
- `ship_ready` in the CI manifest is `false` because at **Normal** sensitivity TV-like Bangla
  gave 3 false wakes / 10 h (target < 1).
- The app therefore defaults to **Low** sensitivity (strictest): measured 0 false wakes in
  10 h plain Bangla, 1 / 10 h TV-like Bangla + music, 0 in 3.5 h English; misses 12.8 % at
  1–2 m and 8.4 % close up (synthetic voices — confirm on real phones).
- A false wake costs one beep + the listening sheet; nothing runs without the confirm card.

Retrain: `tools/wakeword/README.md` (add real BD voices per `owner_actions/WAKEWORD_RECORDING_BN.md`).
