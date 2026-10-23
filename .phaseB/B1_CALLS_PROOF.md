# B1 — Calls: voice↔video, controls, PiP, quality, reconnect (branch `agent/b1-calls`)

Owner order part B, items 1, 2 and 6. Items 3 (group calls / SFU), 4 (screen share) and 5 (recording) are
**designed below, not built**.

## 0. Reality run 39946885424 — flow 18 "video call never confirmed connected"

**Root cause (from the run's logcat + django.log):** in step "A accepts → video call connects", A's
`getUserMedia({audio, video})` failed on the emulator (`FlutterWebRTCPlugin: getUserMedia(): Failed to create
new track` — the camera, not the mic). `WebRtcCallMedia.open()` threw, the controller ended the WHOLE call
with `POST /circle/calls/2/event {event:fail}` right after `answer`, so A never sent its SDP answer (django.log:
zero `rt/send` from A for call 2) and B (the caller) could never reach ICE connected. The backend behaved
correctly; the app was wrong to fail a video call because only the camera refused.

**Fix:** `WebRtcCallMedia.open(video: true)` now retries audio-only when the camera fails and reports
`cameraUnavailable`; the controller goes on with the camera OFF, shows "The camera couldn't start…" and tells
the other side `media {camera:false}`. Turning the camera on later re-tries it (callee asks the caller to
re-offer with `reneg_request`). Mic failure still fails honestly (as before).

Tests: `app/test/b1_calls_test.dart` › "camera refused at start (reality run 39946885424)";
`backend/core/tests_b1_calls.py` › `VideoCallCameraOffRegressionTests` (video call, callee answers + camera-off
media state → server phase `connected`, record `video/active`; and the old `fail`-before-answer path ends as
`failed`, never a fake connect). Needs a new reality run to confirm on CI.

## 1. What works (proven by tests)

| Feature | How | Tests |
|---|---|---|
| Voice → video request | `video_request` signal; other screen shows Accept / Not now card; 30 s timeout both sides (`video_cancel` / `video_decline{reason:timeout}`); both-asked-at-once = yes | b1_calls_test "voice -> video" groups |
| Accept → renegotiation | camera opens (`startVideo`: reuses the voice offer's recv-only video transceiver via addTrack with the AUDIO stream id, or `replaceTrack` after a downgrade); ONLY the caller offers (`reneg_offer`/`reneg_answer`) → no glare; audio is never torn down; 15 s answer timeout → back to voice + honest notice | same |
| Plan gate on upgrade | server: `video_request` runs `circle_calls.can_place_call(…, "video")` for the ASKER → 402 `upgrade_required` (never relayed); the person accepting may be free; **"Free calls (testing)" lifts it** (`calls_free.entitle`) | tests_b1_calls `test_free_user_request_is_gated_402…`, `test_free_calls_testing_switch…` |
| P&L | on `video_accept` the CallRecord becomes `kind=video`, so history and `turn_monitor` relay-cost (per kind) count it as video | tests_b1_calls `test_premium_caller_upgrades…` |
| Video → voice | "Voice only" button: instant for both (`video_off`, `replaceTrack(null)`, no renegotiation); the other side gets "X switched to a voice call"; upgrading again works | b1 "video -> voice" |
| Mute / camera / flip | unchanged controls + `media {camera, mic, video}` sent on every change, on connect when non-default and after every reconnect; old builds' `{camera}` still understood | b1 "mic / camera state" |
| Remote badges | "Nadia is muted" chip, "Their camera is off" chip + avatar instead of video, own camera-off tile | widget tests + shots |
| Audio route | flutter_webrtc's own AudioSwitch (`Helper.audiooutputs` / `selectAudioOutput`: earpiece / speaker / bluetooth / wired-headset) — no new native code. Button = plain earpiece↔speaker toggle; with a headset/Bluetooth connected it opens a picker | b1 "route picker…" |
| Quality | getStats: RTT + loss + **jitter** + **availableOutgoingBitrate** → Good/Fair/Poor bars + short text on Fair/Poor; video needs more bitrate for "good"; relay vs direct shown only in debug builds | b1 "Good / Fair / Poor…" |
| Reconnect | ICE disconnected/failed → "Reconnecting…" + hint; caller repeats ICE-restart offers every 6 s; callee sends `restart_request` (caller restarts); give up after 30 s with honest "Connection lost" on both; server keeps a reconnecting call 35 s (was 15 s heartbeat) | b1 "reconnect state machine", tests_b1_calls `ReconnectGraceTests` |
| PiP (video) | back / Home during a LIVE video call → Android PiP (API 31+ `setAutoEnterEnabled`; 26-30 user-leave hint via reflection); manifest already gets `supportsPictureInPicture` in CI (android.yml) | crash-guarded native; needs phones |
| Minimize (voice, or video without PiP) | back / "Minimize" (chevron) → call keeps running, app-wide green "Tap to return to the call" bar (MaterialApp.builder) with timer + hang-up; tap re-opens the same call | b1 "Minimize hands the LIVE call…", "mini bar hang-up…" |

Back during a live call no longer hangs up (it minimizes); the red button still ends it.

## 2. Needs two real phones (owner steps)

Use two phones in each other's My Circle, both on this build. A = caller.

1. **Voice → video:** A voice-calls B, B answers. A taps **Video**. B sees "A wants to switch to video" → **Accept**.
   Both should see each other within ~3 s; audio must not cut. Repeat with B tapping **Not now** → A sees
   "B wants to stay on voice for now". Repeat with no answer for 30 s → "No answer to the video request".
2. **Callee asks:** B taps **Video**, A accepts → both video.
3. **Video → voice:** in video, either taps **Voice only** → both back to voice instantly; then Video again works.
4. **Plan gate:** with "Free calls (testing)" OFF and a free account asking → "Video calling needs Premium — your
   voice call goes on". With the switch ON → allowed.
5. **Badges:** mute on A → B shows "A is muted"; camera off on A → B shows "Their camera is off" + avatar.
6. **Audio route:** connect Bluetooth earbuds on A → speaker button opens the picker (Earpiece / Speaker /
   Bluetooth); each choice must really move the sound. Also wired headphones.
7. **Network change:** during a call switch A from Wi-Fi to mobile data → "Reconnecting…" then back within
   ~10 s; mute state kept. Airplane mode for 40 s → both end with "Connection lost".
8. **PiP:** in a video call press Home → small floating window (Realme/OPPO/Xiaomi/Samsung/vivo); tap it to
   return. Voice call: back → green bar at the top of the app; tap it to return; red icon ends the call.
9. **Camera busy:** open the camera app on B, then answer a video call → call connects with B's camera off and
   the honest camera message (the reality-run fix).
10. Quality: walk to weak signal → bars + "Fair/Poor connection".

## 3. Remaining / not done

- Group calls (B3), screen share (B4), consented recording (B5) — designs below.
- `connectivity_plus` was NOT added (no pubspec change); network changes are detected through ICE
  disconnected/failed, which libwebrtc raises on Android network switches. Proposal if wanted later: listen to
  connectivity changes and call `restartIce()` immediately (saves the ~2 s ICE timeout).
- Mini bar re-open uses `CallRuntime.reopenCall` (registered by the call screen); covered by widget tests, needs a
  phone check (step 8).
- PiP and audio routes are only provable on real phones.

## 4. Design — B3 group calls (LiveKit SFU, Apache-2.0)

- **Topology:** 1:1 stays P2P (today's code). 3+ people → LiveKit SFU on our box (lifeassisto.com),
  `livekit-server` single binary, systemd unit, behind Caddy for the WSS signalling (`/rtc` → 127.0.0.1:7880).
- **Ports:** 7880 (HTTP/WS, local only via Caddy), 7881/tcp (ICE-TCP), 50000-60000/udp (media; open in the
  security group). Reuse our coturn for clients behind strict NAT: LiveKit `rtc.turn_servers` with the same
  `TURN_STATIC_SECRET` (time-limited creds from `core/logic/rtc.py`), so no second TURN.
- **Token endpoint:** `POST /api/v1/circle/calls/<id>/sfu-token` → LiveKit JWT (room = `call-<id>`,
  identity = user id, grants: publish/subscribe; host gets `roomAdmin` for "mute others"). Gate: same
  `can_place_call` + `calls_free.entitle`; never blocked for accepted My Circle contacts' voice.
- **Upgrade 1:1 → group ("Add people"):** host invites → server creates the room, sends `call.signal
  {kind:'sfu_move', url, token}` to both 1:1 phones; both join the room, then close the P2P peer (audio
  overlap ~1 s, no drop). New signal kinds go into `SIGNAL_KINDS`.
- **App:** `livekit_client` (Apache-2.0) behind a deferred import like `webrtc_media.dart`; `GroupCallController`
  mirrors `CallController` (phases, notices, media-state from LiveKit track mute events → same badges); grid
  (2×2, 3×3 paged), active speaker (LiveKit `activeSpeakersChanged`), host mute (server API `MutePublishedTrack`),
  leave/rejoin (token valid for the call's life).
- **Cost metering → P&L:** LiveKit webhooks (`participant_left`, `track_unpublished`) + its `/metrics`
  (Prometheus `livekit_packet_bytes`) → new `SfuUsage` rows (call_id, bytes_in/out, minutes) → `turn_monitor`
  style per-kind cost (`sfu_voice`, `sfu_video`) priced in `core/logic/pricing.py` (admin-editable), shown in
  Owner Admin P&L next to TURN relay cost; `free_testing` flag carried as today.

## 5. Design — B4 screen share

Android `MediaProjection` via flutter_webrtc `getDisplayMedia` (it starts its own projection); Android 14+
requires a `mediaProjection` foreground service type → proposal to declare the service type in the manifest
and start our existing `CallKeepAlive` service with `FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION` before
`getDisplayMedia`. Share = `replaceTrack` of the video sender with the screen track (same path as
`startVideo`), signal `media {screen:true}`; the other side shows "X is sharing their screen"; a red
"You are sharing your screen — Stop" banner stays on top while sharing. Same plan gate as video.

## 6. Design — B5 recording (consent only)

Never silent. Request → `call.signal {kind:'record_request'}` → the other person must tap Allow; either can
stop; a red "Recording" chip shows on both screens the whole time; denied = nothing recorded. Record locally
on the requester's phone (no server media): mix the remote + local audio tracks via flutter_webrtc
`MediaRecorder` (Android) to an encrypted file in the app's private storage; history row gets a
"recorded (both agreed)" mark with both consent timestamps stored server-side (`CallSession` JSON field,
migration needed). Legal text reviewed by the owner before launch (BD law: all-party consent).
