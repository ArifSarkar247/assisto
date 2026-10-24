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

## Wake word feature extractor — rebuild check (agent/ww2, 22 Oct 2026)

| Item | Source | Licence (how confirmed) | Commercial OK? | Notes |
|---|---|---|---|---|
| Google **speech_embedding** v1 (TF1 Hub module, 2.8 MB) | tfhub.dev/google/speech_embedding/1 → Kaggle Models `google/speech-embedding` (TensorFlow1 instance) | **Apache-2.0** — Kaggle Models API `GET /api/v1/models/google/speech-embedding/get` returns `"licenseName": "Apache 2.0"` for the TensorFlow1 instance; fetched by `rebuild_features.py` in CI at every build and stored verbatim in `e2e_info.json → licence_check` (the step fails if the field is not Apache) | **Yes** (keep the Apache-2.0 notice) | Rebuilt as `assisto_embed_e2e.onnx`: our own ONNX log-mel front end (parameters read from the module graph) + the module's frozen conv net (weights unchanged). A derived work of Apache-2.0 weights → ship with the Apache-2.0 notice + "modified: converted to ONNX". |
| eSpeak NG (also a training TTS voice — see the k1-wake register) | Ubuntu package | GPL-3.0 (program); its audio output is not covered by the GPL | Yes for generated audio; the program is never shipped | Here only generates verification speech for the conversion check |
| tensorflow-cpu 2.15.1, tf2onnx 1.16.1 (build tools only) | PyPI | Apache-2.0 | Yes | not shipped |

## Wake word training data added by agent/ww3 (23 Oct 2026)

Rule unchanged: Apache-2.0 / MIT / BSD / CC-BY / CC0 / public domain only; NC, ND or unclear = not used.
Every source below is also listed in `tools/wakeword/ww/datasets.py → SOURCES` and copied into each
build's `licences.json`.

| Source | What / used for | Licence (how confirmed) | Commercial OK? |
|---|---|---|---|
| **OpenSLR 26** `sim_rir_16k.zip` — simulated room impulse responses (Ko et al., ICASSP 2017) | room/reverb augmentation; rooms split 80/10/10 into train / validation / test | **Apache-2.0** — stated on openslr.org/26 (read 23 Oct 2026). Image-method simulations, no third-party recordings | **Yes** |
| OpenSLR 28 `rirs_noises.zip` | **NOT USED** — its *real* RIRs come from RWCP / REVERB / Aachen AIR, whose own terms are not restated on the page; we take only the simulated set (SLR 26) | Apache-2.0 on the page, but third-party lineage unclear | not used |
| **FLEURS hi_in** (train split) | Hindi read speech — "Hindi serial on the TV" negatives, raw + TV-mixed | **CC BY 4.0** (same dataset card as FLEURS bn_in) | **Yes** |
| **MUSAN speech** (LibriVox + US-government recordings, same archive as MUSAN music/noise) | broadcast-style English speech: train negatives, TV-like mixes, noise under positives ("TV on"), held-out val/test parts | MUSAN corpus CC BY 4.0; the speech files are **public domain** per MUSAN's per-folder LICENSE files; the NC/ND filter is applied to them like music/noise | **Yes** |
| **OpenSLR 53 shard 1** (`asr_bengali_1.zip`) | speech of the 10 h **TV-like Bangla test set** (mixed with MUSAN *test* music/noise + test rooms) — **evaluation only**, never training | **CC BY-SA 4.0** (openslr.org/53); used only to measure false accepts, not in model weights | Yes (eval only) |
| More TTS near-miss phrases ("হেই", "এসিস্ট", "হে আসিফ", "assist", "assistance", "hey assistant", …) | hard negatives | same engines as before: Kokoro-82M (Apache-2.0), eSpeak NG output | **Yes** |
| Real voice recordings (`owner_actions/WAKEWORD_RECORDING_BN.md`) | optional; only with each speaker's written consent; never committed, cached or uploaded | consent-based, owner-held | Yes (with consent) |

Model contract unchanged: `assisto_embed_e2e.onnx` ([1, 12400] → 96-d, Google speech_embedding,
Apache-2.0) + `assisto_wake.onnx` ([N, 16, 96] → [N, 1]). The ww3 classifier graph may contain a seed
ensemble, a 2-position min ("in-graph smoothing") and a temperature — all plain ONNX ops (Slice, Reshape,
Sub, Div, Gemm, Relu, Sum, Mul, Min, Sigmoid; opset 13), checked in CI with ONNX Runtime 1.23.2.

## Photo Studio — d1-photo re-check and additions (23 Oct 2026)

Licence texts re-read on 23 Oct 2026 (repo LICENSE files fetched from GitHub; Hugging Face
model cards via the HF API `cardData.license`). "Commercial OK" = code AND weights allow it.

