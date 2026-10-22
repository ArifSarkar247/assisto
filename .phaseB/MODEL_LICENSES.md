# Photo Studio — model & runtime licences (ps1-photo, 21 Oct 2026)

Rule (owner order): only models whose **code AND weights** allow commercial use.
Anything unclear is marked **NOT USED** until a human checks the licence text.
"Verified" below means the licence statement was read on the project's own
page/LICENSE on 21 Oct 2026; re-check before shipping a model update.

## USED / planned (commercial OK)

| Purpose | Model / runtime | Weights source | Licence | Commercial? | Size (approx.) |
|---|---|---|---|---|---|
| Upscale 2x/4x + deblur + denoise (hero one-tap enhance) | **Real-ESRGAN `realesr-general-x4v3`** (SRVGGNet compact) + `realesr-general-wdn-x4v3` (denoise-strength twin) | github.com/xinntao/Real-ESRGAN releases (v0.2.5.0) — we convert to TFLite fp16 and host the converted file ourselves | **BSD-3-Clause** (repo licence, verified) | **Yes** | ~4.9 MB each (.pth); TFLite fp16 ~2.5 MB |
| Higher-quality upscale on strong phones / cloud | Real-ESRGAN `RealESRGAN_x4plus` / `x2plus` | same releases | BSD-3-Clause | Yes | ~64 MB |
| Training framework of the above | BasicSR | github.com/XPixelGroup/BasicSR | Apache-2.0 | Yes | (not shipped) |
| On-device inference runtime | **TensorFlow Lite / LiteRT** (`tflite_flutter`) | Google | Apache-2.0 | Yes | ~2–4 MB native lib per ABI |
| (alternative runtime) | ONNX Runtime Mobile | Microsoft | MIT | Yes | ~5–8 MB |
| Face detection for FACE-LOCK | **Google ML Kit Face Detection** (bundled model) | Google (Maven `com.google.mlkit:face-detection`) | ML Kit Terms of Service (free, commercial use allowed) | Yes | ~1–2 MB bundled |
| Landmark geometry for IDENTITY GUARD | ML Kit face **contours** (same model) | Google | ML Kit ToS | Yes | (same) |
| Landmark geometry (alternative, 478 pts) | MediaPipe Face Landmarker (`face_landmarker.task`: BlazeFace + FaceMesh-V2) | storage.googleapis.com/mediapipe-models | Model cards state Apache-2.0 — **re-read the model-card PDFs before use** | Yes (pending that read) | ~3.6 MB |
| Low-light fix, auto-levels, crop/straighten, passport/visa sizing, document cleanup | **Classic algorithms** (gamma/CLAHE-style curves, colour matrix, deskew) — no ML model | our code | ours | Yes | 0 |
| Background blur/remove (on-device, optional) | MediaPipe Selfie/Image Segmenter | Google | Apache-2.0 per model card (re-read before use) | Yes (pending that read) | ~0.5–2.5 MB |

## NOT USED (non-commercial or unclear)

| Model | Why not |
|---|---|
| **CodeFormer** | S-Lab License 1.0 — **non-commercial only**. Never. |
| **GFPGAN** (v1.3 / v1.4) | Code is Apache-2.0, **but** the repo licence itself lists third-party parts under NVIDIA Source Code License (StyleGAN2 ops, "non-commercially … research or evaluation purposes only") and DFDNet (CC BY-NC-SA 4.0); the face-restoration weights are trained on FFHQ (CC BY-NC-SA 4.0 dataset). Its dependency **facexlib** (MIT code) downloads RetinaFace (from Pytorch_Retinaface, MIT) and a parsing net from face-parsing.PyTorch trained on **CelebAMask-HQ (non-commercial research only)**. Too unclear → NOT USED. |
| **InsightFace ArcFace / buffalo_l / antelopev2** (face embedding) | Code MIT, but pretrained models are "for non-commercial research purposes only"; buffalo_l needs a commercial licence from insightface (recognition-oss-pack@insightface.ai). NOT USED. |
| OpenCV-Zoo SFace / FaceNet ports / MobileFaceNet (face embedding) | Training datasets (CASIA-WebFace, VGGFace2, MS1M) are research-only / retracted; weight licences not clear → NOT USED. **Consequence:** the identity guard ships with landmark geometry only; the embedding slot (`FaceEmbedder`) stays unavailable until the owner licenses a commercial embedding model (e.g. buys the InsightFace commercial pack). |
| DeOldify (colorize) | MIT code; weights trained on ImageNet (non-commercial terms) — unclear → NOT USED. Colorize is cloud-only (provider) for now. |
| DDColor, BigColor (colorize) | weight licences unclear → NOT USED. |
| Microsoft "Bringing Old Photos Back to Life" (scratch restore) | Repo MIT; very large; its face-enhancement stage and training data need review → NOT USED yet (CANDIDATE). |
| LaMa (object removal / inpainting) | Apache-2.0 code; big-lama weights trained on Places2 (research-only dataset terms) → NOT USED. Object removal goes to the cloud provider. |
| Zero-DCE / Zero-DCE++ (low light) | no clear licence on weights → NOT USED; classic curves instead. |
| NAFNet / Restormer (deblur/denoise) | MIT/other code; weights trained on SIDD/GoPro/REDS — dataset terms vary → NOT USED; Real-ESRGAN general covers deblur/denoise. |

## Cloud providers (switchable in Integrations)

Gemini image editing, OpenAI images, Replicate-class. Their outputs are covered
by each provider's own commercial API terms (owner must accept them when
creating the key). On Replicate, **only** models whose page shows a commercial
licence may be configured (the integration guide says so).

---

