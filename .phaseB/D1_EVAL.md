# D1 — Photo Studio evaluation (23 Oct 2026)

## Honest scope
- **Remini was NOT run.** We cannot run it here and must not copy it. The "Remini" column of the
  contact sheets is empty until the owner runs the same 20 inputs through Remini on the phone
  (`owner_actions/PHOTO_COMPARE_BN.md`) and we re-run
  `tools/photo_eval/run_eval.py … --remini <folder>`; the script then fills the column and the
  same metrics. **No claim of "better than Remini" is made anywhere until that is done.**
- Test set: 20 licence-clean originals (10 US-Congress official portraits = public domain, 10 CC0
  photos, Wikimedia Commons; `.phaseB/photo_studio_eval/sources.json`), damaged on purpose in four
  categories (5 each) so we can measure against the clean original. Synthetic damage is not the same
  as real old/blurry photos — numbers show direction, not a guarantee.
- "Assisto" = the app's own code paths: Dart classical pipeline compiled AOT
  (`app/tool/ps_eval.dart` → `ps_classic.dart`), the exact Real-ESRGAN ONNX the server serves with the
  phone's tiling and face-lock merge, the server's old-photo restore (`backend/core/photo_restore.py`
  with the real DDColor-tiny ONNX). Faces for face-lock: OpenCV Haar (stand-in for ML Kit).
- Contact sheets: `.phaseB/d1_eval/sheet_1..4.jpg` (clean | damaged | Assisto | Remini). Every number:
  `.phaseB/d1_eval/results.json`.

## Results (metrics vs the clean original; higher PSNR/SSIM = closer to it)

| category (5 photos each) | damaged PSNR / SSIM | **Assisto** PSNR / SSIM | Remini PSNR / SSIM | PSNR better on | sharpness damaged → Assisto (clean) | mean |ΔL| damaged → Assisto | time / photo here |
|---|---|---|---|---|---|---|---|
| portrait | 28.1 / 0.848 | **22.7 / 0.825** | not run (owner) | 0 / 5 | 10 → 255 (682) | 1.8 → 5.6 | 3.1 s |
| old | 15.3 / 0.633 | **13.5 / 0.613** | not run (owner) | 1 / 5 | 28 → 109 (2134) | 6.8 → 13.4 | 11.0 s |
| blurry | 25.0 / 0.738 | **21.6 / 0.776** | not run (owner) | 1 / 5 | 29 → 283 (1208) | 3.2 → 6.3 | 3.8 s |
| low light | 8.5 / 0.382 | **19.9 / 0.722** | not run (owner) | 5 / 5 | 617 → 2926 (2616) | 36.0 → 8.3 | 0.4 s |

| photo | category | damaged PSNR | Assisto PSNR | Assisto SSIM | faces clean/damaged/Assisto | run |
|---|---|---|---|---|---|---|
| 01_portrait.jpg | portrait | 27.1 | 23.7 | 0.798 | 1/1/1 | ai_tiles 6, ai_ms 3274, classic_ms 208, total_ms 3697 |
| 02_portrait.jpg | portrait | 29.0 | 24.9 | 0.894 | 1/1/1 | ai_tiles 4, ai_ms 2106, classic_ms 58, total_ms 2246 |
| 03_portrait.jpg | portrait | 29.3 | 25.7 | 0.819 | 1/1/1 | ai_tiles 6, ai_ms 3425, classic_ms 333, total_ms 3987 |
| 04_portrait.jpg | portrait | 27.0 | 17.9 | 0.715 | 1/1/1 | ai_tiles 6, ai_ms 3101, classic_ms 229, total_ms 3530 |
| 05_portrait.jpg | portrait | 28.1 | 21.3 | 0.900 | 1/1/1 | ai_tiles 4, ai_ms 1981, classic_ms 55, total_ms 2119 |
| 06_portrait.jpg | old | 13.3 | 12.5 | 0.622 | 2/1/2 | colorized True, server_ms 11731, total_ms 11731 |
| 07_portrait.jpg | old | 13.3 | 12.3 | 0.601 | 2/2/2 | colorized True, server_ms 12911, total_ms 12911 |
| 08_portrait.jpg | old | 12.6 | 12.4 | 0.778 | 1/1/1 | colorized True, server_ms 9852, total_ms 9852 |
| 11_scene.jpg | old | 16.1 | 18.6 | 0.472 | 0/0/0 | colorized True, server_ms 11181, total_ms 11181 |
| 12_scene.jpg | old | 21.4 | 11.6 | 0.595 | 0/0/0 | colorized True, server_ms 9175, total_ms 9175 |
| 09_portrait.jpg | blurry | 26.0 | 19.5 | 0.797 | 1/1/1 | ai_tiles 6, ai_ms 3046, classic_ms 575, total_ms 3931 |
| 10_portrait.jpg | blurry | 28.2 | 19.6 | 0.851 | 1/1/1 | ai_tiles 6, ai_ms 2963, classic_ms 285, total_ms 3430 |
| 13_scene.jpg | blurry | 27.3 | 25.9 | 0.823 | 0/1/1 | ai_tiles 6, ai_ms 3084, classic_ms 475, total_ms 3830 |
| 14_scene.jpg | blurry | 23.0 | 21.9 | 0.722 | 0/0/0 | ai_tiles 6, ai_ms 3197, classic_ms 515, total_ms 4056 |
| 15_scene.jpg | blurry | 20.7 | 21.0 | 0.689 | 1/0/1 | ai_tiles 6, ai_ms 3068, classic_ms 453, total_ms 3818 |
| 16_scene.jpg | low_light | 9.6 | 19.9 | 0.693 | 0/0/0 | classic_ms 169, total_ms 329 |
| 17_scene.jpg | low_light | 9.1 | 21.4 | 0.697 | 0/0/0 | classic_ms 151, total_ms 269 |
| 18_scene.jpg | low_light | 9.4 | 21.3 | 0.724 | 1/0/0 | classic_ms 187, total_ms 312 |
| 19_scene.jpg | low_light | 8.0 | 21.1 | 0.763 | 0/0/0 | classic_ms 172, total_ms 284 |
| 20_scene.jpg | low_light | 6.3 | 15.5 | 0.733 | 0/0/0 | classic_ms 296, total_ms 572 |

