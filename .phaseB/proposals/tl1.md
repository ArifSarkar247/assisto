# tl1 — Firebase Test Lab matrix + Robo, OEM background guide

Branch `agent/tl1` (from origin/main 013451e). Local commits only.

## 3. Test Lab (`.github/workflows/testlab.yml`, manual)

**Inputs:** `apk_source` (android.yml run id → its `assisto-apk` artifact,
plus `assisto-apk-emu` x86_64 if still kept; or `latest-published` →
`/api/v1/app/latest` apk_url), `device_set` (smoke | full), `robo_timeout`
(default 300s), `plan` (spark | blaze → caps), `results_bucket` (optional gs://).

**Secrets:** `GCP_TESTLAB_SA` (new, service-account JSON, project
assisto-247), `CALL_PROOF_A_PHONE`, `CALL_PROOF_A_PASSWORD` (existing test
account A). Missing secret → summary "NOT RUN — missing …", job red.

**Steps:** lint Robo script + run the Python dry-run tests (no creds) →
prerequisites → APK → `google-github-actions/auth@v2.1.7` +
`setup-gcloud@v2.1.2` → `gcloud firebase test android models list
--format=json` → `tools/testlab/pick_devices.py` (prints catalog brands +
per-brand physical count, "NOT in Test Lab" for absent brands, the picks and
uncovered API levels into the job summary) → fill `__TL_*__` placeholders
from secrets (masked) into `$RUNNER_TEMP/robo.json`, lint `--filled` → one
physical matrix (arm64 APK) + one virtual matrix (ARM virtual devices for
the arm64 APK, x86 when the run also has the x86_64 smoke APK) via
`gcloud firebase test android run --type robo --robo-script … --format=json
--no-auto-google-login --results-dir tl-<run>-<attempt>-<label>` → logcats
pulled per device from the raw-results URL → `tools/testlab/summarize.py` →
job summary + artifact **testlab-summary** (`testlab-summary.md`) → verdict
(any device not PASS = red).

**Device selection:** BD brand order Samsung, Xiaomi/Redmi/POCO, OPPO,
vivo/iQOO, realme, OnePlus, Infinix/Tecno/itel, then motorola/Google
fallbacks. Physical, non-deprecated, arm64-capable; round-robin one model per
brand per round, each at the lowest API level it adds (26..36 = Android
8..16); virtual devices fill uncovered levels. smoke = Samsung + first
Chinese-OEM brand + one low-API virtual (3 total). Caps: spark 4 phys / 8
virt, blaze 12 / 11. A static fallback list (a10/29, oriole/33,
MediumPhone.arm 26/30/34) is used only if the catalog query fails; refresh it
from the printout. **Catalog note (honest):** I could not query the catalog
here (no credentials); from public knowledge Test Lab carries Samsung + Google
Pixel widely, some Xiaomi/Redmi, OPPO, vivo, realme and motorola models, and
normally no Walton/Symphony/Infinix/Tecno — the first run's summary will say
exactly. Those brands stay on the real-phone checklist.

**Robo script** `tools/testlab/robo_mycircle.json`: language
(en) → login (tl_login_id / tl_login_password / tl_login_submit) → skip
onboarding (optional) → close the one-time OEM guide (optional `tl_oem_later`)
→ drawer (`Open navigation menu`) → `tl_drawer_my_circle` → chat row
`tl_chat_row` + name regex "Call Proof Test B" (contentDescription and text
variants, both optional; the second can't misfire because the chat screen has
no `tl_chat_row`) → `tl_chat_input` + `tl_chat_send` → `tl_chat_voice_call`
→ `tl_call_hangup` (30 actions). Ids come from a tiny `RoboId` widget
(`lib/widgets/robo_id.dart` = `MergeSemantics(Semantics(identifier:))`;
Flutter sends the identifier to Android as `resource-id`). The MergeSemantics
matters: a plain `Semantics(identifier:)` wrapper became a separate PARENT node
(widget test caught it — Robo could click it but never type into it). Flutter
only offers set-text on a FOCUSED field, so the script clicks each field
before `VIEW_TEXT_CHANGED`; widget tests prove id + text-field flag + set-text
(after focus) on login and chat input, and tap on login/send/call/language. Robo grants runtime permissions by default.
The call really rings test account B (accepted circle contact), as in
call-proof.yml.

**Validation done here:** YAML parses (PyYAML); `robo_lint.py` clean (event
types, descriptor keys, regexes, every tl_* id exists in app/lib, placeholders
unfilled in git); `tools/testlab/test_testlab.py` 13 tests on fixtures of
gcloud's JSON outcome, its stderr (console + GCS URLs) and logcats (Java
FATAL of our process → top frame; other apps' crashes ignored; native
tombstone; ANR). Not run against Test Lab.

`.gitignore`: `!tools/testlab/`.

## 4. OEM background guide

**Finished, not duplicated:** the existing `BatteryGuidanceScreen`
(Settings tile + push settings + voice settings links) was a brand-chip text
list. It is now the guide (same class/route, so the three entry points keep
working); Settings tile renamed **Background & notifications** /
**ব্যাকগ্রাউন্ড ও নোটিফিকেশন**.

- Detection: native `Build.MANUFACTURER/BRAND/MODEL`, SDK, ROM label from
  system properties (HyperOS/MIUI/realme UI/ColorOS/Funtouch/OxygenOS/XOS,
  One UI via SEM_PLATFORM_INT), `PowerManager.isIgnoringBatteryOptimizations`
  (API 23+), `ActivityManager.isBackgroundRestricted` (API 28+). No new
  plugin (device_info_plus is not a dependency).