# "Hey Assisto" wake word — licence register (k1-wake, 22 Oct 2026)

Commercial app ⇒ everything that goes INTO the shipped model or the APK must be commercially
usable. "Eval only" items never touch model weights or the app; they only measure false
accepts. Not legal advice — have it reviewed before launch.

## Ships in the app / on the server

| Item | Source | Licence | Commercial OK? | Notes |
|---|---|---|---|---|
| openWakeWord **code / recipe** | github.com/dscripka/openWakeWord | Apache-2.0 | **Yes** | We re-implement the recipe (`tools/wakeword/`, `OwwEngine.kt`); no openWakeWord code ships in the APK. |
| openWakeWord **pre-trained wake-word models** (alexa, hey_jarvis, …) | release assets | CC BY-NC-SA 4.0 (README: "due to the inclusion of datasets with unknown or restrictive licensing") | **NO** | Not used. We train our own "Hey Assisto" model. |
| openWakeWord **feature models** `melspectrogram.onnx`, `embedding_model.onnx` (v0.5.1) | release assets | **Not stated separately.** README: embedding = re-implementation of Google's Apache-2.0 speech_embedding; mel = fixed-parameter function; but the blanket "included pre-trained models are CC BY-NC-SA" sentence may cover them | **UNCONFIRMED** | Not shipped by default. Backend `oww` is only a fallback; it packages `licence_cleared: false`, which the server refuses to serve. To use it: written confirmation from the maintainer (GitHub issue), then `oww_feature_licence_confirmed: true`. Used locally ONLY for the Kotlin parity test (no distribution). |
| Google **speech_embedding** (TF-Hub / Kaggle Models v1) | tfhub.dev/google/speech_embedding/1 | Apache-2.0 | **Yes** | DEFAULT extractor: `rebuild_features.py` converts the original module to ONNX in CI (`assisto_embed_e2e.onnx`). Keep the Apache-2.0 notice in the app's open-source licences page. |
| Our classifier `assisto_wake.onnx` | `.github/workflows/wakeword-train.yml` | ours | Yes, if all training inputs below are OK | |
| **ONNX Runtime Android** `com.microsoft.onnxruntime:onnxruntime-android:1.23.2` | Maven Central | MIT (pom) | **Yes** | arm64 libs 16 KB-page aligned (readelf: LOAD align 0x4000). Add to open-source licences page. |

## Training inputs (go into the classifier weights)

| Item | Source | Licence | Commercial OK? | Used? |
|---|---|---|---|---|
| **Kokoro-82M v1.0** TTS (US/UK English + Hindi voices, voice blends) | huggingface.co/hexgrad/Kokoro-82M | Apache-2.0 (card: trained only on permissive / non-copyrighted audio) | **Yes** | Yes — positives + near-miss negatives |
| `kokoro`, `misaki` packages | PyPI | Apache-2.0 | Yes | CI only |
| **eSpeak NG** (Bangla, Hindi, English accents) | apt `espeak-ng` | GPL-3.0 (program) | **Yes** for our use | Only RUN in CI; generated audio is program output. Nothing ships. |
| Piper `bn_BD-google-medium`, `en_US-libritts_r-medium`, `en_GB-vctk-medium` | rhasspy/piper-voices | datasets CC BY-SA 4.0 / CC BY 4.0, **but fine-tuned from "lessac"**, whose Blizzard-2013 data is **non-commercial only** | **UNCERTAIN → not used** | OFF by default (`tts.piper=false`); turning it on makes the package `licence_cleared: false`. |
| Piper `en_US-l2arctic-medium` (non-native accents) | same | L2-ARCTIC CC BY-NC 4.0 | **NO** | Never. |
| Piper `hi_IN-*` | same | CC BY-NC-SA 4.0 (card) | **NO** | Never. |
| Meta MMS-TTS Bengali | HF | CC BY-NC 4.0 | **NO** | Never. |
| **FLEURS** Bengali (bn_in) train/dev | HF google/fleurs | CC BY 4.0 | **Yes** (attribution) | Bangla speech negatives / validation |
| **LibriSpeech** dev-clean | openslr.org/12 | CC BY 4.0 | **Yes** (attribution) | English negatives |
| **MUSAN** music + noise | openslr.org/17 | CC BY 4.0 (corpus) + per-file LICENSE lines | **Yes** after filter | `musan_split` drops every file whose LICENSE line says NonCommercial / NoDerivatives and reports the count. |
| Room impulse responses | generated (`audio.synthetic_rir`) | ours | Yes | no RIR dataset |
| openWakeWord ACAV100M pre-computed features | HF davidscripka | non-commercial / unclear | **NO** | Never (the reason openWakeWord's own models are NC). |
| Real recordings (`real_positive_dir`) | owner's volunteers | written consent | Yes with consent | Optional; never committed. |

## Evaluation only (never in the weights)

| Item | Source | Licence | Notes |
|---|---|---|---|
| OpenSLR 53 Large Bengali ASR, shard `asr_bengali_0` (~13 h, 10 h used) | openslr.org/53 | CC BY-SA 4.0 | Bangla background for "false accepts / 10 h". |
| LibriSpeech test-clean | openslr.org/12 | CC BY 4.0 | English background. |
| MUSAN held-out 15 % | openslr.org/17 | CC BY 4.0 | TV-like mixes. |

Build tools (CI only, nothing shipped): TensorFlow-CPU 2.15 / tf-keras / tensorflow-hub,
tf2onnx, onnx (Apache-2.0); onnxruntime (MIT); numpy / scipy / soundfile / PyTorch (BSD-3;
libsndfile LGPL-2.1 dynamically linked).
