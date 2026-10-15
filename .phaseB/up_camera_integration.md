# In-app Camera — integration note

Wires the "My Circle" hub camera button to a real in-app camera (live preview,
photo + hold-to-record video, recent strip, gallery picker, flash, switch,
edit/draw/text/caption, and send to chat(s) / post-as-Status). Built to
Section-21 "advanced": bn/en via AppLocalizations, no clipped text at 360dp,
honest permission + gated states, original Assisto identity (not a Meta copy).

## Files created

- `app/lib/screens/camera/camera_screen.dart`
  - The camera. Official `camera` plugin live preview (`CameraPreview`), Photo/
    Video mode toggle, big shutter (TAP = photo via `takePicture`, HOLD = record
    via `startVideoRecording`/`stopVideoRecording`, release to stop; in Video
    mode a tap also starts/stops), a horizontal recent-photos strip above the
    shutter, bottom-left gallery button (`image_picker`), top-right flash cycle
    (off/auto/always), top-left close (X), bottom-right front/back switch, and a
    simple enhance button. Lifecycle-aware (disposes/rebuilds the controller on
    background/resume). Routes through the permission gate first.
- `app/lib/screens/camera/camera_permission_gate.dart`
  - `CameraPermissions` (permission_handler wrapper: camera is the hard gate;
    mic + photos are soft and reported separately so video / the gallery strip
    degrade honestly) and `CameraPermissionScreen` (full-screen explain-before-
    ask, and a blocked → "Open settings" screen using `openAppSettings()`).
    Never a dead tap or blank preview.
