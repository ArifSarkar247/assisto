# Integration — #70 Smartwatch & fitness (Health Connect) + #196 Home-screen widget

Two NATIVE Android features, built to compile in headless CI and work on a real
device. Real packages only. Honest permission/denied states with a real
"Open settings" path (never a dead tap). ZERO Bangla literals in any `.dart`.
Reuses the existing reminders + wellness/fitness data — no new store.

Health Connect `<application>` entries and the widget `<receiver>` are
documented below for the integrator to inject into the workflow manifest patch
(`.github/workflows/android.yml`). This note does NOT edit that workflow.

---

## Files created

### Dart
| File | Purpose |
|---|---|
| `app/lib/screens/smartwatch_screen.dart` | #70 Health Connect bridge. Requests READ access to STEPS / HEART_RATE / SLEEP_ASLEEP / ACTIVE_ENERGY_BURNED via the `health` package, reads TODAY (steps, latest heart rate, sleep minutes, active kcal) + a 7-day steps bar chart (totals/avg). Honest phases: `checking · unavailable (install HC) · needsPermission (grant / Open settings) · loading · ready (with connected-no-data sub-state) · error`. Surfaces the data for viewing and links the user to the existing Wellness / Fitness screens (the system of record) — it does NOT duplicate their storage. `_Summary.from(...)` is a pure, clock-free projection. ZERO Bangla literals. |
| `app/lib/services/home_widget_service.dart` | #196 Dart side of the widget. `init()` (self-guarded), `isEnabled()/setEnabled()` (persist `home_widget_enabled` pref), `refresh(app, labels:)` pushes next-reminder title + "when" + today count, `clear(labels)` resets to empty, and a PURE `snapshot(items, now)` that mirrors the reminders screen's "today"/"next" logic. All human-readable copy is passed IN already-localised (`HomeWidgetLabels`) so the service holds no literals. |

### Native overlay (paths mirror `android/` exactly; merged by the workflow)
| File | Purpose |
|---|---|
| `app/android_overlay/app/src/main/kotlin/com/assisto/assisto/AssistoWidgetProvider.kt` | `AppWidgetProvider` that reads the pushed `HomeWidgetPlugin.getData(context)` SharedPreferences keys, renders next-reminder/empty state + today count, and opens the app's launcher activity on tap. No hard-coded user-facing copy — every string comes from the app. |
| `app/android_overlay/app/src/main/res/layout/assisto_widget.xml` | Widget layout (icon + count line, bold title, subtitle). Brand-dark rounded background; all TextViews filled at runtime. |
| `app/android_overlay/app/src/main/res/drawable/assisto_widget_bg.xml` | Rounded brand gradient background (cyan→blue→purple on dark). |
| `app/android_overlay/app/src/main/res/drawable/assisto_widget_preview.xml` | Vector preview shown in the launcher's widget picker (illustrative, no user data). |
| `app/android_overlay/app/src/main/res/xml/assisto_widget_info.xml` | `appwidget-provider` metadata: 2x1 default, resizeable, 30-min update period, initialLayout + previewImage. |

