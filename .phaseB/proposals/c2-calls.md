# c2-calls — proposal (manifest / Gradle / pubspec / live steps)

Branch `agent/c2-calls`. Real 1:1 voice/video calls + call sounds.

## 1. pubspec — NO change
`flutter_webrtc: ^1.6.2` is already in pubspec (a2-cctv, SHARED_DEPS.md).
No new packages: tones are generated in Dart and played through our own
native AudioTrack (`calls/CallsChannel.kt`), ringtones through RingtoneManager.

## 2. AndroidManifest (android.yml manifest patch) — ONE attribute

Picture-in-picture for video calls. Without it `enterPip` answers `false`
(the PiP button simply does nothing; no crash), so this is safe to apply later.

```diff
--- a/.github/workflows/android.yml   (inside the manifest-patch python block, after the w1-webphoto App Link block)
+          # ---- c2-calls ---- video calls can shrink to picture-in-picture.
+          if 'android:supportsPictureInPicture' not in s:
+              i = s.find('android:name=".MainActivity"')
+              if i != -1:
+                  s = s[:i] + 'android:supportsPictureInPicture="true"\n            ' + s[i:]
```

All permissions calls need are ALREADY in the patch: RECORD_AUDIO, CAMERA,
MODIFY_AUDIO_SETTINGS, ACCESS_NETWORK_STATE, CHANGE_NETWORK_STATE, WAKE_LOCK
(proximity), VIBRATE, BLUETOOTH_CONNECT (+ legacy BLUETOOTH ≤30) for headset
routing, USE_FULL_SCREEN_INTENT, POST_NOTIFICATIONS.

Flutter's default MainActivity `configChanges` already contains
orientation|screenSize|smallestScreenSize|screenLayout, which PiP needs.

## 3. MainActivity.kt — applied directly (task allowed "minimal registration")
* `CallsChannel.register(...)` in `configureFlutterEngine` (try/catch).
* `onActivityResult` forwards ONLY our ringtone-picker request code
  (0x5a11) to CallsChannel; everything else goes to `super` (plugins).
* `onPictureInPictureModeChanged` → `CallsChannel.onPipChanged` (try/catch).
* `onDestroy` → `CallsChannel.release()` (stops tone/ringtone/proximity).

OPTIONAL follow-up (not applied): auto-enter PiP when the user presses Home
during a live video call:
```kotlin
override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    try { com.assisto.assisto.calls.CallsChannel.autoPipIfVideoCall() } catch (e: Throwable) {}
}
```
(needs a small `autoPipIfVideoCall` flag set from Dart; left out to keep the
launch path untouched until the CI API-33 smoke has run once.)

## 4. Backend — migration + routes (no live step besides migrate)
* `core/migrations/0055_c2_calls.py` (depends on 0053_w1_webphoto — integrator
  rechains after 0054): CallSession, RtEvent, RtPresence.
* Routes appended in `core/urls.py` block `# ---- c2-calls ----`:
  `rt/events`, `rt/send`, `circle/calls/incoming`, `circle/calls/<id>`.
* `push.py`: new data-only kind `missed_call` (TTL 24 h, app channel
  `missed_calls`).
* Live: `manage.py migrate` on deploy. coturn is unchanged (credentials come
  from the existing `TURN_STATIC_SECRET` / `TURN_HOST` settings; TURN_HOST on
  the live box must be `turn.lifeassisto.com`).

## 5. Real-time transport — why short polling, and the WebSocket upgrade

The box runs gunicorn **sync** workers (3) with no Django Channels / ASGI.
A WebSocket (or a held long-poll) would pin one worker per open phone, so
the live transport is SHORT polling of ONE queue (`RtEvent`, one row per
recipient, id = sequence number): `GET /rt/events?after=<seq>` returns at
once. Phones poll every 0.5 s while a call is being set up or live, 2.5 s
while the app is open without FCM (5 s with FCM), and stop in background.
Measured cost: one indexed SELECT per poll.

Envelope (shared with c3-msg presence/typing):
```
{"seq": <int>, "topic": "call.signal" | "call.state" | "call.incoming"
          | "presence.*" | "typing.*", "payload": {...}, "ts": "<iso8601>"}
```
Producers: server code calls `views_c2_calls.rt_publish(user, topic,
payload)`; client sends go to `POST /rt/send {topic, payload}` and are
dispatched by prefix through `views_c2_calls.register_producer(prefix, fn)`
(c2 registers `call.`; c3 registers `typing.` / `presence.`).
Dart: `lib/realtime/realtime_transport.dart` `PollRealtimeTransport`
(connect / subscribe(prefix) / send(topic, payload) / events stream /
reconnect / setFast / setPaused / close / connected) — the implementation
behind c3's `RealtimeChannel` interface (integrator: `implements
RealtimeChannel`, or a 10-line adapter if c3's signatures differ).

WebSocket follow-up (when wanted): add `channels` + `daphne` (or run a
separate small `uvicorn` ASGI process on another port behind Caddy for
`/ws/rt`), push each `RtEvent` row to the user's group on create, and swap
`PollRealtimeTransport` for a `WsRealtimeTransport` with the SAME envelope
and `after=<seq>` resume. Nothing else in the call code changes.

## 6. Not done (documented, not faked)
* Android **CallStyle** notification: flutter_local_notifications 17 has no
  CallStyle API; we use category=call + full-screen intent + Accept/Decline
  actions (the existing path). A native CallStyle post from AssistoFcmService
  would duplicate the Dart-drawn ring — follow-up.
* **ConnectionService / self-managed** telecom: not added (ColorOS crash
  history; needs MANAGE_OWN_CALLS + a service). Follow-up after two-phone
  test passes.
* Call waiting: a second incoming call while in a call is answered "busy".
* Group calls (circle/groups/<id>/call, messenger/group-call) are untouched.
