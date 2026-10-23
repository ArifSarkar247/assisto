# b3-group — native / manifest / dependency changes (integrator)

## 1. Manifest (CI, `.github/workflows/android.yml`) — NOT applied on the branch

Exact diff: `.phaseB/proposals/b3-group-android-yml.diff` (`git apply` checks clean on origin/main).

| Change | Why |
|---|---|
| flutter_foreground_task `ForegroundService` `foregroundServiceType="microphone|location"` → `"microphone|location|mediaProjection"` | Android 10+ only allows MediaProjection (screen capture) while a foreground service **of type mediaProjection** runs; Android 14+ throws `SecurityException` otherwise. The call keeps using the SAME service (CallKeepAlive), restarted with `[microphone, mediaProjection]` only after the user accepted the system "Start sharing?" dialog, and back to `[microphone]` when sharing stops. |
| `<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION"/>` | Android 14+ requirement for that type (normal, install-time permission — no prompt). |

Until it is applied, `CallsChannel.screenShareReady()` (Kotlin) answers **false** (it checks the
declared service type + the permission), so **"Share screen" is hidden** — no crash, no showpiece.
Play Console: the FGS-type declaration form will ask for "mediaProjection — screen sharing
during calls initiated by the user" (video demo: the B3_PROOF screen-share steps).

Launch smoke (API 33, `smoke.yml`) must stay green after applying (nothing new runs at launch).

## 2. Applied on the branch (own area)

| File | Change |
|---|---|
| `app/pubspec.yaml` / `pubspec.lock` | `livekit_client: 2.13.1` (exact; it pins `flutter_webrtc 1.6.2+hotfix.4` = our lock). New transitive packages: asn1lib, connectivity_plus 7.3.1, convert, dart_jsonwebtoken, mime_type, nm, pointycastle, protobuf, sdp_transform. |
| `app/android_overlay/.../calls/CallsChannel.kt` | `screenShareReady()` (above) + `audioOwner(webrtc|livekit)` — see §3. register() sets flutter_webrtc's audio session management back ON. All by reflection / try-catch. |
| `app/android_overlay/app/proguard-rules.pro` | `-keep class io.livekit.plugin.** { *; }` + `-keep class com.paramsen.noise.** { *; }` (LiveKit plugin + its JNI FFT helper under R8). |

## 3. IMPORTANT side effect of livekit_client and how it is neutralised

`io.livekit.plugin.LiveKitPlugin.onAttachedToEngine` (runs at **every** app launch, like every
plugin) calls `AudioSwitchManager.setAudioSessionManagementEnabled(false)` — i.e. it switches OFF
flutter_webrtc's own audio routing for the whole process. Our 1:1 calls (B1 earpiece / speaker /
Bluetooth picker) and the Shop Box live view rely on it. Fix in `CallsChannel.register()`
(called right after plugin registration in `MainActivity.configureFlutterEngine`): turn it back
ON; a group call hands the audio session to LiveKit (`CallNative.audioOwner(livekit: true)`)
only while it is connected and gives it back on disconnect. **Needs the real-phone check in
B3_PROOF step 1 (1:1 route picker still works on a build with LiveKit).**

The plugin otherwise adds no ContentProvider, no service, no receiver, no WorkManager (its
`AndroidManifest.xml` is empty); at attach it creates one idle `HandlerThread`
("LKAudioSwitchThread") and a method channel. Gradle deps: `io.github.webrtc-sdk:android:
150.7871.01` (same as flutter_webrtc), `io.livekit:noise:2.0.0` (FFT for audio visualisers,
unused), `com.github.davidliu:audioswitch` (jitpack, already used by flutter_webrtc).
minSdk 21, compileSdk 36.

## 4. Licences

| Package | Licence |
|---|---|
| livekit-server 1.13.7 (server binary) | Apache-2.0 |
| livekit_client 2.13.1 | Apache-2.0 |
| io.livekit:noise (paramsen noise fork) | Apache-2.0 |
| connectivity_plus, convert, protobuf, asn1lib | BSD-3-Clause |
| dart_jsonwebtoken, pointycastle, sdp_transform, mime_type | MIT |
| nm 0.5.0 (connectivity_plus's Linux-desktop NetworkManager client; not used on Android) | MPL-2.0 (file-level copyleft; unmodified, no obligation beyond keeping its notice) |
