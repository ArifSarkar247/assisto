# Integration note — #15 Voice mood sensing + #6 Proactive AI (§21 ADVANCED)

Two new AI-core surfaces built to the Section-21 advanced standard.

- **#15 Voice mood sensing** — an OPT-IN, ON-DEVICE, NON-CLINICAL wellness
  check-in. No audio leaves the device, no server, no AI key. Deterministic mood
  log + 7-day trend + gentle supportive (non-clinical) suggestions. Never
  diagnoses; shows a helpline pointer when the recent trend is persistently low.
- **#6 Proactive AI** — a proactive-suggestions digest. DETERMINISTIC rules over
  the user's OWN data (the existing server alert builder + reminders +
  subscriptions) surface grouped nudges, each dismissable + "why am I seeing
  this". Built on `watch_feed.py`; never fabricates. AI-personalised proactivity
  is a documented key-gated seam.

Nothing in `api.dart`, `core/models.py`, `core/urls.py`, the sidebar,
`app_*.arb`, migrations, or Asalify was touched.

---

## 1. Files created / edited

### Backend (`backend/core/`) — all NEW, pure, deterministic
- **ADDED** `logic/voice_mood.py` — pure engine: `validate`, `fold_by_day`,
  `trend(rows, today)`, `suggestions(mood, persistently_low)`,
  `check_in(...)`. No Django, no DB, no network, **no clock** (today passed in),
  **no AI, no audio**. Carries honest markers (`marker="mood_self_report"`,
  `mock=False`, `on_device=True`, `ai_required=False`). Civil-date arithmetic
  (`_day_index`/`_iso_from_index`) avoids importing `datetime`.
- **ADDED** `logic/voice_mood_tests_snippets.py` — 13 plain-assert checks.
- **ADDED** `logic/proactive_ai.py` — pure engine built on `watch_feed`:
  `suggestion_id`, `epoch`, `is_dismissed`, `reason_key`, `to_suggestion`,
  `digest(signals, dismissed)`, `ordered(...)`. Maps watch_feed groups →
  urgency buckets (`now`/`soon`/`fyi`), carries stable ids + dismissal epochs +
  reason keys. `marker="proactive_rule"`, `ai_required=False`, never fabricates.
- **ADDED** `logic/proactive_ai_tests_snippets.py` — 11 plain-assert checks.
- **EDITED** `core/tests.py` — two lines via the existing `_make_snippet_case`
  helper (`VoiceMoodSnippetTests`, `ProactiveAiSnippetTests`), placed next to
  `WatchFeedSnippetTests` / `AiInboxSnippetTests`. No other test touched.

### Flutter (`app/lib/screens/`) — all NEW
- **ADDED** `voice_mood_screen.dart` — opt-in gate → welcome → check-in sheet →
  today card + 7-day trend + supportive suggestions + (conditional) helpline
  card. On-device `_Mood` class is a VERBATIM mirror of `voice_mood.py`.
- **ADDED** `proactive_ai_screen.dart` — composes read-only signals, runs the
  `_Pro`/`_Sug` mirror of `proactive_ai.py`, renders urgency-grouped dismissable
  nudges with "why am I seeing this". Deep-links via `ChatNav.push`.

> Zero Bangla literals in either .dart (verified: 0 chars in U+0980–U+09FF).
> Every user-facing string is an `AppLocalizations` getter. The only non-ASCII
> literals are mood emoji (😢😕😐🙂😄), which are not Bangla.

---

## 2. New ARB keys — emit file `up_moodproactive_arb.json`

- **85 new keys**, each `[bn, en]`. Bangla is real + natural.
- Shared keys reused (already in `app_*.arb`, NOT re-emitted): `cancel`,
  `delete`, `save`, `retry`, `loadFailed`, `saveFailed`.
