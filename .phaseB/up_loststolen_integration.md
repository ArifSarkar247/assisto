# #80 Lost / Stolen Phone Protection (device-admin) — Integration Note

Native device-admin anti-theft: remote **lock**, loud **alarm**, **locate** (reuses
SOS GPS), and a lock-screen **lost-message** with owner contact. Honest
INACTIVE states, a locally-hashed recovery PIN, and a documented (gated)
SMS-trigger seam. **No remote wipe** (deliberate — see Play-policy section).

---

## 1. Files

### Dart
- `app/lib/screens/lost_stolen_screen.dart` — the whole feature UI + MethodChannel
  client. Zero Bangla literals (all strings via `AppLocalizations`).
- `app/lib/widgets/chatnav.dart` — added route `'lost_stolen' => LostStolenScreen()`.
- `app/lib/widgets/sidebar_sections.dart` — added a Safety-section `SidebarItem`
  (`Icons.phonelink_lock_outlined`, `t.lostStolenTitle`, synonyms incl.
  lost/stolen/theft/anti-theft/churi/harano).
- `app/lib/l10n/app_en.arb` + `app/lib/l10n/app_bn.arb` — 59 new keys merged;
  localizations regenerated (`flutter gen-l10n`).

### Native overlay (paths mirror `android/`)
- `app/android_overlay/app/src/main/kotlin/com/assisto/assisto/AssistoDeviceAdminReceiver.kt`
  — the real `DeviceAdminReceiver`.
- `app/android_overlay/app/src/main/kotlin/com/assisto/assisto/MainActivity.kt`
  — **overwrites** the `flutter create`-generated empty MainActivity; adds the
  `com.assisto/device_admin` MethodChannel. (Compatible with the existing
  `AssistoWidgetProvider.kt` #196, which uses `HomeWidgetPlugin` and needs no
  MainActivity wiring.)
- `app/android_overlay/app/src/main/res/xml/device_admin.xml` — the policy set.

### Reused (NOT duplicated)
- **GPS**: `_position()` in `lost_stolen_screen.dart` is the identical Geolocator
  flow as `app/lib/screens/journey_sos_screen.dart:75-90`
  (`Geolocator.isLocationServiceEnabled` / `checkPermission` / `requestPermission`
  / `getCurrentPosition`).
- **Location transport**: `ApiClient.journeySos(...)` from
  `app/lib/widgets/journey_api.dart:82-95` (POST `/journey/sos`) — the same
  endpoint SOS uses; "report last location" calls it with `silent:true`.
- **PIN hashing**: `Pbkdf2.derive(...)` from `app/lib/crypto/e2e.dart:118` — no
  new `crypto` dependency added.

**pubspec.yaml**: unchanged. Everything used (`geolocator`,
`flutter_secure_storage`, local `crypto/e2e.dart`) is already present.

---

## 2. Manifest injection — EXACT text (add to the workflow's manifest-patch step)

The workflow already injects `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION`
(reused for locate). **Add these** so device-admin + alarm vibrate work:

### Permissions (inside the existing `perms` block, alongside the others)
```xml
<uses-permission android:name="android.permission.VIBRATE"/>
```
> `BIND_DEVICE_ADMIN` is NOT a `<uses-permission>` — it is enforced on the
> `<receiver>` via `android:permission` (below). No extra runtime permission is
> needed to call `DevicePolicyManager.lockNow()` once admin is granted. Alarm
> audio needs no permission (uses the ALARM stream).

### Receiver (inject INSIDE `<application>`, same pattern as the UCropActivity patch)
```xml
<receiver
    android:name="com.assisto.assisto.AssistoDeviceAdminReceiver"
    android:label="@string/app_name"
    android:description="@string/app_name"
    android:permission="android.permission.BIND_DEVICE_ADMIN"
    android:exported="true">
    <meta-data
        android:name="android.app.device_admin"
        android:resource="@xml/device_admin"/>
    <intent-filter>
        <action android:name="android.app.action.DEVICE_ADMIN_ENABLED"/>
    </intent-filter>
</receiver>
```

