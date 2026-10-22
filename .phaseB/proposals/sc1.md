# sc1 — secure storage that never breaks the session + crash/error reporting

Branch `agent/sc1` (local, not pushed). Kotlin/Gradle can only be built in CI;
this file lists the exact Android changes and what the CI smoke must confirm.

## Scope (after two integrator orders, 22 Oct)
Item 1 (storage) is DROPPED from this branch. The owner order is that every
secret lives in an encrypted app-private no_backup file store
(`app/lib/security/secret_store.dart` + IdentityVault, built by the
integrator). sc1 changes NO flutter_secure_storage call site, token,
identity or logout code. What sc1 provides for it is the hook
`reportNonFatal(String where, Object error, [StackTrace?])` in
`app/lib/services/error_report.dart` (same name/signature as the
integrator's stub). It is safe before the first frame and in background
isolates, it is buffered in memory, and nothing is sent before consent. On
merge, keep sc1's version of that file.
Follow-up after SecretStore lands: migrate vault / lost_stolen / shop_box /
contacts secrets onto SecretStore (separate commit).

## Finding on user 18 (OPPO Reno 12 F, ColorOS)
flutter_secure_storage 9.2.4, `FlutterSecureStoragePlugin.MethodRunner.run`:
`catch (FileNotFoundException e) { Log.i(...) }` sends NO result to Dart, so
the awaiting future never completes. `KeyService.publish` shares one
`_inflight` future; if its first `identity()` call hangs on storage, every
later trigger (start, login, all 15 `key_request` pushes) returns that same
never-ending future, which matches "never POSTed /circle/keys". Also
`StorageCipher18Implementation` makes a NEW AES key when the RSA unwrap fails,
after which every older value throws BadPaddingException. SecretStore and
IdentityVault must time-box any legacy read. Also note: `main.dart` starts
KeyWiring only after `await Notifications.init()`; a hang there would delay
it as well (left for the integrator, it is in the identity path).

## Android changes (all in .github/workflows/android.yml, step "Crash reporting (sc1)")
1. (Suggestion for the integrator, not in this branch: exclude
   `FlutterSecureStorage.xml` / `FlutterSecureKeyStorage.xml` from auto-backup.
   A restored copy, whose Keystore key never restores, is a classic source of
   BadPaddingException on the legacy read.)
2. `<meta-data android:name="firebase_crashlytics_collection_enabled" android:value="false"/>`:
   no collection until the app enables it after sign-in and onboarding.
3. Only when google-services.json exists: `com.google.firebase.crashlytics`
   Gradle plugin 3.0.8 (published 2026-08-19, from google()) declared in
   settings.gradle(.kts) next to google-services 4.5.0 and applied in
   app/build.gradle(.kts). Mapping upload is OFF
   (`mappingFileUploadEnabled = false`), so the build has no network or secret
   dependency. The cost is that JVM frames are obfuscated in the console (Dart
   frames are not obfuscated).
4. proguard-rules.pro: `-keepattributes SourceFile,LineNumberTable`,
   `-keep public class * extends java.lang.Exception`.
5. pubspec: `firebase_crashlytics: 5.4.0` (2026-09-14, same FlutterFire train
   as firebase_messaging 16.7.0, firebase_core ^4.14.0, so it fits 4.15.0;
   BoM 34.19.0 resolves firebase-crashlytics 20.1.1). `device_info_plus: 12.4.0`
   moved from transitive to direct (same version, no lock bump otherwise).

## Startup-safety audit (from the AAR manifests, downloaded from maven.google.com)
| artifact | components merged |
|---|---|
| firebase_crashlytics 5.4.0 (plugin) | ComponentDiscoveryService meta-data (FlutterFirebaseAppRegistrar); res bool `com.crashlytics.RequireBuildId=false` |
| firebase-crashlytics 20.1.1 | INTERNET; ComponentDiscoveryService registrars only |
| firebase-sessions 3.0.8 | `SessionLifecycleService` (not exported, bound on demand), registrar |
| transport-runtime 3.3.0 | JobInfoSchedulerService, AlarmManagerSchedulerBroadcastReceiver, TransportBackendDiscovery service |
| transport-backend-cct 3.3.0, firebase-installations 19.1.2, firebase-datatransport 19.0.0 | registrars / permissions only |
| firebase-common 22.2.1 | **FirebaseInitProvider** (already `tools:node="remove"` by the a6 step, unchanged) |

None of these adds a ContentProvider or androidx.startup initializer.
FirebaseInitProvider stays removed, so Crashlytics starts only when Dart calls
`Firebase.initializeApp()` through the new single-flight `FirebaseLazy.ensure()`
(shared with push). That happens 4 s after the first frame and never in
StartupGuard safe mode.

One launch-time cost to watch: the plugin's `onAttachedToEngine` (main thread,
at engine attach) runs `ElfBuildIdReader.readBuildId`. It reads at most a
4 KB to 256 KB prefix of libapp.so and, when native libs are not extracted,
enumerates the APK zip entries. It is wrapped in `catch (Exception)` and
`catch (OutOfMemoryError)`, so it cannot crash, but it is a few ms of I/O.
If the smoke shows a regression, drop the Flutter plugin and keep only our
server sink.

Crashes before Firebase is initialised are not seen by Crashlytics. They
still reach us: the StartupGuard breadcrumb goes to /client/crash-report
(source=startup) on the next launch.

## What the CI API-33 release cold-start smoke must confirm
* Release x86_64 cold start: no crash or ANR, process alive after 30 s
  (existing gate).
* Merged manifest (aapt dump of emu-x64.apk) has no `FirebaseInitProvider`,
  no `androidx.startup.InitializationProvider` and no new `<provider>`.
  Suggested extra check: `aapt2 dump xmltree --file AndroidManifest.xml emu-x64.apk | grep -c provider`
  must equal the count on build 189.
* `firebase_crashlytics_collection_enabled=false` is present.
* logcat shows no `FirebaseCrashlytics` init line before `Displayed com.assisto.assisto/.MainActivity`.

## Privacy scrubbing (phone: lib/diag/crash_scrub.dart; server again: core/logic/crash_scrub.py)
Removed: quoted text; URLs (with query); e-mails; phone-like digit runs (7+);
any 5+ digit number; paths under /data /storage /sdcard /mnt /private /var
/Users /home; tokens of 20+ chars. Messages are capped at 300 chars. Frames
keep only `fn (package:…:line)`. The server computes the fingerprint itself.
User data: the Crashlytics user id is `sha256("assisto-crash-v1:"+id)[:16]`.
No logs and no custom keys go to Crashlytics. On our server the user FK is
shown only on the owner panel. Crashlytics gets only `ScrubbedError`, so the
raw `toString` is never sent. Limit: native JVM exception messages captured
by the Crashlytics SDK itself cannot be scrubbed from Dart.