### Honest reading
- **Low light — clear win:** PSNR 8.5 → 19.9 dB, SSIM 0.38 → 0.72 on 5/5, 0.3–0.6 s. Grain is
  lifted with the brightness; the preset was re-tuned during this eval (sharpen 0.25 → 0.08, full
  denoise) because the first run doubled the grain.
- **Blurry / small portraits — sharper, NOT more faithful:** SSIM up on blurry (0.74 → 0.78),
  sharpness 10–30 → ~260–280 (originals 680–1 200), but PSNR goes DOWN (28 → 23 dB portraits,
  25 → 22 blurry). Two reasons: (1) GAN super-resolution invents texture that is not in the original
  (PSNR punishes that), (2) the classical Natural pass also changes tone/contrast on purpose
  (mean |ΔL| 1.8 → 5.6); photo 04 got over-contrasted (17.9 dB). Faces are face-locked (25 % AI
  detail), so they stay the same person but get LESS crisp than a face-restoration app would make them.
- **Old photos — dust gone, colour added, scratches only partly removed:** colour from DDColor is a
  guess (12_scene turned warm orange, 08's face came out pale); PSNR vs the colour original is
  therefore low for 4/5 (only 11 improved, 16.1 → 18.6). Wide scratches survive the median cleanup;
  fade is fixed. Faces kept (Haar counts equal on 4/5; 06 damaged 1 → restored 2 = the clean count).
- **Face restoration:** not offered (no licence-clean model). Remini will very likely look crisper on
  faces; ours will not change who the person is. That is the honest trade-off until a commercially
  licensed face model exists.
- **Deblur (NAFNet):** not evaluated — GPU-only and not connected.


## Speed (measured on THIS server; phone numbers are estimates until measured on the owner's phone)
| step | measured here (Xeon 8259CL, 2 vCPU shared with the live backend + another agent) | mid-range phone (Snapdragon 680 class) |
|---|---|---|
| Real-ESRGAN 144-px tile (128 useful) | 0.53 s idle, 0.71 s busy (1 thread; 2 threads no faster on this 1-core/2-HT box) | **estimate 1.1 s/tile** (4× A73 + XNNPACK ≈ half this core's FP32 rate) — the app uses this only until the first real run, then the phone's MEASURED ms/tile (`perf.json`) |
| AI step in Enhance (budget 7.5 s → 6 tiles first run) | 2.4–4.8 s for 4–6 tiles (one 10.8 s outlier while the box was busy) | ≈ 6.6 s (6 × 1.1 s) + classical ≤ 1 s → **< 10 s**; larger photos work on a smaller copy so it stays in budget |
| Classical enhance / denoise / low-light (free preview ≤ 1 024 px) | 0.06–0.7 s (AOT Dart, 1 core) | ≈ 0.2–1.5 s |
| Background-blur mask (U²-Net-p 320²) | 0.55 s | ≈ 1.2 s + Dart blur ≈ 1 s → ~2.5 s |
| Upscale 2×/4× tool | 0.53–0.71 s × tiles (e.g. 640×480 = 20 tiles ≈ 12 s here) | ≈ 1.1 s × tiles — **only ≤ 6-tile photos (~384×256) are under 10 s**; the button shows the honest estimate, progress per tile and Cancel |
| Colorize (server, DDColor-tiny 512²) | model 3.4–4.5 s; whole job 6.7–13 s (worker start + 1.5 s model load) | — (server) |
| Old-photo restore (server, ≤ 512 px → ×4, + colour) | 12–16 s whole job (worker, peak RSS 1.4 GB, one at a time) | — (server) |
| Deblur NAFNet-w32 (server CPU, measured with random weights) | 1.6 s @256², 3.8 s @512×384, **16 s @768×576, 69 s @1024×768** | → **GPU API only** (Replicate, Admin key), hidden until connected + priced |
