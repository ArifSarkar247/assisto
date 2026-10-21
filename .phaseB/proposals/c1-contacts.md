# c1-contacts — native proposal (phonebook read for "Contacts on Assisto")

Branch `agent/c1-contacts`. Everything except the phonebook read already ships in
Dart and on the backend. This build uses `UnavailableContactsSource`: the screen
says honestly that "reading your phonebook arrives in the next update", and
find-by-number works. Apply the three parts below in the next native build,
and only after a CI launch smoke on API 33.

## 1. pubspec (one new dependency)

```diff
--- a/app/pubspec.yaml
+++ b/app/pubspec.yaml
@@
   permission_handler: ^11.3.1 # camera/mic/photos permission flow + openAppSettings
+  flutter_contacts: 1.1.9+2   # c1-contacts: read-only phonebook (MIT). Lazy; screen-only.
```

- Package: `flutter_contacts`, exact version **1.1.9+2**, licence **MIT**
  (fine for commercial use). It is a plain method-channel plugin. It has **no
  startup ContentProvider, no WorkManager and no Application-level
  initialiser**. Its ContentObserver is registered only when
  `FlutterContacts.addListener` is called. We call it only while the
  Contacts screen is open.
- We use it **read-only**. We never call insert, update or delete, so we do
  NOT add `WRITE_CONTACTS`.
- The permission itself goes through `permission_handler` (`Permission.contacts`),
  which is already in pubspec. No extra plugin is needed for it.
- After `flutter pub get`, check that the CI build log has no Kotlin or
  compileSdk conflict. flutter_contacts 1.1.9+2 builds with the AGP/Kotlin
  versions that recent Flutter stable uses. If CI complains, pin
  `flutter_contacts: 1.1.7+1`. Its API is the same for every call we use.

## 2. Manifest (one line, via the CI manifest patch)

The manifest is patched in `.github/workflows/android.yml` (the `perms`
string). Add one line:

```diff
--- a/.github/workflows/android.yml
+++ b/.github/workflows/android.yml
@@
               # #80 lost/stolen — alarm vibration
-              '\n    <uses-permission android:name="android.permission.VIBRATE"/>\n'
+              '\n    <uses-permission android:name="android.permission.VIBRATE"/>'
+              # c1-contacts — read the phonebook ONLY after the in-app disclosure
+              '\n    <uses-permission android:name="android.permission.READ_CONTACTS"/>\n'
           )
```

The resulting manifest line is:
`<uses-permission android:name="android.permission.READ_CONTACTS"/>`

Play Console: READ_CONTACTS is not a restricted permission. It does need the
**prominent in-app disclosure** (already built: `C1Disclosure`, shown before
the OS prompt, which says "We only send hashed numbers to find who is on
Assisto"). The **Data safety** form must also say: "Contacts: collected? No —
only salted hashes are sent to match; nothing about non-users is stored."
Mention the same in the privacy policy.

## 3. Dart (move one file into lib + one line)

1. Copy `.phaseB/pending_native/c1/device_contacts_source.dart` →
   `app/lib/services/device_contacts_source.dart`. It is written against
   `flutter_contacts` 1.1.9+2 + `permission_handler` 11.
2. Point the lazy factory at it with one line in `app/lib/main.dart`. Assigning
   a closure creates nothing. The source is built only when the Contacts
   screen opens:

```dart
// app/lib/main.dart (top-level, before runApp — creates NOTHING at launch)
import 'services/contacts_source.dart';
import 'services/device_contacts_source.dart';
...
ContactsSources.factory = () => DeviceContactsSource();
```

   (Instead, you can put this line at the start of
   `_ContactsScreenState._source` with `widget.source ?? DeviceContactsSource()`.
   Both are lazy.)

### Crash guards (already in the file)
- `ContactsSources.create()` wraps the factory in try/catch. A plugin that
  fails to load falls back to `UnavailableContactsSource`, which is the honest
  banner, not a crash.
- Every plugin call (`status`, `request`, `read`, `addListener`,
  `removeListener`, `openAppSettings`) is in try/catch. On failure it returns
  `ContactsPermission.unavailable` or an empty list.
- `read()` checks `Permission.contacts.status.isGranted` again before it
  touches the plugin.
- The screen asks the OS only after the user taps Allow on the disclosure, and
  remembers that consent (`c1_contacts_consent_v1`). If permission is later
  revoked, the screen returns to the disclosure or the denied state, with
  Open settings and Find by number instead.

## 4. Smoke checklist for the integrator (CI, API 33)
- App launch is unchanged (no plugin code runs before you open Contacts).
- Open Messenger → Contacts → disclosure → Allow → OS prompt → the list shows
  "On Assisto" first and Invite for everyone else.
- Deny → denied state → "Find by number instead" works.
- Add or edit a phonebook contact while the screen is open → the list
  re-syncs within about 2 s. Pull-to-refresh also re-syncs.

## No other native changes
No Gradle, MainActivity, Kotlin, service or ContentProvider changes.
