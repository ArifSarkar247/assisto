# up_calls — Connected Circle CALLS reviewer-pass to Section-21 "advanced"

Features **#89 Voice call** (FREE on all plans) and **#90 Video call** (PREMIUM,
caller-pays, server-gated). This was a reviewer-pass, **not a rebuild** — the
screens, widgets, backend logic, model, endpoints and self-tests already
existed and were already close to advanced. The pass closed the remaining
Section-21 gaps: the `reconnecting` call-flow state, a **live call-duration
clock**, honest **failed + retry** handling, and an honest **SFU/TURN relay
seam** (no fabricated media stream).

The video gate stays **server-authoritative** in `circle_calls.can_place_call()`
and is only *surfaced* in the UI (locked state + upgrade/points CTA for free
callers); it is never bypassed client-side.

## Files changed

| File | Change |
|---|---|
| `backend/core/logic/circle_calls.py` | Added `reconnecting` to the FSM (`CALL_RECONNECTING`, `active -> reconnect -> reconnecting`, `reconnecting -> connected/hangup/fail`); added `is_connected()` and `live_status_label()` helpers. Duration still measured answered_at→end, so it survives a mid-call reconnect. |
| `backend/core/logic/circle_calls_tests_snippets.py` | +5 snippet tests (reconnect path, reconnect→fail/hangup, non-terminal-but-connected, duration-survives-reconnect, live-status label coverage). Now 29 tests. |
| `backend/core/views_build61.py` | `CircleCallsView.get()` now also returns a formatted `duration` (via `CC.format_duration`, blank for unanswered) and an explicit `outgoing` flag — the history screen already reads both. |
| `app/lib/screens/circle_call_screen.dart` | Live duration `Timer` (`_fmtElapsed`, digit-only mm:ss / h:mm:ss); `reconnecting` + `failed` states surfaced in `_statusLabel()` and the status row (error icon/color); failure now shows a **Retry** button (`_retry`); offline/relay-unreachable now yields an honest `failed` state instead of fake `ringing`; added the ICE-callback seam methods `_markActive` / `_markReconnecting` / `_markFailed`, exposed as labeled dev affordances the integrator replaces with real `onIceConnectionState` callbacks. |

No change to the forbidden surfaces: `api.dart` helpers, `core/models.py`,
`core/urls.py`, sidebar, `app_*.arb`, migrations, Flutter builds, Asalify.

## New ARB keys (6, all NEW — none parameterized)

Emitted in `/.phaseB/up_calls_arb.json` as `{"key":["<bn>","<en>"]}`:

- `circleCallReconnecting` — "আবার সংযোগ হচ্ছে…" / "Reconnecting…"
- `circleCallFailed` — "কল ব্যর্থ হয়েছে" / "Call failed"
- `circleCallRetry` — "আবার চেষ্টা করুন" / "Try again"
- `circleCallRelayConnected` — "সংযোগ হয়েছে (রিলে)" / "Media connected (relay)"
- `circleCallRelayDropped` — "সংযোগ পড়ে গেছে" / "Media dropped"
- `circleCallRelayFailed` — "সংযোগ ব্যর্থ" / "Media failed"

`_params`: **{}** (empty). The call duration is rendered client-side from
`Duration` with ASCII digits only, so there is no localizable duration string.
The existing live-flow labels (`circleCallRinging`, `circleCallIncoming`,
`circleCallConnecting`, `circleCallActive`, `circleCallEnded`) already exist in
the ARB and are **reused unchanged**.

Fold step: merge `up_calls_arb.json` into `app_en.arb`/`app_bn.arb`, then run
`flutter gen-l10n`. The 6 getters must exist before the Dart compiles (same
convention as every other `up_*` pass).

## Endpoints

No new endpoints. Existing ones (in `core/urls.py`, unchanged) are reused:

- `POST /circle/<id>/call` and `POST /circle/<id>/call/answer` — run the
  server-side video gate (`can_place_call`) and issue the ICE config.
