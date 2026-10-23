# D1 — Photo Studio "on-device enhance failed": root cause (23 Oct 2026)

## Device + session
- **Device:** very likely the owner's **Realme 9i** (ColorOS / Android 13, Snapdragon 680, arm64).
  No device model is stored server-side, so this is inferred from the owner's phone on record —
  from now on every Photo Studio failure report carries the model + Android version (below).
- **Build:** 202 (published 23 Oct 09:33 UTC).
- **What the server saw** (nginx, owner account = superuser, plan **free**, 0 credits):
  `11:17:37 GET /photo-studio/config 200` → 58 s later
  `11:18:35 POST /photo-studio/jobs 201` (an `enhance_hd` export job, funding `ads`, 2 ads needed) →
  `11:18:35 POST /photo-studio/jobs/1/unlock 402` → nothing else (no ad-ticket, no credits).
  **No phone has EVER requested `/photo-studio/model/<file>`** although the live config has offered
  the Real-ESRGAN model since 22 Oct 11:37. The crash-report table was empty.

## Error — three stacked failures, none of them a crash
1. **The AI step was silently never offered for real camera photos (the main cause).**
   `StudioEnhanceEngine.aiEligible()` returned *false* for any photo whose long edge is
   > 1600 px (`aiMaxSourceLong`), and the screen only shows the "AI restore & upscale" switch when
   `aiEligible` is true. A Realme 9i camera photo is 4080×3060 (50 MP mode 8160×6120), so the
   switch never appeared, the model was never downloaded (nginx: 0 requests), and "Enhance" ran
   only the classical tone/denoise pass on the 1 024 px free preview — a barely visible change,
   i.e. "enhance failed" from the owner's point of view.
2. **Save was a dead end.** Export → `unlock` 402 → the funding sheet offered "Watch 2 ads", but this
   build's ad bridge is `NoopPhotoAdBridge` (AdMob not linked; server `ads_configured=false`) and the
   owner's account is on the free plan with 0 credits. Nothing could succeed; the owner closed the sheet.
3. **Nothing was reported.** Every failure path in `ps_controller.dart` / `ps_enhance.dart` was a bare
   `catch (_)`; native errors came back as free text and were dropped → Owner Admin → App errors empty.

## Ruled out (checked, not guessed)
- **Native side of build 206's APK** (`apk_public/.../assisto-part7-build206.apk`, dexdump):
  `libonnxruntime.so` + `libonnxruntime4j_jni.so` + ML Kit `libface_detector_v2_jni.so` are present for
  arm64-v8a, armeabi-v7a and x86_64; `ai.onnxruntime.*` is kept by ProGuard; R8 folded the
  `capabilities` answer to constants `upscale=true, faces=true` — the probe could not fail on the phone.
- **Model input shape:** the ONNX is FIXED 1×3×144×144 and both Dart (`tile: 144`) and Kotlin
  (`side = tile`, useful 128 + 2×8 pad) feed exactly 144 — consistent. The "Got 160 Expected 144"
  error the integrator hit was in a Python call, not the app. Now guarded anyway (fix 4).
- Storage: the model goes to `getApplicationSupportDirectory()/photo_models` (app-private, no
  permission, fine on ColorOS).

## Fix (branch agent/d1-photo)
1. **AI step for every photo size, sized by a time budget** (`AiPlan.of`, `ps_enhance.dart`): the model
   input is chosen so the AI step fits ~7.5 s at THIS phone's measured speed (first run: 1.1 s/tile
   estimate = 6 tiles; afterwards the real ms/tile from the native result, kept in `perf.json`).
   Big photos work on a smaller copy and the switch says so honestly ("Works on a 1 280 px copy ·
   about 7 s"); it is off by default for big photos, on for small/old ones. Regression tests:
   `p2_photo_test` "d1 root cause …" (a 4080×3060 photo is planned, never skipped).
2. **Gate without a dead button** (`ps_gate_sheet.dart`): when no ad network is linked, "Watch ads" is
   not shown — credits / Premium only, with the honest "ads aren't available yet" note
   (`d1_photo_test` "gate: no ad network linked"). *Owner action:* the owner's own account is on the
   free plan with 0 credits — give it Premium/Business or credits (Owner Admin) or link AdMob, otherwise
   the owner cannot save from Photo Studio either.
3. **Every Photo Studio failure is reported** (`ps_report.dart` → `reportNonFatal('photo_studio.<stage>',
   PhotoStudioFailure(stage, code, model, ep))` → the existing sc1 crash pipe → POST
   /api/v1/client/crash-report). Non-PII only: stage (download / upscale / upscale_tool / segment /
   enhance / tool / server / batch / export / availability), a short code (`http 503`, `sha256`,
   `ort_session: OrtException`, `model_shape`, `oom`, `cancelled` is NOT reported), model version,
   execution provider; the pipe adds device model + Android version (DeviceFacts). The user always gets
   an honest message ("The AI step didn't run on this phone, so the safe enhance was used. The problem
   was reported to us.").
4. **Native error codes + shape check** (`PhotoNativeChannel.kt`): errors are short codes, never a path;
   the session's input shape is checked against the requested tile before the first tile
   (`model_shape`), OOM is caught (`oom`), session creation failures are `ort_session: <Type>`.
5. **Honest progress + cancel:** download %, "AI: part 2 of 6", time left from the measured speed,
   Cancel (native stops after the current tile; nothing kept, nothing charged).

## How verified
- Flutter: `test/d1_photo_test.dart` simulates the failing paths with a fake native layer — native AI
  failure (`ort_session: OrtException`) → classical result + report; `model_shape` → report; download
  503 → report; enhance throwing → report + "Something went wrong"; cancel → no result, no report;
  per-tile progress/ETA; tools; batch; gate. `test/p2_photo_test.dart` updated (AI plan / big photos).
- Kotlin: `PhotoNativeChannel.kt` + `UpscaleTiler.kt` compiled with kotlinc 2.x against
  android-35 `android.jar` + the real `onnxruntime-android 1.23.2` classes.jar (Flutter API stubbed).
- APK 206 inspected with `dexdump` (see "Ruled out").
- **Still needs the owner's phone** (cannot be proven here): the real ms/tile on the Realme 9i and that
  the first Photo Studio error, if any, now appears in Owner Admin → Reports → App errors.
