# Photo Studio evaluation (p2-photo, 22 Oct 2026)

20 licence-clean photos (Wikimedia Commons: 10 official US-Congress portraits = US federal
works, public domain; 10 CC0 photos — per-file links + licences in `sources.json`), long edge
≤ 800 px. Tool: `tools/photo_model/eval_photos.py`; the classical pipeline is the APP'S OWN
Dart code (`app/lib/photo_studio/ps_classic.dart`, compiled AOT with
`dart compile exe app/tool/ps_eval.dart`), the AI step is the exact ONNX model the server
serves (`realesr_general_x4v3_dn050_t144.onnx`, sha256 `82ac4e3e…5ecf`) with the phone's
tiling (`UpscaleTiler.kt`, mirrored in Python; JVM parity check: tiling 0 mismatches, face-lock
merge max |diff| 1/255 vs Python).

`thumbs/NN.jpg` = degraded | Light | Natural | Strong | (½ size →) bicubic | (½ size →) AI step.
`face_lock_demo.jpg` = photo 01 face: bicubic | raw Real-ESRGAN | shipped AI step (original
colours + 25 % AI inside the face ellipse). Raw Real-ESRGAN turns blue eyes black and skin
waxy — that is why the shipped step face-locks. `results.json` = every number per photo.

## A. One-tap classical enhance (degraded → enhanced, PSNR vs the clean original)

Degradation (typical phone photo): under-exposed (gamma 1.35, ×0.82), colour cast, sensor
noise σ = 7, JPEG q 60. Face boxes from an OpenCV Haar cascade (stand-in for ML Kit).

| mean of 20 | degraded | Light | **Natural** | Strong | clean original |
|---|---|---|---|---|---|
| PSNR dB (higher = closer to original) | 15.65 | 19.61 | **21.54** | 20.72 | — |
| colour cast (mean \|channel mean diff\|, 0–255) | 38.2 | 22.5 | **13.8** | 11.2 | 0 |
| sharpness (Laplacian variance) | 1563 | 3116 | 4396 | 6025 | 2112 |

Natural improved PSNR on **20 / 20** photos (+5.9 dB mean). Strong over-shoots on purpose
(more contrast/sharpening than the original had). Sharpness above the original = the
unsharp mask also lifts residual noise/JPEG texture; Light/Natural stay moderate.

## B. AI restore & upscale (the "small / old photo" case)

Original shrunk to ½ (+ JPEG q 75) and brought back to full size the way the phone does it
(model ×4, then shrink to 2×). PSNR vs the clean original:

| mean of 20 | bicubic | raw Real-ESRGAN | **shipped AI step** |
|---|---|---|---|
| PSNR dB | 27.15 | 25.60 | 25.79 |
| sharpness | 167 | 1053 | 990 (original 2113) |

Honest reading: like every GAN super-resolution model, Real-ESRGAN scores LOWER PSNR than
bicubic (PSNR rewards blur; bicubic was better on 19 / 20) but is ~6× sharper and looks much
crisper (edges, hair outline, text, background). It does not recover true detail. Faces are
protected by face-lock + the identity check, so the shipped step never repaints a face.
Haar face count before/after the AI step: same on 17 / 20 (photos 06, 07: 2 → 1; 15: 0 → 1 —
Haar is a weak detector; on the phone ML Kit + the identity check would reject a lost face).

## C. Speed (THIS box — 2-vCPU x86 server, 1 thread, shared with the live backend)

| step | measured here | note |
|---|---|---|
| classical, 0.41 MP photos (Natural) | 178 ms mean (≈ 440 ms/MP) | AOT Dart, 1 core |
| classical, free preview 1024×768 | 310–370 ms (Light–Strong) | |
| classical, 12 MP (4000×3000) | 4.4 / 4.7 / 5.4 s (Light / Natural / Strong) | whole process peak RSS 199 MB incl. the 48 MB input + 48 MB output buffers (256-row strips) |
| AI, one 144 px tile (128 px useful) | 0.58 s (idle) / ~0.7 s (busy box) | ORT 1.19 CPU, 1 thread |
| AI, ½-size photo (~400×300, ~10 tiles) | 6.8 s mean | 1 thread |

**Mid-range phone time: TO BE MEASURED** on a real phone (checklist PS-1 and PS-3 in
`.phaseB/proposals/p2-photo.md`, Bangla). Expectation only (not a measurement): the phone
uses 4 threads + XNNPACK or NNAPI, so a ~10-tile photo should take a few seconds; classical
preview well under a second.