Suggested Python patch (mirrors the UCropActivity approach — do NOT hand-edit
the workflow yourself; this is for the workflow owner to add):
```python
admin_receiver = (
    '\n        <receiver'
    ' android:name="com.assisto.assisto.AssistoDeviceAdminReceiver"'
    ' android:label="@string/app_name"'
    ' android:description="@string/app_name"'
    ' android:permission="android.permission.BIND_DEVICE_ADMIN"'
    ' android:exported="true">'
    '\n            <meta-data android:name="android.app.device_admin"'
    ' android:resource="@xml/device_admin"/>'
    '\n            <intent-filter>'
    '<action android:name="android.app.action.DEVICE_ADMIN_ENABLED"/>'
    '</intent-filter>'
    '\n        </receiver>\n'
)
if 'AssistoDeviceAdminReceiver' not in s:
    s = s.replace('</application>', admin_receiver + '    </application>', 1)
if 'android.permission.VIBRATE' not in s:
    s = s.replace('<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.INTERNET"/>'
        '\n    <uses-permission android:name="android.permission.VIBRATE"/>', 1)
```

### device_admin.xml (already in the overlay — NO injection needed)
`res/xml/device_admin.xml` is merged by the overlay copy step. Contents:
```xml
<device-admin xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-policies>
        <force-lock />
        <limit-password />
        <reset-password />
        <watch-login />
    </uses-policies>
</device-admin>
```
Scope is **minimal on purpose**: `force-lock` (remote lock), `limit-password`/
`reset-password` (enforce a lock on a lost device), `watch-login` (seam for a
failed-unlock alarm). **No `<wipe-data>`.**

---

## 3. MethodChannel contract — `com.assisto/device_admin`

| method | args | returns | notes |
|---|---|---|---|
| `isAdminActive` | — | `bool` | the ONLY source of truth for "protection on" |
| `requestAdmin` | `{explanation: String}` | `bool` | opens system consent screen; returns `false` if not-yet-granted (Dart re-polls on resume) |
| `lockNow` | — | `bool` | re-checks admin; `false` if not granted / SecurityException |
| `startAlarm` | — | `bool` | max-volume ALARM-stream loop + vibrate |
| `stopAlarm` | — | `bool` | — |
| `openAdminSettings` | — | `bool` | opens Security settings so the owner can **deactivate + uninstall** |

Honesty: every admin-gated call re-checks `isAdminActive()` natively, so Dart
can never show a protection as active when the OS hasn't granted it. On
`MissingPluginException` (channel absent) the UI falls back to INACTIVE.

---

## 4. Settings wiring

- SharedPreferences (via `Settings` helper in `state.dart`): `ls_action_lock`,
  `ls_action_alarm`, `ls_action_message`, `ls_action_locate`, `ls_sms_trigger`,
  `ls_owner_name`, `ls_owner_phone`, `ls_lost_message`.
- `flutter_secure_storage`: `ls_pin_salt`, `ls_pin_hash` (PBKDF2-HMAC-SHA256,
  20000 iters, 16-byte random salt; raw PIN never stored). The PIN gates the
  "Manage / deactivate" path as a deterrent (constant-time compare).
- Nav: ChatNav `'lost_stolen'`, sidebar Safety section.

---

## 5. ARB keys

59 new `lostStolen*` keys, all static (no placeholders), in
`.phaseB/up_loststolen_arb.json` as `key:[bn,en]`. Already merged into both
`.arb` files + regenerated. The screen also reuses existing generic keys
`cancel` / `save` / `edit` / `safetyCheckinSet`.

---

## 6. PLAY-POLICY CHECKLIST — READ BEFORE PUBLISHING

Device-admin anti-theft is a **high-scrutiny** area on Google Play. The owner
must verify ALL of the following before uploading a build with this feature:

1. **Device Admin API deprecation.** Many `DeviceAdminReceiver` policies are
   deprecated for the *legacy* admin path; Google steers new apps to
   Device Policy Controller / managed-profile APIs. `force-lock`, `reset-password`
   and `wipe-data` in particular are restricted. **Confirm** that the policies we
   request (`force-lock`, `limit-password`, `reset-password`, `watch-login`) are
   still accepted for a consumer anti-theft app on the **current target SDK**,
   and that `lockNow()` still works without being a device/profile owner.
2. **Anti-theft / "theft" use-case review.** Apps whose purpose is locating or
   locking a lost device can trigger a manual policy review and may need to be
   an **approved / verified** anti-theft app. Expect to justify the feature in
   the Play Console declaration.
