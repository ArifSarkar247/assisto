# Proposal a2-cctv — CCTV Part 4 (Shop Box live view + Shop Box mode)

Apply in this order, each behind a real API-33 launch smoke on CI.

## 1. pubspec: `flutter_webrtc: ^1.6.2` (ALREADY on branch `agent/a2-cctv`)

Resolved to `1.6.2+hotfix.4` (published 2026-10-07). Shared constraint with
a4-remote, recorded in `/home/ubuntu/wt/SHARED_DEPS.md`.

Why: owner live view (viewer) and Android Shop Box mode (sender) — P2P WebRTC,
TURN fallback. Dart side is LAZY: the only file importing it is
`lib/screens/shop_live_rtc.dart`, imported `deferred as` by the live screen and
Shop Box mode; nothing calls it at launch.

Native facts checked in the plugin source (please re-check on the smoke):
* `FlutterWebRTCPlugin.onAttachedToEngine` runs at engine start (every plugin
  does). It only builds an `AudioSwitchManager` (stores `AudioManager` +
  a list), a `MethodCallHandlerImpl` (stores refs) and the channels. The
  PeerConnectionFactory / libwebrtc native init is LAZY (`initialize()` on the
  first `createPeerConnection`/`getUserMedia`). No ContentProvider, no
  WorkManager, no service. Still: **launch-ANR smoke required** (ColorOS).
* Plugin `minSdkVersion 21` (app forces 26), `compileSdkVersion 36`.
* Ships `consumerProguardFiles 'proguard-rules.pro'` (keeps `org.webrtc.**`,
  `com.cloudwebrtc.webrtc.**`) — R8 release builds are covered.
* Gradle deps: `io.github.webrtc-sdk:android:150.7871.01` (Maven Central) and
  `com.github.davidliu:audioswitch` from **jitpack.io** — the plugin adds the
  jitpack repo itself via `rootProject.allprojects`; if CI's settings ever set
  `FAIL_ON_PROJECT_REPOS`, add `maven { url "https://jitpack.io" }` there.
* APK size: libwebrtc adds roughly 10-15 MB per ABI (arm64 split ~12 MB).

## 2. Manifest permissions (CI manifest patch, android.yml + smoke.yml)

`flutter_webrtc`'s own manifest is EMPTY, so the app must declare:
* `ACCESS_NETWORK_STATE` — libwebrtc's NetworkMonitor uses ConnectivityManager;
  without it `createPeerConnection` can throw a SecurityException on some
  devices (we catch it in Dart, but live view would never work).
* `CHANGE_NETWORK_STATE` — network binding for ICE on multi-network phones.
* `MODIFY_AUDIO_SETTINGS` — the plugin's audio routing (we send/receive video
  only, but the plugin touches AudioManager on peer init).

Already present (no change): INTERNET, CAMERA, RECORD_AUDIO, WAKE_LOCK.
NOT needed: no foreground service, no `FOREGROUND_SERVICE_CAMERA` — Shop Box
mode deliberately runs only while its screen is open (honest guidance in the
UI). No WorkManager, no boot receiver.

## 3. MainActivity: register the Shop Box helper channel

New Kotlin file (already on branch, compiled even before this diff, unused):
`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/shopbox/ShopBoxChannel.kt`
— channel `com.assisto/shopbox`: `keepScreenOn({on})` (FLAG_KEEP_SCREEN_ON
while Shop Box mode is ON) and `isCharging()` (sticky ACTION_BATTERY_CHANGED,
no permission, no receiver kept). Every call is try/catch. Until this line is
applied, Dart gets MissingPluginException, catches it, and shows the
"set screen timeout to the longest" tip instead.

## Exact diffs

```diff
diff -ru a/.github/workflows/android.yml b/.github/workflows/android.yml
--- a/.github/workflows/android.yml	2026-10-21 04:44:28.647275138 +0000
+++ b/.github/workflows/android.yml	2026-10-21 04:44:38.675772675 +0000
@@ -103,6 +103,10 @@
               '\n    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>'
               '\n    <uses-permission android:name="android.permission.RECORD_AUDIO"/>'
               '\n    <uses-permission android:name="android.permission.CAMERA"/>'
+              # CCTV Part 4 live view (flutter_webrtc): network monitor + audio routing
+              '\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>'
+              '\n    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>'
+              '\n    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>'
               '\n    <uses-permission android:name="android.permission.READ_MEDIA_IMAGES"/>'
               '\n    <uses-permission android:name="android.permission.READ_MEDIA_VIDEO"/>'
               '\n    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>'
diff -ru a/.github/workflows/smoke.yml b/.github/workflows/smoke.yml
--- a/.github/workflows/smoke.yml	2026-10-21 04:44:28.654964264 +0000
+++ b/.github/workflows/smoke.yml	2026-10-21 04:44:38.676002190 +0000
@@ -56,6 +56,10 @@
               '\n    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>'
               '\n    <uses-permission android:name="android.permission.RECORD_AUDIO"/>'
               '\n    <uses-permission android:name="android.permission.CAMERA"/>'
+              # CCTV Part 4 live view (flutter_webrtc): network monitor + audio routing
+              '\n    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>'
+              '\n    <uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>'
+              '\n    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>'
               '\n    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>'
               '\n    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>\n'
           )
diff -ru a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
--- a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt	2026-10-21 04:44:28.669819164 +0000
+++ b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt	2026-10-21 04:44:38.676191768 +0000
@@ -48,6 +48,9 @@
 
     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
         super.configureFlutterEngine(flutterEngine)
+        // CCTV Part 4 Shop Box mode: keep-screen-on + charging state. Handler
+        // registration only — nothing runs until Dart calls it (lazy).
+        com.assisto.assisto.shopbox.ShopBoxChannel.register(flutterEngine, this)
         MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
             .setMethodCallHandler { call, result ->
                 when (call.method) {
```

## Smoke checklist for the integrator
1. Cold launch on API 33 (and the owner's Realme 9i if possible): no ANR, no
   crash with flutter_webrtc registered.
2. Open Shop Box → Cameras → a camera → Live view with the device offline:
   honest "device is offline" message (no spinner).
3. Shop Box mode on a second phone: pair with a camera token, switch ON,
   wave a hand in the cash zone after hours → owner gets "Please check".
4. Live view P2P on the same Wi-Fi; then with the viewer on mobile data
   (relay path) — the chip should switch to "Relayed (uses credits)".
