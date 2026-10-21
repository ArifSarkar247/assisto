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
