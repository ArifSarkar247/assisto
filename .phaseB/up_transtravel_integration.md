# Integration — #92 Call & voice-note transcription + #35 Travel planner (§21 ADVANCED, KEY-GATED)

Two NEW advanced features built to the Section-21 standard. Both are fully usable
with NO key (deterministic organiser + manual tools). The key-gated halves
(auto speech-to-text; AI itinerary suggestions; live booking/prices) are HONEST,
DOCUMENTED SEAMS that NEVER fabricate a transcript, a suggestion, a price, or a
booking, and never hold money. No `api.dart` / `core/models.py` / `core/urls.py`
/ sidebar / `app_*.arb` / migration / Flutter-build edits were made.

## New files

Backend pure logic (no Django, no DB, no network, no AI, no clock — all time passed in):
- `backend/core/logic/transcription.py`
- `backend/core/logic/transcription_tests_snippets.py`  (12 plain-assert tests)
- `backend/core/logic/travel_planner.py`
- `backend/core/logic/travel_planner_tests_snippets.py`  (12 plain-assert tests)

Flutter screens (ZERO Bangla literals; ৳ exempt; every string an AppLocalizations getter):
- `app/lib/screens/transcription_screen.dart`
- `app/lib/screens/travel_planner_screen.dart`

ARB + this doc:
- `.phaseB/up_transtravel_arb.json`  (90 NEW keys, 8 parameterized)
- `.phaseB/up_transtravel_integration.md`

## One registration line changed per file

- `backend/core/tests.py` — added `TranscriptionSnippetTests` + `TravelPlannerSnippetTests`
  via `_make_snippet_case(...)` (same pattern as every other snippet case).
- `backend/core/views.py` — appended 5 collection names to `GENERIC_COLLECTIONS`
  (`transcribe/notes`, `travel/trips`, `travel/days`, `travel/budget`,
  `travel/packing`). The `GENERIC_COLLECTION_VIEWSETS` comprehension builds the
  viewsets automatically — NO migration (reuses `PaCollectionItem` flexible
  per-user JSON store + the flatten serializer; each row round-trips as
  `{id, ...data}`). Verified total is now 57 collections and all 5 register.

## Collection paths + row shapes (generic REST-collection pattern)

All via `api.listItems/createItem/updateItem/deleteItem` (already in `api.dart` —
not edited). Rows are user-scoped by `PaCollectionViewSet`.

