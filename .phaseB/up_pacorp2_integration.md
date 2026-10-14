# PA CORPORATE tier — integration note (SPEC v2.1 §14 #119 + #120)

Extends PA Secretary Mode with the CORPORATE-tier pair, built to Section-21
ADVANCED as deterministic/mock (works with no key) + honest "connect a key"
seams. Everything below is additive. Nothing listed in the "do not touch" set
was modified (api.dart, core/models.py, core/urls.py, sidebar, app_*.arb,
migrations, Flutter builds, pa_hub_screen.dart, Asalify).

## New files

Backend (pure logic, no Django/DB/network/clock/AI/booking):
- `backend/core/logic/pa_biztravel.py` — #119 engine (event/attendee/agenda/
  budget/task assembly, day-span, passed-in-`now` countdown, attendee rollup,
  budget est-vs-actual-variance, checklist %, chronological ordering,
  `booking_seam()`).
- `backend/core/logic/pa_biztravel_tests_snippets.py` — 17 plain-assert tests.
- `backend/core/logic/pa_projects.py` — #120 engine (project/milestone/risk
  normalize+validate, `is_overdue`/`days_to_due` from a passed-in `now`,
  `classify_project` → one health bucket, `portfolio_summary`,
  `status_synthesis_seam()`).
- `backend/core/logic/pa_projects_tests_snippets.py` — 17 plain-assert tests.

Flutter (ZERO Bangla literals; every string is an AppLocalizations getter; ৳
is the only non-ASCII glyph used, and it is exempt):
- `app/lib/screens/pa/biz_travel_events_screen.dart` — #119 screen.
- `app/lib/screens/pa/project_tracking_screen.dart` — #120 screen.

ARB:
- `.phaseB/up_pacorp2_arb.json` — 129 keys × {en, bn} + `placeholders_meta`
  for the 19 parameterised keys.

## Wiring already applied in this change set

1. `backend/core/views.py` — added 4 names to `GENERIC_COLLECTIONS` (the
   `type()` loop auto-creates the ViewSets; **no migration**, reuses the
   `PaCollectionItem` flexible per-user JSON store + flatten serializer):
   `"pa/bizevents"`, `"pa/bizattendees"`, `"pa/projects"`, `"pa/milestones"`.
2. `backend/core/tests.py` — added the two snippet TestCases next to the other
   `_make_snippet_case(...)` lines:
   ```python
   PaBizTravelSnippetTests = _make_snippet_case(
       "core.logic.pa_biztravel_tests_snippets", "PaBizTravelSnippetTests")
   PaProjectsSnippetTests = _make_snippet_case(
       "core.logic.pa_projects_tests_snippets", "PaProjectsSnippetTests")
   ```

## Remaining integrator steps

### A. Merge ARB + codegen
Merge `up_pacorp2_arb.json` `en` → `app/lib/l10n/app_en.arb`, `bn` →
`app/lib/l10n/app_bn.arb`, and the `placeholders_meta` @-blocks into
`app_en.arb` (this project keeps @-metadata in app_en.arb only). Then run
`flutter gen-l10n` / build. Until this merge the two new screens show analyzer
errors "getter X isn't defined for AppLocalizations" (160 of them, ALL of that
one kind — verified; no other analyzer issues exist in the new files).

