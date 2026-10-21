# ps1-photo — Photo Studio: finish report + native proposal

## FINISH REPORT

**Branch:** `agent/ps1-photo` (worktree `/home/ubuntu/wt/ps1-photo`, based on ship148). Not pushed.

### Built (no native code needed — all in this branch)

**Backend (Django)**
- `core/logic/photo_studio.py` (pure): admin-editable `photo_studio` config block (entry-interstitial cap 30 min, HD-enhance 2 ads / 2 credits, max 3 ads per job, 1 free prompt trial/day, ad-value override, 70% share cap, preview size, ticket TTL, active provider); funding / Profit Guard math (`ads = ceil(cost ÷ (0.70 × ad value))`, `credits = max(table, ceil(cost ÷ net floor ÷ credit ৳))`, >3 ads → credits/Premium, unknown cost → refused); server-side safety classifier (sexual/undressing, real person in fake/compromising scene + face swap, ID/certificate/document text/money/seal fraud, identity-changing beauty, beauty allow-list, child caution, consent flag; en + Bangla + Banglish); SSV query splitting; per-day/per-feature stats.
- `core/logic/pricing.py`: new actions `photo_enhance_cloud`, `photo_prompt_edit`, `photo_generate` (margin-floor checked) + the `photo_studio` block (normalize + validate); editable through `/admin/pricing` (`views_build61.py` merge list).
- `core/integrations.py`: switchable key-gated providers `photo_gemini`, `photo_openai`, `photo_replicate` (API key + model + **cost per image**; a provider without a cost is never used); AdMob gets an `interstitial_unit` field (`logic/ads.py` UNIT_FIELDS + Google test id).
- `core/photo_providers.py`: Gemini generateContent (inline image, IMAGE modality), OpenAI images edits/generations, Replicate predictions — each with the face rule in the instruction. Mocked-HTTP only; first real call happens when the owner adds a key.
- `core/photo_studio_service.py`: jobs (funding TAKEN before any cost), atomic credit/pool debit (Premium/Business Photo Studio jobs come from the monthly pool), **ad-reward ledger**: `PhotoAdTicket` nonce → AdMob SSV `custom_data`; **only Google's ECDSA-signed callback `GET /ads/ssv` verifies an ad** (keys from gstatic, cached 12 h; replayed `transaction_id` ignored; user_id must match; open tickets ≤ ads still needed); no-fill → nothing verified → retry or `fund` with credits at full price; cloud run with retry-on-failure (funds kept, 3 runs, then credits refunded), face-lock compositing (Pillow, when face boxes are sent), reduced + watermarked preview for free users; **the export gate** `unlock()` for save/share/wallpaper/copy/open_in (free: funded job only, corner mark required; Premium/Business: clean); owner stats.
- Models + migration `0050_ps1_photo_studio.py` (depends on `0048_v1_vehicle_tracking` — integrator re-chains after `0049_d1_discover_cards`): `PhotoStudioJob`, `PhotoAdTicket`, `PhotoExport`.
- Routes (`core/urls.py`, block `# ---- ps1-photo ----`): `photo-studio/config|safety|entry-ad|jobs|jobs/<pk>|jobs/<pk>/ad-ticket|jobs/<pk>/fund|jobs/<pk>/run|jobs/<pk>/unlock`, `ads/ssv` (public, signature-authenticated), `admin/photo-studio/pnl`. `/admin/pnl` now also carries `photo_studio` (ad revenue vs cost per day per feature).
- `core/screen_synonyms.py`: `photo_studio` route synonyms.