- `POST /circle/calls/<call_id>/event` — advances the CallRecord via
  `finalize_call`. **Now also accepts `reconnect`** (active→reconnecting) and
  `connected` from `reconnecting` (back to active). No view change was needed
  for this — `finalize_call` already routes any event through the FSM.
- `GET /circle/calls` — history; now returns `duration` (formatted) + `outgoing`.

## Model

No new model, **no migration**. `core/models.py:CallRecord` already stores
`kind / state / duration_sec / started_at / answered_at / ended_at`. The
`state` CharField already accepts free-form strings, so `"reconnecting"` needs
no schema change. (If the field were ever constrained by `choices`, the only
change would be adding `("reconnecting","reconnecting")` — documented here per
the "describe, don't add" rule; it is NOT required today.)

## Tests added (backend)

`circle_calls_tests_snippets.py`, folded into Django via the existing
`_make_snippet_case("core.logic.circle_calls_tests_snippets",
"CircleCallsSnippetTests")` in `core/tests.py` (no edit to tests.py needed —
discovery is automatic). **+5 new, 29 total**, all passing:

```
python3 -c "import core.logic.circle_calls_tests_snippets as t; t.run_all()"
# -> circle_calls: 29 tests passed
```

New cases: `test_call_fsm_reconnect_path`,
`test_call_fsm_reconnect_then_fail_or_hangup`,
`test_reconnecting_not_terminal_but_connected`,
`test_duration_survives_reconnect`,
`test_live_status_label_covers_all_states`.

## SFU/TURN wiring seam (the self-hosted step, later)

Honest today: voice/video signalling runs over the relay **while the app is
open**; app-closed ring (push keys) and a production **TURN** relay are
key-gated on infra the owner provisions — `transport_status()` states this and
`CircleCallTransportBanner` shows it. The screen **models** call states and
controls; it does **not** fabricate a media connection.

When flutter_webrtc + the self-hosted SFU/TURN land, wire:

1. In `_start()` (marked `SFU/TURN SEAM`), after the server returns `r['ice']`,
   open the `RTCPeerConnection` with `ice_config(...)` and exchange offer/answer
   through the relay. Attach `RTCVideoRenderer`s; `onSwitchCamera` → the
   renderer's `switchCamera()`; mute/speaker/camera toggle the real tracks.
2. Replace the three labeled dev affordances with real ICE callbacks:
   - `onIceConnectionState == connected` → `_markActive()` (starts the clock,
     POSTs `connected`).
   - mid-call `disconnected`/`checking` → `_markReconnecting()` (POSTs
     `reconnect`; clock keeps running).
   - `failed` (ICE give-up) → `_markFailed()` (POSTs `fail`, stops clock, shows
     Retry).
3. Server flips `CIRCLE_TURN_READY` / `CIRCLE_PUSH_READY` + `CIRCLE_TURN` in
   settings once the SFU/TURN box is live; `ice_config()` then includes the
   TURN server and the banner upgrades automatically.

## Wiring steps

1. Merge `up_calls_arb.json` → `app_en.arb` / `app_bn.arb`; run `flutter gen-l10n`.
2. Deploy backend (`circle_calls.py` + `views_build61.py`); no migration.
3. Run `python manage.py test core` — `CircleCallsSnippetTests` picks up the 5
   new methods automatically.
4. (Later) do the SFU/TURN wiring above.

## Confirmation

- **Zero Bangla literals** in `circle_call_screen.dart`,
  `circle_call_history_screen.dart`, `circle_call_controls.dart`
  (`grep -P '[\x{0980}-\x{09FF}]'` → none). Every user-facing string is an
  AppLocalizations getter.
- Voice (#89): no paywall anywhere — `can_place_call` returns allowed for voice
  on every plan; the UI shows no gate for voice.
- Video (#90): gate stays server-side in `can_place_call`; UI only surfaces the
  locked state + upgrade/points CTA for free callers.
