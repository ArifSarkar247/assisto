# Photo Studio benchmark: baseline (free local provider only, 24 Oct 2026)

`tools/photo_bench/run_bench.py` produced these results with
`--inputs <eval50 thumbnails> --models <server photo_models>`.

- **Sheets:** `bench_*.jpg`, in this order: clean original | input | local_worker Natural | local_worker Strong (with portrait blur).
- **Numbers:** `results.json`.
- **Photos:** Wikimedia Commons, Public domain / CC0. The licence records are in `.phaseB/d1_eval/sources_50.json`.
- **Input:** we simulated cheap-phone / WhatsApp damage on the clean originals (½ size, soft blur, JPEG q55). Low-light inputs are darkened with gamma 2 × 0.45 plus noise. Real old photos are used as they are.
- **Paid providers:** none were run (no keys; we spent no money). Run them later with `--paid` once the keys are in env (see the script header).
- **The owner's own upload:** add it with `--extra <file>`. The integrator copies it from the server; it is never committed.

## Results (local_worker, CPU, cost $0)

Identity is the AuraFace cosine between the clean original and the output, taken for the worst face. 1.0 means the same embedding; a different person scores below about 0.35.

Seconds were measured on the 2-vCPU box at `nice 19`, while other agents' Flutter suites were running. On an idle worker expect about half.

| photo | kind | Natural s | Strong s | identity N / S | sharpness in → N / S | Face Lock |
|---|---|---|---|---|---|---|
| 01 | portrait | 69 | 73 | 0.92 / 0.90 | 76 → 91 / 154 | kept |
| 04 | portrait | 50 | 61 | 0.86 / 0.84 | 104 → 135 / 174 | kept |
| 21 | dark skin | 11 | 12 | 0.68 / 0.66 | 116 → 142 / 216 | kept |
| 25 | dark skin | 11 | 26 | 0.83 / 0.83 | 174 → 161 / 180 | kept |
| 29 | dark skin, low light | 22 | 28 | 0.92 / 0.91 | 198 → 750 / 1208 | kept |
| 33 | real old photo (3 faces) | 30 | 42 | 0.84 / 0.84 | 746 → 1802 / 3052 | kept |
| 36 | real old photo | 13 | 16 | 0.98 / 0.96 | 402 → 1071 / 1167 | kept |
| 41 | group (4 faces) | 47 | 22 | 0.00* | 287 → 291 / 436 | original faces pasted back |
| 44 | group (15 faces) | 35 | 36 | 0.00* | 284 → 197 / 378 | original faces pasted back |
| 47 | low light (no face) | 0.4 | 0.4 | — | 173 → 996 / 2978 | no faces |

\* **Group photos:** at least one tiny face was not re-detected in the output, so the "worst face" score is 0. Face Lock then pasted the original faces back, so the people are unchanged but not improved. This is an honest limit of the free path for groups.

## Quality notes (looking at the sheets)

**What improved:**
- Portraits are clearly sharper, warmer and cleaner.
- In Strong mode, portrait blur gives a Remini-like soft background.
- Low light and old photos are lifted a lot.
- Skin is not whitened. The skin-tone guard keeps each face's brightness in step with the whole scene.

**Fixed during this run:**
- Background blur had wiped out the small people in a group photo. It now runs only on portraits: 1–3 people with a large face.
- Small faces had turned waxy. Skin smoothing now runs only on faces at least 160 px wide, and each face gets only one Real-ESRGAN pass.

**Still weaker than Remini:**
- When the face is heavily blurred or tiny (photo 21: a 335 px WhatsApp-quality input), Real-ESRGAN gives a smooth, slightly waxy face and does not "re-imagine" the detail.
- Closing that gap needs a face-restoration model. GFPGAN is ready behind the owner's legal switch (`.phaseB/MODEL_LICENSES.md`), or Phase 2 would provide our own model.
- No "better than Remini" claim is made.

## Re-run 25 Oct 2026: `local_clean` (no Real-ESRGAN = the new server default)

`realesrgan_allowed` is now OFF by default (weights licence grey), so the free server pipeline uses
Lanczos x2 + unsharp + the same look stage + Face Lock, with no ML upscaler. Same 10 photos, same damage,
`tools/photo_bench/run_bench.py` (provider `local_clean`, nothing downloaded, cost $0). Sheets and numbers:
`clean_2510/` (sheet = clean original | input | Natural | Strong).

| photo | input px | out px (clean / old Real-ESRGAN) | s N / S | identity N / S (old) | sharpness in → N / S (old N / S) |
|---|---|---|---|---|---|
| 01 portrait | 480×639 | 960×1278 / 1225×1631 | 10 / 11 | 0.91 / 0.90 (0.92 / 0.90) | 76 → 24 / 34 (91 / 154) |
| 04 portrait | 480×600 | 960×1200 / 1264×1581 | 5 / 15 | 0.90 / 0.88 (0.86 / 0.84) | 104 → 30 / 37 (135 / 174) |
| 21 dark skin | 167×205 | 334×410 / 668×820 | 1 / 2 | 0.65 / 0.58 (0.68 / 0.66) | 116 → 42 / 66 (142 / 216) |
| 25 dark skin | 158×211 | 316×422 / 632×844 | 2 / 3 | 0.85 / 0.85 (0.83 / 0.83) | 174 → 50 / 59 (161 / 180) |
| 29 dark skin, low light | 960×1200 | same | 5 / 8 | 0.88 / 0.88 (0.92 / 0.91) | 198 → 808 / 1400 (750 / 1208) |
| 33 real old (3 faces) | 960×800 | same | 5 / 6 | 0.83 / 0.79 (0.84 / 0.84) | 746 → 1810 / 3085 (1802 / 3052) |
| 36 real old | 960×1239 | same | 3 / 5 | 0.95 / 0.96 (0.98 / 0.96) | 402 → 1080 / 1184 (1071 / 1167) |
| 41 group (4) | 480×320 | 960×640 / 1732×1154 | 9 / 10 | 0.00* | 287 → 77 / 114 (291 / 436) |
| 44 group (15) | 480×346 | 960×692 / 1665×1200 | 22 / 28 | 0.00* | 284 → 89 / 153 (197 / 378) |
| 47 low light | 960×540 | same | 0.7 / 0.6 | — | 173 → 996 / 2978 (same) |

Honest reading:
- Big photos (29, 33, 36, 47) are practically the same as before: neither path upscales them; the look
  stage does the work. Identity stays 0.79–0.96, Face Lock kept every face.
- Small / WhatsApp photos (01, 04, 21, 25, 41, 44) are now enlarged x2 by Lanczos instead of ~x2.6 by
  Real-ESRGAN. They are **softer**: no invented detail. (The sharpness number is a Laplacian variance and
  drops on any enlarged image, so compare it only within the same size.) This is the price of not using
  licence-grey weights; the owner can turn `realesrgan_allowed` on, or choose a commercial face upscaler
  (Topaz / Clarity Crystal on fal.ai), to win this back.
- It is 3–7× faster on our CPU (no tiles).
- \* Group photos: as before, a tiny face is not re-detected, so Face Lock pastes the original faces back.
- No "better than Remini" claim.
