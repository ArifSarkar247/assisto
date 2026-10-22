# Python ⇄ Kotlin parity check (k1-wake)

Proves the phone's `OwwEngine.kt` produces the same scores as the training/evaluation code
(`ww/features.py` + `ww/evaluate.py`), so the CI numbers are the phone's numbers.
Run on a dev machine (JVM ONNX Runtime jar `com.microsoft.onnxruntime:onnxruntime:1.23.2`,
kotlinc 2.1). `make_fixture.py <work>` builds a tiny model + 10 s audio + `expected.txt`;
compile `ParityMain.kt` with `app/android_overlay/.../voice/OwwEngine.kt` and compare.

Result 2026-10-22 (k1-wake): e2e backend max |Δscore| = 1.3e-7 over 109 frames;
oww backend (openWakeWord v0.5.1 feature files, used only for this test) max |Δscore| = 7.3e-5
over 101 frames. Audio was fed in irregular chunk sizes (77…3000 samples).