### B. pa_hub_screen.dart tiles (ready to paste — integrator applies; I did not edit it)
Add two imports:
```dart
import 'biz_travel_events_screen.dart';
import 'project_tracking_screen.dart';
```
Add two `_PaTool` tiles to the `tools` list (suggest after `paResearchTitle`):
```dart
      _PaTool(Icons.groups_3_outlined, t.paBizTitle,
          (_) => const BizTravelEventsScreen()),
      _PaTool(Icons.account_tree_outlined, t.paProjTitle,
          (_) => const ProjectTrackingScreen()),
```
Tile **title ARB keys** (reused by the hub tile, exactly like every other PA
tile reuses the destination's title getter): `paBizTitle`, `paProjTitle`.

## Collection paths + row shapes (generic REST collection pattern)

All four go through `listItems/createItem/updateItem/deleteItem` (existing
api.dart helpers — untouched). Rows round-trip as `{id, ...data}`.

### `pa/bizevents` — #119, mixed rows tagged by `kind`
```
{id, kind:'event',  name, date, end, venue, city, note}
{id, kind:'agenda', event_id, title, at, speaker, note}
{id, kind:'budget', event_id, label, category, estimated, actual}
{id, kind:'task',   event_id, label, done}
```
- `category` ∈ travel|venue|lodging|catering|materials|other (else → other).
- `estimated`/`actual` are MANUAL ৳ numbers the PA typed; coerced ≥ 0.

### `pa/bizattendees` — #119, attendee + per-person travel, linked by `event_id`
```
{id, event_id, name, role, mode, from_place, depart, ref, status, cost, note}
```
- `mode` ∈ flight|train|car|bus|launch|local (else → local).
- `status` ∈ pending|booked|confirmed|cancelled (else → pending).
- `ref` is a reference the PA/agent already booked (never ours). `cost` is a
  MANUAL ৳ estimate; the engine holds no money.

### `pa/projects` — #120, mixed rows tagged by `kind`
```
{id, kind:'project', name, owner, status, percent, due, note}
{id, kind:'risk',    project_id, label, severity, status, note}
```
- project `status` ∈ planned|active|on_hold|done|cancelled (else → planned);
  `percent` clamped 0..100.
- risk `severity` ∈ low|med|high (else → med); `status` ∈ open|closed
  (else → open).

### `pa/milestones` — #120, milestone rows linked by `project_id`
```
{id, project_id, title, date, status, note}
```
- `status` ∈ pending|done|missed (else → pending).

## Honest seams (deterministic; `{required, mock}`; never fabricate)

- **#119 live booking** — `pa_biztravel.booking_seam(query)` →
  `{action:'book', query, results:[], required:True, mock:True,
  marker:'booking_seam'}`. UI card `_BookingSeamCard` ("connect a booking key —
  nothing is booked here"). The engine NEVER invents a flight/price/PNR; every
  ৳ figure is a value the PA typed; a `paBizBudgetDisclaimer` line restates
  this below the budget and in the printable summary. Wire to a real booking
  provider when a `booking` key exists — the returned shape is the contract.
- **#120 AI status synthesis** — `pa_projects.status_synthesis_seam(project,
  milestones, risks)` → `{action:'status_synthesis', facts:{...}, text:"",
  required:True, ai_required:True, mock:True, marker:'ai_review'}`. UI card
  `_AiSeamCard` ("written status update needs an AI key"). `facts` is exactly
  the deterministic data the real model would summarise — the request shape
  mirrors `core.ai.generate` (see `backend/core/integrations.py` `anthropic`).
  The engine NEVER fabricates a narrative; the pure `portfolio_summary` roll-up
  is always available key-free.

## Determinism / parity

The Dart screens mirror the Python engines exactly:
- #119: inclusive `day_span` (single-day = 1), passed-in-today countdown,
  budget estimated/actual/variance + grand estimate (+ attendee travel sum),
  checklist %, attendee rollup (confirmed/pending), chronological ordering
  (undated last).
- #120: `is_overdue`/`days_to_due` from today's date, `classify_project` into
  one of overdue|at_risk|on_track|done|cancelled (overdue beats at_risk;
  at_risk = open-high-risk OR missed-milestone), weighted-by-count average %
  over OPEN projects only, worst-health-first ordering.

## Honest states / polish

Welcome (no events/projects), loading (`SkeletonList`), error (`StateMessage` +
retry) on both. All text via getters; list/tile text uses `maxLines` +
`TextOverflow.ellipsis` so nothing clips at 360dp. Brand palette
(cyan→blue→purple) + theme tokens (`Gap`/`Radii`/`Brand`) reused; no bottom nav.

## Tests

- `pa_biztravel_tests_snippets.py`: 17 tests.
- `pa_projects_tests_snippets.py`: 17 tests.
- Total 34, folded into `core/tests.py` via `_make_snippet_case`. Verified:
  both snippet suites pass standalone AND all 34 wired TestCase methods pass
  when invoked through `core.tests` (the sandbox cannot CREATE the test DB, but
  these cases are pure-logic and need none; `flake`-free pure stdlib).

## Confirmation

- Files created: 7 (2 backend engines, 2 backend test-snippets, 2 Flutter
  screens, 1 ARB json). Plus 1 integration note (this file).
- Edits: `core/views.py` (+4 collection names), `core/tests.py` (+2 snippet
  cases). Nothing in the do-not-touch set.
- ARB keys: **129** (× en + bn), 19 parameterised.
- Tests: **34** (17 + 17).
- ZERO Bangla literals in either .dart file (grep over U+0980–U+09FF, ৳ exempt,
  returns NONE for both screens).
