# B3 / B4 / B5 — group calls (LiveKit SFU), screen share, consent recording (branch `agent/b3-group`)

Owner order part B items 3, 4, 5. Design notes from `.phaseB/B1_CALLS_PROOF.md` §4–6 were
followed, with the changes noted below.

## 0. One-paragraph summary

3+ person calls run on **our own LiveKit SFU** (Apache-2.0, installed by
`deploy/livekit/install.sh`, not by me); 1:1 stays peer-to-peer. The backend mints LiveKit
tokens only for people of that call, rings invitees (real-time queue + FCM), runs host mute /
remove through LiveKit's RoomService, records join/leave, meters SFU egress into Owner Admin P&L
and respects **"Free calls (testing)"** + the video plan gate. The app loads LiveKit **lazily**
(deferred import), and **every group-call entry is hidden until the server says LiveKit is
installed** (`GET circle/calls/group/config → available`). Screen share (B4) works in 1:1
(flutter_webrtc `getDisplayMedia` + renegotiation) and groups (LiveKit), with a permanent "You are
sharing your screen — Stop" banner; it stays hidden until the manifest proposal is applied.
Recording (B5) is consent-only, server-authoritative, audio-only, encrypted on the requester's
phone.

## 1. What is proven (tests)

### Backend — `backend/core/tests_b3_group.py` (32 tests)
| Area | Tests |
|---|---|
| HS256 JWT (no new dependency): claims (iss/sub/nbf/exp/name/video grant/roomAdmin only for host/metadata), signature, expiry, forged payload, `alg=none` refused, admin token, webhook sha256 | `JwtTests` |
| `canPublishSources` follows the plan: free person in a VOICE room → mic only (SFU-enforced); Free calls ON → + screen share | `test_publish_sources_follow_the_plan` |
| Hidden + 503 when LiveKit isn't configured; owner switch off hides; max participants admin-editable (409 `too_many`) | `NotConfiguredTests`, `OwnerSwitchTests` |
| Add people to a live 1:1: room created, other 1:1 phone gets `call.signal sfu_move`, invitee rings (`call.group_incoming` + incoming list), host token has `roomAdmin` | `test_add_person_moves_both_and_rings_invitee` |
| Token only for members (1:1 parties, invitees, group members); outsider / not-invited 404; removed 403; full 409; ended 410 | `test_token_only_for_members`, `test_room_full`, `…removed_cannot_rejoin`, `…records_participants` |
| Joining ends the P2P call; join/leave records; leave + rejoin while the room lives; room ends when everyone left | `test_joining_ends_the_p2p_call_and_records_participants` |
| Invite more people from inside (only own accepted circle) | `test_invite_more_people_from_inside` |
| Group chat call rings every active member; second "call" joins the live room; non-member refused; decline | `GroupChatCallTests` |
| Video gate: group video / upgrading a video 1:1 = Premium (402) unless "Free calls (testing)" (room marked `free_testing`) | `test_group_video_needs_premium_unless_free_calls`, `test_free_calls_switch_and_video_gate_on_upgrade` |
| Host-only mute (RoomService `MutePublishedTrack`, exact URL/body/admin JWT; track sid looked up via `ListParticipants`, AUDIO default enum handled); LiveKit down → 502 `sfu_error`; host-only remove (`RemoveParticipant`) + removed can't get a token | `HostActionTests` |
| Cost math (streams = N×(N−1) audio, V×(N−1) video; bytes; BDT) + metering through join/leave ticks into `sfu_cost` and `turn_monitor.relay_cost` (P&L) + owner price override | `CostMathTests`, `MeteringTests` |
| LiveKit webhook: bad signature 401, good one records the join | `test_webhook_signed_by_livekit` |
| Consent state machine (pure): all must accept; one decline is final; a newcomer pauses until they accept; requester alone never records; stop | `ConsentMachineTests` |
| Consent API: group (prompt events, only requester records, newcomer pauses for everyone, decline blocks, re-request, bad action 422, double request 409) and 1:1 (`record_state` signal both ways, stop, outsider 404) | `RecordingConsentApiTests` |

