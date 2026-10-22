# hc1 — MainActivity → FlutterFragmentActivity (Health Connect + local_auth really attach)

Branch `agent/hc1` (from origin/main 572c9b3). Local commit only, not pushed.

## The bug

`health` 13.3.1 `HealthPlugin.onAttachedToActivity` does
`(activity as ComponentActivity).registerForActivityResult(PermissionController.createRequestPermissionResultContract())`.
`FlutterActivity` extends `android.app.Activity` (not `ComponentActivity`), so the cast threw
`ClassCastException`. The embedding attaches the engine to the activity *before*
`configureFlutterEngine`, so the throw happened inside `GeneratedPluginRegistrant`'s per-plugin
`try/catch` → logged as "Error registering plugin health", app still opened, but the permission
launcher stayed null → `requestAuthorization()` always returned `false` → the Smartwatch screen's
"Connect" button never opened Health Connect (a dead button).

Same root cause, second victim: `local_auth_android` 1.0.56 answers every `authenticate()` with
`no_fragment_activity` unless the activity is a `FragmentActivity`. `SecurityGuard.ensureBiometric`
caught that and silently fell back to PIN-only, so the class-3 biometric step never ran.

## Where MainActivity comes from

`flutter create --org com.assisto` generates `android/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt`;
the "Apply android_overlay" step (`cp -rv android_overlay/. android/`, android.yml:73-74) overwrites it with
`app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt`. No sed/heredoc in
android.yml touches the Kotlin class; the manifest patches only *find* `android:name=".MainActivity"`
(App Link intent-filter, `supportsPictureInPicture`) and the smoke test starts `.MainActivity` by name.
The class name and package are unchanged, so all of that still applies. CI therefore builds exactly
the overlay file in this branch.

## The diff (Kotlin)

```diff
-import io.flutter.embedding.android.FlutterActivity
+import io.flutter.embedding.android.FlutterFragmentActivity
 ...
-class MainActivity : FlutterActivity() {
+class MainActivity : FlutterFragmentActivity() {
 ...
-    @Deprecated("Activity result API is not available on FlutterActivity")
+    @Deprecated("Legacy result path kept for the startActivityForResult pickers")
     override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
```
(+ a KDoc paragraph). Every MethodChannel registration (ShopBox, OBD, Voice, C3 messaging, Calls,
PhotoNativeChannel, lockscreen, device_admin) and every override is unchanged and still
individually try/catch-guarded. `BubbleActivity` stays a plain `FlutterActivity` (see risks).

## Why each override is safe (checked with `javap` on this engine's `flutter_embedding.jar`, Flutter 3.47.7 / engine deb28748)

| override | on FlutterFragmentActivity / its supers | note |
|---|---|---|
| `onCreate(Bundle?)` | `FlutterFragmentActivity.onCreate` (protected) | we call `super` first, then the lock-screen + voice policy, as before |
| `onNewIntent(Intent)` | `FlutterFragmentActivity.onNewIntent` → `flutterFragment.onNewIntent` (deep links / App Link reach Dart as before) | Kotlin non-null `Intent` matches both activity 1.8 (Java) and 1.9+ (Kotlin) `ComponentActivity` |
| `onActivityResult(Int, Int, Intent?)` | `FlutterFragmentActivity.onActivityResult` → fragment → plugins; `ComponentActivity` first dispatches `ActivityResultRegistry` results | our pickers use 0xC3 / 0x5a11; registry codes are random ≥ 0x10000, no clash. Unknown codes still go to `super` |
| `configureFlutterEngine(FlutterEngine)` | public on `FlutterFragmentActivity` (it is the `FlutterEngineConfigurator`); `super` runs `GeneratedPluginRegister` | unchanged body |
| `onStop()` / `onDestroy()` | `FragmentActivity` | unchanged |
| `onPictureInPictureModeChanged(Boolean, Configuration)` | `ComponentActivity` (open, `@CallSuper`) — not overridden by FlutterFragmentActivity | we call `super`; compiled against both activity 1.8.1 and 1.10.1 |
| `setShowWhenLocked` / `setTurnScreenOn` / `window` / `intent` | `Activity` | unchanged |

No `provideFlutterEngine` / `getCachedEngineId` / `onUserLeaveHint` overrides exist in our class
(FlutterFragmentActivity provides its own; PiP is entered explicitly from `CallsChannel`).

**Theme:** `FragmentActivity` does NOT require an AppCompat theme (only `AppCompatActivity` does).
`@style/LaunchTheme` / `NormalTheme` (`@android:style/Theme.Light.NoTitleBar`) and the
`NormalTheme` meta-data switch are handled identically by `FlutterFragmentActivity.switchLaunchThemeForNormalTheme`.

**Classpath:** `flutter_embedding_release-1.0.0-deb28748….pom` declares `androidx.fragment:fragment:1.7.1`
with `<scope>compile</scope>`; `health` also brings `fragment-ktx:1.8.9`. So `FragmentActivity`
is on the app module's compile classpath without any new Gradle dependency.

