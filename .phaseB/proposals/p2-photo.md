# p2-photo — Photo Studio made real (round 2, items 4a–4d)

Branch `agent/p2-photo` (worktree `/home/ubuntu/wt/p2-photo`). Not pushed.

## What is real now

| Item | What the user gets | Where |
|---|---|---|
| 4a(1) instant enhance | Classical pipeline on every phone, offline: grey-world white balance, 0.5/99.5 % levels + gamma lift for dark photos, guided-filter denoise (luma) + chroma blur, 8×8 CLAHE, skin smoothing ONLY where skin colour meets an ML Kit face ellipse, thresholded unsharp mask (less on skin), vibrance. Light / Natural / Strong = one parameter table (`ClassicParams`). Runs in a background isolate, in 256-row strips (bounded memory). Per-pixel / small local filters only → face geometry cannot move. | `app/lib/photo_studio/ps_classic.dart`, `ps_enhance.dart` |
| 4a(2) AI restore & upscale | Optional switch, shown only for small/old photos (long edge ≤ 1600 px) when the server publishes a licence-cleared model AND the phone has the native runtime + face check. Real-ESRGAN realesr-general-x4v3 (denoise 0.5 blend) via ONNX Runtime 1.23.2, NNAPI fp16 if it is faster *and* matches the CPU on a probe tile (verdict stored per model), else CPU/XNNPACK; static 144 px tiles (128 + 8 px reflect pad), progress events, cancel. Output keeps the ORIGINAL colours (luminance detail only) and FACE-LOCK: inside face ellipses only 25 % of the AI detail (a general SR model repaints small eyes/skin — see eval). Then the identity check (4c) on the result: fail → the AI result is thrown away and the classical result is shown with a note. Model downloaded once from our server (resumable HTTP Range, sha256-verified, `.ok` marker → offline + instant next time). | `ps_enhance.dart`, `ps_model.dart`, `ps_native.dart`, Kotlin `photo/PhotoNativeChannel.kt`, `photo/UpscaleTiler.kt`; backend `core/photo_models.py` |
| 4b FLAG_SECURE | Free-user Photo Studio: `FLAG_SECURE` set on the activity window when the studio opens, cleared when the user leaves (controller dispose). Note "Screenshots are blocked on this preview." only when the platform confirmed the flag. psSecureOff removed. | `PhotoNativeChannel.kt` (`com.assisto/photo_secure`), `ps_engines.dart ChannelSecureScreen` |
| 4c identity check | ML Kit (bundled, offline) 8 landmarks per face; Procrustes (similarity) alignment AFTER→BEFORE, residual in inter-ocular units; same iff RMS ≤ 0.045 and every point ≤ 0.07 IOD; face lost / new face → different; incomplete landmarks or failed detection → cannot verify (= not used). Used for the AI step and for cloud prompt edits of people. The classical step needs none (geometry-preserving). The "people in this photo" switch is now pre-set from what ML Kit actually finds. | `ps_identity.dart`, `ps_engines.dart IdentityGuard`, `PhotoFaces.kt` |
| 4d prompt edits | No cloud image-AI provider ready → the whole prompt section (and generate-without-photo) is HIDDEN for users; the owner (superuser, `is_owner` from `/photo-studio/config`) sees one small note "Add a key in Admin → Integrations". With a key: unchanged ps1 flow. | `photo_studio_screen.dart`, `photo_studio_service.client_config` |
| showpieces | psEnhanceNotInBuild, psIdentityMissing, psSecureOff are no longer referenced (test enforces it). Integrator: delete the 3 keys from both ARBs (listed in `.phaseB/up_p2_arb.json` `_remove`). | |

## Numbers (measured here — NOT a phone)

See `.phaseB/photo_studio_eval/README.md` (20 licence-clean photos, thumbnails, method).
Real mid-range-phone timing: **to be measured** (steps below, Bangla).

## Integrator steps

1. **Merge** `agent/p2-photo`. ARB: `python3 ~/assisto/bin/arb_apply.py .phaseB/up_p2_arb.json`
   (11 keys, en+bn) **and delete** `psEnhanceNotInBuild`, `psIdentityMissing`, `psSecureOff`
   from `app_en.arb` + `app_bn.arb`.
2. **Model on the server** (seconds, light, no torch):
   ```
   ~/assisto/.venv/bin/pip install numpy==1.26.4 onnx==1.16.2
   ~/assisto/.venv/bin/python tools/photo_model/convert_realesrgan.py --out backend/core/photo_models
   ```
   → `realesr_general_x4v3_dn050_t144.onnx` (4 858 595 B, sha256 `82ac4e3e35b7fc862e9c55e9857ca0c8792d7e9b28ae8d584e89c27c65735ecf` — deterministic) + `manifest.json` (`licence_cleared: true`). `*.onnx` is git-ignored there; alternatively set `PHOTO_MODEL_DIR` to a data dir outside the repo. Check: `curl -sI https://api.lifeassisto.com/api/v1/photo-studio/model/realesr_general_x4v3_dn050_t144.onnx` → 200, `Accept-Ranges: bytes`. Caddy/nginx: nothing to change (Django serves Range itself; if a proxy buffers, fine).
   No migration. Route block `# ---- p2-photo ----` in `core/urls.py` (inside the ps1 block).