**App (Dart)**
- `lib/photo_studio/`: `ps_models`, `ps_backend` (server seam), `ps_engines` (**EnhanceEngine**, **FaceDetector**, **LandmarkProvider**, **FaceEmbedder**, **IdentityGuard** + **GuardedEdit** (natural → lighter → discard), pure-Dart **compositeFaces** face-lock, **SecureScreen** over `com.assisto/photo_secure`), `ps_ads` (**PhotoAdBridge**: interstitial + rewarded-with-SSV; no-op in this build, reuses a6 `RewardOutcome`), `ps_session` (original kept, undo/redo, version history; **PngMeta** writes Software/Comment tEXt + XMP IPTC DigitalSourceType = AI-edited), `ps_export` (**ExportGate** — the one gate; **ExportRenderer** corner mark "Edited with Assisto" for free saves; **ExportSink**), `ps_controller`, `ps_gate_sheet`.
- `lib/screens/photo_studio_screen.dart`: entry-interstitial transition, pick (gallery/camera), before/after slider (existing `PhotoCompare`) + strength (Light / **Natural** / Strong), honest "not in this build yet" engine state, prompt box with the existing `VoiceMicButton`/`VoiceDictation`, 12 tickable ready options (incl. BD passport 40×50 / visa 50×50 white, product photo, document cleanup, crop/straighten) and the 9 allowed beauty ops, people / someone-else / child switches with consent + child-caution notes, cost line (ads / credits / pool / trial), refusal card, export tiles (Save, Share, Wallpaper, Copy, Open in…) all through `PhotoStudioController.export` → gate, watermark over the free preview, FLAG_SECURE note, version sheet.
- Navigation: ChatNav route `photo_studio` + sidebar entry next to the existing Photo Enhance. Home screen untouched.
- Owner P&L screen: new "Photo Studio: ad revenue vs cost" section.

### Tests
- Backend `core.tests_ps1_photo`: **47 tests** — includes the grid test "a loss-making edit is impossible" (>1000 config/cost/plan combinations), every export path locked for free users until 2 SSV-verified ads, forged/unsigned/replayed/wrong-user SSV rejected, no-fill then credits = full price, ticket-farming cap, Premium/Business never get ads or an entry ad, trial limit, provider without cost never used, provider cost above table raises credits, failure keeps funds then refunds, face-lock pixels, reduced preview, owner P&L feed.
- Full backend `core` suite: **2549 tests, OK** (`--parallel 1`, settings_test).
- Flutter `test/ps1_photo_test.dart`: **37 tests** (face-lock, identity guard incl. embedding, guarded retry/discard, version history, PNG metadata + CRC, gate on all 5 exit paths at controller AND widget level, no-fill never a bypass, unavailable exit refused before any ad, Premium clean path, preview reduced / full render only after the gate, people-photo without identity check takes no money, trial limit, refusal, provider-missing, entry interstitial cap / no-fill / Premium never).
- Gallery: `test/ps1_shots.dart` wired into `screenshots_test.dart` — 9 shots × bn/en × light/dark (36 PNGs): free empty, free enhanced (before/after + watermark, synthetic test pattern through a fake engine), free full page, Premium, engine-unavailable + provider-missing page, refusal, gate sheet, no-fill sheet, trial-used credits-only sheet.
- `flutter analyze` on all touched files: 0 errors (pre-existing warnings in chatnav/owner_pnl untouched). Lang gate clean. `route_check --report-only`: 0 problems. `makemigrations --check`: no changes.

### Honest limits
- **No on-device AI in this build.** EnhanceEngine / face detection / landmarks / FLAG_SECURE are interfaces with "not available in this build yet" states. One-tap enhance shows that message; nothing fake is ever shown.
- Because the identity guard needs on-device landmarks, **cloud edits of photos with people are refused up front (no ads/credits taken)** until the native part ships. Photos without people (products, landscapes, documents: switch "There are people in this photo" off) and generation work as soon as a provider key exists.
- **AdMob is not linked** (a6 no-op bridge): free users can only pay with credits until the AdMob native part + SSV callback are live. That is by design — no free bypass.
- Provider adapters are written to the public APIs but tested with mocked HTTP only.
- Safety classifier is keyword/regex based (first line); the provider's own filter is the second line.
- Free export "Save" in this build writes to the app's own folder (not the Gallery); Wallpaper and Copy report "not available in this app version" (their Kotlin is below). Ads are never taken for an exit that cannot deliver.
- A modified/rooted client could still screenshot or extract an on-device preview; server-side, cloud results are only released in full after the unlock.
- **Open decision for the owner/integrator:** the older `PhotoEnhanceScreen` (faithful colour-matrix editor, home quick button `photo_enhance`) still saves/shares without ads. Home is frozen, so I did not re-route it.
- Embedding model: none with a commercial licence was found (see `.phaseB/MODEL_LICENSES.md`) — the guard uses geometry only until the owner licenses one.

### What the owner must provide
1. One image provider in Integrations (Gemini image editing **or** OpenAI images **or** Replicate) **+ its cost per image (USD)** — see `owner_actions/OWNER_UNLOCK_LIST.md` (Photo Studio section).
2. AdMob: rewarded unit ID, **interstitial unit ID**, and the rewarded unit's **SSV callback URL** `https://api.lifeassisto.com/api/v1/ads/ssv` in the AdMob console.
3. The real value of one rewarded ad in BD (`/admin/pricing → photo_studio.ad_value_bdt`); with the default eCPM floor (৳30/1000) ads cannot fund cloud jobs, only HD exports.

