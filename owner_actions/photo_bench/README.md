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
