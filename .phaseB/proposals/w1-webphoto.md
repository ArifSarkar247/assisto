# w1-webphoto — native / live-install steps (for the integrator)

## 1. `.github/workflows/android.yml` (APPLIED on branch, minimal)

One App Link intent-filter appended inside `<activity android:name=".MainActivity">`
by the existing "Patch manifest" python step (same style as the other blocks,
idempotent guard on `android:pathPrefix="/photo/app"`):

```xml
<intent-filter android:autoVerify="true">
    <action android:name="android.intent.action.VIEW"/>
    <category android:name="android.intent.category.DEFAULT"/>
    <category android:name="android.intent.category.BROWSABLE"/>
    <data android:scheme="https" android:host="lifeassisto.com" android:pathPrefix="/photo/app"/>
</intent-filter>
```

Why: the website's "Get it in the Assisto app" button must open the SAME photo
in the app. No plugin, no Kotlin, no MainActivity change: Flutter's built-in
deep linking (`flutter_deeplinking_enabled` defaults to `true` since 3.27, we
are on 3.47.7) hands the URL to Dart:
* cold start -> `PlatformDispatcher.defaultRouteName` = full URL ->
  `_Root` pushes `WebPhotoLinkScreen` on top of home after the first frame
  (`WebPhotoLink.maybeOpenColdStart`, crash-guarded, once per process);
* app already running -> `onNewIntent` -> `pushRouteInformation` ->
  `MaterialApp.onGenerateRoute` -> `WebPhotoLink.route` (only `/photo/app`,
  every other name returns null exactly as before).
Nothing runs at launch unless the launch intent carries that URL.

Launch-smoke note: the filter only adds a VIEW/BROWSABLE entry; LAUNCHER
start is unchanged. Please include it in the next API-33 smoke run.
Optional manual check on CI emulator:
`adb shell am start -a android.intent.action.VIEW -d "https://lifeassisto.com/photo/app?t=test" com.assisto.assisto`
(expected: app opens, "link expired" message for a fake token).

## 2. `assetlinks.json` (served by Django, needs one env var)

`GET https://lifeassisto.com/.well-known/assetlinks.json` is now a Django
route (`web.views.assetlinks`). It returns `[]` until the release-certificate
fingerprint is configured. Set in the server env (`backend/.env` or
`~/.assisto_secrets.env`; the fingerprint is PUBLIC, not a secret):

```
ANDROID_CERT_SHA256=AA:BB:...:FF     # SHA-256 of the permanent release signing cert
```

Get it from the signed APK: `apksigner verify --print-certs app-release.apk`
("Signer #1 certificate SHA-256 digest", add colons, upper-case) or
`keytool -list -v -keystore <release.jks> -alias <alias>`.

Resulting body:
```json
[{"relation": ["delegate_permission/common.handle_all_urls"],
  "target": {"namespace": "android_app", "package_name": "com.assisto.assisto",
             "sha256_cert_fingerprints": ["AA:BB:...:FF"]}}]
```
nginx must pass `/.well-known/assetlinks.json` to Django (if nginx serves
`/.well-known/` itself, e.g. for ACME, add an exact `location =
/.well-known/assetlinks.json { proxy_pass http://127.0.0.1:8700; }`), served
as `application/json`, HTTP 200, no redirect. Verify:
`https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://lifeassisto.com&relation=delegate_permission/common.handle_all_urls`

Without verification the link still works on Android Chrome: the result page
uses an `intent://…#Intent;scheme=https;package=com.assisto.assisto;S.browser_fallback_url=…;end`
URL (opens the app if installed, else the download page). From other apps
(WhatsApp etc.) an unverified https link opens the browser page
`/photo/app?t=…`, which offers the app button + install instructions.

## 3. Cron (purge after <= 1 hour)

File: `deploy/w1-webphoto/purge_web_photos.cron`
```
*/10 * * * * cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py purge_web_photos >> /home/ubuntu/assisto/logs/purge_web_photos.log 2>&1
```
Also enforced without cron: an expired drop is deleted the moment it is
touched (web `/photo/app` page or the app claim), every new upload sweeps all
expired drops, and a claimed drop is deleted immediately.

## 4. Migration

`core/migrations/0053_w1_webphoto.py` (depends on `0052_ps1_photo_studio`):
one table `core_webphotodrop` (token, preset, image BYTEA, ip_hash,
created_at, expires_at). Re-chain if another 0052 lands first.

## 5. No pubspec / Gradle / MainActivity / plugin changes.
