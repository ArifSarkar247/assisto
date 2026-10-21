# v1-vehicle — native / manifest / gradle proposals

Branch `agent/v1-vehicle`. Nothing in this file is applied on the branch; the
integrator applies each part separately, after a real API-33 launch smoke.

**pubspec: NO new dependency.** Everything reuses packages already in
`app/pubspec.yaml`:
- map: a tile-free `CustomPainter` (`lib/vehicle/route_canvas.dart`) + "Open in
  Maps" (url_launcher). No map SDK, no API key, nothing at launch.
- Bluetooth OBD: our own classic-SPP channel (below), not a plugin. Cheap ELM327
  v1.5 dongles are classic Bluetooth, which BLE plugins (flutter_blue_plus)
  can't talk to. Runtime permission uses the existing `permission_handler`.
- Car Mode: geolocator (foreground stream only while the screen is open),
  url_launcher (navigation intents), camera screen (dashcam), and the existing
  `com.assisto/shopbox` keepScreenOn channel (try/catch; a no-op if absent).
- Optional later (NOT proposed now): `flutter_map` for street tiles needs a
  tile provider we are allowed to use commercially (OSM's public tiles are not
  for app traffic). Owner decision.

## Part 1 — register the OBD Bluetooth channel (MainActivity.kt)

New file already on the branch (compiles on its own, unused until registered):
`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/vehicle/ObdBtChannel.kt`.
Lazy: registering a MethodChannel handler is free; the Bluetooth adapter is only
touched when Dart calls it from the OBD screen. All I/O on one background
thread, every call try/catch. No service, no receiver, no ContentProvider, no
WorkManager. If this part is NOT applied, the OBD screen says "Bluetooth OBD
isn't available on this app version" (MissingPluginException is caught) —
nothing crashes.

(If a2-cctv's `ShopBoxChannel.register(...)` line is applied first, put this
line next to it; order doesn't matter.)

```diff
--- a/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
+++ b/app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt
@@ -15,6 +15,7 @@
 import io.flutter.embedding.android.FlutterActivity
 import io.flutter.embedding.engine.FlutterEngine
 import io.flutter.plugin.common.MethodChannel
+import com.assisto.assisto.vehicle.ObdBtChannel
 
 /**
  * Hosts the #80 lost/stolen device-admin MethodChannel.
@@ -48,6 +49,9 @@
 
     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
         super.configureFlutterEngine(flutterEngine)
+        // v1-vehicle: ELM327 OBD over classic Bluetooth. Registering is free;
+        // the adapter is only touched when Dart calls it from the OBD screen.
+        try { ObdBtChannel.register(flutterEngine, this) } catch (_: Throwable) {}
         MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
             .setMethodCallHandler { call, result ->
                 when (call.method) {
```

## Part 2 — Bluetooth permissions (CI manifest patch in android.yml)

The manifest is generated in CI, so the permission lines go into the
"Patch manifest" step. `BLUETOOTH_SCAN` is deliberately NOT requested: we only
list already-bonded devices (the user pairs the dongle once in Android
settings), and `cancelDiscovery()` is only called on Android <= 11.

```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@ -144,7 +144,13 @@
               '\n    <uses-permission android:name="android.permission.health.READ_SLEEP"/>'
               '\n    <uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>'
               # #80 lost/stolen — alarm vibration
-              '\n    <uses-permission android:name="android.permission.VIBRATE"/>\n'
+              '\n    <uses-permission android:name="android.permission.VIBRATE"/>'
+              # v1-vehicle: ELM327 OBD dongle over classic Bluetooth (bonded
+              # devices only, we never scan). CONNECT is a runtime permission on
+              # 12+, requested lazily from the OBD screen; legacy pair <= 11.
+              '\n    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>'
+              '\n    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>'
+              '\n    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>\n'
           )
           if 'android.permission.INTERNET' not in s:
               s = re.sub(r'(<manifest[^>]*>)', r'\1' + perms, s, count=1)
```

Smoke expectation: app launches unchanged (no new startup code). Open My
Vehicles -> Live tracking -> any tracker -> Car health (OBD) -> "Read dongle":
Android 12+ shows the "Nearby devices" prompt; without a paired dongle the
screen shows the honest "No paired Bluetooth devices" message.

## Not proposed / not needed
- No foreground service, no background location: Car Mode trip logging is
  foreground-only (stated on screen). Head-unit theft protection is impossible
  without a hardware tracker (stated on screen).
- No new `<queries>`: navigation uses `google.navigation:` / https maps VIEW
  intents, already covered by the existing VIEW query.
