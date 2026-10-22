# c3-msg — native proposal (manifest only; NO Gradle / pubspec change)

## 1. BubbleActivity (Android Bubbles API, Android 11+) — REQUIRED for bubbles

Why: a bubble expands an activity that must be embeddable + resizeable and
launch as its own document. Until this lands, `BubbleHelper.attach()` detects
the activity is not declared and skips the bubble quietly (notifications,
inline reply, mark-as-read all work without it).

Add to `.github/workflows/android.yml`, inside the `native_components` string
(next to the other `com.assisto.assisto.*` components):

```diff
               '\n        <service android:name="com.assisto.assisto.voice.WakeWordService"'
               ' android:foregroundServiceType="microphone"'
               ' android:exported="false"/>\n'
+              # c3-msg: chat bubbles (Android 11+). Embedded + resizeable +
+              # its own document so several bubbles can be open at once. Not
+              # exported; only our own mutable PendingIntent opens it.
+              '\n        <activity android:name="com.assisto.assisto.messaging.BubbleActivity"'
+              ' android:exported="false"'
+              ' android:allowEmbedded="true"'
+              ' android:resizeableActivity="true"'
+              ' android:documentLaunchMode="always"'
+              ' android:hardwareAccelerated="true"'
+              ' android:windowSoftInputMode="adjustResize"'
+              ' android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"'
+              ' android:theme="@style/LaunchTheme">'
+              '\n            <meta-data android:name="io.flutter.embedding.android.NormalTheme"'
+              ' android:resource="@style/NormalTheme"/>'
+              '\n        </activity>\n'
           )
```

(`native_components` is only inserted when `.AssistoWidgetProvider` is not yet
in the manifest, i.e. once per CI build — same as the other entries.)

## 2. Nothing else

* POST_NOTIFICATIONS is already requested (a6). No SYSTEM_ALERT_WINDOW.
* Conversation shortcuts are DYNAMIC (`ShortcutManager.pushDynamicShortcut`),
  so no `res/xml/shortcuts.xml` / `<meta-data android.app.shortcuts>` needed.
* `com.google.firebase:firebase-messaging` is already an app dependency
  (android.yml adds it), so `AssistoFcmService.onMessageReceived(RemoteMessage)`
  compiles.
* Launcher badge: Android launchers badge from ACTIVE notifications; we cancel
  a chat's notification the moment it is opened / marked read, so the icon
  badge follows with NO plugin. (A numeric badge plugin such as
  flutter_app_badger is discontinued and not needed — not proposed.)
* `MainActivity.kt` edits are minimal and in-overlay (registration of
  `C3MessagingChannel`, `onNewIntent` forward, `onActivityResult` forward for
  the phone's sound picker) — all try/catch, nothing at launch.

## Launch-safety notes for the API 33 smoke
* BubbleActivity is never started at launch (only from a bubble tap).
* BubbleHelper runs only inside the FCM service after a message push, on the
  main looper with short delays, fully try/catch.
* New drawable `res/drawable/c3_person_avatar.xml` (vector, original).
