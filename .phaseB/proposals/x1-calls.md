# x1-calls — live-box steps for the integrator (calls fix, owner order A1/A3/A4)

## 0. Root cause (A1-a) — evidence, file:line in the pre-fix tree (5d5fee4)

1. `app/lib/screens/circle_chat_screen.dart:966` (`_placeCall`) POSTed
   `/circle/<member>/call` as a "video gate pre-check" (`_api.circlePlaceCall`),
   then `:978` pushed `CircleCallScreen`, whose controller POSTed the SAME call
   again at `app/lib/calls/call_controller.dart:316`
   (`signaling.place(...)`). Same in `_newGroupCall` (`:1294` + `:1303`).
   -> every tap = 2 POSTs ~0–1 s apart from the same phone (nginx log), 201 both.
2. Server `backend/core/views_c2_calls.py:429-434` (`place_call`): the 2nd
   POST found the 1st record live for the callee -> `is_busy()` (`:124`, any
   live row counted, even a ringing one with the SAME caller) -> ended
   `busy` by the server (the #17/#13/#24/... rows).
3. That busy end is in `MISSED_REASONS` (`core/logic/call_signal.py:58`) ->
   `end_call` sent a "Missed call" push + log row to the callee
   (`views_c2_calls.py:177,189`) -> 6–7 identical Missed rows.
4. The caller's call SCREEN was attached to the 2nd (busy) record -> showed
   "Busy — on another call"; it never opened media for the 1st record, so no
   offer/ICE ever existed for it. The callee's phone rang for the 1st record;
   Accept -> waited for an offer that never came -> "Connecting…" forever, and
   no TURN allocation was ever requested (coturn log empty, relayed=False).
   Repeated taps (07:25:53/55/57/58, 07:34:11/12/26/27/28…) = the same pattern
   per tap; when both people dialled, `call_runtime.dart:158` also answered the
   incoming one with an automatic `busy`.
5. Separately (integrator): coturn `user-quota=6` made allocations fail with
   486 after a few attempts — fixed live (40/400).

Fixes: the pre-check POST is gone (the call screen's single placement runs
the same server gate and shows the upgrade screen); `CallController.start()`
runs once; one live call screen at a time (`CallRuntime.acquireScreen`); every
placement carries `client_call_id` and the server returns the existing live
call for a repeat (key match, or same caller->callee within 60 s, under a row
lock); glare merges into the peer's call (auto-accepted); busy only when the
callee has a call with media connected and both heartbeats < 15 s; a callee
"busy" event is ignored unless that is true.

Nothing here was applied by the agent. Apply in this order. Every step is
reversible; none touches Asalify.

## 1. Backend deploy (with the merge)

1. Migration `core/migrations/0060_x1_calls.py` (adds
   `CallSession.client_call_id`, indexed, default ""). Re-chain its
   `dependencies` to the latest migration at merge time. Additive only.
2. One-time cleanup of stale live call rows left by the double-start bug
   (no pushes, no missed-call alerts are sent for these):

   ```
   cd /home/ubuntu/assisto/backend
   ../.venv/bin/python manage.py calls_cleanup_stale            # DRY RUN: lists rows
   ../.venv/bin/python manage.py calls_cleanup_stale --apply    # ends them
   ```
3. Cron, every minute (append to `/etc/cron.d/assisto-app`):

   ```
   * * * * * ubuntu cd /home/ubuntu/assisto/backend && /home/ubuntu/assisto/.venv/bin/python manage.py calls_sweep >/dev/null 2>&1
   ```
   The sweep also runs lazily on every call event and poll. The cron makes
   sure a call whose two phones both vanished still ends (ringing max 45 s,
   accepted but not connected 20 s, no heartbeat 15 s).
4. `systemctl restart assisto.service` (normal deploy).

## 2. coturn: TURN over TLS on 5349 (A1-b) — DONE by the integrator (22 Oct)

The integrator reports coturn now listens on TLS 5349 with a valid Let's
Encrypt cert for turn.lifeassisto.com (renewal hook installed, ufw open) and
raised `user-quota=6` -> 40 / `total-quota=400` (the old quota made every
allocation fail with "486 Allocation Quota Reached" after a few attempts).

Backend side (this branch): `TURN_TLS_PORT` now DEFAULTS to 5349, so
`GET /rtc/turn` and the call `ice` list
`turn:…:3478?transport=udp`, `turn:…:3478?transport=tcp`, then
`turns:turn.lifeassisto.com:5349?transport=tcp` LAST. Set `TURN_TLS_PORT=0`
in `backend/.env` to stop offering it. (Shop Box live view is unchanged.)

App side: `iceCandidatePoolSize` 2 -> 0 (each pooled set held an extra TURN
allocation), and the peer connection is closed on every end path, including
an end that arrives while the mic / peer is still being created.

`no-tcp-relay` — keep it: it only disables RFC 6062 TCP relay allocations
to peers, which WebRTC never uses; TURN over TCP/TLS transport still works.

Optional, for the next real-phone test: `verbose` in turnserver.conf logs
every allocation (remove once calls are proven).

## 3. AWS security group (the owner must do this in the AWS console)

Run the manual workflow **"TURN probe"** (`.github/workflows/turn-probe.yml`)
first: it tests from OUTSIDE AWS and prints which of these are blocked. The
inbound rules needed on the instance's security group (source `0.0.0.0/0`,
also `::/0` if IPv6 is enabled):