### App — `app/test/b3_group_test.dart` (30 tests, fake SFU room + fake server)
Group controller: add-people start, join existing room, honest errors (503/402/409/410/403/
network, SFU unreachable, mic denied), tiles (me first, ringing invitee, mic badge), active
speaker (loudest → last speaker → screen share wins), grid shape (1 / 2×2 / 3×3 / pages), host
mute/remove (member cannot; failure notice), server events (muted by host, removed, ended),
leave + rejoin, SFU reconnect / kicked, screen share (consent declined = nothing; accepted =
published + `media` event; hidden when unsupported). Recording: all accept → only the requester's
engine starts; one decline → nothing; newcomer → pause (agreed part saved) → resume; the person
asked answers through the server; group `record` events drive the engine; consent card + red
banner widgets. 1:1: `sfu_move`, `record_state` (ending the call finishes the file), screen share
in a voice call (plan gate first — consent never asked when refused — then `screen_start`,
renegotiation, `media{screen:true}`, stop), remote screen flag. Screens: **add person** from a
live 1:1 (More → Add people → picker → group room with the 1:1 controller handed over), More
hidden when group calls aren't installed, picker (exclude, max), group grid / active-speaker ring
/ host menu mute / speaker view, member has no host menu, remove asks first, screen-share banner
Stop, consent prompt sends accept, ended screen (honest reason, rejoin only when allowed).

Gallery: `app/test/b3_group_shots.dart` — 18 states × bn/en × light/dark (72 PNGs), and the
dead-button sweep is clean for all of them.

## 2. Choices (and why)

* **Add person = the 1:1 call hands over to the room, then ends.** The host's phone creates the
  room (server checks the 1:1 is live), the other 1:1 phone receives `sfu_move`; each phone opens
  the group call screen with the 1:1 controller as a *handover*: the P2P call keeps running
  until that phone is connected to the SFU, then it is hung up (the server also ends it on
  `joined`). So the overlap is "both", never "nobody" (≈1 s while LiveKit connects). Simpler and
  more robust than renegotiating the P2P peer into the SFU.
* **Minimal JWT** (HS256, 60 lines, tested) instead of the `livekit-api` package — no new
  backend dependency.
* **Recording is audio-only**: two flutter_webrtc `MediaRecorder`s (microphone + what the phone
  plays = everyone else) → two M4A tracks that play together. Video recording of a WebRTC call is
  not reliable across Android OEMs, so it is not offered. Files are ChaCha20-Poly1305-encrypted
  (per-file random key in `SecretStore`, with its fallback), plaintext deleted at once, never
  uploaded. Share decrypts to the cache for the share sheet, then wipes.
* **Group call encryption wording is honest**: "Encrypted on the way · through Assisto's call
  server" (DTLS-SRTP to our SFU; the SFU itself can technically see media). LiveKit E2EE
  (insertable streams with a shared key) is possible later; not claimed now.
* **Screen share in a VOICE call/room** needs the video entitlement (same gate as switching to
  video; SFU-enforced via `canPublishSources`); "Free calls (testing)" lifts it.
* **The livekit_client audio side effect** (it switches flutter_webrtc's audio routing off at
  every launch) is undone natively and handed to LiveKit only during a group call — see
  `.phaseB/proposals/b3-group.md` §3.
