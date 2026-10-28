# cashguard — native proposals (integrator applies after a real launch smoke on CI, API 33)

## 1. Register the Guard Box person-model channel (needed for "person check on this phone")

Without this the Guard Box still works, honestly labelled "motion only"
(`guard_box_model.dart` catches the MissingPluginException).
No new dependency: `onnxruntime-android` is already added by android.yml
(Photo Studio step). No permission, no service, no ContentProvider; nothing
runs until Dart calls `detect` from an open Guard Box screen.

```diff
--- a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
+++ b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
@@ override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
         try {
             com.assisto.assisto.journey.JourneyChannel.register(
                 this, flutterEngine.dartExecutor.binaryMessenger
             )
         } catch (e: Throwable) {
         }
+        // cashguard: Guard Box on-device person model ("com.assisto/guardbox").
+        // Handler only — the ORT session is created on the first detect()
+        // from an open Guard Box screen (flag guard_box_mode), never at launch.
+        try {
+            com.assisto.assisto.guardbox.GuardBoxChannel.register(
+                this, flutterEngine.dartExecutor.binaryMessenger
+            )
+        } catch (e: Throwable) {
+        }
```

ProGuard: `-keep class ai.onnxruntime.** { *; }` is already in proguard-rules.pro.

## 2. (NOT applied, phase 2) RTSP on the Guard Box phone

Guard Box v1 reads the camera's HTTP snapshot (ONVIF GetSnapshotUri /
Hikvision ISAPI / Dahua CGI). RTSP-only cameras (TP-Link Tapo) need a
native decoder: `androidx.media3:media3-exoplayer-rtsp` (Apache-2.0, the
same media3 version video_player_android already pulls) rendering into an
`ImageReader` surface, sampled at 2 fps. Not written yet: it cannot be proven
without a real phone + camera and adds crash surface on old phones. Decide
after the first real Guard Box run.

## 3. Play policy check (no change needed)

Guard Box runs only while its screen is open and the phone is plugged in
(FLAG_KEEP_SCREEN_ON via the existing com.assisto/shopbox channel) — no
foreground service, so no FGS type declaration (camera / dataSync /
mediaProcessing) is needed. It reads a NETWORK stream, never the phone's
camera, so no CAMERA permission is requested for Guard Box.
