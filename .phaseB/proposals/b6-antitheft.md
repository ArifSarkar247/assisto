# Proposal — b6-antitheft (native always-on Lost/Stolen engine)

The integrator applies these. Native Kotlin files under
`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/antitheft/` and the
one-line channel registration + `onPasswordFailed` hook are already committed on
`agent/b6-antitheft` (they only ADD files / add one registration line, nothing
runs at launch). Below is everything that touches the SHARED build files
(AndroidManifest patch in `.github/workflows/android.yml`, Gradle, pubspec).

Apply ONLY after a real API-33 launch smoke passes (owner rule: native builds
are not publish-on-cancel). Nothing here runs at app launch, on a
ContentProvider, via WorkManager, or on boot. On BOOT_COMPLETED the receiver
only queues a 'boot' event (if protection was on); it never starts the
service, because a location FGS started from the background can throw in
startForeground on Android 14+ and take the process down. The engine resumes
when the owner opens the Always-on protection screen.

---

## 1. AndroidManifest permissions (`.github/workflows/android.yml`, `perms` string)

All already present and reused as-is (no NEW permission is required):
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `POST_NOTIFICATIONS`,
`WAKE_LOCK`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `CAMERA`,
`RECEIVE_BOOT_COMPLETED`, `VIBRATE`.

Deliberately NOT requested (honest minimal scope, Play-policy friendly):
- **READ_PHONE_STATE** — not needed. The SIM carrier name is read via
  `TelephonyManager.simOperatorName`, which needs no permission. The SIM phone
  NUMBER is not readable by a normal app on modern Android, so we never try.
- **ACCESS_BACKGROUND_LOCATION** — not needed. We read the OS's cached
  last-known fix on each heartbeat (foreground service, `foregroundServiceType=
  location`); we do NOT run a continuous background GPS loop. This avoids the
  Play background-location review and saves battery.

The foreground-service type is `location` (justification: the service's core
job is reporting the lost phone's last location to the owner/family; the
persistent notification is always shown). Play's foreground-service and
location-permission declarations in the console must say exactly this.

No permission diff is required. If the integrator prefers to make the
`location` FGS type explicit for Android 14, the existing
`FOREGROUND_SERVICE_LOCATION` already covers it.

## 2. AndroidManifest components (`native_components` string in android.yml)

Append INSIDE `<application>` (next to the existing device-admin receiver), in
the same `native_components` block the manifest patch writes:

```python
    # ---- b6-antitheft: always-on Lost/Stolen engine ----
    # Opt-in foreground service (location type: it reports the lost phone's
    # last location; a permanent notification is always shown). Started ONLY
    # from Dart after the user turns protection on; never at launch or boot.
    '\n        <service android:name="com.assisto.assisto.antitheft.AntiTheftService"'
    ' android:foregroundServiceType="location"'
    ' android:exported="false"/>'
    # ACTION_SHUTDOWN (best-effort last location) + BOOT_COMPLETED (queues a
    # 'boot' event only; starts nothing). Does no heavy work; cannot block boot.
    '\n        <receiver android:name="com.assisto.assisto.antitheft.ShutdownReceiver"'
    ' android:exported="false">'
    '\n            <intent-filter>'
    '\n                <action android:name="android.intent.action.ACTION_SHUTDOWN"/>'
    '\n                <action android:name="android.intent.action.QUICKBOOT_POWEROFF"/>'
    '\n                <action android:name="android.intent.action.BOOT_COMPLETED"/>'
    '\n                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>'
    '\n            </intent-filter>'
    '\n        </receiver>'
```

Guard it like the others so re-runs are idempotent, e.g. extend the existing
`if '.AssistoWidgetProvider' not in s:` insert, or add a dedicated
`if 'antitheft.AntiTheftService' not in s:` block that inserts before
`</application>`.

Honest broadcast-delivery note (Android 8+): most IMPLICIT broadcasts
(airplane mode, connectivity, SIM state, battery-low) are delivered only to
RUNTIME-registered receivers — so the service registers those itself while it
runs (`AntiTheftService.registerReceivers`). The manifest receiver above is
only for `ACTION_SHUTDOWN` and `BOOT_COMPLETED`, which are still allowed for
manifest receivers. `ACTION_SHUTDOWN` is best-effort (a forced/battery-dead
power-off sends no broadcast — covered by the server "went dark" alert and the
brand lock).

## 3. Gradle — CameraX (OPTIONAL; only for the intruder photo)

`app/android/app/build.gradle` `dependencies { }` — add (pin exact versions,
all Apache-2.0):

```gradle
    // b6-antitheft: front-camera intruder photo (no preview). Loaded by
    // reflection in IntruderCamera.kt so the app compiles/runs WITHOUT it;
    // add it only if the intruder-photo feature is shipped.
    implementation "androidx.camera:camera-core:1.3.4"
    implementation "androidx.camera:camera-camera2:1.3.4"
    implementation "androidx.camera:camera-lifecycle:1.3.4"
```

LAUNCH-ANR NOTE: CameraX pulls `androidx.startup`. The manifest patch ALREADY
removes `androidx.startup.InitializationProvider` (`tools:node="remove"`), which
keeps CameraX lazy-initialised — do not re-add that provider.

If CameraX is NOT added, `IntruderCamera.available()` returns false and the app
honestly records a photo-less `failed_unlock` event and tells the user the
camera-in-background limit. **Recommendation:** ship WITHOUT CameraX in the
first native build (smaller, lower ANR risk); add it in a later build once the
base engine has a green API-33 smoke. The feature is honest either way.

## 4. pubspec.yaml — NONE

No new Dart dependency. The engine bridge uses `MethodChannel`; the UI reuses
`http`, `provider`, `intl`, `geolocator` (already present).

## 5. Migration / routes (already in the branch)

- `core/migrations/0054_b6_antitheft.py` depends on `0053_w1_webphoto`.
- Routes appended in `core/urls.py` under `# ---- b6-antitheft ----`.
- `python3 tools/route_check.py --report-only` stays at 0 problems.
- `makemigrations --check` is clean.

## 6. Optional server setting

`ANTITHEFT_PHOTO_KEY` (env): a dedicated key for encrypting intruder photos at
rest. If unset, the key is derived from `SECRET_KEY` (works out of the box).
Set it only if the owner wants photo encryption independent of `SECRET_KEY`
rotation. No secret is committed.
```