- **6 keys carry placeholders** (metadata in the ARB's `_params` block):
  - `moodEnergyValue(value:int, max:int)`
  - `moodTrendSummary(logged:int, days:int)`
  - `proWhenInDays(days:int)`
  - `proWhenOverdue(days:int)`
  - `proEmptyDismissed(count:int)`
  - `proHiddenCount(count:int)`

Prefixes: `mood*` (#15, 52 keys) and `pro*` (#6, 33 keys). Merge into
`app_bn.arb` / `app_en.arb` with the existing merge script, then regen
localizations (NOT done here — ARB/build untouched per constraints).

---

## 3. Collections — paths & shapes

### #15 Voice mood — **ON-DEVICE SharedPreferences only** (no collection, no DB)
Privacy is the whole point, so mood data NEVER touches the server.
- `mood_optin_v1` (bool) — explicit opt-in flag.
- `mood_logs_v1` (String, JSON list) — rows hold **only**:
  `{id:int (client millis, ordering), mood:'low'|'down'|'ok'|'good'|'great',
    energy:int 0–5 (0 = not rated), date:'YYYY-MM-DD'}`.
  **No audio, no transcript.** One row per day (today's row is replaced on
  re-check-in — latest wins, mirroring the backend fold). "Delete all" / "Turn
  off" clears both keys. **Integrator: nothing to add to GENERIC_COLLECTIONS.**

### #6 Proactive AI — reads existing data + persists dismissals
- **Reads** (existing endpoints, best-effort, no new API): `alertsList()`
  (`/alerts` cross-module builder — bills/loans/refill/family/journey/budget/
  birthday), `listItems('reminders')`, `listItems('subscriptions')`. Nothing is
  invented; a source with no signal contributes nothing.
- **Persists dismissals** to generic collection **`proactive/dismissed`**, rows:
  `{sid:string (stable id "kind:ref"), epoch:string (due date or week, '' if
    sticky)}`. A dismissal only hides the SAME `epoch`, so a new due date / week
  re-surfaces the nudge.
  **Integrator: add `"proactive/dismissed"` to `GENERIC_COLLECTIONS` in
  `backend/core/views.py`** (one string; `PaCollectionItem` flexible store — NO
  migration). Suggested placement next to `"saved/items"`:
  ```python
  # #6 Proactive AI — dismissed-nudge bookkeeping {sid, epoch}
  "proactive/dismissed",
  ```

---

## 4. Seams (honest, documented — not built)

- **#15**: there is NO AI seam by design — it is on-device + key-free. (Any
  future on-device audio-energy *measurement* would still never leave the phone
  and would only populate the same `energy:int` field.)
- **#6**: AI-personalised proactivity is the `core.ai.generate` seam. The
  request shape is the signal list `digest()` already consumes; the real-AI path
  would only **re-order / re-phrase** nudges from the user's own patterns, never
  fabricate one. Current rule path carries `ai_required=False`; the honest note
  card tells the user AI personalisation turns on when a key is added.

---

## 5. Safety / honesty markers

- **#15 never diagnoses.** Opt-in gate states "not a medical/mental-health
  service" (`moodOptInPoint4` / `moodSafetyNote`). Suggestions are
  everyday/supportive only (`moodSuggestionsNote`). When the 7-day trend is
  persistently low (avg mood score ≤ 2.0 over ≥ 3 logged days — one bad day
  never trips it) a non-alarming helpline card appears (`moodHelplineBody`
  points to the Bangladesh national mental-health helpline, toll-free).
- **#15 privacy-forward**: "stays on your device" messaging on the gate, the
  check-in sheet, and a persistent privacy note; one-tap delete + turn-off.
- **#6**: every nudge traces to a real signal; `_HonestNote` labels the rule
  path and the AI seam. Empty state is honest ("nothing needs you right now").

---

## 6. Tests

- `voice_mood_tests_snippets.py` — **13** checks (date normalise/reject, energy
  clamp, day-index roundtrip, validate, fold latest-wins/skip-bad, trend window
  & averages, persistently-low thresholds, low-streak break, suggestion keys +
  helpline, check-in self-inclusion, bad-input problems).
- `proactive_ai_tests_snippets.py` — **11** checks (stable id/ref, epoch,
  reason lookup/fallback, group→urgency, low-sev-upcoming→fyi, far-future drop,
  field trace-back, digest groups/counts/empty, dismissal same-epoch-only,
  is_dismissed, ordered flatten).
- Both runnable standalone:
  `python3 -c "import core.logic.voice_mood_tests_snippets as t; t.run_all()"`
  `python3 -c "import core.logic.proactive_ai_tests_snippets as t; t.run_all()"`
- **24 tests total, all passing.** Wired into the Django suite via the two new
  `_make_snippet_case` lines in `core/tests.py`.

---

## 7. Sidebar / navigation wiring (integrator)

NOT edited here (sidebar is off-limits). Suggested entries:
- **#15 Voice mood → Settings or Daily Life.** Given it is a private, opt-in
  wellness check-in, **Settings → Privacy/Wellness** is the cleanest home, but
  **Daily Life** is also fine. Route a drawer/menu item to
  `const VoiceMoodScreen()`.
- **#6 Proactive AI → Daily Life or Home.** Best surfaced near the Watch Feed
  (it is the proactive sibling). Route to `const ProactiveAiScreen()`. Consider
  a home-screen entry/badge driven by `digest().counts['total']`.

Both screens are self-contained `StatefulWidget`s needing no constructor args;
`ProactiveAiScreen` reads `context.read<AppState>().api` exactly like
`WatchFeedScreen`.