| Type        | Protocol | Port range  | Why                                  |
|-------------|----------|-------------|--------------------------------------|
| Custom UDP  | UDP      | 3478        | STUN + TURN over UDP                 |
| Custom TCP  | TCP      | 3478        | TURN over TCP                        |
| Custom TCP  | TCP      | 5349        | TURN over TLS (coturn ready; SG still closed) |
| Custom UDP  | UDP      | 49200-49300 | relayed media (coturn min/max-port)  |

ufw already allows all four (5349/tcp added by the integrator).

**For the owner (Bangla):**

> AWS কনসোল → EC2 → Instances → আমাদের সার্ভার (16.4.105.173) → Security →
> Security group → "Edit inbound rules" → "Add rule" দিয়ে এই চারটি নিয়ম যোগ
> করুন, Source সব ক্ষেত্রে 0.0.0.0/0:
> ১) Custom UDP, পোর্ট 3478 ২) Custom TCP, পোর্ট 3478 ৩) Custom TCP, পোর্ট
> 5349 ৪) Custom UDP, পোর্ট রেঞ্জ 49200-49300। তারপর "Save rules" চাপুন।
> এগুলো না থাকলে অনেক মোবাইল নেটওয়ার্কে কল "সংযোগ হচ্ছে…"-তে আটকে থাকে।

## 4. GitHub (manual workflows + secrets)

Secrets (repo → Settings → Secrets and variables → Actions):

| Secret                   | What                                                     |
|--------------------------|----------------------------------------------------------|
| `CALL_PROOF_A_PHONE`     | test account A phone (login id)                          |
| `CALL_PROOF_A_PASSWORD`  | test account A password                                  |
| `CALL_PROOF_B_PHONE`     | test account B phone                                     |
| `CALL_PROOF_B_PASSWORD`  | test account B password                                  |
| `TURN_STATIC_SECRET`     | optional: only if the probe should mint its own TURN creds when no test account works |

The two test accounts must be accepted My Circle members of each other
(A has B in their circle and B has A). Calls between them are normal calls:
they show in their own call logs only.

Workflows (both `workflow_dispatch`, need the gh `workflow` scope to push):
* `.github/workflows/turn-probe.yml` — reachability of UDP/TCP 3478, TLS
  5349, relay allocation + relay port range, from the GitHub runner.
* `.github/workflows/call-proof.yml` — two real clients (Python aiortc) place
  a call through the live API + live TURN, answer, send audio both ways for
  30 s, hang up; once forced-relay, once direct. Results table in the job
  summary (connect time, relay used, packets/bytes both ways, hang-up
  latency, PASS/FAIL); the job is red if a run fails. Input `runs`
  (default `relay,direct`) also accepts `relay-tcp` and `relay-tls`
  (TURN over TLS 5349 forced — run it once the security group has TCP 5349).
  API base default: `https://api.lifeassisto.com/api/v1`.
  `.github/workflows/turn-probe-quick.yml` (integrator's, on main) can stay;
  `turn-probe.yml` adds TLS 5349, relay port-range and a summary table.

## 5. Real-time signalling: why no WebSocket process (A1-c)

Decision: **not now**. A separate ASGI WebSocket process would need a new
pubspec dependency (`web_socket_channel`), a second systemd service, an
nginx `Upgrade` location and Postgres LISTEN/NOTIFY wiring — too much risk
for an emergency build, and it is not what broke the calls (the double start
was). What ships instead:

* call-time polling at **0.3 s** (was 0.5 s) while a call is being set up or
  live — offer/answer/ICE/hang-up arrive in ~0.3–0.6 s incl. the round trip;
* a backlog fetch filtered by `call_id`, so the callee always gets the
  caller's pre-sent offer at once (it could be pushed past the 200-event
  batch before);
* a **high-priority FCM data push `call_signal`** (ids only, no SDP, no
  names) to the other phone for offer / answer / ICE-restart / end, which
  makes a slow (Doze / backgrounded) phone poll immediately;
* early ICE candidates and offers that arrive before the peer connection
  exists are queued and replayed in order; ICE restart on failure (also one
  restart before the first connect).

If a later build wants WebSocket, the shape is: `deploy/rt_ws/app.py`
(Starlette + uvicorn, token auth via DRF token table, `LISTEN rt_event` on
Postgres, a trigger `NOTIFY rt_event, user_id` on RtEvent insert), unit
`assisto-rt.service` on 127.0.0.1:8710, nginx
`location /ws/ { proxy_pass http://127.0.0.1:8710; proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection
"upgrade"; proxy_read_timeout 1h; }`, and the app's
`PollRealtimeTransport` gains a WebSocket mode with the HTTP poll as
fallback. Not implemented in this branch.

## 6. What the owner should test on the two phones (after the build ships)

1. BOTH phones on the new build (the live log showed
   `POST /circle/5/call/answer` — no code in this tree calls that endpoint,
   so one phone may still run an older APK).
2. Call 3 → 20: caller sees Calling → Ringing; callee rings ONCE (one row);
   Accept → "Connected" + timer in ~2–3 s.
3. Both press call at the same moment → ONE call connects (never "Busy").
4. Switch one phone to airplane mode after Accept → both phones show
   "Couldn't connect — check internet" within 20 s, with "Call again".
5. Miss 3 calls in a row → one notification "Name (3)" and one call-log row
   "Name (3)", with the caller's photo.