* The old group-chat header call buttons were a showpiece ("Group call starting…" and nothing
  happened). They are now real group calls, and **hidden** (with the menu's "New group call")
  until LiveKit is installed.

## 3. Owner tests on real phones (after install + a build with this branch)

Use 3 phones (A, B, C) that are in each other's My Circle; D = a 4th person if available.

1. **1:1 still fine (LiveKit side effect check):** A calls B (voice). Speaker button → speaker;
   connect Bluetooth earbuds → the picker shows Bluetooth and it really moves the sound. Repeat
   once after a group call has ended on that phone.
2. **Add person:** A↔B voice call. A: **More → Add people** → pick C → C's phone rings "A invites
   you to a group call" (open app: full screen; closed app: notification → tap → ring screen).
   A and B must keep hearing each other while it switches (~1 s). C taps **Join** → 3 tiles; the
   person speaking gets a cyan frame.
3. **Group chat call:** in a circle group chat, the phone + camera icons appear (only after
   LiveKit is installed). Tap the phone icon → every member rings. Tap video as a free account
   with Free calls OFF → "needs Premium"; with Free calls ON → works.
4. **Grid / speaker view:** with 4+ people the grid is 2×2, 5+ → 3×3, more than 9 → swipe
   pages. Top-right icon → speaker view (big active speaker).
5. **Host:** A (host) taps B's tile → **Mute B** → B's mic turns off and B sees "The host muted
   you"; B can unmute himself. **Remove C** → confirm → C's call ends "The host removed you";
   C cannot rejoin.
6. **Leave / rejoin:** B taps the red button → "You left the call" → **Rejoin** works while
   others are still in. When everyone leaves, the room ends.
7. **Screen share** (needs the manifest proposal applied): in a call, **More → Share screen** →
   Android asks "Start recording or casting?" → Start → red "You are sharing your screen — Stop
   sharing" banner + an ongoing notification; the others see your screen (1:1: full view with
   "A is sharing their screen"; group: your tile + speaker view). Stop from the banner. Test on
   Android 14/15/16 (Samsung, Xiaomi, Realme/OPPO, vivo) and once on Android 9–11.
8. **Recording consent:** A: **More → Record call → Ask everyone**. B and C each see "A wants to
   record this call" with Allow / Don't allow. Only when both Allow → red "Recording" banner on all
   phones. C taps Don't allow on a new request → "Not everyone agreed, so recording is off", nothing
   saved. With recording on, D joins → recording pauses until D allows.
9. **Recordings:** A → Calls history → the waveform icon → **Call recordings** → play (both voices
   play together), share, delete. B/C have no copy.
10. **Unreachable:** stop LiveKit (`sudo systemctl stop livekit`) → joining shows "Group calls are
    not available right now"; start it again → Rejoin works. Owner Admin → Call relay → untick
    "Group calls on" → the buttons disappear (after ≤10 min or app restart).
11. **P&L:** after a few group calls, Owner Admin → P&L / Call relay → "Group calls (SFU)" row
    with calls, person-minutes, GB and ৳ (free-testing share shown separately).

## 4. Integrator: install LiveKit
See `deploy/livekit/README.md` (bn + en). Short version, on the lifeassisto box after merge +
migrate + deploy:
```bash
cd /home/ubuntu/assisto && sudo bash deploy/livekit/install.sh      # quiet hour: restarts coturn once
curl -s https://api.lifeassisto.com/livekit/                        # -> OK
```
Rollback: `sudo bash deploy/livekit/rollback.sh` (`--coturn` to restore coturn's 65535).
Optional owner action: AWS SG inbound TCP 7881.

## 5. Not done / needs phones
* Everything media-related (LiveKit connect, screen capture, recording quality, audio routing
  hand-over) is proven only with fakes here — it needs the phone steps above (no local Android
  builds, no LiveKit on this box).
* Manifest change for screen share is a proposal (`.phaseB/proposals/b3-group-android-yml.diff`);
  until applied, Share screen stays hidden.
* Group call while the app is minimized: back asks "Leave the call?" (no mini bar / PiP for
  group calls yet).
* A group invite to a phone whose app is closed shows a normal notification (tap → ring screen),
  not the full-screen ring a 1:1 call uses.
* Privacy Policy text is a proposal for the owner: `owner_actions/CALL_RECORDING_POLICY_BN.md`.
