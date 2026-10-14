# Photo Enhance — ADVANCED (SPEC v2.1 §21) — integrator notes

Upgrades `PhotoEnhanceScreen` (launch gap E) from GOOD -> ADVANCED. Everything
that ships works offline on CPU and is 100% FAITHFUL (non-generative) — it
cannot add, remove, or invent content, and it NEVER alters identity. AI enhance
stays KEY-GATED and HONEST (no faked result). ID / official documents remain
hard-blocked server-side.

## Advanced vs. before
| | GOOD (before) | ADVANCED (now) |
| --- | --- | --- |
| Pick | gallery/camera | same + honest permission-blocked state + "change photo" |
| Adjust | pick a few named ops, then a server "plan" (no visible result) | LIVE on-device edit: brightness / contrast / saturation / sharpness sliders, 90° rotate, small straighten (±15°), square crop, **auto-fix**, **reset** — all rendered via a faithful colour-matrix + transform pipeline |
| Presets | none | document-scan · portrait (faithful bundles) · **passport/ID-size** -> opens the exact-size web tool (never edits identity) |
| Compare | none | **before/after**: draggable split slider + press-&-hold reveal of the original |
| AI enhance | single "cloud" note | key-gated upscale / denoise / background — honest 🔑 note + "Key needed" badge, re-checks the server plan, shows the real refusal, never fakes |
| Output | none | **Save** (PNG to device) + **Share** (exports exactly what you see) |
| Batch | none | honest "one-at-a-time for now" note |
| States | partial | empty / loading / permission / error(offline) all designed |

## Files changed / created (STRICTLY in scope)
| File | What |
| --- | --- |
| `app/lib/screens/photo_enhance_screen.dart` | **Rewritten.** Phase-driven (empty/editing/busy), live faithful editor, presets, before/after, key-gated AI, save/share, batch note, all honest states, safety banner reinforced with "never alter IDs". |
| `app/lib/widgets/photo_strings.dart` | **NEW.** Bilingual string table (Bangla as `\u` codepoints — **zero Bangla glyphs in .dart**), `pStr`/`pIsBn`/`pNum` (Bangla digits). Mirrors the ARB. |
| `app/lib/widgets/photo_canvas.dart` | **NEW.** Faithful render pipeline: colour-matrix (brightness/contrast/saturation) + transform (rotate/straighten/square-crop) + sharpen overlay; `capturePng` exports via `RepaintBoundary.toImage` (what you see = what you save). Flutter built-ins only, no new deps. |
| `app/lib/widgets/photo_presets.dart` | **NEW.** `PhotoAdjustments` model + `kPhotoPresets` (document/portrait faithful bundles, passport = web-tool link) + `PhotoPresetBar` tiles (Semantics, selected state). |
| `app/lib/widgets/photo_compare.dart` | **NEW.** Before/after split slider + press-&-hold original; high-contrast labelled chips; Semantics. |
| `backend/core/photo.py` | **Extended** (optional). Added `BASIC_ADJUSTMENTS`, `AI_OPS`, `presets(lang)` (faithful bundles, passport `web_tool:true`), `ai_ops(lang)` (always `requires_key:true`, `available` mirrors real provider wiring). Existing `plan()` safety brain UNCHANGED — `background_replace` still forbidden on the faithful path. |
| `backend/core/launch_gaps_tests_snippets.py` | **Extended** +2 tests (`test_photo_advanced_presets_and_ai_honest`, `test_photo_advanced_scenario`). The 3 photo tests pass standalone. |
| `.phaseB/up_photo_arb.json` | **NEW.** 49 ARB keys `{key:[bn,en]}`. |

> Per task constraints, NOT edited: `api.dart` (reused `photoEnhancePlan` as-is),
> `app_*.arb` / `app_localizations.dart` (new keys emitted to `up_photo_arb.json`;
> the screen reads them via `photo_strings.pStr` TODAY), `models.py`, `urls`,
> sidebar, other screens. No flutter/build/migrations run. No Asalify touched.
> `dart analyze` on the 5 app files: **No issues found.**

## ARB sync
Apply `.phaseB/up_photo_arb.json` (**49 keys**, prefix `ph*`) into
`app_bn.arb`/`app_en.arb`. All values are plain strings (no placeholders). The
screen/widgets read them via `photo_strings.pStr` today, so no ARB edit is
needed to ship; folding into the ARB lets `dart gen-l10n` own them later.
Existing `photo*` getters (`photoTitle`, `photoNeverDocuments`,
`photoFromGallery/Camera`, `photoConfirmOwn`, `photoConfirmNotDocument`,
`photoKindPersonal/Document`, `photoEnhanceButton`, `photoReady`, `photoBlocked`,
`photoOffline`) are REUSED as-is.

## Backend wiring (optional)
- `GET /photo/presets?lang=` -> `{presets: photo.presets(lang),
  ai_ops: photo.ai_ops(lang)}` if you want the app to pull presets/AI metadata
  from the server. The app ships a local copy today, so this is optional.
- The existing `POST /photo/plan {kind, ops, own_photo}` is UNCHANGED and is
  what the AI-enhance button calls. With no image-AI provider wired,
  `cloud_available()` is false -> `ai_ops[*].available == false` and an AI plan
  for `background_replace` returns `allowed:false, reason:forbidden_op`. Nothing
  is ever faked.

## Section-21 coverage (all 10)
1. **Benchmarked** vs a stock gallery editor — equal/better: live faithful
   adjustments, presets, before/after, save+share, honest AI gating.
2. **Full flow**: pick -> attest own + declare kind -> adjust/preset ->
   compare -> save/share; reset + change-photo; AI re-check path.
3. **Both rails**: manual sliders + one-tap presets; AI path is explicitly
   marked key-gated (🔑), never auto-run, never faked.
4. **Empty / loading / error / permission** all designed: empty state with
   pick CTA; busy overlay during the server plan check; offline snackbar on
   plan failure; dedicated permission-blocked state with retry.
5. **bn/en** strict (zero Bangla glyphs in .dart; percentages use Bangla
   digits via `pNum`), light/dark via `ColorScheme`, small/large via Wrap +
   ellipsis-safe layouts. WCAG: compare labels are dark-scrim chips (not colour
   alone), Semantics on sliders/presets/compare.
6. Wired to the existing `photoEnhancePlan` API + the web passport tool
   (`{apiBase}/photo`) via `url_launcher`; reachable from the existing route.
7. **Server tests** pass incl. a real-world **scenario** (user cleans a holiday
   photo with the portrait bundle; AI upscale with no key stays honest).
8. **Share/result**: `RepaintBoundary` export shares exactly the on-screen
   faithful result (PNG) via `share_plus`; save writes the same PNG.
9. **Privacy/consent/safety**: own-photo attestation required; ID/document
   kind reaches the server hard-block (defense-in-depth); identity never
   altered; AI never fabricates; reinforced "we never alter IDs" banner.
10. Pending **independent reviewer**.
