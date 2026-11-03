# k1-wake — native proposal ("Hey Assisto" on openWakeWord / ONNX Runtime)

**Already APPLIED on branch agent/k1-wake (clearly marked `---- k1-wake ----`)** because the
new Kotlin (`OwwEngine.kt`) imports `ai.onnxruntime.*` and would not compile without it.
Integrator: verify on a CI build + API-33 launch smoke before shipping.

## 1. Gradle dependency (android.yml, new step "Add ONNX Runtime (k1-wake wake word)")
- `com.microsoft.onnxruntime:onnxruntime-android:1.23.2` — **MIT** (pom), minSdk 24 (we force 26).
- Released Oct 2025 (> 2 weeks old). arm64 native libs are **16 KB-page aligned**
  (`readelf -lW libonnxruntime.so` → LOAD align 0x4000) → Play 16 KB rule OK.
- Size: libonnxruntime.so 19.3 MB (arm64) / 14.0 MB (armeabi-v7a) uncompressed; expect
  roughly +7–8 MB per ABI download after compression (AAB splits by ABI). Not measured on a
  built APK yet — check the CI APK size diff.
- Nothing initialises at launch: ORT classes load only when WakeWordService starts
  (user enabled "Hey Assisto"). No ContentProvider, no WorkManager.

## 2. Manifest (android.yml native_components)
- `WakeWordService` unchanged: `foregroundServiceType="microphone"`, `exported="false"`.
  FOREGROUND_SERVICE + FOREGROUND_SERVICE_MICROPHONE permissions already present.
- NEW `WakeBootReceiver` (exported=false) for BOOT_COMPLETED / MY_PACKAGE_REPLACED /
  QUICKBOOT_POWERON. It never touches the microphone (Android 14+ forbids a mic FGS from
  boot); it only posts the one-tap "Turn on Hey Assisto again" notification when the user
  had it on. RECEIVE_BOOT_COMPLETED is already declared (a6).
- No new permissions. Auto-pause uses AudioManager mode, AudioRecordingCallback and
  BatteryManager — none needs a permission. No READ_PHONE_STATE.

## 3. R8 (app/android_overlay/app/proguard-rules.pro)
`-keep class ai.onnxruntime.** { *; }` — the AAR ships no consumer rules and its JNI looks up
Java classes by name.

## 4. pubspec
No change (uses existing http, path_provider, permission_handler, url_launcher).

## Exact diff (vs launch @ 0816f7a)
```diff
diff --git a/.github/workflows/android.yml b/.github/workflows/android.yml
index 1eca5aa..6c51b61 100644
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@ -313,11 +313,21 @@ jobs:
               '\n                <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>'
               '\n            </intent-filter>'
               '\n        </activity-alias>'
-              # Opt-in "Hey/Hi Assisto" wake word (never started at launch/boot;
-              # the Porcupine engine itself ships in stage 2, by reflection).
+              # ---- k1-wake ---- Opt-in "Hey/Hi/Ok Assisto" wake word (openWakeWord
+              # on ONNX Runtime). Never started at launch or from boot; the boot
+              # receiver only posts a one-tap "turn on again" notification
+              # (Android 14+ forbids a microphone FGS from BOOT_COMPLETED).
               '\n        <service android:name="com.assisto.assisto.voice.WakeWordService"'
               ' android:foregroundServiceType="microphone"'
-              ' android:exported="false"/>\n'
+              ' android:exported="false"/>'
+              '\n        <receiver android:name="com.assisto.assisto.voice.WakeBootReceiver"'
+              ' android:exported="false">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.intent.action.BOOT_COMPLETED"/>'
+              '\n                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>'
+              '\n                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>'
+              '\n            </intent-filter>'
+              '\n        </receiver>\n'
           )
           if '.AssistoWidgetProvider' not in s:
               s = s.replace('</application>', native_components + '    </application>', 1)
@@ -498,6 +508,27 @@ jobs:
               print("already enabled")
           PY
 
+      # ---- k1-wake ---- ONNX Runtime for the on-device "Hey Assisto" wake word
+      # (WakeWordService/OwwEngine.kt). MIT licence; 1.23.2 native libs are
+      # 16 KB-page aligned (Play requirement, checked with readelf). Adds ~8 MB
+      # per ABI (arm64 / armeabi-v7a split by Play from the AAB). Proposal:
+      # .phaseB/proposals/k1-wake.md
+      - name: Add ONNX Runtime (k1-wake wake word)
+        working-directory: app
+        run: |
+          python3 - <<'PY'
+          import os
+          kts = "android/app/build.gradle.kts"
+          p, is_kts = (kts, True) if os.path.exists(kts) else ("android/app/build.gradle", False)
+          s = open(p).read()
+          if "onnxruntime-android" not in s:
+              s += ('\n\ndependencies {\n    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.2")\n}\n'
+                    if is_kts else
+                    "\n\ndependencies {\n    implementation 'com.microsoft.onnxruntime:onnxruntime-android:1.23.2'\n}\n")
+              open(p, "w").write(s)
+              print("onnxruntime-android 1.23.2 added to", p)
+          PY
+
       - name: Apply google-services Gradle plugin (only when Firebase config exists)
         working-directory: app
         run: |
diff --git a/app/android_overlay/app/proguard-rules.pro b/app/android_overlay/app/proguard-rules.pro
index 5418556..fc8f0ff 100644
--- a/app/android_overlay/app/proguard-rules.pro
+++ b/app/android_overlay/app/proguard-rules.pro
@@ -31,3 +31,8 @@
 -keep class kotlin.coroutines.intrinsics.CoroutineSingletons { *; }
 -keep class kotlin.coroutines.Continuation { *; }
 -keep class com.github.dart_lang.jni_flutter.** { *; }
+
+# ---- k1-wake ---- ONNX Runtime (on-device "Hey Assisto"): its JNI library
+# creates / reads ai.onnxruntime Java objects by name and the AAR ships no
+# consumer rules, so R8 must keep the whole package.
+-keep class ai.onnxruntime.** { *; }
```

## Rollback
Revert the two android.yml hunks + the proguard hunk AND restore the old
`WakeWordService.kt`/delete `OwwEngine.kt` + `WakeBootReceiver.kt` (the Kotlin needs ORT).
