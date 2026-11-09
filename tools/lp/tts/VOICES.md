# Listening audio voices — licences (checked 9 Nov 2026)

> বাংলায়: লিসেনিং অডিও বানানো হয় শুধু GitHub Actions-এ, ওপেন-সোর্স TTS দিয়ে। কারও কণ্ঠ নকল (voice cloning) করা হয় না। নিচে প্রতিটি ভয়েসের লাইসেন্স লেখা আছে।

| Accent | Engine | Voices | Licence | Notes |
|---|---|---|---|---|
| British (GB) | **Kokoro-82M** v1.0 (`kokoro==0.9.4`, `misaki[en]==0.9.4`), weights `hexgrad/Kokoro-82M` | narrator `bm_george`; `bf_emma`, `bf_isabella`, `bf_lily`, `bm_fable`, `bm_lewis`, `bm_daniel` | **Apache-2.0** (model + voice packs) | Voices are synthetic style vectors shipped with the model, not recordings of a named person. Already cleared for CI use in `.phaseB/MODEL_LICENSES.md`. |
| American (US) | Kokoro-82M | `af_heart`, `af_bella`, `af_nicole`, `af_sarah`, `am_michael`, `am_fenrir`, `am_puck` | **Apache-2.0** | same |
| Australian (AU) | **MeloTTS** English (`myshell-ai/MeloTTS`, commit `209145371cff8fc3bd60d7be902ea69cbdb7965a`; weights `myshell-ai/MeloTTS-English`) | speaker `EN-AU` | **MIT** (code + weights, per model card) | Only one Australian voice exists, so a part has at most one AU speaker (lpcheck enforces). If the voice's measured pitch does not match the script's gender, `assemble.py` applies a mild pitch shift and records it in the manifest. If MeloTTS fails to install, AU lines fall back to a Kokoro GB voice and the manifest says `accent_substituted: true` (honest label, never hidden). |
| G2P fallback | eSpeak NG (apt) | — | GPL-3.0 (program only run in CI) | Generated audio is program output; nothing of eSpeak ships. |

**Not used** (and why): Piper `en_GB-vctk`, `en_US-libritts_r` and other medium voices — fine-tuned from the
`lessac` voice whose Blizzard-2013 data is non-commercial (see `.phaseB/MODEL_LICENSES.md`); Piper
`en_US-l2arctic` (CC BY-NC); Coqui XTTS (CPML, non-commercial + cloning model); any voice-cloning model.

**Where the audio goes:** CI artifact `lp-audio-<run>` (mp3, 64 kbps mono, 24 kHz, loudness −18 LUFS) +
`audio_manifest.json` (sha256, bytes, duration, voices + licences per file, cue times per question range) and
`lp_bundle/` (lpcore import dir, `manage.py lp_import`). Audio is never committed to git.