3. **Clear disclosure + consent.** Lock/locate/alarm must be clearly disclosed
   in-app AND in the store listing + privacy policy. The consent is already the
   real system device-admin screen (`ACTION_ADD_DEVICE_ADMIN` with an explanation
   string) — keep that; do not auto-enable anything.
4. **Permissions declaration.** Location is sensitive — the Play **Location
   permissions** declaration must cover this use; it reuses the existing SOS
   location flow, so align the justification with the SOS declaration.
5. **Uninstall-resistance must be honest.** The listing must not overclaim; the
   app surfaces the true limitation (owner can always deactivate via Settings).
6. **AVOID remote-wipe.** `<wipe-data>` is intentionally NOT requested. Adding
   it escalates the review substantially (data-destruction capability) and risks
   rejection. **Only** add wipe if the owner explicitly accepts the anti-theft
   policy review and adds the matching disclosure + consent. Recommended
   conservative scope: **lock + alarm + locate + lost-message**.

**Recommendation:** ship the conservative scope above; treat remote-wipe and the
SMS-trigger receiver as separate, reviewed follow-ups.

---

## 7. DEVICE-TEST-ONLY (cannot be validated in headless CI)

- Granting device-admin on the real system consent screen.
- `lockNow()` actually locking the screen.
- The alarm playing at max ALARM volume + vibration (no audio/vibrator in CI).
- Uninstall being blocked while admin is active, then allowed after deactivation.
- The lost-message appearing on the lock screen (OEM-dependent; may need an
  owner-info / lock-screen-message hook on some ROMs — note for the device tester).
- GPS fix + `/journey/sos` round-trip (needs a signed-in backend + a real fix).

CI validates: Dart analyze (0 errors), lang gate (0 mixed/hard-coded strings,
0 Bangla in .dart), Kotlin compiles in the merged `android/` tree, APK builds.

---

## 8. Trusted-contact / SMS-trigger SEAM (documented + GATED)

The SMS-command trigger (text a secret command from another phone to
lock/alarm/locate) needs a **separate native `BroadcastReceiver`** for
`android.provider.Telephony.SMS_RECEIVED` with the `RECEIVE_SMS` permission —
**NOT shipped in this build.** In the UI the toggle is honestly labelled
"coming soon" and disabled. To add it later:
- New overlay receiver (e.g. `AssistoSmsCommandReceiver.kt`) registered with an
  `<intent-filter>` for `SMS_RECEIVED` + `<uses-permission RECEIVE_SMS>`.
- It must match a command keyed to the **recovery PIN** before acting (don't
  act on any inbound SMS), and route to the same lock/alarm/locate paths.
- `RECEIVE_SMS` is itself a **restricted Play permission** (requires a separate
  permissions declaration + justification) — gate it behind its own review.
A trusted-contact variant (a Circle member triggers via the backend/FCM) is the
lower-risk alternative and avoids the SMS-permission review entirely.

---

## 9. bn/en Device-test checklist

Run in **both** languages (switch app language), confirm every string renders
(no clipping, no mixed script):

1. **INACTIVE honesty** — fresh install: banner shows **Protection is OFF**,
   lock/locate rows say "needs device-admin", Enable button visible.
2. **Enable** — tap Enable → system device-admin consent screen appears with the
   explanation; grant it → on resume the banner flips to **Protection is ON**.
3. **Recovery PIN** — set a 4–8 digit PIN; "A PIN is set" shows; re-open and the
   PIN is required before the Manage/deactivate path opens; wrong PIN is rejected.
4. **Remote LOCK** — tap Test lock → screen locks immediately. (Full test:
   trigger from another phone once the SMS/trusted-contact path exists.)
5. **Alarm** — tap Test alarm → loud ALARM-stream sound + vibration even on
   silent; Stop alarm works.
6. **Locate** — tap Report location now → with a GPS fix + signed-in backend,
   "Last location reported"; offline shows the queued message.
7. **Lost message** — set owner name/phone/message; confirm it's stored.
8. **Uninstall-resistance** — while admin active, try to uninstall Assisto →
   Android blocks it. Deactivate via Manage → Settings, then uninstall succeeds.
9. **bn/en parity** — repeat steps 1–8 in the other language; all labels localized.
