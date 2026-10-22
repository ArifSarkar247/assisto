# Proposal — slot l1-launch (Google Play launch track)

Branch `agent/l1-launch`. The backend (legal pages, app-ads.txt, deletion
tickets) and the Dart `PLAY_STORE` guard are already in the branch and need
no proposal. This file covers what only the integrator may change:

- **A** — `.github/workflows/android.yml`: build + sign a release **AAB** for
  Google Play on every run (artifact `assisto-aab`), as the Play build
  (`--dart-define=PLAY_STORE=true`, no `REQUEST_INSTALL_PACKAGES`).
- **B** — new GitHub Actions secrets for a separate Play **upload key**
  (optional; until they exist the AAB is signed with the existing release key).
- **C** — manifest: register the Health Connect privacy-policy activity
  (`legal/PrivacyPolicyActivity.kt`, already in the overlay). Health Connect
  will not show its permission dialog without it.
- **D** — Play-policy findings that need an owner/integrator decision (no diff).

Nothing here changes the shipped website APK: the APK build, its signing step
and the launch smoke stay exactly as they are. Part A runs AFTER the APK is
uploaded, with `continue-on-error: true`, so an AAB problem can never block an
APK release. Apply A first, check one CI run, then remove `continue-on-error`.

---

## A — Signed release AAB (Google Play)

Insert after the existing `Upload APK artifact` step of job `build-apk`
(before `launch-smoke-test:`):

```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@
       - name: Upload APK artifact
         uses: actions/upload-artifact@v4
         with:
           name: assisto-apk
           path: app/out/*.apk
           retention-days: 14
 
+      # ---- l1-launch: Google Play release bundle ----
+      # Runs AFTER the website APK is built, signed and uploaded, so nothing
+      # above changes. It is the PLAY build: PLAY_STORE=true turns the in-app
+      # updater off (Play forbids self-updates) and REQUEST_INSTALL_PACKAGES is
+      # removed from the merged manifest. Signed with the Play UPLOAD key when
+      # the PLAY_UPLOAD_* secrets exist, else with the existing release key
+      # (see owner_actions/PLAY_APP_SIGNING.md for which to choose).
+      - name: Build + sign release AAB (Google Play)
+        id: aab
+        continue-on-error: true      # first rollout: never block the APK release
+        working-directory: app
+        env:
+          UP_KS_B64: ${{ secrets.PLAY_UPLOAD_KEYSTORE_B64 }}
+          UP_KS_PASS: ${{ secrets.PLAY_UPLOAD_KEYSTORE_PASSWORD }}
+          UP_ALIAS: ${{ secrets.PLAY_UPLOAD_KEY_ALIAS }}
+          UP_KEY_PASS: ${{ secrets.PLAY_UPLOAD_KEY_PASSWORD }}
+          REL_KS_B64: ${{ secrets.ANDROID_KEYSTORE_B64 }}
+          REL_KS_PASS: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
+          REL_ALIAS: ${{ secrets.ANDROID_KEY_ALIAS }}
+          REL_KEY_PASS: ${{ secrets.ANDROID_KEY_PASSWORD }}
+        run: |
+          set -euo pipefail
+          # 1) Play manifest: drop the self-update permission even if a plugin
+          #    contributes it (tools:node="remove" wins in the merger).
+          python3 - <<'PY'
+          p = "android/app/src/main/AndroidManifest.xml"
+          s = open(p).read()
+          s = s.replace('<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>',
+                        '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" tools:node="remove"/>')
+          assert 'REQUEST_INSTALL_PACKAGES" tools:node="remove"' in s, "manifest patch not found"
+          open(p, "w").write(s)
+          print("Play manifest: REQUEST_INSTALL_PACKAGES removed")
+          PY
+          # 2) Build the bundle (all ABIs; Play serves each phone its own split).
+          flutter build appbundle --release \
+            --build-number=${{ github.run_number }} \
+            --build-name=1.0.${{ github.run_number }} \
+            --dart-define=API_BASE="${{ github.event.inputs.api_base || 'https://api.lifeassisto.com' }}" \
+            --dart-define=BUILD_TIME="$(date -u +%Y-%m-%dT%H:%MZ)" \
+            --dart-define=PLAY_STORE=true
+          AAB=build/app/outputs/bundle/release/app-release.aab
+          # the bundle's own (protobuf) manifest keeps permission names as text
+          unzip -p "$AAB" base/manifest/AndroidManifest.xml > /tmp/play-manifest.pb
+          if grep -a -q REQUEST_INSTALL_PACKAGES /tmp/play-manifest.pb; then
+            echo "::error::REQUEST_INSTALL_PACKAGES still in the Play bundle manifest"; exit 1
+          fi
+          # 3) Pick the key: Play upload key if configured, else the release key.
+          if [ -n "${UP_KS_B64:-}" ]; then
+            printf '%s' "$UP_KS_B64" | base64 -d > /tmp/aab.p12
+            export SP="$UP_KS_PASS" KP="$UP_KEY_PASS"; ALIAS="$UP_ALIAS"; WHICH="play-upload-key"
+          else
+            printf '%s' "$REL_KS_B64" | base64 -d > /tmp/aab.p12
+            export SP="$REL_KS_PASS" KP="$REL_KEY_PASS"; ALIAS="$REL_ALIAS"; WHICH="release-key"
+          fi
+          # 4) Flutter's template signs release with the DEBUG key; strip that
+          #    signature, then sign with jarsigner (the tool Google documents for
+          #    .aab — apksigner is for APKs). Passwords via env, never argv.
+          zip -q -d "$AAB" 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.EC' \
+              'META-INF/*.DSA' 'META-INF/MANIFEST.MF' 2>/dev/null || true
+          jarsigner -keystore /tmp/aab.p12 -storetype PKCS12 \
+            -storepass:env SP -keypass:env KP -digestalg SHA-256 \
+            "$AAB" "$ALIAS" > /dev/null
+          jarsigner -verify "$AAB" | tail -1
+          echo "signed with: $WHICH"
+          keytool -printcert -jarfile "$AAB" | grep -E 'Owner:|SHA256:' | head -2   # public cert info only
+          rm -f /tmp/aab.p12
+          mkdir -p out
+          cp "$AAB" "out/assisto-play-build${{ github.run_number }}.aab"
+          ls -la out/*.aab
+
+      - name: Upload AAB artifact (Google Play)
+        if: steps.aab.outcome == 'success'
+        uses: actions/upload-artifact@v4
+        with:
+          name: assisto-aab
+          path: app/out/*.aab
+          retention-days: 30
+      # ---- /l1-launch ----
+
   # Install the RELEASE APK on real Android emulators and prove it OPENS without
```

