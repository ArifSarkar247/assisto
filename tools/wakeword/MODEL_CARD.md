# Model card — "Hey Assisto" wake word (assisto_wake.onnx)

**What it does.** Detects the phrase "Hey Assisto" (also "Hi Assisto" / "Ok Assisto") in a
continuous 16 kHz microphone stream, on the phone. Output: one probability every 80 ms.
Nothing is recorded or uploaded; the app only acts after a detection.

**Architecture.** openWakeWord-style: a frozen speech-embedding extractor (one 96-d
embedding per 80 ms) + a small classifier (16 embeddings = 1.28 s → Dense 64 → Dense 64 →
sigmoid, ~100k parameters, ~0.4 MB). Decision = threshold + patience (Low: 2 frames in a row)
+ 2 s cooldown. Feature extractor: either Google `speech_embedding` (Apache-2.0, rebuilt to
ONNX by `rebuild_features.py`, backend `e2e`, the default) or openWakeWord's split
mel+embedding ONNX files (backend `oww`, licence unconfirmed → not served).

**Training data (all synthetic or commercially licensed — see `.phaseB/MODEL_LICENSES.md`).**
Positives: Kokoro-82M (Apache-2.0) US/UK English + Hindi voices and voice blends, eSpeak NG
Bangla / Hindi / several English accents, × speed, pitch, gain, synthetic rooms (0.3–3 m) and
noise (0–20 dB SNR). Negatives: near-miss phrases from the same TTS ("Hey assistant",
"Hey Siri", "হেই আসিফ", …), FLEURS Bengali (CC BY 4.0), LibriSpeech (CC BY 4.0), MUSAN
music/noise with NC/ND files removed (CC BY 4.0), and TV-like mixes of these.

**Evaluation (measured by the CI run; see `eval_report.md` of each build).** False accepts per
hour on held-out Bangla speech (OpenSLR 53 shard, CC BY-SA 4.0, eval only), TV-like Bangla +
music mixes and English speech; false rejects on held-out synthetic speakers at a simulated
1–2 m with 5–15 dB noise. Targets: < 1 false accept / 10 h Bangla background; < 10 % false
rejects at 1–2 m. Synthetic far-field numbers are NOT a substitute for the real-phone test.

**Known limits.** No native-Bangla commercial TTS voice with clean licence lineage was found,
so the "Bangla accent" comes from eSpeak NG's Bangla voice and Hindi Kokoro voices; real
recordings from Bangladeshi speakers (`real_positive_dir`) will improve it. Children's and
very elderly voices are under-represented. Whispered speech is weakly covered.

**Intended use.** Opt-in hands-free start of Assisto Voice on the user's own phone.