- Steps per family: Xiaomi/OPPO/realme/OnePlus/vivo/Transsion → auto-start,
  OEM battery page, battery optimisation, lock in recents (by hand, no
  button); Samsung → Unrestricted (App info) + sleeping/deep-sleeping apps
  (Device care battery); Walton/Symphony/near-stock → battery optimisation
  only; any phone with background restriction → "Allow background use".
- Buttons: shown only when `available(step)` says a screen resolves
  (`resolveActivity` + `exported`); label says what opens ("Open" vs "Open App
  info"); after tapping, App-info fallback / nothing-opened notes are honest.
  No resolve → no button, by-hand text ("This phone doesn't let Assisto open
  that screen…"). Done state re-checked on resume.
- Shown once after login: `OemGuideGate.schedule` from `_RootState.build`
  past login + onboarding, Android only, 4 s after the frame, prefs flag
  `oem_guide_seen_v1`, pushes a separate route (home screen untouched). Not
  relevant (all checkable steps already done, e.g. Walton with optimisation
  off) → flag set, nothing shown. Native unavailable → not marked, retried
  next launch. Existing logged-in users also see it once after updating.

**OEM intent list** (`oem/OemGuideChannel.kt`, tried in order, each
resolve-checked and in try/catch, then App info, then "none"):
- Xiaomi/Redmi/POCO autostart: `com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity`, action `miui.intent.action.OP_AUTO_START`; battery saver: `com.miui.powerkeeper/.ui.HiddenAppsConfigActivity` (+ package_name/package_label extras).
- OPPO/realme/OnePlus autostart: `com.coloros.safecenter/.permission.startup.StartupAppListActivity`, `com.coloros.safecenter/.startupapp.StartupAppListActivity`, `com.oppo.safe/.permission.startup.StartupAppListActivity`, `com.oneplus.security/.chainlaunch.view.ChainLaunchAppListActivity`; battery: `com.coloros.oppoguardelf/com.coloros.powermanager.fuelgaue.PowerUsageModelActivity`, `…PowerSaverModeActivity` (ColorOS 12+ → App info, which is where "Allow background activity" lives).
- vivo/iQOO autostart: `com.vivo.permissionmanager/.activity.BgStartUpManagerActivity`, `com.iqoo.secure/.ui.phoneoptimize.BgStartUpManager`, `…AddWhiteListActivity`; background power: `com.vivo.abe/com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity`, `com.iqoo.powersaving/.PowerSavingManagerActivity`.
- Samsung battery (sleeping apps live under it): `com.samsung.android.lool/com.samsung.android.sm.battery.ui.BatteryActivity`, `com.samsung.android.sm/…battery.ui.BatteryActivity`, `…ui.battery.BatteryActivity`; Unrestricted → App info.
- Infinix/Tecno/itel: `com.transsion.phonemaster/com.cyin.himgr.autostart.AutoStartActivity`; Phone Master launch intent for the power step.
- Standard: `Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS`, `ACTION_APPLICATION_DETAILS_SETTINGS`.

**Manifest (android.yml queries block):** `<package>` entries for those 14
vendor packages + the two Settings intents + `miui.intent.action.OP_AUTO_START`,
so resolveActivity works on API 30+. No new permission.

**Play policy decision:** we do NOT declare
`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and never fire
`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, in either flavour. Google
Play allows that permission only when the app's core function breaks under
Doze and FCM high-priority can't serve it; Assisto's calls/messages/SOS are
delivered by FCM high-priority (a6 push), so a reviewer would likely reject
it, and a rejection blocks the whole Play listing. The settings-list intent
needs no permission and is policy-safe; the user taps Assisto → "Don't
optimise" themselves. (The website APK could add the direct dialog later —
one manifest line in the APK-only step — but the gain is one tap, so not now.)

**Startup safety:** channel registration only (inside MainActivity's
try/catch, like the other channels); no native work until the guide calls;
gate runs 4 s after the first post-login frame, one prefs read + one native
call, all try/catch; never on iOS; no WorkManager; no new plugin.

**Robo ids added (no visual change; `RoboId` wrapper):** `tl_lang_en/bn/continue`,
`tl_login_id/password/submit`, `tl_onb_skip`, `tl_drawer_my_circle`,
`tl_chat_row`, `tl_chat_input`, `tl_chat_send`, `tl_chat_voice_call`,
`tl_call_hangup`, `tl_oem_done/later`. home_screen.dart is not touched.

## Checks
- flutter analyze: 0 errors (132 pre-existing warnings/infos, none in tl1 code).
- Full flutter test: 2098 passed (all). `test/tl1_oem_guide_test.dart`: 44 tests, 3 consecutive green runs (detection, steps, relevance, honest buttons, done-on-resume, first-run Done/Later, show-once gate incl. "another screen on top", no overflow at 360 px x1.3/x2.0 for 6 phones bn+en, Robo ids on actionable nodes).
- Gallery (reviewed): oem_guide_{oppo,xiaomi,samsung,vivo}_bottom, oem_guide_samsung_done, oem_guide_walton_allset — bn/en, light/dark, x1.0 and x2.0. Brand ChoiceChips clipped at x2.0 → replaced by wrapping pills.
- `python3 app/tool/lang_gate.py` clean; `python3 tools/route_check.py --report-only` 0 problems.
- Kotlin: `OemGuideChannel.kt` + MainActivity + every overlay file except the
  widget/FCM ones (need plugin jars) compiled with kotlinc 2.x against
  android-35 + flutter_embedding.jar: rc=0.
- ARB: `.phaseB/up_tl1_arb.json` (37 keys, en+bn); not applied in git.

## Integrator
1. `python3 ~/assisto/bin/arb_apply.py --app app .phaseB/up_tl1_arb.json`.
2. Merge; android.yml conflict, if any, is only inside the `<queries>` string.
3. Owner: owner_actions/TESTLAB_SETUP.md before the first Test Lab run.