- `transcribe/notes` → `{id, title, duration(int secs), date("YYYY-MM-DD"),
  audio_ref(String), consent_ack(bool), transcript(String), source(""|"manual"|"auto"),
  notes(String)}`
  - `source` is set by the screen: empty transcript → `""`; non-empty typed text → `"manual"`.
    `"auto"` is ONLY ever set by the integrator's STT executor, never by the screen or by
    `normalize_note`. `normalize_note` additionally forces `""` when transcript is empty
    (can't claim provenance for empty text) and `"manual"` when text exists but source is blank.
- `travel/trips` → `{id, destination, start("YYYY-MM-DD"), end("YYYY-MM-DD")}`
- `travel/days` → `{id, trip_id(int), day(int), title, activities:[{what, place, time}]}`
  (the `activities` list is stored inline in the row's JSON; blank-`what` rows are dropped on save)
- `travel/budget` → `{id, trip_id(int), category(one of transport/stay/food/activities/shopping/other),
  estimate(String BDT amount), actual(String BDT amount)}`
- `travel/packing` → `{id, trip_id(int), label, checked(bool)}`

Child rows (`days`/`budget`/`packing`) carry `trip_id`; the detail screen filters each
collection client-side by `trip_id == trip.id`.

## Key-gated seams + which Integrations keys

All three are DOCUMENTED-ONLY: the pure logic builds the request SHAPE and returns
`ready`/`marker`; it NEVER calls a provider and NEVER fabricates output. The Flutter
screens render a static honest "connect a … key" card (no client-side integration-status
hook exists in `state.dart`, matching the existing `_LiveSeamCard` precedent in
`language_partner_screen.dart`).

| Seam | Logic fn | Integrations key (integrations.py REGISTRY slug) | Honest marker | Never fabricates |
|------|----------|--------------------------------------------------|---------------|------------------|
| Auto speech-to-text | `transcription.transcribe_request(note, has_key)` | `transcription` (Deepgram/Google STT/Whisper) | `stt_needs_key` (UI: `tnSttSeam*`) | transcript text (always `""`) |
| AI itinerary suggestions | `travel_planner.suggest_itinerary_request(trip, has_ai_key)` | `anthropic` (`core.ai.generate`) | `ai_needs_key` (UI: `tvAiSeam*`) | activities/places (`suggestions: []`) |
| Live booking / prices | `travel_planner.booking_request(item, has_booking_key)` | a booking Integration (`provider_integration:"booking"` — not yet in REGISTRY; add when a provider is chosen) | `booking_needs_key` (UI: `tvBookingSeam*`) | price/availability/confirmation (all `None`); holds no money |

Each seam returns `ready=False` with its marker when the key is absent. With a key
present, `ready=True` and the executor performs the real call — but the pure functions
themselves STILL return empty/None results (they are contracts, not providers).

Integrator wiring (future, no migration): route `transcribe_request.payload` to the
STT provider from `integrations.get('transcription')`; route `suggest_itinerary_request.inputs`
to `core.ai.generate`; add a booking REGISTRY entry and route `booking_request.inputs` to it.
Pass `has_key = integrations.is_enabled(<slug>)`.

## Audio capture seam (documented, not invented)

Real microphone / call recording is the DEVICE's job. A `transcribe/notes` row stores
only `audio_ref` (a file name / opaque id) + `duration`; the backend never receives
audio bytes. If a recorder plugin is later added, write its output reference into
`audio_ref` — no logic change needed. Call recording surfaces a `consent_ack` flag
(all-party consent / local law); it never defaults to `true`.

## Tests

- 12 + 12 = 24 plain-assert snippet tests, folded into Django TestCases via the
  existing `_make_snippet_case` registration in `core/tests.py`.
- Standalone: `python3 transcription_tests_snippets.py` and
  `python3 travel_planner_tests_snippets.py` — both print "N tests passed".
- Cover: duration clamp/format, word-count/reading-time, search/stats, source rules
  (never claims auto from empty, forces manual), STT request honesty (no key → marker,
  with key → ready but still no text); poisha money (no drift, negatives clamped),
  inclusive date span, countdown (upcoming/ongoing/past, boundary = ongoing),
  budget estimated-vs-actual + overspent flag, packing %, itinerary counts, and AI +
  booking seams never fabricating.
- `flutter analyze` on both screens: clean except the expected "undefined l10n getter"
  errors that resolve once the ARB is merged. No unused/dead code, no other warnings.

## Sidebar entries (for the integrator — sidebar NOT edited here)

- Transcription (#92) → **Work** or **Daily Life** group. Suggested: Daily Life.
  Route to `const TranscriptionScreen()`. Icon suggestion: `Icons.graphic_eq` /
  `Icons.mic_none`. Label key: `tnTitle`.
- Travel planner (#35) → **Daily Life** group. Route to `const TravelPlannerScreen()`.
  Icon suggestion: `Icons.luggage`. Label key: `tvTitle`.

Both screens are self-contained `StatefulWidget`s that load their own data and need no
constructor args — drop them into the existing nav map exactly like
`MockInterviewScreen` / `LanguagePartnerScreen`.

## ARB (merge step — integrator runs the existing merge script)

`.phaseB/up_transtravel_arb.json`: 90 NEW keys, format `key -> [bn, en]`, Bangla real
& natural, ৳ kept as-is. REUSES (does not redefine) the shared keys `add, cancel,
delete, edit, loadFailed, retry, save`. The 8 parameterized keys are listed under
`_params` — add each to the merge script's PARAMS map so `@`-metadata is generated:
`tvDaysCount{days:int}`, `tvCountdown{days:int}`, `tvOngoing{days:int}`,
`tvPast{days:int}`, `tvItinerarySummary{days:int,activities:int}`, `tvDayN{n:String}`,
`tvPackingProgress{checked:int,total:int}`, `tvBudgetLine{estimate:String,actual:String}`.

## Honesty / hard-rule compliance

- No fabricated transcripts / suggestions / bookings / prices anywhere (verified by tests).
- Honest key-gated "connect a key" states on every seam (3 marker families).
- Deterministic mocks only; all money is integer poisha with no float drift; holds no money.
- Original Assisto identity; bilingual copy; zero Bangla literals in `.dart` (৳ exempt).
- Nothing touched in the forbidden list (api.dart / models.py / urls.py / sidebar /
  app_*.arb / migrations / Flutter builds / Asalify).
