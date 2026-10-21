# Proposal — slot a6-leftovers

Part **FCM** (owner TOP PRIORITY) is self-contained and can ship as its own
build. AdMob + annual-margin parts follow in later sections (added later).

## FCM — what ships where

| Piece | Where | Needs proposal? |
|---|---|---|
| Pure payload/routing model + tests | `app/lib/push/push_payload.dart`, `app/test/push_payload_test.dart` | no (in branch) |
| Local notifications (5 channels, call full-screen + Accept/Decline, cancel) | `app/lib/push/push_notifier.dart` | no |
| UI-isolate orchestration (lazy init, token register/unregister, foreground show, tap routing) | `app/lib/push/push_service.dart`, `push_api.dart` | no |
| Ringing screen (Accept -> existing `CircleCallScreen(outgoing:false)`) | `app/lib/push/incoming_call_screen.dart` | no |
| Settings -> Notifications & calls (honest status, POST_NOTIFICATIONS, Android 14 FSI deep link, battery hint) | `app/lib/push/push_settings_screen.dart` + tile in `settings_screen.dart` | no |
| Firebase SDK bridge + `@pragma('vm:entry-point')` background handler | `app/lib/push/firebase_push_bridge.dart.pending` | **P1** (activate) |
| pubspec firebase_core / firebase_messaging | `app/pubspec.yaml` | **P1** |
| Native lazy Firebase init when a push arrives with the app closed | `app/android_overlay/.../push/AssistoFcmService.kt` | needs **P2** manifest entry to be used |
| CI: secret -> google-services.json, manifest, Gradle plugin | `.github/workflows/android.yml` | **P2** |

Without P1 the branch is green and push is silently OFF (NoopPushBridge).
Without the GitHub secret (P1+P2 applied) the APK still builds and launches:
no google-services.json -> Gradle plugin not applied -> `Firebase.initializeApp()`
throws inside try/catch -> push silently off.

### P1 — pubspec + activate the bridge (app side)

One command from the repo root (idempotent):

```
bash .phaseB/proposals/a6-fcm-apply.sh
cd app && ~/assisto/bin/heavy.sh ~/assisto/tools/flutter/bin/flutter pub get
```

What it does (exact):

```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@
   home_widget: ^0.7.0
+  # a6 FCM push — key-gated by google-services.json (CI secret
+  # GOOGLE_SERVICES_JSON_B64). Lazy init after first frame; the auto-init
+  # FirebaseInitProvider is removed in the manifest (ColorOS history).
+  firebase_core: 4.15.0
+  firebase_messaging: 16.7.0
```

```
git mv app/lib/push/firebase_push_bridge.dart.pending app/lib/push/firebase_push_bridge.dart
```

```diff
--- a/app/lib/push/push_binding.dart
+++ b/app/lib/push/push_binding.dart
@@
-import 'push_bridge.dart';
+import 'firebase_push_bridge.dart';
+import 'push_bridge.dart';
@@
-PushBridge createPushBridge() => const NoopPushBridge();
+PushBridge createPushBridge() => FirebasePushBridge();
```

Versions: firebase_core 4.15.0 / firebase_messaging 16.7.0 (both published
2026-09-14; the 5.0/17.0 majors are < 2 weeks old and deliberately skipped).

### P2 — CI workflow (`.github/workflows/android.yml`)

Owner's injection method: secret **GOOGLE_SERVICES_JSON_B64** = `base64 -w0 google-services.json`.

1. New step after the native overlay: decode the secret to
   `app/android/app/google-services.json` (validated for package
   `com.assisto.assisto`, never printed). No secret -> nothing written.
