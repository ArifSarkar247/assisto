# h1-home — native proposal (home ad hero + image in chat)

Everything in the branch works WITHOUT these parts: the home shows the normal
logo + "Hi, I'm Assisto" block (Noop hero bridge), and image in chat shows an
honest "reading photos on the phone isn't in this app version yet" state, while
the detailed (cloud) answer works as soon as the owner adds a vision key.
Apply each part only after a real launch smoke on CI (API 33). All native code
is lazy (first use, after the first frame) and try/caught. No WorkManager, no
startup ContentProvider.

## A — AdMob native hero (no new dependency)

Prerequisite: the a6 AdMob part (`.phaseB/proposals/a6-leftovers-admob.md` A1-A3):
`google_mobile_ads: 9.1.0` in pubspec, manifest
`com.google.android.gms.ads.APPLICATION_ID = ${admobAppId}` (Gradle
`manifestPlaceholders["admobAppId"]` = CI secret `ADMOB_APP_ID`, default
Google's TEST app id `ca-app-pub-3940256099942544~3347511713`),
`MobileAdsInitProvider` removed (`tools:node="remove"`), and
`--dart-define=ADMOB_APP_ID=${{ secrets.ADMOB_APP_ID }}`. This part adds
nothing to pubspec/manifest/Gradle.

1. `cp .phaseB/pending_native/h1/admob_hero_bridge.dart.pending app/lib/ads/admob_hero_bridge.dart`
2. ```diff
   --- a/app/lib/ads/hero_binding.dart
   +++ b/app/lib/ads/hero_binding.dart
   -import 'hero_ad.dart';
   +import 'admob_hero_bridge.dart';
   +import 'hero_ad.dart';
   @@
   -HeroAdBridge createHeroAdBridge() => const NoopHeroAdBridge();
   +HeroAdBridge createHeroAdBridge() => AdmobHeroAdBridge();
   ```
3. Sound (owner order §3): `AdmobHeroAdBridge` builds the ad with
   `NativeAdOptions(videoOptions: VideoOptions(startMuted: <ad_rewards.hero_start_muted>,
   customControlsRequested: false, clickToExpandRequested: false))`. With
   `customControlsRequested: false` the SDK draws its own video controls,
   including the speaker toggle. It also calls
   `MobileAds.instance.setAppMuted(false)` once at init, so rewarded,
   interstitial and app-open ads keep normal AdMob sound. Recommended matching
   one-liner in the a6 `AdmobAdsBridge.init()` and the ps1 `AdmobPhotoAdBridge._init()`
   (one shared rule, `AdSound.appMuted`):
   ```diff
         await MobileAds.instance.initialize();
   +     try { await MobileAds.instance.setAppMuted(AdSound.appMuted); } catch (_) {}
   ```
4. Rendering uses the plugin's **native templates** (`NativeTemplateStyle(templateType:
   TemplateType.medium)`), so there is **no Kotlin `NativeAdFactory` and no
   MainActivity change**. The template shows the AdChoices icon + "Ad" badge;
   the app adds its own "Ad" label row OUTSIDE the ad view.
5. Rules already enforced in Dart (`lib/ads/hero_ad.dart`, `lib/widgets/home_hero.dart`)
   and on the server: Free only (`/ads/config.hero_enabled` false for
   paid plans; the client checks again); owner flag `ad_rewards.hero_enabled` (default OFF,
   o2-admin `/owner/ads`); home only, and only while home is the visible route;
   collapses on input focus / keyboard / once a chat starts (the slot is unmounted
   and the `NativeAd` disposed); refresh >= `max(60 s, pricing.home_hero.refresh_sec)`;
   no fill / timeout 12 s / offline / not linked / less than 240 dp of room -> the normal
   logo block; one AdMob ad on home: `HomeAdGuard.heroShowing` -> Discover sends
   `hero_ad=1` and the server drops its ADMOB card.
6. Units: Integrations → AdMob gets a new non-secret field **"Native unit ID (home
   hero)"** (`native_unit`). Until it is set (and `configured`), only Google's TEST native
   unit `ca-app-pub-3940256099942544/2247696110` is used, and only in debug/QA test mode.

## B — ML Kit on-device reading (pubspec only, no manifest change)

```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@
+  # h1-home: image in chat — on-device text (Latin) + image labels, free/offline.
+  # Pin the exact versions at apply time (>= 2 weeks old, resolves with the tree).
+  google_mlkit_text_recognition: <pin, 0.15.x line>
+  google_mlkit_image_labeling: <pin, 0.14.x line>
```
- Licences: the Flutter plugins are MIT (flutter-ml/google_ml_kit_flutter); the ML Kit
  SDKs are under the Google ML Kit Terms of Service (free, commercial use allowed;
  on-device, no data sent to Google for these APIs).
- Size: bundled Latin text model + base image-labeling model ≈ 4–6 MB per ABI.
  Do NOT add the Chinese/Devanagari/Japanese/Korean script dependencies.
- minSdk: plugins need 21+; we are 26.
- Then `cp .phaseB/pending_native/h1/mlkit_on_device_vision.dart.pending
  app/lib/chat_vision/mlkit_on_device_vision.dart` and in `on_device_vision.dart`:
  ```diff
  -OnDeviceVision createOnDeviceVision() => const UnavailableOnDeviceVision();
  +OnDeviceVision createOnDeviceVision() => MlKitOnDeviceVision();
  ```
  (add `import 'mlkit_on_device_vision.dart';`). Lazy: recognisers are created on the
  first photo. The photo is written to the app's temp folder only for the ML Kit call
  and deleted right after (ML Kit's Flutter API reads a file path).

### Bangla script — checked honestly
ML Kit Text Recognition v2 supports **Latin, Chinese, Devanagari, Japanese and Korean**
only. **Bengali script is NOT supported on-device.** What the build does about it:
- the on-device card says so plainly ("The phone reads English text only. Bangla text is
  read in the detailed answer");
- the detailed (cloud) answer — Claude / OpenAI / Gemini vision — reads Bangla.

Honest on-device alternative for Bangla, if the owner wants it later (NOT in this
proposal, needs its own review): Tesseract OCR with the `ben` model from
`tessdata_fast` (Apache-2.0, ~1–2 MB, downloaded on first use, not bundled) through a
Flutter Tesseract plugin (verify the plugin's licence + maintenance at that time).
Accuracy on phone photos of packaging is clearly lower than the cloud answer.

## C — backend live-install steps (main session)
- The Claude vision adapter uses the official `anthropic` Python SDK (lazy import, same
  as `core/ai.py`). It is **not installed in `~/assisto/.venv`** today (also true for
  `core/ai.py`'s Claude path): `~/assisto/.venv/bin/pip install anthropic` before the
  owner connects "Claude vision". Without it the provider fails honestly
  (`sdk_missing` -> "server didn't respond, try again", funds kept / refunded after 3).
  OpenAI and Gemini vision use `requests` (already installed).
- No migration (reuses `PhotoStudioJob` / `PhotoAdTicket` with `feature="chat_vision"`).
- Owner setup: Integrations → "Claude vision (image in chat)" (API key, model — default
  `claude-sonnet-5-5` —, cost per image USD), or OpenAI / Gemini vision. `/admin/pricing`:
  `chat_vision` block (enabled, free_detailed_per_day=1, min_ads=2, max_ads=3,
  max_image_kb=4096, provider) + action `chat_vision_image` (provider_cost, credits) +
  `home_hero.refresh_sec` (>= 60). Hero on/off + muted: `/owner/ads` (o2-admin
  `ad_rewards.hero_enabled` / `hero_start_muted`).