- `app/lib/screens/camera/camera_preview_edit_screen.dart`
  - Preview + edit after capture/pick: crop + rotate (`image_cropper`), freehand
    DRAW over the image (CustomPaint + gesture), drop/drag TEXT stickers, a
    colour palette + undo, and a caption field. Photo gets the full surface;
    VIDEO shows an honest video placeholder + caption + the same SEND chooser
    (pixel tools don't apply to video). SEND opens the destination sheet.
- `app/lib/screens/camera/camera_draw_canvas.dart`
  - `DrawStroke`, `TextSticker` models and the `DrawPainter` CustomPainter for
    the freehand drawing layer.
- `app/lib/screens/camera/camera_send_sheet.dart`
  - The destination chooser: post-as-Status, or multi-select circle members and
    send to one/several chats. This is the backend-reuse surface (below).

## Files edited

- `app/lib/screens/messenger/messenger_home_screen.dart`
  - Hub camera button wired (see "Hub button" below).
- `app/pubspec.yaml` — packages added (below).
- `.github/workflows/android.yml` — Android permissions + new iOS Info.plist
  patch step (below). The APK's `android/` and `ios/` projects are generated
  fresh at CI time via `flutter create --platforms=android .`, then patched by
  Python steps in this workflow — there is no committed `app/android/` or
  `app/ios/` tree, so permission edits live in the workflow's patch steps, which
  is where the existing CAMERA/RECORD_AUDIO permissions already were.

## Packages added (app/pubspec.yaml)

- `camera: ^0.11.0+2` — official Flutter camera plugin: live preview + photo +
  video recording. The core requirement (a real camera, not a fake preview).
- `permission_handler: ^11.3.1` — camera / mic / photos runtime permission flow
  + `openAppSettings()` for the honest "blocked" screen.
- `image_cropper: ^8.0.2` — crop + rotate on the edit screen.
- `image_picker` (^1.1.2, already present) — reused for the full gallery picker.
- `flutter pub get` run clean after the edit (15 deps added/changed).

## Android permissions (.github/workflows/android.yml → "Patch manifest" step)

Already injected by the workflow: `CAMERA`, `RECORD_AUDIO` (+ INTERNET, location).
ADDED for the gallery strip/picker on modern + legacy Android:
- `android.permission.READ_MEDIA_IMAGES`
- `android.permission.READ_MEDIA_VIDEO`
- `android.permission.READ_EXTERNAL_STORAGE` (`android:maxSdkVersion="32"`)

## iOS usage strings (.github/workflows/android.yml → new "Patch iOS Info.plist" step)

New step injects (only if an `ios/Runner/Info.plist` exists — skipped on the
android-only CI build, correct whenever iOS is enabled):
- `NSCameraUsageDescription` — take photos / record videos to share or post.
- `NSMicrophoneUsageDescription` — record audio while shooting video.
- `NSPhotoLibraryUsageDescription` — pick an existing photo/video to share/post.

## Hub camera button wiring

`messenger_home_screen.dart` already had an `IconButton` (tooltip
`msgrHubCameraTooltip`, `Icons.photo_camera_outlined`) in the AppBar `actions:`
calling `_openCamera`. Previously `_openCamera` pushed `CircleStatusComposerScreen`
(or the status list). Now `_openCamera` pushes the real
`CameraScreen(identity: _identity, members: _members)` (forwarding the on-device
E2E identity + accepted member list already loaded by the hub bootstrap). Added
`import '../camera/camera_screen.dart';` and removed the now-unused
`circle_status_composer_screen.dart` import (the composer is still reached — via
the send sheet's post-as-Status path).

## Sending-to-chat(s) + post-as-Status reuse (NO new backend)

All sends route through EXISTING circle paths; no new endpoints were invented.

- Send to one / several chats — `camera_send_sheet.dart` `_sendToSelected()`:
  uses the SAME relay envelope as `circle_chat_screen.dart._send()`
  (`app/lib/screens/circle_chat_screen.dart:285` encrypt +
  `:315` `POST /circle/<peer>/messages`). For each selected member it
  `SoftwareE2E.encrypt`s the caption to that peer's `public_key` (base64Decode,
  same as `circle_chat_screen.dart:117-120`) and POSTs `content_type: photo|video`,
  a `client_msg_id`, `media_gated: true`, and `...ct.toEnvelopeFields()`.
  `media_gated` mirrors `circle_chat_screen.dart:252` (`mediaGated`) and
  `core/logic/circle_media.py media_gate_notice`: the encrypted blob bucket is
  key-gated until provisioned, so the caption/envelope ships now and the
  integrator attaches the encrypted blob ref at the marked seam. The sheet shows
  an honest gated note so this is never silently misleading.
- Post as Status — `_postAsStatus()` opens the EXISTING
  `CircleStatusComposerScreen(identity, members)`
  (`app/lib/screens/circle_status_composer_screen.dart`), exactly as the owner
  spec states ("Posting as Status reuses the existing status composer flow").
  Text status posts live via `ApiClient.postTextStatus`
  (`app/lib/api.dart:686`); photo/video status stays key-gated inside that
  composer (its own gated tabs), consistent with the rest of the app.

Why this is the correct reuse: there is NO media-blob upload API in `api.dart`
for chat or status (confirmed by grep) — media is key-gated end-to-end today.
Reusing the text/relay envelope + the status composer is the only path that hits
the REAL backend without inventing an endpoint. When encrypted blob storage is
provisioned, the integrator attaches the blob at the two marked seams
(`media_gated` POST in the send sheet; the composer's photo/video tabs).

## ARB

- `.phaseB/up_camera_arb.json` — 37 new keys, 3 parameterized
  (`_params`: `camSentToChats{count:int}`, `camSentPartial{ok:int,fail:int}`,
  `camSendCount{count:int}`). Reused existing keys (NOT re-added): `close`,
  `cancel`, `save`, `continueWord`, `notNow`. bn is real, natural Bangla.
- Cross-checked: every `cam*` getter used in Dart exists in the ARB and every
  ARB key is used (0 orphans both ways).

## Zero Bangla in .dart — confirmed

`grep -rlP '[\x{0980}-\x{09FF}]'` over all new/edited .dart files → none.
All user-facing strings go through `AppLocalizations` getters.

## flutter analyze

`flutter analyze` on the camera files + the hub screen reports ONLY the 41
expected "getter isn't defined for the type 'AppLocalizations'" errors (the new
ARB getters, undefined until the integrator merges `up_camera_arb.json`). No
other errors/warnings/infos. `flutter pub get` is clean.

## Device-test checklist (CANNOT be verified headless)

Needs a real Android device with a camera + a signed APK from the CI build:
1. Tap the hub camera icon → the explain screen appears (first run), then the
   OS camera/mic/photos prompts; grant → live preview fills the screen.
2. Deny camera, reopen → the "blocked" screen with a working "Open settings".
3. Photo mode: TAP shutter → edit screen with the captured photo.
4. Video mode (or HOLD shutter in photo mode): record ring + timer; release/tap
   again → edit screen with the video placeholder.
5. Flash cycle (off/auto/always) visibly changes capture; front/back switch
   flips the preview.
6. Gallery button opens the system picker; a picked item lands on the edit
   screen and appears in the recent strip.
7. Edit: crop+rotate (image_cropper UI), draw strokes + palette + undo, add/drag
   text, type a caption.
8. Send sheet: multi-select members → "Send to N" posts to each chat (verify on
   the receiving device / chat list); "Post as status" opens the existing
   composer with the flow intact.

## Gallery-testable (no camera hardware needed)

- The permission EXPLAIN and BLOCKED screens (force a denied state) — layout +
  bn/en + the Open-settings button.
- The edit/preview screen if launched with a bundled placeholder image: crop/
  rotate dialog, draw + palette + undo, add/drag text, caption field, and the
  send sheet's member multi-select + gated note (the POST will no-op offline but
  the UI/selection is fully exercisable).