2. Manifest patch step gains (all idempotent):
   - `USE_FULL_SCREEN_INTENT` (+ `RECEIVE_BOOT_COMPLETED` for reminder reschedule).
     `POST_NOTIFICATIONS` is already in the list.
   - MainActivity `android:showWhenLocked="true" android:turnScreenOn="true"`
     (ringing call / SOS over the lock screen).
   - `FirebaseInitProvider` -> `tools:node="remove"` (no startup ContentProvider).
   - firebase_messaging's `FlutterFirebaseMessagingInitProvider` -> `tools:node="remove"`
     (it only stores the app context; the plugin receiver / engine attach /
     `AssistoFcmService.onCreate` set the same `ContextHolder`).
   - plugin `FlutterFirebaseMessagingService` -> `tools:node="remove"`, replaced by
     `com.assisto.assisto.push.AssistoFcmService` (subclass; inits Firebase lazily
     from the google-services resources, crash-guarded) with the
     `com.google.firebase.MESSAGING_EVENT` filter.
   - `com.google.firebase.messaging.default_notification_channel_id` = `alerts`.
     The 5 channels (messages / **calls** / reminders / alerts / sos) are created in
     Dart (`PushNotifier.createChannels`, UI isolate after first frame AND in the
     background isolate before the first draw). The **calls** channel is
     Importance.max with the system ringtone + ringtone audio usage.
   - flutter_local_notifications receivers: `ActionBroadcastReceiver` (call
     Accept/Decline actions), `ScheduledNotificationReceiver` +
     `ScheduledNotificationBootReceiver`. **Finding:** the scheduled receivers were
     never declared, so `Notifications.schedule()` (zonedSchedule) reminders could
     not fire on device — this fixes that too.
3. New step before "Build release APK": apply `com.google.gms.google-services`
   (4.5.0, declared in `settings.gradle.kts` plugins + applied in
   `app/build.gradle.kts`) **only if** `android/app/google-services.json` exists.
   Handles .kts and Groovy. Verified locally against a fresh
   `flutter create` (Flutter 3.47.7, AGP 9.1.0): no-file run = no-op; with-file run
   inserts both lines; re-run is idempotent; patched manifest parses as XML.

Exact diff:

