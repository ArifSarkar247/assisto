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

## Call sounds (c2-calls) — no audio files, nothing copyrighted

| Sound | Origin |
|---|---|
| Incoming ringtone | The phone's OWN default ringtone (RingtoneManager TYPE_RINGTONE) or one the user picks from the phone's sounds. Assisto ships no ringtone file. |
| Ringback (caller "toot… toot…") | Generated in code (`app/lib/calls/tone_generator.dart`): a 425 Hz sine, 1 s on / 4 s off — a standard telephony cadence (ITU-T E.180 style), not a recording. |
| Busy / declined / ended tones | Generated in code: 425 Hz, 0.5/0.5 s ×4; 0.25/0.25 s ×3; two short pips. |
| "Assisto" signature ringtone (optional, OFF by default) | ORIGINAL melody written for Assisto on 2026-10-22 by the c2-calls agent (score in `ToneGenerator.signatureScore`: E5 G#5 B5 E6 · D6 B5 C#6 · E5 G#5 B5 E6 F#6), synthesised in code with a bell-like additive voice. Not derived from any existing tune. Installed on the phone as "Assisto.wav" (Android 10+) only when the user turns it on. |
| Message notification sound | The phone's default notification sound, or one the user picks from the phone's sounds. |


## Photo Studio — what p2-photo actually ships (22 Oct 2026)

| Purpose | Model / runtime / data | Source | Licence | Commercial OK? | Shipped how |
|---|---|---|---|---|---|
| AI restore & upscale (optional, small/old photos) | **Real-ESRGAN `realesr-general-x4v3`** blended 50/50 (DNI, Real-ESRGAN's own `--denoise_strength 0.5`) with **`realesr-general-wdn-x4v3`** | github.com/xinntao/Real-ESRGAN releases **v0.2.5.0**; sha256 x4v3 `8dc7edb9…6292`, wdn `1641f8c4…9dca` | **BSD-3-Clause** (repo LICENSE; the release ships no separate weight terms). Notice reproduced in the app licence page (`ps_enhance.dart` → LicenseRegistry) and `backend/core/photo_models/README.md` | **Yes** (BSD-3: keep the notice). *Note:* the authors trained on DIV2K/Flickr2K/OST, whose dataset pages say "academic research"; the weights themselves are released under BSD-3 — same position as every Real-ESRGAN commercial user; owner order names Real-ESRGAN as allowed. | Converted to ONNX by `tools/photo_model/convert_realesrgan.py` (numpy+onnx, no torch), served by OUR server (`/api/v1/photo-studio/model/…`, licence-gated manifest), downloaded once in the app, never in the APK. ~4.9 MB fp32. |
| On-device inference runtime | **ONNX Runtime Android 1.23.2** (`com.microsoft.onnxruntime:onnxruntime-android`) | Maven Central | **MIT** | Yes | Gradle dep (same version + guard as k1-wake → one runtime) |
| Face boxes + 8 landmarks (identity check, skin mask, AI face-lock) | **Google ML Kit Face Detection 16.1.7, bundled model** (`com.google.mlkit:face-detection`) | Google Maven | ML Kit Terms (Google APIs ToS) — free, commercial use allowed; AAR carries `third_party_licenses.txt` | Yes | Gradle dep; its startup `MlKitInitProvider` removed, `MlKit.initialize` on first use |
| Classical enhance (WB, levels, guided-filter denoise, CLAHE, skin smoothing, unsharp, vibrance) | our own code (`ps_classic.dart`) | — | ours | Yes | Dart isolate |
| Evaluation photos (20) | 10 official US-Congress portraits (US federal works, **public domain**) + 10 **CC0** photos | Wikimedia Commons (per-file links in `.phaseB/photo_studio_eval/sources.json`) | PD / CC0 | Yes (thumbnails only in the repo) | not shipped |
| Haar face cascade (evaluation only, stands in for ML Kit on the desktop) | OpenCV `haarcascade_frontalface_default.xml` | opencv-python-headless 4.10 | Intel/OpenCV licence (BSD-style) / Apache-2.0 | Yes | not shipped |

Still NOT used: GFPGAN (weights/deps unclear, see above), CodeFormer (non-commercial), any
face-restoration model. **Face-embedding re-check (22 Oct 2026):** InsightFace packs —
non-commercial; OpenCV-Zoo SFace — Apache-2.0 files but training data undisclosed;
**fal AuraFace-v1** — Apache-2.0, card says trained on a *commercially licensed* face dataset
(the cleanest found) — but it is a ResNet-100 ArcFace (~250 MB ONNX, heavy per face), not
practical as a phone download/on-device model; candidate for a future server-side check only.
So the identity check stays landmark geometry (ML Kit) + face-lock.