**Registration timing:** FlutterFragmentActivity commits the FlutterFragment in `onCreate`; it
attaches during `FragmentActivity.onStart`'s pending-transaction flush, before the activity's
lifecycle reaches STARTED — so the health plugin's `registerForActivityResult` is legal (this is the
setup the `health` and `local_auth` READMEs require). If it ever threw, it would still be inside the
`GeneratedPluginRegistrant` try/catch (same as today).

## Dart changes (same branch)

- `smartwatch_screen.dart`: any Health Connect status other than `sdkAvailable` (not installed —
  normal on ColorOS / Android 13 —, provider update required, or plugin did not answer) shows the
  honest install/update state; the "Install Health Connect" button opens the Play Store page
  (falls back to app settings if there is no Play Store). On resume from the Play Store the screen
  re-checks by itself, so it never stays stuck on "not installed". New body text
  `swUnavailableBody2` (bn+en) in `.phaseB/up_hc1_arb.json` (integrator applies).
- `security_guard.dart`: local_auth now really prompts. On Android 8.x (API 26/27) androidx.biometric
  draws its own fingerprint dialog that needs a `Theme.AppCompat` activity theme
  (local_auth README "Android theme"); ours is not, so there we skip the biometric step and keep
  the Security PIN (always required anyway). API 28+ uses the system BiometricPrompt — no theme need.
  The SDK level comes from the existing `com.assisto/device_admin` `deviceInfo` call (no new plugin).

Health Connect manifest pieces from l1-launch are unchanged and still correct: the
`ACTION_SHOW_PERMISSIONS_RATIONALE` filter is on `com.assisto.assisto.legal.PrivacyPolicyActivity`
(a plain `Activity`, exists in the overlay, independent of MainActivity) and the
`ViewPermissionUsageActivity` alias targets that same class; READ_STEPS / HEART_RATE / SLEEP /
ACTIVE_CALORIES_BURNED permissions and the `com.google.android.apps.healthdata` `<queries>` entry
are present.

## Compile proof (local)

kotlinc 2.x, classpath = android-35 `android.jar` + this engine's `flutter_embedding.jar` +
androidx fragment 1.8.9, activity 1.8.1 **and** 1.10.1 (two runs), core 1.13.1, lifecycle 2.7.0,
savedstate 1.2.1 + the p2-photo ML Kit / ORT jars. Sources: MainActivity + every overlay Kotlin file
except `push/AssistoFcmService.kt` (Firebase) and `AssistoWidgetProvider.kt` (needs generated `R`).
Both runs: `kotlinc rc=0`, only pre-existing deprecation warnings; `javap` shows
`MainActivity extends io.flutter.embedding.android.FlutterFragmentActivity` with the 7 overrides.

## Risks

1. **Launch (worst case).** Different base class on the launch path. Mitigations: no theme change,
   no new dependency, unchanged manifest entry, all registrations try/catch. Must be proven by the
   CI API-33 release cold-start smoke AND a Realme 9i real-phone open.
2. **Health plugin now attaches at launch.** Its `onAttachedToActivity` only builds a contract and
   registers a launcher (no Health Connect IPC). Health Connect itself is still only queried when
   the Smartwatch screen opens.
3. **Status bar / edge-to-edge look.** `FlutterFragmentActivity.configureStatusBarForFullscreenFlutterExperience`
   mirrors FlutterActivity's; still, compare the home screenshot (home is frozen at build 103).
4. **PiP.** `onPictureInPictureModeChanged` now comes from `ComponentActivity`; behaviour same.
   Check a video call → Home → PiP window and return.
5. **Lock-screen call.** `setShowWhenLocked` path unchanged; check a ringing call on a locked phone
   still shows only the call screen.
6. **Deep links / App Link** (`lifeassisto.com/photo/app`) and notification/shortcut intents go
   through `FlutterFragmentActivity.onNewIntent` → fragment → Dart, as with FlutterActivity.
7. **Bubbles.** `BubbleActivity` is still `FlutterActivity`; the health plugin's attach there throws
   and is swallowed exactly as it was on MainActivity before (proven harmless on the phone). Health
   is never used inside a bubble.
8. **Biometric now real.** Security actions will show the system fingerprint prompt before the PIN
   (API 28+). Cancel → action cancelled (existing, intended behaviour). Android 8.x → PIN only.
9. **Process-death restore.** FragmentManager restores the FlutterFragment; FlutterFragmentActivity
   reuses it (`retrieveExistingFlutterFragmentIfPossible`). Low risk.

## What CI + the phone must confirm

- CI: APK builds; API-33 release cold-start smoke passes (`Displayed com.assisto.assisto/.MainActivity`,
  no FATAL); logcat no longer shows "Error registering plugin health".
- Realme 9i: PHONE_TEST_CHECKLIST.md new section ৯৮–১০২ (open/rotate/background, Smartwatch without
  and with Health Connect, permission dialog really opens, fingerprint before PIN, PiP / locked call /
  bubble / photo link unchanged).