```diff
--- a/.github/workflows/android.yml	2026-10-21 04:29:32.273378809 +0000
+++ b/.github/workflows/android.yml	2026-10-21 04:33:11.507237160 +0000
@@ -53,6 +53,29 @@
             echo "no android_overlay — skipping"
           fi
 
+      # a6 FCM: Firebase config is KEY-GATED. google-services.json lives ONLY in
+      # the GOOGLE_SERVICES_JSON_B64 Actions secret (repo is public — never
+      # commit it, never print it). No secret -> no file -> the Gradle plugin is
+      # not applied, Firebase.initializeApp() fails inside its try/catch and the
+      # app builds + launches with push silently off.
+      - name: Firebase config (google-services.json from secret)
+        working-directory: app
+        env:
+          GSJ_B64: ${{ secrets.GOOGLE_SERVICES_JSON_B64 }}
+        run: |
+          if [ -n "${GSJ_B64:-}" ]; then
+            printf '%s' "$GSJ_B64" | base64 -d > android/app/google-services.json
+            python3 - <<'PY2'
+          import json
+          d = json.load(open("android/app/google-services.json"))
+          pk = [c["client_info"]["android_client_info"]["package_name"] for c in d.get("client", [])]
+          assert "com.assisto.assisto" in pk, "google-services.json has no com.assisto.assisto client"
+          print("google-services.json OK for project", d["project_info"]["project_id"])
+          PY2
+          else
+            echo "no GOOGLE_SERVICES_JSON_B64 secret - push stays OFF in this build"
+          fi
+
       - name: Pub get
         working-directory: app
         run: flutter pub get
@@ -191,8 +214,69 @@
           )
           if 'androidx.startup.InitializationProvider' not in s:
               s = s.replace('</application>', startup_remove + '    </application>', 1)
+          # ---- a6 FCM push ----
+          # Full-screen incoming calls (Android 14+: user-grantable special
+          # permission; Settings -> Notifications & calls deep-links to it).
+          if 'USE_FULL_SCREEN_INTENT' not in s:
+              s = re.sub(r'(<manifest[^>]*>)', r'\1' +
+                  '\n    <uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>'
+                  '\n    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>\n',
+                  s, count=1)
+          # A ringing call / SOS may open over the lock screen and wake it.
+          if 'android:showWhenLocked' not in s:
+              s = s.replace('android:name=".MainActivity"',
+                  'android:name=".MainActivity"\n            android:showWhenLocked="true"'
+                  '\n            android:turnScreenOn="true"', 1)
+          push_components = (
+              # NO startup ContentProvider: Firebase is initialised lazily (Dart
+              # after the first frame; native AssistoFcmService when a push
+              # arrives with the app closed).
+              '\n        <provider android:name="com.google.firebase.provider.FirebaseInitProvider"'
+              ' android:authorities="${applicationId}.firebaseinitprovider"'
+              ' tools:node="remove"/>'
+              # firebase_messaging's own startup provider only stores the app
+              # context; the plugin's receiver, engine attach and our service
+              # set the same holder, so it goes too (no startup providers).
+              '\n        <provider android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingInitProvider"'
+              ' android:authorities="${applicationId}.flutterfirebasemessaginginitprovider"'
+              ' tools:node="remove"/>'
+              # swap the plugin's messaging service for our subclass (it inits
+              # Firebase on demand, crash-guarded)
+              '\n        <service android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService"'
+              ' tools:node="remove"/>'
+              '\n        <service android:name="com.assisto.assisto.push.AssistoFcmService"'
+              ' android:exported="false">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="com.google.firebase.MESSAGING_EVENT"/>'
+              '\n            </intent-filter>'
+              '\n        </service>'
+              # notification messages that arrive before the app created its
+              # channels land on "alerts" (channels are created in Dart:
+              # messages / calls / reminders / alerts / sos)
+              '\n        <meta-data android:name="com.google.firebase.messaging.default_notification_channel_id"'
+              ' android:value="alerts"/>'
+              # flutter_local_notifications receivers: notification ACTIONS
+              # (call Accept/Decline) + scheduled reminders + reschedule on boot.
+              # (The scheduled receivers were missing before, so zonedSchedule
+              # reminders could not fire.)
+              '\n        <receiver android:exported="false"'
+              ' android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"/>'
+              '\n        <receiver android:exported="false"'
+              ' android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>'
+              '\n        <receiver android:exported="false"'
+              ' android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">'
+              '\n            <intent-filter>'
+              '\n                <action android:name="android.intent.action.BOOT_COMPLETED"/>'
+              '\n                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>'
+              '\n                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>'
+              '\n                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>'
+              '\n            </intent-filter>'
+              '\n        </receiver>\n'
+          )
+          if 'AssistoFcmService' not in s:
+              s = s.replace('</application>', push_components + '    </application>', 1)
           open(p, "w").write(s)
-          print("manifest patched: label, permissions, queries, UCropActivity, native components, androidx.startup removed")
+          print("manifest patched: label, permissions, queries, UCropActivity, native components, androidx.startup removed, FCM push")
           PY
 
       - name: Patch iOS Info.plist (camera/mic/photos usage strings)
@@ -269,6 +353,44 @@
               print("already enabled")
           PY
 
+      - name: Apply google-services Gradle plugin (only when Firebase config exists)
+        working-directory: app
+        run: |
+          python3 - <<'PY'
+          import os, re
+          if not os.path.exists("android/app/google-services.json"):
+              print("no google-services.json - google-services plugin NOT applied (push off)")
+              raise SystemExit(0)
+          GMS = "4.5.0"
+          for settings in ("android/settings.gradle.kts", "android/settings.gradle"):
+              if os.path.exists(settings):
+                  s = open(settings).read()
+                  if "com.google.gms.google-services" not in s:
+                      kts = settings.endswith(".kts")
+                      line = ('    id("com.google.gms.google-services") version "%s" apply false' % GMS
+                              if kts else
+                              '    id "com.google.gms.google-services" version "%s" apply false' % GMS)
+                      s, n = re.subn(r'(\n[ \t]*id[ (]+"dev\.flutter\.flutter-plugin-loader"[^\n]*)',
+                                     lambda m: m.group(1) + "\n" + line, s, count=1)
+                      assert n == 1, "plugin-loader line not found in " + settings
+                      open(settings, "w").write(s)
+                  print("google-services plugin declared in", settings)
+                  break
+          for app in ("android/app/build.gradle.kts", "android/app/build.gradle"):
+              if os.path.exists(app):
+                  s = open(app).read()
+                  if "com.google.gms.google-services" not in s:
+                      kts = app.endswith(".kts")
+                      line = ('    id("com.google.gms.google-services")' if kts
+                              else '    id "com.google.gms.google-services"')
+                      s, n = re.subn(r'(\n[ \t]*id[ (]+"dev\.flutter\.flutter-gradle-plugin"[^\n]*)',
+                                     lambda m: m.group(1) + "\n" + line, s, count=1)
+                      assert n == 1, "flutter-gradle-plugin line not found in " + app
+                      open(app, "w").write(s)
+                  print("google-services plugin applied in", app)
+                  break
+          PY
+
       - name: Build release APK (arm64 only)
         working-directory: app
         run: |
```