| Purpose | Model | Code licence | Weights licence / source | Training data note | Commercial OK? | Where it runs |
|---|---|---|---|---|---|---|
| Upscale 2x/4x, AI enhance, old-photo detail | Real-ESRGAN `realesr-general-x4v3` (+ wdn, DNI 0.5) | BSD-3-Clause | BSD-3 (official release v0.2.5.0, sha256 pinned) | DIV2K/Flickr2K/OST (academic datasets) | **Yes** (unchanged from p2) | phone (ONNX, downloaded once) + server (old-photo restore) |
| Background blur mask | **U²-Net-p** (`u2netp`, 4.6 MB) | **Apache-2.0** (github.com/xuebinqin/U-2-Net LICENSE, read 23 Oct) | released by the authors with the repo (Apache-2.0); ONNX export from the rembg project release v0.0.0 (rembg = MIT), sha256 `309c8469…ddd8` pinned in `tools/photo_model/install_d1_models.py` | DUTS-TR (research dataset) — same position as Real-ESRGAN | **Yes** (keep the Apache notice — added to the app licence page) | phone (ONNX, downloaded on first blur) |
| Colorize B&W, old-photo colour | **DDColor-tiny** (`ddcolor_paper_tiny`, ConvNeXt-T) | **Apache-2.0** (github.com/piddnad/DDColor LICENSE, commit 2adb63f2) | **Apache-2.0** (HF `piddnad/ddcolor_paper_tiny` model card, read 23 Oct) | ImageNet (the image collection's own terms are research-only; the authors release the weights under Apache-2.0 — same position as every ImageNet-pretrained model) | **Yes** (keep the notice; owner may re-confirm) | **server only** (ONNX ~270 MB, never sent to phones) |
| Deblur | **NAFNet** (megvii-research) | **MIT** (LICENSE read 23 Oct) | released with the repo (MIT); trained on GoPro (CC BY 4.0) / REDS | — | **Yes** | **pay-per-use GPU API** (Replicate model `megvii-research/nafnet`) behind the Admin key `photo_restore_gpu` — hidden until connected and priced. We never host these weights. Replicate's own API terms apply to the call. |
| (considered) super-resolution | SwinIR | Apache-2.0 (LICENSE read 23 Oct) | released with the repo | DIV2K/Flickr2K | Yes | **not used**: far slower than Real-ESRGAN compact on CPU/phone for the same job |
| Face restoration | GFPGAN v1.3/1.4 | Apache-2.0 code, BUT the repo LICENSE itself carries the **NVIDIA Source Code License** for StyleGAN2 parts (non-commercial, line 88+ of LICENSE, re-read 23 Oct) and the weights build on an FFHQ-trained StyleGAN2 prior (FFHQ = CC BY-NC-SA 4.0) | — | — | **NO — NOT USED** | — |
| Face restoration | CodeFormer | S-Lab License 1.0 (non-commercial) | — | — | **NO — never** | — |
| Face restoration | any other (RestoreFormer, VQFR, DiffBIR face …) | various | all trained on FFHQ / CelebA (non-commercial datasets) or unclear | — | **not cleared** | **Face restoration is therefore NOT offered** in Photo Studio (the app tells the owner why; users simply don't see it). Faces are protected instead: face-lock (25 % of AI detail inside face ellipses) + the on-device identity check on every result. |
| Low light, denoise | our classical code (`ps_classic.dart` presets `lowLightTool`, `denoiseTool`) | ours | — | — | Yes | phone |
| Old-photo scratch/dust cleanup, fade fix | our code (`core/photo_restore.py`: adaptive median defect mask, levels) | ours | — | — | Yes | server |
| Server inference runtime | ONNX Runtime 1.19.2 (Python) | MIT | — | — | Yes | server (pip, backend venv) |
| Evaluation photos (20) | 10 US-Congress portraits (public domain) + 10 CC0 photos, Wikimedia Commons (`.phaseB/photo_studio_eval/sources.json`) | — | — | — | Yes (only small contact sheets in the repo) | not shipped |

## Photo Studio v2 (owner order 6) — FACE LOCK + worker models (23 Oct 2026)

| Purpose | Model | Licence (how checked, 23 Oct 2026) | Commercial OK? | Where |
|---|---|---|---|---|
| Face detection + 5 landmarks (FACE LOCK, face detail pass) | **YuNet** `face_detection_yunet_2023mar.onnx` (OpenCV Zoo, 230 KB, sha256 `8f2383e4…2fa4`) | **MIT** (opencv_zoo/models/face_detection_yunet/LICENSE, Copyright (c) 2020 Shiqi Yu) | **Yes** | photo worker (server) |
| Face IDENTITY score (FACE LOCK) | **AuraFace-v1** `glintr100.onnx` (fal.ai, ResNet-100 ArcFace-style, 260 MB, sha256 `a7933ea5…5c60`) | **Apache-2.0** (HF card + LICENSE.md); README: "trained on commercially and publicly available data sources to enable its usage in commercial setting" | **Yes** | photo worker (server) |
| (NOT used, same HF repo) | `scrfd_10g_bnkps.onnx`, `2d106det.onnx`, `genderage.onnx`, `1k3d68.onnx` in fal/AuraFace-v1 | byte-identical (same sha256 as the copies in public antelopev2 mirrors) to **InsightFace** models = **non-commercial** | **NO** — never downloaded (install.sh fetches glintr100.onnx only) | — |
| (NOT used) | InsightFace antelopev2 / buffalo_l (incl. its own `glintr100.onnx`, sha256 `4ab1d643…4cdf`) | non-commercial research only | **NO** | — |
| Seamless paste-back of the original face | OpenCV `seamlessClone` (Poisson blending) | Apache-2.0 (opencv-python-headless 4.10) | Yes | photo worker |
| Face RESTORATION (GAN face prior) | GFPGAN / CodeFormer / RestoreFormer … | see above: NVIDIA NC parts / S-Lab NC / FFHQ-NC training data | **NO** | **not offered**. Best clean alternative shipped: a *face detail pass* = Real-ESRGAN (BSD-3) on the face crop at native resolution, luminance only, then FACE LOCK. Honest consequence: faces get crisper but not "re-imagined" like Remini's. |
| Premium HD fast path (optional) | Real-ESRGAN on Replicate (`face_enhance=false` — GFPGAN is never requested) | BSD-3 model; Replicate API terms | Yes | GPU API, key-gated (`photo_restore_gpu.enhance_version`) |
| Prompt edit (“Nano Banana” / GPT Image / Flux) | Google Gemini image models, OpenAI GPT Image, Replicate-hosted models (e.g. FLUX Kontext **[pro]** only — FLUX [dev] weights are non-commercial) | provider API terms (owner accepts them when adding the key) | Yes via the paid API | cloud, key-gated, switchable in Owner Admin (`photo_studio.provider`); every result goes through FACE LOCK on the worker |

## G1 — Business AI Agent: matching a customer's photo to the catalog

| Option | Licence (weights) | Decision |
|---|---|---|
| **Perceptual hash + colour histogram** (average hash 8×8, difference hash 9×8, 64-bin RGB histogram; our own code on Pillow, `core/bizagent_media.py`) | no model weights at all | **USED** — runs on our CPU, cost 0; matches a re-sent product photo or a phone screenshot of the post (white/black bars trimmed) |
| Cloud vision (Claude / OpenAI / Gemini — the existing "image in chat" adapters) | provider terms (commercial API) | **USED, key-gated** — only when the hash is not sure; charged `ai_sales_vision` credits; describes + reads text; the price always comes from the catalog in code |
| OpenAI CLIP ViT-B/32 | code + weights MIT, but the model card puts deployed use out of scope | not used |
| Google SigLIP base (patch16-224) | Apache-2.0 | candidate for later (needs onnxruntime on the server, ~200M params — not installed, not shipped) |
| Apple MobileCLIP | Apple ML research licence (non-commercial) | **never** |
| OpenCLIP LAION-2B checkpoints | MIT weights, LAION data-provenance concerns | not used |


## Photo Studio FINAL — face restoration licence check (photo-final, 24 Oct 2026)

Owner asked for "GFPGAN v1.4 (Apache-2.0)". Checked from primary sources on 24 Oct 2026. This is a
summary of licence texts, **not legal advice**.

### GFPGAN v1.4 — verdict: NOT clearly commercial-OK → shipped **switchable, OFF by default**

| Part | Source | What it says |
|---|---|---|
| Code | https://raw.githubusercontent.com/TencentARC/GFPGAN/master/LICENSE | "GFPGAN is licensed under the Apache License Version 2.0 **except for the third-party components listed below**." |
| StyleGAN2 CUDA ops (third-party, same file) | NVIDIA Source Code License | "may be used or intended for use **non-commercially**" — "research or evaluation purposes only". The *clean* v1.3/v1.4 architecture does not need these ops (README: "a clean version of GFPGAN, which does not require customized CUDA extensions"). |
| DFDNet part (same file) | CC BY-NC-SA 4.0 | non-commercial |
| v1.4 **weights** (`GFPGANv1.4.pth`, GitHub releases v1.3.0 / v1.3.4) | https://api.github.com/repos/TencentARC/GFPGAN/releases | **no licence statement for the weights at all**; README does not say the weights are Apache-2.0 |
| Training data | FFHQ — https://raw.githubusercontent.com/NVlabs/ffhq-dataset/master/README.md | dataset "made available under **Creative Commons BY-NC-SA 4.0**"; individual images CC BY 2.0 / **CC BY-NC 2.0** / PD — "allow free use … for **non-commercial** purposes" |
| facexlib (dependency, face parsing used for paste-back) | https://raw.githubusercontent.com/xinntao/facexlib/master/LICENSE + `facexlib/parsing/parsenet.py` | MIT code, but ParseNet is "Modified from PSFRGAN", whose LICENSE is **CC BY-NC-SA 4.0** |
| Replicate page tencentarc/gfpgan | https://replicate.com/tencentarc/gfpgan | **no licence shown**; ≈ $0.0032/run, L40S, ~4 s. Hosting on Replicate does **not** change the weights' licence. |

**Verdict:** code Apache-2.0 ✔, weights unlicensed + trained on a non-commercial dataset + NC
parsing net → **legally grey / risky for a paid app**. Many companies ship it anyway (whether
weights inherit the dataset licence is legally unsettled), but it is not clean.
**Implementation:** `photo_studio.face_restore_gfpgan = false` (Owner Admin → Ads/Pricing,
photo_studio block) + an empty "GFPGAN model version" field in Integrations →
`photo_enhance_replicate`. Only when the owner turns the switch on AND pastes a version does the
Replicate pipeline call GFPGAN (blend 55 % Natural / 70 % Strong, all faces, then FACE LOCK).
**Owner decision needed (legal).** Real-ESRGAN's own `face_enhance=true` = GFPGAN → never sent.

### Alternatives checked (24 Oct 2026)

| Model | Code licence (primary URL) | Weights / data | Verdict |
|---|---|---|---|
| CodeFormer | S-Lab License 1.0 (github.com/sczhou/CodeFormer LICENSE) "non-commercial purpose" | — | **NO** (owner-excluded, confirmed) |
| RestoreFormer / RestoreFormer++ | Apache-2.0 (wzhouxiff repos) | weights unlicensed; README: "trained with FFHQ" | grey (same as GFPGAN) |
| VQFR (TencentARC) | Apache-2.0 + permissive third-party | FFHQ | grey |
| DiffBIR | Apache-2.0 (XPixelGroup) | `v1_face.pth` "trained on FFHQ" + Stable Diffusion 2.1 base | grey |
| DifFace, PGDiff | S-Lab License 1.0 | — | **NO** |
| DMDNet | CC BY-NC-SA 4.0; CelebRef-HQ "non-commercial research only" | — | **NO** |
| GPEN (Alibaba/yangxy) | no LICENSE file (404) → all rights reserved; README: model taken down "due to commercial issues" | — | **NO** |
| FaceFusion model pack | OpenRAIL-AS app licence; HF pack only re-packages gfpgan/codeformer/gpen/restoreformer ONNX | inherits each original | no new clean option |
| Real-ESRGAN (general SR) | BSD-3-Clause | weights released with the repo | **YES** (unchanged) |
| U²-Net-p (portrait-blur mask) | Apache-2.0 (github.com/xuebinqin/U-2-Net LICENSE, re-read 24 Oct) | released with the repo | **YES** (already shipped) |
| MediaPipe Selfie Segmentation | model card PDF (storage.googleapis.com/mediapipe-assets/Model Card MediaPipe Selfie Segmentation.pdf) could not be machine-read; secondary sources say Apache-2.0 | — | not used (U²-Net-p is enough); a human must read the card before use |

**No open-source face restorer with weights trained on commercially-licensed face data was found.**
Clean ways to get a "restored" face: (1) a paid API whose provider takes responsibility (e.g. fal.ai
`fal-ai/crystal-upscaler`, marketed for faces/portraits — read fal's model terms before launch);
(2) our own model trained only on commercial-use data (Phase 2 — on hold by owner decision 24 Oct).

### Hosted providers added (photo-final)

| Provider | Model | Licence position | Where |
|---|---|---|---|
| Replicate | `nightmareai/real-esrgan` (BSD-3 model), `face_enhance=false` | Replicate API terms | key-gated `photo_enhance_replicate`, rollout % (default 0) |
| Replicate (optional) | `tencentarc/gfpgan` v1.4 | **grey — see above** | only with the owner's legal switch |
| RunPod Serverless | our own handler (`tools/photo_train/serve_handler.py`) running Real-ESRGAN / later "Assisto Face" | our code + chosen weights | key-gated `photo_runpod` / `photo_assisto_face` |
| fal.ai | `fal-ai/crystal-upscaler` (Ultra HD, Premium) | fal API terms ("Commercial use" tag on fal pages) | key-gated `photo_fal` |