Why each line:

- `--dart-define=PLAY_STORE=true` — `AppConfig.playStore` (already in the
  branch): the updater never calls `/app/latest`, the Settings → Update tile
  is hidden, About and the update screen say "updates through Google Play"
  (ARB keys `l1PlayUpdatesViaStore`). Play's Device and Network Abuse policy
  forbids an app from Play updating itself by any other means.
- `REQUEST_INSTALL_PACKAGES tools:node="remove"` — this permission is
  restricted on Play and only allowed when installing packages is the app's
  core purpose. The website APK keeps it (it needs it to self-update).
- Same `run_number` as the APK → the Play `versionCode` always increases.
- `jarsigner` after stripping `META-INF` — the generated
  `build.gradle.kts` signs `release` with the debug key; Play rejects a
  debug-signed bundle, and a bundle carrying two signers is ambiguous. No
  `-sigalg`: jarsigner picks SHA256withRSA / SHA256withECDSA from the key.
- `continue-on-error` + `if: steps.aab.outcome == 'success'` — the APK
  release (ship_watch) can never be blocked by the new step. Remove
  `continue-on-error` once one run is green.
- The AAB is NOT launch-smoke-tested on the emulator (the smoke job installs
  the x86_64 APK built from the same Dart code). Before the first Play
  production rollout, use Play Console → Testing → Internal testing and
  install it on the Realme 9i (Play's pre-launch report also runs it).

Verify after the first run (CI log of this step): `jar verified.`, `signed
with: …`, the SHA-256 line, and the `assisto-aab` artifact (~50–70 MB).

## B — Secrets (only if you choose the separate upload key)

See `owner_actions/PLAY_APP_SIGNING.md` (Bangla) — **recommended plan: give
Google the existing release key as the app-signing key, and make a NEW upload
key for CI**. Then add four repository secrets (Settings → Secrets → Actions):

| Secret | Value |
|---|---|
| `PLAY_UPLOAD_KEYSTORE_B64` | `base64 -w0 upload-keystore.p12` |
| `PLAY_UPLOAD_KEYSTORE_PASSWORD` | store password of that file |
| `PLAY_UPLOAD_KEY_ALIAS` | `upload` (or what you chose) |
| `PLAY_UPLOAD_KEY_PASSWORD` | key password (same as store password for PKCS12) |

The existing `ANDROID_KEYSTORE_*` secrets stay — they keep signing the
website APK. Never commit any of these files (repo is public).

## C — Health Connect privacy-policy activity (manifest)

`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/legal/PrivacyPolicyActivity.kt`
is in the branch (opens https://lifeassisto.com/privacy#perm-health and
finishes; no UI, crash-guarded, never runs at launch). Health Connect requires
an activity for `ACTION_SHOW_PERMISSIONS_RATIONALE` (Android ≤ 13) and an
alias for `VIEW_PERMISSION_USAGE` + `HEALTH_PERMISSIONS` (Android 14+);
without them `requestAuthorization` shows nothing and the Smartwatch screen
stays "permission denied". Play's Health Connect declaration form also asks
for this privacy-policy link.

In the `native_components` string of the "Patch manifest" step, before the
closing `'\n        <service android:name="com.assisto.assisto.voice.WakeWordService"'` line:

```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@
               '\n        </activity>'
+              # ---- l1-launch: Health Connect privacy-policy entry ----
+              '\n        <activity android:name="com.assisto.assisto.legal.PrivacyPolicyActivity"'
+              ' android:exported="true" android:excludeFromRecents="true"'
+              ' android:noHistory="true"'
+              ' android:theme="@android:style/Theme.Translucent.NoTitleBar">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>'
+              '\n            </intent-filter>'
+              '\n        </activity>'
+              '\n        <activity-alias android:name="com.assisto.assisto.legal.ViewPermissionUsageActivity"'
+              ' android:exported="true"'
+              ' android:targetActivity="com.assisto.assisto.legal.PrivacyPolicyActivity"'
+              ' android:permission="android.permission.START_VIEW_PERMISSION_USAGE">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>'
+              '\n                <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>'
+              '\n            </intent-filter>'
+              '\n        </activity-alias>'
               # Opt-in "Hey/Hi Assisto" wake word (never started at launch/boot;
```

Note: `native_components` is only inserted when `.AssistoWidgetProvider` is
not yet in the manifest, which is always true on the fresh `flutter create`
tree CI uses. Needs the API-33 launch smoke (no launch impact expected: the
activity is only started by Health Connect).

## D — Play-policy findings (decide before submitting; no diff)

1. **Device admin `reset-password` / `limit-password`** (`res/xml/device_admin.xml`):
   `resetPassword()` is ignored/throws for device-admin apps targeting API 24+,
   and password policies are deprecated for non-device-owner admins on
   Android 14+. Play reviews device-admin use strictly; declare the anti-theft
   purpose in Play Console → App content → "Device admin" (wording in
   `owner_actions/PLAY_STORE_PACK.md`). Consider dropping the two password
   policies (keep `force-lock` + `watch-login`) to make review easier.
2. **`USE_FULL_SCREEN_INTENT`**: since Jan 2025 Play only pre-grants it to
   calling/alarm apps and needs the Play Console declaration (Assisto
   qualifies: voice/video calling). Text in PLAY_STORE_PACK.md.
3. **Foreground service types** `microphone` + `location`: each needs the
   Play Console FGS declaration with a short demo video showing the user
   switching voice SOS on and the persistent notification.
4. **AdMob is not in the APK yet** (`NoopAdsBridge`; proposal
   `a6-leftovers-admob.md` pending). Fill the Data safety / Ads declaration
   for the build you actually submit (PLAY_STORE_PACK.md says how for both).
5. **EEA/UK users + AdMob**: Google requires a certified consent message
   (UMP) for EEA/UK/Switzerland traffic even for non-personalised ads. The
   app has no UMP flow. Simplest honest option for launch: restrict the Play
   countries to exclude the EEA/UK/CH until a UMP flow is added.
6. **`backup.sh` keystore**: it looks only for `*.jks`; the CI key is a
   PKCS12 (`--ks-type PKCS12`) kept in GitHub secrets. Keep an offline copy
   of the `.p12` (PLAY_APP_SIGNING.md §5).