### Live install steps
- Deploy + `migrate` (0050, after re-chaining). No cron/systemd/nginx change. `/api/v1/ads/ssv` must be reachable from Google (public, no auth — the signature is the auth). Pillow must be in the deploy venv for previews/face-lock (it is installed in the current venv but **not listed in `backend/requirements.txt`** — add `Pillow` there).

---

## NATIVE PROPOSAL (integrator: ship after a real launch smoke on CI, API 33)

All native pieces are lazy (first use inside Photo Studio only) and try/caught. Nothing at app launch, no ContentProvider, no WorkManager.

### N1 — AdMob for Photo Studio (after a6 AdMob part is live)
- No new pubspec entry (uses a6's `google_mobile_ads: 9.1.0`).
- Copy `.phaseB/pending_native/ps1/admob_photo_bridge.dart.pending` → `app/lib/photo_studio/admob_photo_bridge.dart`; in `app/lib/photo_studio/ps_ads.dart`:
```diff
-PhotoAdBridge createPhotoAdBridge() => const NoopPhotoAdBridge();
+PhotoAdBridge createPhotoAdBridge() => AdmobPhotoAdBridge();
```
  (+ `import 'admob_photo_bridge.dart';`). It loads InterstitialAd for the entry and RewardedAd with `ServerSideVerificationOptions(userId, customData = ticket nonce)`.
- Owner: SSV callback URL on the rewarded unit (above).

### N2 — On-device enhance runtime + model download
- pubspec: `tflite_flutter: 0.11.0` (Apache-2.0). Pin the exact version at apply time (≥2 weeks old, resolves with the current tree).
- Model: Real-ESRGAN `realesr-general-x4v3` (+ `-wdn-`) converted to TFLite fp16 (~2.5 MB each), hosted by us (owner server `/static/models/` or a GitHub release) with a SHA-256 the app checks; downloaded on first use inside the app ("Preparing the photo tool…"), never a separate install. Tile-based inference (e.g. 128 px tiles) to stay within memory on 3–4 GB phones; 4x only when RAM ≥ 6 GB.
- Implement `EnhanceEngine` (`TfliteEnhanceEngine`) in Dart; bind in `PsDeps` default.

### N3 — FLAG_SECURE on the free preview
- Add `.phaseB/pending_native/ps1/PhotoSecure.kt` to `app/android_overlay/app/src/main/kotlin/com/assisto/assisto/`, and in `MainActivity.configureFlutterEngine`:
```diff
+        PhotoSecure.register(this, flutterEngine)   // ps1-photo
```
  The Dart side (`ChannelSecureScreen`) already calls `enable`/`disable` and shows the honest note while the channel is missing.

### N4 — Gallery save, wallpaper, copy image
- Add `.phaseB/pending_native/ps1/PhotoExportChannel.kt` to the overlay and register:
```diff
+        PhotoExportChannel.register(applicationContext, flutterEngine)   // ps1-photo
```
- Manifest (via the android.yml permission patch list):
```diff
+              '\n    <uses-permission android:name="android.permission.SET_WALLPAPER"/>'
+              '\n    <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>'
```
- Dart: a `ChannelExportSink` (save→`saveToGallery`, wallpaper→`setWallpaper`, copy→`copyImage`, share/open-in unchanged) replacing `PlatformExportSink` — every call still behind the gate.

### N5 — ML Kit face detection + contours (FACE-LOCK + IDENTITY GUARD)
- pubspec: `google_mlkit_face_detection` (bundled model; ML Kit ToS, commercial OK). Pin the exact version at apply time and confirm it resolves with `camera 0.12`.
- Implement `FaceDetector` (boxes, normalised) and `LandmarkProvider` (eye centres first, then nose, mouth corners, jaw contour points) in Dart; bind both in `PsDeps`. Then cloud edits of people photos unlock: boxes are sent as `face_boxes` → server composites the ORIGINAL face pixels back; the app re-checks geometry before showing.
- Face embedding (ArcFace-class): **none licensed** — keep `UnavailableEmbedder` until the owner buys a commercial model licence.

### Size impact (approx.)
tflite native libs ~2–4 MB/ABI; ML Kit face bundled ~1–2 MB; models downloaded later (~5 MB).