3. **android.yml** — already applied in this branch, marked `---- p2-photo ----`, step
   "Photo Studio native deps (p2-photo)" just before "Build release APK":
   - `implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")` — guarded by
     `if "onnxruntime-android" not in s`, the SAME version/guard as k1-wake: merge both and the
     app still has ONE runtime;
   - `implementation("com.google.mlkit:face-detection:16.1.7")` (bundled model);
   - manifest: `<provider android:name="com.google.mlkit.common.internal.MlKitInitProvider" … tools:node="remove"/>`
     (no startup ContentProvider; `PhotoFaces.kt` calls `MlKit.initialize()` on first use).
   - `proguard-rules.pro`: `-keep class ai.onnxruntime.** { *; }` (same as k1-wake; duplicate harmless).
   - `MainActivity.kt`: one try/catch `PhotoNativeChannel.register(...)` (handlers only).
   APK size: ORT ≈ +8 MB/arm64 (shared with k1-wake), ML Kit bundled face ≈ +8.5 MB .so +
   ~3 MB models (uncompressed; arm64-only build). Lighter alternative if size matters:
   `com.google.android.gms:play-services-mlkit-face-detection:17.1.0` (unbundled, model via
   Play services — needs network once + GMS; same API, no code change).
4. **CI**: run the normal Android build + API-33 launch smoke (nothing new at launch). Then the
   real-phone checks below.
5. Kotlin was compile-checked here with kotlinc 2.x against android-35 + the exact AARs
   (ORT 1.23.2, ML Kit 16.1.7, flutter embedding of this engine) — see report; tiling + face-lock
   merge checked on a desktop JVM against the Python mirror (`tools/photo_model/kotlin_parity`).

## Real-phone checklist (Bangla) — Photo Studio p2

PS-1. Photo Studio খুলুন → একটি ছবি নিন → Natural → "Enhance"। স্টপওয়াচে সময় লিখুন (ছবির মাপ সহ, যেমন ৪০০০×৩০০০)। আগে/পরে স্লাইডার টেনে দেখুন: রং স্বাভাবিক, মুখের গড়ন একই।
PS-2. Light / Strong একই ছবিতে — Light প্রায় বোঝা যায় না, Strong স্পষ্ট কিন্তু প্লাস্টিকের মতো নয়।
PS-3. ছোট/পুরোনো ছবি (WhatsApp থেকে, ১৬০০ px-এর কম) নিন → "AI দিয়ে রিস্টোর ও বড় করা" সুইচ চালু → প্রথমবার ডাউনলোড (~৪.৬ MB) প্রগ্রেস দেখা যায় → Enhance। সময় লিখুন (সেকেন্ড) — এটাই "মাঝারি ফোনে AI সময়"।
PS-4. Wi-Fi/ডেটা বন্ধ করে অ্যাপ বন্ধ-খুলে আবার ৫৩ — ডাউনলোড ছাড়াই চলবে (অফলাইন)।
PS-5. ডাউনলোডের মাঝখানে ইন্টারনেট বন্ধ → "AI মডেল ডাউনলোড হয়নি…" + আবার চেষ্টা → ইন্টারনেট চালু করে আবার চেষ্টা: শুরু থেকে নয়, যেখানে থেমেছিল সেখান থেকে চলবে।
PS-6. মানুষের ছবিতে AI চালালে মুখ হুবহু একই থাকে (চোখের রং, চামড়া)। কোনো ছবিতে "AI-এর ফলাফলে মুখ হুবহু থাকেনি…" এলে স্ক্রিনশট নয়, ছবিটা পাঠান (থ্রেশহোল্ড টিউনিং)।
PS-7. ফ্রি অ্যাকাউন্টে Photo Studio-তে স্ক্রিনশট নিন → কালো/ব্লক হবে, নোট "এই প্রিভিউতে স্ক্রিনশট বন্ধ।" Photo Studio থেকে বের হয়ে অন্য স্ক্রিনে স্ক্রিনশট আবার কাজ করবে। Premium-এ ব্লক নেই।
PS-8. ইমেজ-AI key ছাড়া: সাধারণ ব্যবহারকারী প্রম্পট অংশ দেখবেন না; মালিক (owner) একটি ছোট নোট "Admin → Integrations-এ একটি key যোগ করুন" দেখবেন।
PS-9. অ্যাপ খোলার সময় কোনো ধীরগতি/ক্র্যাশ নেই (ML Kit/ORT শুধু Photo Studio খুললে চালু হয়)।