### Edits (wiring)
- `app/pubspec.yaml` — added `health: ^13.3.1` and `home_widget: ^0.7.0`. (NB: `health ^11` was requested but conflicts with `flutter_localizations`'s `intl ^0.20.3`; `^13.3.1` is the resolvable version and uses the same API surface I call.)
- `app/lib/main.dart` — `unawaited(HomeWidgetService.init());` next to `Notifications.init()` (fully self-guarded).
- `app/lib/widgets/sidebar_sections.dart` — import + a Daily Life `SidebarItem` (`Icons.watch_outlined`, `t.swTitle`) → `SmartwatchScreen`, next to Fitness partner.
- `app/lib/screens/settings_screen.dart` — import + a `_HomeWidgetTile` (SwitchListTile) inserted before the "input source permissions" tile; toggling pushes/clears the widget.
- `app/lib/screens/reminders_screen.dart` — fire-and-forget `HomeWidgetService.refresh(...)` in `build` so the widget tracks reminder changes (no-op when the widget is disabled).

Both new Dart files + all edits pass `flutter analyze` with ZERO issues attributable to this work (the 2 pre-existing repo issues — an unused `en` in the fall-detect section and an unrelated `lostStolenTitle` from another in-flight feature — are not from here). `flutter pub get` resolves; `flutter gen-l10n` succeeds.

---

## Packages added
```yaml
health: ^13.3.1       # #70 — bridges Android Health Connect natively (reads only)
home_widget: ^0.7.0   # #196 — pushes data to a native AppWidgetProvider
```
Resolved lockfile: `health 13.3.1`, `home_widget 0.7.0+1`. No custom Kotlin for
#70 (the `health` package is the whole native bridge). #196's only native code
is the overlay widget provider/layout above.

---

## EXACT manifest entries to inject (integrator → workflow manifest patch)

The workflow's "Patch manifest" Python step already injects permissions after
`<manifest ...>` and `<application>` components before `</application>`. Add the
blocks below the same way (guard each with an `if 'marker' not in s:` check, as
the existing code does for UCropActivity).

### A) #70 Health Connect — permissions + rationale activity-alias

**1. Health Connect read permissions** (inject after `<manifest ...>`, next to
the other `<uses-permission>` lines):
```xml
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_HEART_RATE"/>
<uses-permission android:name="android.permission.health.READ_SLEEP"/>
<uses-permission android:name="android.permission.health.READ_ACTIVE_CALORIES_BURNED"/>
<!-- Android 10+ step sensor fallback used by getTotalStepsInInterval -->
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>
```

**2. Health Connect visibility query** (inject into / alongside the existing
`<queries>` block so the app can detect + launch Health Connect):
```xml
<package android:name="com.google.android.apps.healthdata"/>
<intent>
  <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>
</intent>
```

**3. Permissions-rationale handler** — Health Connect requires the app to
declare a component that handles the "why do you need this data" rationale
intent. Inject INSIDE `<application>` (before `</application>`). An
`<activity-alias>` onto Flutter's existing `.MainActivity` is the lightest
option (no new Kotlin):
```xml
<!-- #70 Health Connect permissions rationale (API 33 and lower) -->
<activity-alias
    android:name="ViewPermissionUsageActivity"
    android:exported="true"
    android:targetActivity=".MainActivity"
    android:permission="android.permission.START_VIEW_PERMISSION_USAGE">
  <intent-filter>
    <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>
    <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>
  </intent-filter>
</activity-alias>
```
And, for Android 14+ (API 34), also add an intent-filter to `.MainActivity`
itself (the step adds it to the existing activity node):
```xml
<!-- add to the existing .MainActivity <activity> for Android 14+ -->
<intent-filter>
  <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>
</intent-filter>
```
(No manifest `android:scheme` or extra theme is needed; the `health` package
drives the permission UI through Health Connect itself.)

### B) #196 Home-screen widget — receiver

Inject INSIDE `<application>` (before `</application>`):
```xml
<!-- #196 Home-screen widget -->
<receiver
    android:name=".AssistoWidgetProvider"
    android:exported="true"
    android:label="@string/app_name">
  <intent-filter>
    <action android:name="android.appwidget.action.APPWIDGET_UPDATE"/>
  </intent-filter>
  <meta-data
      android:name="android.appwidget.provider"
      android:resource="@xml/assisto_widget_info"/>
</receiver>
```
`.AssistoWidgetProvider` resolves to `com.assisto.assisto.AssistoWidgetProvider`
(matches the overlay Kotlin package + the app id `com.assisto`). `@string/app_name`
already exists in the generated project; if the patch runs before it is present,
substitute the literal label `"Assisto"`.

> compileSdk/minSdk: the workflow already forces `compileSdk 36` / `minSdk 23`.
> Health Connect's AndroidX client needs compileSdk ≥ 34 — already satisfied. No
> gradle change required (the `health` plugin pulls its own AndroidX deps).

---

## ARB keys — `.phaseB/up_healthwidget_arb.json`

34 NEW keys (`{"key":["<bn>","<en>"]}`, bn real + natural). Prefixes: `sw*`
(smartwatch, 27) and `hw*` (home widget, 7). Reused existing common key `retry`
(NOT re-emitted). Already merged into `app_en.arb` / `app_bn.arb` (parity 8686 =
8686) and `flutter gen-l10n` run, so the screens compile now.

Parameterized keys (declared with `@`-placeholders, `type: Object`):

| key | params |
|---|---|
| `swBpm` | `bpm` |
| `swHours` | `hours` |
| `swKcal` | `kcal` |
| `swStepsWeekSummary` | `total`, `avg` |

Weekday letters come from Flutter `MaterialLocalizations.narrowWeekdays` — no
date keys. If re-merging from scratch, the 4 parameterized keys above need the
`@`-metadata (the merge used the repo's standard Object-typed placeholders).

---

## Sidebar / settings wiring
- **Sidebar (Daily Life):** `Smartwatch & fitness` (`swTitle`, `Icons.watch_outlined`)
  → `SmartwatchScreen`, placed right after Fitness partner. Done in
  `sidebar_sections.dart`.
- **Settings:** `Home-screen widget` SwitchListTile (`hwTile`/`hwTileSub`) — the
  `_HomeWidgetTile` persists `home_widget_enabled`, pushes the snapshot on enable
  and clears it on disable, with a bn/en toast. Done in `settings_screen.dart`.

---

## DEVICE-TEST-ONLY parts
- **#70 end-to-end:** requires a device with Google Health Connect installed and
  a paired watch/band writing real samples. In CI / an emulator without HC the
  screen compiles and shows the honest `unavailable → install` path (the plugin
  reports `sdkUnavailable`). Permission grant/denial, live steps/HR/sleep/energy,
  and the 7-day chart can ONLY be verified on a real device.
- **#196 end-to-end:** requires placing the widget on a real launcher. The toggle,
  snapshot projection and push code run anywhere, but you can only SEE the widget
  render / tap-to-open on a device after adding it from the widget picker. On
  some OEM launchers the preview image + resize behaviour also need a real device.

---

## Follow-ups (documented, intentionally NOT built)
- **Wear OS tile** (separate heavy module): needs a dedicated `:wear` Gradle
  module + Wear Tile service + a paired-device data layer. Out of scope here;
  build it as its own module later.
- **"Copy today's steps into Fitness"** convenience: deliberately omitted to
  avoid silent double-writes into the Fitness partner store — the smartwatch
  screen links to Fitness instead. Can be added as an explicit one-tap action.
- **Widget background refresh:** today the widget updates on app open / reminders
  view / settings toggle + the 30-min `updatePeriodMillis`. A `home_widget`
  background callback (or FCM) would make it live without opening the app — a
  later enhancement (kept off to respect the project's no-background-work rule
  that removed WorkManager).

---

## bn/en device-test checklist
1. **Language flip:** set app to Bangla, open Smartwatch & fitness — title,
   connect/denied/empty/error copy, metric labels, 7-day summary, privacy note
   all in Bangla; flip to English, repeat. No clipped text at 360dp (metrics are
   2-up cards with ellipsis; run the small-width check).
2. **#70 unavailable:** on a device WITHOUT Health Connect → "Health Connect
   isn't available" + a working **Install Health Connect** button (opens Play /
   HC install), both languages.
3. **#70 connect flow:** with HC installed, tap **Allow & connect** → HC consent
   sheet appears; deny → returns to the connect state with a working **Open
   Health Connect settings** path (never a dead tap). Grant → data loads.
4. **#70 data:** with a watch/band syncing, verify today's steps/HR/sleep/energy
   show real numbers (or an honest "No reading" per metric), and the 7-day bar
   chart + totals/avg are sane. Pull-to-refresh updates.
5. **#70 no-data:** granted but no samples → "No data yet" sub-state (not an
   error), both languages.
6. **#196 toggle:** Settings → turn **Home-screen widget** on → bn/en toast
   prompting to add the widget. Add it from the launcher's widget picker (preview
   shows). Confirm it renders the next reminder + "Today: N" (localised label).
7. **#196 content:** create/snooze/complete a reminder, reopen the Reminders
   screen → widget updates (next reminder + count change). With no upcoming
   reminders → empty state ("No upcoming reminders" / "You're all caught up"),
   both languages.
8. **#196 tap + off:** tap the widget → app opens. Turn the toggle off → widget
   clears to the empty state; "Widget turned off" toast.
